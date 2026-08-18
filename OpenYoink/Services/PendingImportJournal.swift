import Foundation
import OSLog

/// Crash-recovery journal for files delivered through `NSFilePromiseReceiver`.
///
/// A promised file exists only after the source application has finished
/// writing it into a staging directory. Before moving that file to its final
/// managed URL, OpenYoink records both locations here. The record is removed
/// only after the resulting ShelfItem has been synchronously written to
/// `shelf.json`, which makes every crash window retryable.
final class PendingImportJournal: @unchecked Sendable {
    static let currentSchemaVersion = 1

    struct Record: Codable, Equatable, Identifiable, Sendable {
        /// Stable transaction id; also used as the eventual ShelfItem id so a
        /// crash after shelf persistence but before journal removal is easy to
        /// reconcile without creating a duplicate card.
        var id: UUID
        var stagingPath: String
        var destinationPath: String
        var displayName: String
        var promisedTypeIdentifiers: [String]
        var createdAt: Date
    }

    enum LoadResult: Equatable, Sendable {
        case loaded([Record])
        case missing
        /// Existing but unreadable/unsafe data blocks managed-file cleanup.
        case failed

        var records: [Record] {
            guard case .loaded(let records) = self else { return [] }
            return records
        }

        var permitsOrphanCleanup: Bool {
            switch self {
            case .loaded, .missing: true
            case .failed: false
            }
        }
    }

    enum JournalError: LocalizedError, Equatable {
        case damaged
        case pathOutsideManagedDirectory
        case missingRecord(UUID)

        var errorDescription: String? {
            switch self {
            case .damaged:
                String(localized: "Pending import recovery data is damaged.")
            case .pathOutsideManagedDirectory:
                String(localized: "The pending import points outside OpenYoink's managed storage.")
            case .missingRecord:
                String(localized: "The pending import recovery record is missing.")
            }
        }
    }

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var records: [Record]
    }

    let directoryURL: URL
    let managedDirectoryURL: URL
    private var journalURL: URL { directoryURL.appendingPathComponent("pending-imports.json") }
    private var temporaryURL: URL { directoryURL.appendingPathComponent("pending-imports.json.tmp") }
    private var backupURL: URL { directoryURL.appendingPathComponent("pending-imports.json.backup") }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "PendingImportJournal")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(directoryURL: URL? = nil, managedDirectoryURL: URL? = nil) {
        let support = directoryURL ?? AppDirectories.applicationSupport()
        self.directoryURL = support
        self.managedDirectoryURL = managedDirectoryURL
            ?? support.appendingPathComponent("Materialized", isDirectory: true)
    }

    func loadResult() -> LoadResult {
        withLock { loadResultLocked() }
    }

    /// Creates the durable boundary before the staging payload is moved.
    @discardableResult
    func create(stagingURL: URL,
                destinationURL: URL,
                displayName: String,
                promisedTypeIdentifiers: [String]) throws -> Record {
        try withLock {
            guard isManagedPath(stagingURL), isManagedPath(destinationURL) else {
                throw JournalError.pathOutsideManagedDirectory
            }
            var records = try recordsForMutationLocked()
            let record = Record(
                id: UUID(),
                stagingPath: stagingURL.standardizedFileURL.path,
                destinationPath: destinationURL.standardizedFileURL.path,
                displayName: displayName,
                promisedTypeIdentifiers: promisedTypeIdentifiers,
                createdAt: Date()
            )
            records.append(record)
            try writeLocked(records)
            return record
        }
    }

    /// Changes the reserved destination before a retrying move. The journal is
    /// updated first, so a crash during the following move still names both
    /// possible locations.
    func updateDestination(id: UUID, to destinationURL: URL) throws -> Record {
        try withLock {
            guard isManagedPath(destinationURL) else {
                throw JournalError.pathOutsideManagedDirectory
            }
            var records = try recordsForMutationLocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw JournalError.missingRecord(id)
            }
            records[index].destinationPath = destinationURL.standardizedFileURL.path
            try writeLocked(records)
            return records[index]
        }
    }

    func remove(id: UUID) throws {
        try withLock {
            var records = try recordsForMutationLocked()
            guard records.contains(where: { $0.id == id }) else { return }
            records.removeAll { $0.id == id }
            try writeLocked(records)
        }
    }

    /// Both candidates must survive cleanup: a crash can leave the payload at
    /// either path, and a cross-volume move can briefly leave both.
    func protectedPaths() -> Set<String> {
        guard case .loaded(let records) = loadResult() else { return [] }
        return Set(records.flatMap { [$0.stagingPath, $0.destinationPath] })
    }

    var permitsOrphanCleanup: Bool { loadResult().permitsOrphanCleanup }

    // MARK: - Locked persistence

    private func loadResultLocked() -> LoadResult {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: journalURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion <= Self.currentSchemaVersion,
                  snapshot.records.allSatisfy({ record in
                      isManagedPath(URL(fileURLWithPath: record.stagingPath))
                          && isManagedPath(URL(fileURLWithPath: record.destinationPath))
                  }) else {
                return .failed
            }
            return .loaded(snapshot.records)
        } catch {
            logger.error("Failed to load pending import journal: \(error.localizedDescription, privacy: .public)")
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
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: backupURL)
            return
        }

        let data = try encoder.encode(Snapshot(
            schemaVersion: Self.currentSchemaVersion,
            records: records
        ))
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: journalURL.path) {
            do {
                let previousData = try Data(contentsOf: journalURL)
                _ = try decoder.decode(Snapshot.self, from: previousData)
                try previousData.write(to: backupURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh pending import journal backup: \(error.localizedDescription, privacy: .public)")
            }
            _ = try fileManager.replaceItemAt(journalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: journalURL)
        }
    }

    private func isManagedPath(_ url: URL) -> Bool {
        let root = managedDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
