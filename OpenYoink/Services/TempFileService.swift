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

    struct CleanupResult: Equatable, Sendable {
        var removedItemCount = 0
        var reclaimedBytes: Int64 = 0
    }

    /// The managed materialization directory; inject a custom one in tests.
    let directoryURL: URL

    /// Promise 接收临时目录的唯一命名约定。创建、常规孤儿清理与按龄清理
    /// 必须共用它，否则目录会永远清不到，或在文件仍写入时被提前删除。
    private static let promiseStagingPrefix = "PromiseStaging-"

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

    /// 创建一个 receiver 批次共享的 staging 目录。目录名与启动时的按龄
    /// 清理规则严格一致；文件 promise 回调期间不会删除该目录。
    func createPromiseStagingDirectory() throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent(
            Self.promiseStagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
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
    @discardableResult
    func cleanupOrphans(keepingPaths: Set<String> = []) -> CleanupResult {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return CleanupResult() // directory does not exist yet — nothing to clean
        }
        var result = CleanupResult()
        let keep = Set(keepingPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            guard !keep.contains(url.standardizedFileURL.path) else { continue }
            // Promise writer 可能仍在向 staging 写文件。它由下面的按龄策略
            // 独立回收，常规孤儿清理绝不能在启动时无条件删除。
            guard !name.hasPrefix(Self.promiseStagingPrefix) else { continue }
            do {
                let bytes = allocatedSize(of: url)
                try fileManager.removeItem(at: url)
                result.removedItemCount += 1
                result.reclaimedBytes += bytes
            } catch {
                logger.error("Failed to remove orphaned file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    /// 托管目录当前占用。读取失败的单个文件按 0 计，设置页不会因某个并发
    /// promise 写入而失效。
    func storageUsage() -> Int64 {
        allocatedSize(of: directoryURL)
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileSizeKey,
        ]
        let rootValues = try? url.resourceValues(forKeys: keys)
        if rootValues?.isRegularFile == true {
            return byteSize(from: rootValues)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return byteSize(from: rootValues)
        }
        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            let values = try? childURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += byteSize(from: values)
        }
        return total
    }

    private func byteSize(from values: URLResourceValues?) -> Int64 {
        let candidates = [
            values?.totalFileAllocatedSize,
            values?.fileAllocatedSize,
            values?.totalFileSize,
            values?.fileSize,
        ].compactMap { $0 }
        return Int64(candidates.first(where: { $0 > 0 }) ?? 0)
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
        for name in names where name.hasPrefix(Self.promiseStagingPrefix) {
            let url = directoryURL.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Failed to remove stale staging dir \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
