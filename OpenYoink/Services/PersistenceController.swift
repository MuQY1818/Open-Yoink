import Foundation
import OSLog

/// Shared locations inside the app's sandbox container.
enum AppDirectories {
    /// `Application Support/OpenYoink` inside the sandbox container.
    static func applicationSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenYoink", isDirectory: true)
    }
}

/// ISO8601 with fractional seconds, used for dates in `shelf.json` so the file
/// stays human-readable and hand-editable.
private func makeShelfDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

/// On-disk envelope for `shelf.json`.
private struct ShelfSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var items: [ShelfItem]
}

/// JSON persistence for the shelf's items.
///
/// Storage is a single `shelf.json` in `Application Support/OpenYoink` (inside
/// the sandbox container). Writes are atomic (temporary file + rename) and
/// debounced: rapid `scheduleSave(_:)` calls coalesce into one disk write.
@MainActor
final class PersistenceController {
    /// Current on-disk schema version. Bump it and add a migration in
    /// `migrate(_:)` when the format changes.
    static let currentSchemaVersion = 1

    /// Directory containing `shelf.json`; inject a custom one in tests.
    let directoryURL: URL
    /// Debounce interval for `scheduleSave(_:)`; inject a small value in tests.
    let debounceInterval: Duration

    /// Number of completed disk writes (diagnostics and tests).
    private(set) var saveCount = 0

    private var shelfFileURL: URL { directoryURL.appendingPathComponent("shelf.json") }
    private var pendingItems: [ShelfItem]?
    private var saveTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "Persistence")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .formatted() requires a DateFormatter, which ISO8601DateFormatter is
        // not a subclass of — encode manually.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeShelfDateFormatter().string(from: date))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // Accept dates with or without fractional seconds (hand-edited files).
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = makeShelfDateFormatter().date(from: string)
                ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return decoder
    }()

    init(directoryURL: URL? = nil, debounceInterval: Duration = .milliseconds(500)) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
        self.debounceInterval = debounceInterval
    }

    // MARK: - Loading

    /// Loads the persisted items. Returns an empty array when the file is
    /// missing or corrupted — the error is logged, never thrown, so a damaged
    /// `shelf.json` can never crash launch.
    func load() -> [ShelfItem] {
        guard FileManager.default.fileExists(atPath: shelfFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: shelfFileURL)
            let snapshot = try decoder.decode(ShelfSnapshot.self, from: data)
            return migrate(snapshot).items
        } catch {
            logger.error("Failed to load \(self.shelfFileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Saving

    /// Schedules a debounced write. Rapid successive calls coalesce into a
    /// single disk write of the most recent value.
    func scheduleSave(_ items: [ShelfItem]) {
        pendingItems = items
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceInterval)
            } catch {
                return // cancelled by a newer scheduleSave or flushPendingSave
            }
            guard !Task.isCancelled, let pending = pendingItems else { return }
            pendingItems = nil
            saveTask = nil
            writeToDiskOrLog(pending)
        }
    }

    /// Writes immediately, bypassing the debounce. Throws on I/O errors.
    func saveNow(_ items: [ShelfItem]) throws {
        saveTask?.cancel()
        saveTask = nil
        pendingItems = nil
        try writeToDisk(items)
        saveCount += 1
    }

    /// Forces any pending debounced save to run now, best-effort
    /// (call from `applicationWillTerminate`).
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let pending = pendingItems else { return }
        pendingItems = nil
        writeToDiskOrLog(pending)
    }

    // MARK: - Internals

    private func writeToDiskOrLog(_ items: [ShelfItem]) {
        do {
            try writeToDisk(items)
            saveCount += 1
        } catch {
            logger.error("Failed to save \(self.shelfFileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Atomic write: encode to a temporary file in the same directory, then
    /// rename it over the target.
    private func writeToDisk(_ items: [ShelfItem]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items)
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent("shelf.json.tmp")
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: shelfFileURL.path) {
            try fileManager.removeItem(at: shelfFileURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: shelfFileURL)
    }

    /// Schema migration hook. v1 is the first schema, so there is nothing to
    /// migrate yet; files written by a newer app version are decoded
    /// best-effort (unknown fields are ignored by the decoder).
    private func migrate(_ snapshot: ShelfSnapshot) -> ShelfSnapshot {
        if snapshot.schemaVersion > Self.currentSchemaVersion {
            logger.warning("shelf.json schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion); decoding best-effort")
        }
        return snapshot
    }
}
