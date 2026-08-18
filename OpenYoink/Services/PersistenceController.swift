import Foundation
import OSLog

/// Shared locations inside the app's sandbox container.
enum AppDirectories {
    /// `Application Support/OpenYoink` inside the sandbox container.
    static func applicationSupport() -> URL {
        // UI automation launches the real app process, so isolate all file
        // mutations from the user's shelf. AppDelegate clears this exact
        // app-owned directory before each UI-test launch.
        if ProcessInfo.processInfo.environment["OPENYOINK_UI_TESTING"] == "1" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkUITests", isDirectory: true)
        }
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
    private var backupShelfFileURL: URL { directoryURL.appendingPathComponent("shelf.json.backup") }
    private static let corruptSnapshotPrefix = "shelf.json.corrupt-"
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

    /// 加载结果（评审 P1 修复）：严格区分「首次启动无文件」与「读取失败」。
    /// 损坏的文件绝不能静默吞掉——AppDelegate 据此决定是否允许清理
    /// Materialized 孤儿文件（加载失败时禁止清理，否则一次坏写就会在
    /// 下次启动时连锁删除全部保管文件）。
    enum LoadResult: Sendable, Equatable {
        /// 成功读取快照（可能为空）。
        case loaded([ShelfItem])
        /// 文件不存在（首次启动/全新状态）。
        case missing
        /// 文件存在但读取/解码失败（已隔离到 shelf.json.corrupt-<时间戳>）。
        case failed

        /// 启动时用于构造 ShelfStore 的项目。失败仍以空架进入 UI，但必须
        /// 保留同一个 LoadResult，不能再次读取后把已隔离文件误判为 missing。
        var items: [ShelfItem] {
            guard case .loaded(let items) = self else { return [] }
            return items
        }

        /// 只有拿到可信快照，或确认从未有快照时，才允许删除未被引用的
        /// Materialized 文件。读取失败时这些文件可能仍被损坏快照引用。
        var permitsMaterializedOrphanCleanup: Bool {
            switch self {
            case .loaded, .missing: true
            case .failed: false
            }
        }
    }

    /// Loads the persisted items. Returns an empty array when the file is
    /// missing or corrupted — see `loadResult()` for the failure-aware variant.
    func load() -> [ShelfItem] {
        loadResult().items
    }

