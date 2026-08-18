import Foundation
import OSLog

/// Crash-recovery journal for managed moves (`Command`-drop).
///
/// A managed move becomes destructive only after the original file is sent to
/// the Trash.  Before that step, `CutMoveService` writes a `.prepared` record
/// containing both the ordinary reference item and the managed-copy item.  If
/// the process exits before the shelf snapshot is committed, the next launch
/// can reconstruct a safe shelf item instead of treating the managed copy as
/// an orphan.
///
/// The journal intentionally lives beside `shelf.json`, but uses an independent
/// envelope and atomic replacement.  All access is serialized by `lock` because
/// managed copies are prepared on a background task while startup/storage
/// recovery runs on the main actor.
final class ManagedMoveJournal: @unchecked Sendable {
    static let currentSchemaVersion = 1

    struct Record: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Equatable, Sendable {
            /// The managed copy exists and the original has not intentionally
            /// been moved yet.
            case prepared
            /// The original was moved to the Trash; the shelf snapshot may not
            /// contain `managedItem` yet.
            case originalTrashed
        }

        /// The managed item's id is also the transaction id.  This makes
        /// reconciliation with an already-persisted ShelfItem deterministic.
        var id: UUID { managedItem.id }

        var state: State
        var referenceItem: ShelfItem
        var managedItem: ShelfItem
        var resultingTrashPath: String?
        var createdAt: Date
    }

    enum LoadResult: Equatable, Sendable {
        case loaded([Record])
        case missing
        /// The file exists but cannot be decoded.  Callers must block managed
        /// orphan cleanup because its protected paths are unknown.
        case failed

        var records: [Record] {
            guard case .loaded(let records) = self else { return [] }
            return records
        }

        var permitsManagedOrphanCleanup: Bool {
            switch self {
            case .loaded, .missing: true
            case .failed: false
            }
        }
    }

    enum JournalError: LocalizedError, Equatable {
        case damaged
        case missingRecord(UUID)

        var errorDescription: String? {
            switch self {
            case .damaged:
                String(localized: "Managed move recovery data is damaged.")
            case .missingRecord:
                String(localized: "The managed move recovery record is missing.")
            }
        }
    }

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var records: [Record]
    }

    let directoryURL: URL
    private var journalURL: URL { directoryURL.appendingPathComponent("managed-moves.json") }
    private var temporaryURL: URL { directoryURL.appendingPathComponent("managed-moves.json.tmp") }
    private var backupURL: URL { directoryURL.appendingPathComponent("managed-moves.json.backup") }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "ManagedMoveJournal")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
    }

    func loadResult() -> LoadResult {
        withLock { loadResultLocked() }
    }

    /// Writes the safety boundary that must exist before the original can be
    /// moved to the Trash.
    func createPrepared(referenceItem: ShelfItem, managedItem: ShelfItem) throws {
        try withLock {
            var records = try recordsForMutationLocked()
            records.removeAll { $0.id == managedItem.id }
            records.append(Record(
                state: .prepared,
                referenceItem: referenceItem,
                managedItem: managedItem,
                resultingTrashPath: nil,
                createdAt: Date()
            ))
            try writeLocked(records)
        }
    }

    /// Marks the destructive step as completed.  A failure to persist this
    /// transition is still recoverable: the durable `.prepared` record plus a
    /// missing source and existing managed copy is treated conservatively on
    /// the next launch.
    func markOriginalTrashed(id: UUID, resultingURL: URL?) throws {
        try withLock {
            var records = try recordsForMutationLocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw JournalError.missingRecord(id)
            }
            records[index].state = .originalTrashed
            records[index].resultingTrashPath = resultingURL?.path
            try writeLocked(records)
        }
    }

    /// Removes a transaction only after its ShelfItem has been synchronously
    /// persisted, or after startup recovery has safely resolved it.
    func remove(id: UUID) throws {
        try withLock {
            var records = try recordsForMutationLocked()
            guard records.contains(where: { $0.id == id }) else { return }
            records.removeAll { $0.id == id }
            try writeLocked(records)
        }
    }

    /// Paths that must survive automatic and user-triggered orphan cleanup.
    func protectedManagedPaths() -> Set<String> {
        let result = loadResult()
        guard case .loaded(let records) = result else { return [] }
        return Set(records.compactMap { $0.managedItem.path })
    }

    var permitsManagedOrphanCleanup: Bool {
        loadResult().permitsManagedOrphanCleanup
    }

    // MARK: - Locked persistence

    private func loadResultLocked() -> LoadResult {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: journalURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            if snapshot.schemaVersion > Self.currentSchemaVersion {
                logger.warning("Managed move journal schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion)")
                return .failed
            }
            return .loaded(snapshot.records)
        } catch {
            logger.error("Failed to load managed move journal: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func recordsForMutationLocked() throws -> [Record] {
        switch loadResultLocked() {
        case .loaded(let records): records
        case .missing: []
        case .failed: throw JournalError.damaged
        }
    }

    private func writeLocked(_ records: [Record]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if records.isEmpty {
            if fileManager.fileExists(atPath: journalURL.path) {
                try fileManager.removeItem(at: journalURL)
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            return
        }

        let snapshot = Snapshot(schemaVersion: Self.currentSchemaVersion, records: records)
        let data = try encoder.encode(snapshot)
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: journalURL.path) {
            // Preserve the previous valid generation.  The backup is a
            // diagnostic fallback; a damaged primary still blocks cleanup.
            do {
                let previousData = try Data(contentsOf: journalURL)
                _ = try decoder.decode(Snapshot.self, from: previousData)
                try previousData.write(to: backupURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh managed move journal backup: \(error.localizedDescription, privacy: .public)")
            }
            _ = try fileManager.replaceItemAt(journalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: journalURL)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Pure decision table used by launch recovery. Keeping filesystem inspection
/// outside the planner makes every crash window explicit and unit-testable.
enum ManagedMoveRecoveryPlanner {
    enum Decision: Equatable, Sendable {
        /// The shelf snapshot already contains one side of the transaction.
        case alreadyCommitted
        /// No managed copy survives, but the source is still reachable.
        case recoverReference
        /// The source can no longer be relied on; restore the durable copy.
        case recoverManaged
        /// Neither source nor managed copy exists. Preserve the journal and
        /// block cleanup so a future/manual recovery remains possible.
        case unresolved
    }

    static func decision(for record: ManagedMoveJournal.Record,
                         sourceExists: Bool,
                         managedExists: Bool,
                         persistedItemIDs: Set<UUID>) -> Decision {
        if persistedItemIDs.contains(record.managedItem.id)
            || persistedItemIDs.contains(record.referenceItem.id) {
            return .alreadyCommitted
        }
        // Once `.prepared` is durable, the copy already contains the user's
        // data. Even if the source path currently exists, it might be a new
        // file created after a crash in the trash-before-state-update window.
        // Prefer the managed copy: a harmless duplicate is safer than deleting
        // the only surviving copy of the original content.
        if managedExists {
            return .recoverManaged
        }
        if sourceExists {
            return .recoverReference
        }
        return .unresolved
    }
}
