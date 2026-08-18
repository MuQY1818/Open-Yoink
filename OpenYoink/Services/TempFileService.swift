import Foundation
import OSLog

/// Manages the directory where dragged-in file promises and raw data are
/// materialized (`Application Support/OpenYoink/Materialized` in the sandbox
/// container).
///
/// Everything inside the directory is owned by the app: safe to create, move
/// and delete. The service never touches user files outside this directory —
/// deletion APIs refuse URLs outside it.
final class TempFileService: Sendable {
    enum TempFileServiceError: Error, Equatable {
        /// Refused to delete a file outside the managed directory.
        case outsideManagedDirectory(URL)
    }

    /// The managed materialization directory; inject a custom one in tests.
    let directoryURL: URL

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "TempFileService")

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
            ?? AppDirectories.applicationSupport().appendingPathComponent("Materialized", isDirectory: true)
    }

    /// Returns a unique, non-existent file URL inside the managed directory.
    /// The suggested name's extension is preserved (drag targets rely on it for
    /// UTI detection). Creates the directory if needed, but not the file itself.
    func uniqueFileURL(suggestedName: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let sanitized = URL(fileURLWithPath: suggestedName).lastPathComponent
        let name = sanitized.isEmpty ? "file" : sanitized
        var candidate = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        }
        return candidate
    }

    /// Deletes a materialized file (e.g. when its shelf item is removed).
    /// Throws `outsideManagedDirectory` for any URL outside the managed
    /// directory, so a caller bug can never delete a user's original file.
    func removeMaterializedFile(at url: URL) throws {
        guard isInsideManagedDirectory(url) else {
            throw TempFileServiceError.outsideManagedDirectory(url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes everything in the managed directory except `keepingPaths` — the
    /// paths referenced by persisted shelf items. Call once at launch after
    /// loading the store; leftovers from a previous session (interrupted
    /// materializations) are orphans and get removed. Best-effort: individual
    /// failures are logged, not thrown.
    func cleanupOrphans(keepingPaths: Set<String> = []) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return // directory does not exist yet — nothing to clean
        }
        let keep = Set(keepingPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            guard !keep.contains(url.standardizedFileURL.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Failed to remove orphaned file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func isInsideManagedDirectory(_ url: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(prefix)
    }

    /// 清理 promise 物化的共享 staging 目录（`PromiseStaging-*`）：只删
    /// 修改时间早于 `maxAge` 秒的（刚完成的拖入可能仍有文件在路上）。
    /// 与 shelf 内容无关，启动时调用安全（评审 P1：回调不再清理 staging，
    /// 由本方法兜底；默认 1 小时）。
    func cleanupStaleStagingDirectories(maxAge: TimeInterval = 3600) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for name in names where name.hasPrefix("PromiseStaging") {
            let url = directoryURL.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Failed to remove stale staging dir \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