    /// Failure-aware load：missing 与 failed 分开；failed 时把损坏文件改名
    /// 隔离（保留现场供人工恢复），随后按全新空架启动。
    func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: shelfFileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: shelfFileURL)
            let snapshot = try decoder.decode(ShelfSnapshot.self, from: data)
            return .loaded(migrate(snapshot).items)
        } catch {
            logger.error("Failed to load \(self.shelfFileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            quarantineCorruptFile()
            return .failed
        }
    }

    /// Materialized 孤儿清理的最终安全门：本轮读取必须可信，并且磁盘上不能
    /// 留有任何隔离快照。后者必须跨重启生效——损坏文件被移走后，下次读取
    /// 会是 `.missing`；若仅看本轮结果，第二次启动仍会删除所有恢复材料。
    ///
    /// 隔离快照由用户确认恢复/放弃后手工移走；在此之前宁可保留少量孤儿，
    /// 也不能自动破坏可恢复数据。目录读取异常同样按不安全处理。
    func canSafelyCleanupMaterializedOrphans(after result: LoadResult) -> Bool {
        guard result.permitsMaterializedOrphanCleanup else { return false }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return true }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            return !names.contains { $0.hasPrefix(Self.corruptSnapshotPrefix) }
        } catch {
            logger.error("Cannot inspect persistence directory before orphan cleanup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Recovery snapshots

    struct RecoverySnapshot: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case lastKnownGood
            case quarantined
        }

        let url: URL
        let kind: Kind
        let modifiedAt: Date?
        let byteCount: Int64
        /// `false` 的隔离文件仍保留给人工修复，但 UI 不允许用它覆盖当前数据。
        let isRecoverable: Bool

        var id: URL { url }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case invalidSnapshot
        case snapshotIsUnreadable

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                String(localized: "The selected recovery file is not managed by OpenYoink.")
            case .snapshotIsUnreadable:
                String(localized: "This recovery file is damaged and cannot be restored automatically.")
            }
        }
    }

    /// 返回上一份有效快照与所有隔离文件。损坏文件也展示，方便用户在 Finder
    /// 中取回人工修复；只有完整解码成功的条目才标记为可自动恢复。
    func recoverySnapshots() -> [RecoverySnapshot] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            let kind: RecoverySnapshot.Kind
            if url.lastPathComponent == backupShelfFileURL.lastPathComponent {
                kind = .lastKnownGood
            } else if url.lastPathComponent.hasPrefix(Self.corruptSnapshotPrefix) {
                kind = .quarantined
            } else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let recoverable = (try? decodeSnapshot(at: url)) != nil
            return RecoverySnapshot(
                url: url,
                kind: kind,
                modifiedAt: values?.contentModificationDate,
                byteCount: Int64(values?.fileSize ?? 0),
                isRecoverable: recoverable
            )
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func loadRecoverySnapshot(_ snapshot: RecoverySnapshot) throws -> [ShelfItem] {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        do {
            return try decodeSnapshot(at: snapshot.url).items
        } catch {
            throw RecoveryError.snapshotIsUnreadable
        }
    }

    func discardRecoverySnapshot(_ snapshot: RecoverySnapshot) throws {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        guard FileManager.default.fileExists(atPath: snapshot.url.path) else { return }
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// 可解码恢复快照中的项目，供 Materialized 清理计算保留集合。损坏的隔离
    /// 文件会通过 canSafelyCleanup… 阻止清理；有效 backup 则只精确保留其引用。
    func recoverableSnapshotItems() -> [ShelfItem] {
        recoverySnapshots().flatMap { snapshot in
            (try? loadRecoverySnapshot(snapshot)) ?? []
        }
    }

    private func isManagedRecoveryURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directoryURL.standardizedFileURL else {
            return false
        }
        return standardized.lastPathComponent == backupShelfFileURL.lastPathComponent
            || standardized.lastPathComponent.hasPrefix(Self.corruptSnapshotPrefix)
    }

    private func decodeSnapshot(at url: URL) throws -> ShelfSnapshot {
        let data = try Data(contentsOf: url)
        return migrate(try decoder.decode(ShelfSnapshot.self, from: data))
    }

    /// 把损坏的 shelf.json 改名隔离（保留供人工检查/恢复；下次保存会写新文件）。
    private func quarantineCorruptFile() {
        let stamp = makeShelfDateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = directoryURL.appendingPathComponent(Self.corruptSnapshotPrefix + stamp)
        do {
            try FileManager.default.moveItem(at: shelfFileURL, to: quarantineURL)
            logger.warning("Corrupted shelf.json quarantined to \(quarantineURL.path, privacy: .public)")
        } catch {
            // 仍返回 .failed，清理安全门会继续关闭；明确记录隔离失败，不能
            // 伪称已保存恢复副本。
            logger.error("Failed to quarantine corrupted shelf.json: \(error.localizedDescription, privacy: .public)")
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
    /// atomically replace the target with it. Never pre-deletes the old file —
    /// 「先删旧文件再移动临时文件」在移动失败/断电时会同时丢掉新旧两份
    /// （评审 P1：坏 shelf.json 会在下次启动连锁清空保管文件）。
    private func writeToDisk(_ items: [ShelfItem]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items)
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent("shelf.json.tmp")
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: shelfFileURL.path) {
            // 每次覆盖前保留上一份“可完整解码”的已知良好快照。.atomic 会在
            // 同目录完成临时写与替换；备份失败不应阻止主快照继续保存。
            do {
                let previousData = try Data(contentsOf: shelfFileURL)
                _ = try decoder.decode(ShelfSnapshot.self, from: previousData)
                try previousData.write(to: backupShelfFileURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh last-known-good shelf backup: \(error.localizedDescription, privacy: .public)")
            }
            // replaceItemAt 是同卷原子替换；失败时旧文件保持原样。
            _ = try fileManager.replaceItemAt(shelfFileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: shelfFileURL)
        }
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
