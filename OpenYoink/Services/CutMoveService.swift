import Foundation
import OSLog

/// ⌘+拖入（剪切模式）的搬运编排：把原文件复制进保管目录、原文件进废纸篓，
/// 产出 `isCut = true` 的 ShelfItem（bookmark 指向保管副本）。
///
/// 逐文件独立成败；任何一步失败都回退为「复制引用」模式（现状语义），
/// 绝不出现「原文件已删但保管副本缺失」的数据丢失窗口：
///
/// 1. 源已在 app 容器内 → 拒绝剪切（防套娃：保管文件再「剪切」只会
///    复制自身并把保管原件进废纸篓），静默回退引用模式；
/// 2. 在拖放授权仍有效时捕获 bookmark；实际复制由调用方安排到后台；
/// 3. `copyItem` 到 `TempFileService.uniqueFileURL` 并校验副本就位；
/// 4. 在独立 journal 中同步写入 `.prepared` 恢复事务；
/// 5. `FileManager.trashItem` 把原文件进废纸篓（可恢复，比 removeItem
///    安全）；trash 失败（只读卷等）→ 清掉副本、原文件不动、回退引用模式；
/// 6. 标记 `.originalTrashed`，再由调用方同步保存 shelf；只有保存成功才清除
///    transaction。崩溃时下次启动会依据源文件/副本状态安全恢复。
///
/// `trashOriginal` 与 `containerURL` 可注入：单测用 mock 验证编排顺序与分支
/// （测试宿主里 trashItem 未必可用），并自定义「容器内」判定边界。
final class CutMoveService: Sendable {
    /// Synchronously captured while the drag pasteboard grant is active.  The
    /// security-scoped bookmark in `referenceItem` lets the expensive copy run
    /// after `performDragOperation` returns.
    struct Request: Equatable, Sendable {
        let sourceURL: URL
        let displayName: String
        let referenceItem: ShelfItem
    }

    /// 搬运失败回退引用模式的原因。
    enum FallbackReason: Equatable, Sendable {
        /// 源已在 app 容器内（防套娃），静默回退，无需提示。
        case sourceInsideContainer
        /// 复制到保管目录失败（或副本就位校验失败）：原文件不动。
        case copyFailed
        /// 副本已就位但原文件进废纸篓失败（只读卷等）：副本已清，原文件不动。
        case trashFailed
        /// 无法在破坏性步骤之前写入恢复事务；副本已清，原文件不动。
        case transactionFailed
    }

    /// 单个文件的搬运结果。
    enum Outcome: Equatable, Sendable {
        /// 剪切成功：item.isCut = true，path/bookmark 指向保管副本。
        case moved(ShelfItem)
        /// 回退引用模式：item 为普通（复制语义）项目，reason 供调用方决定是否提示。
        case fallbackToReference(ShelfItem, FallbackReason)
    }

    let tempFileService: TempFileService
    let bookmarkService: BookmarkService
    let managedMoveJournal: ManagedMoveJournal
    /// 「app 容器内」判定根（默认 app 容器 Data 根；测试注入临时目录）。
    let containerURL: URL
    /// 原文件进废纸篓；测试注入 mock 验证编排与失败分支。
    let trashOriginal: @Sendable (URL) throws -> URL?

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "CutMove")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         managedMoveJournal: ManagedMoveJournal? = nil,
         containerURL: URL? = nil,
         trashOriginal: (@Sendable (URL) throws -> Void)? = nil) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.managedMoveJournal = managedMoveJournal ?? ManagedMoveJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent()
        )
        // 容器 Data 根 = `~/Library/Containers/<id>/Data`；非沙箱（测试宿主）
        // 下回退为用户 Library 的父目录语义不可靠，故测试必须注入。
        self.containerURL = containerURL
            ?? AppDirectories.applicationSupport()  // <Data>/Library/Application Support/OpenYoink
                .deletingLastPathComponent()        // <Data>/Library/Application Support
                .deletingLastPathComponent()        // <Data>/Library
                .deletingLastPathComponent()        // <Data>
        if let trashOriginal {
            self.trashOriginal = { url in
                try trashOriginal(url)
                return nil
            }
        } else {
            self.trashOriginal = { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return resultingURL as URL?
            }
        }
    }

    /// 在拖放会话仍有效时捕获普通引用与 bookmark。调用方随后可把 `Request`
    /// 发送到后台任务，避免大文件复制阻塞 MainActor。
    func prepareRequest(for sourceURL: URL, displayName: String) -> Request {
        let referenceItem = DropImportCoordinator.makeFileBackedItem(
            for: sourceURL,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        return Request(sourceURL: sourceURL,
                       displayName: displayName,
                       referenceItem: referenceItem)
    }

    /// Backward-compatible synchronous entry point used by focused service
    /// tests. Production drop handling calls this overload on a detached task.
    func makeCutItem(for sourceURL: URL, displayName: String) -> Outcome {
        makeCutItem(for: prepareRequest(for: sourceURL, displayName: displayName))
    }

    /// 搬运一个文件/文件夹。任何路径都不会删除副本之外的任何东西；
    /// 失败时原文件保持不动。
    func makeCutItem(for request: Request) -> Outcome {
        let sourceURL = request.sourceURL
        let displayName = request.displayName
        let referenceItem = request.referenceItem

        // 1. 防套娃：源已在 app 容器内（例如保管目录里的文件被再次 ⌘ 拖入）。
        guard !isInsideContainer(sourceURL) else {
            return .fallbackToReference(referenceItem, .sourceInsideContainer)
        }

        // 2. 复制到保管目录。先建源书签并在安全作用域内复制（拖入瞬间系统授予
        //    访问权；显式 bookmark + startAccessing 与既有导入路径一致）。
        let destination: URL
        do {
            destination = try tempFileService.uniqueFileURL(suggestedName: displayName)
        } catch {
            logger.error("Cut move: failed to allocate managed file URL for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }
        do {
            try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
        } catch {
            logger.error("Cut move: copy failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination) // 清掉半成品
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        // 3. 校验副本就位。
        guard FileManager.default.fileExists(atPath: destination.path) else {
            logger.error("Cut move: managed copy missing after copy for \(sourceURL.path, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        // 4. 在任何破坏性操作前写入恢复事务。managed item 此时已经完整
        //    构造；若 journal 写入失败，绝不能继续移动原文件。
        var item = DropImportCoordinator.makeFileBackedItem(
            for: destination,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        item.isCut = true
        do {
            try managedMoveJournal.createPrepared(referenceItem: referenceItem,
                                                  managedItem: item)
        } catch {
            logger.error("Cut move: failed to create recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .transactionFailed)
        }

        // 5. 原文件进废纸篓（可恢复）。失败：清掉 journal 与副本，原文件
        //    不动，回退引用。journal 删除失败仍是安全的：下次启动会看到
        //    `.prepared` + 原文件存在并恢复为普通引用。
        let resultingTrashURL: URL?
        do {
            resultingTrashURL = try trashOriginal(sourceURL)
        } catch {
            logger.error("Cut move: trash failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? managedMoveJournal.remove(id: item.id)
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .trashFailed)
        }

        // 6. 记录原文件已进废纸篓。若更新失败，旧 `.prepared` 记录仍可根据
        //    「原路径缺失 + 托管副本存在」安全恢复，不能因此丢弃成功结果。
        do {
            try managedMoveJournal.markOriginalTrashed(id: item.id,
                                                       resultingURL: resultingTrashURL)
        } catch {
            logger.error("Cut move: failed to advance recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // 7. 成功：item 指向保管副本，isCut = true。只有调用方把它同步写入
        //    shelf snapshot 后，才可删除 transaction。
        return .moved(item)
    }

    /// 源路径（标准化 + 解符号链接）是否位于容器根之内。
    private func isInsideContainer(_ url: URL) -> Bool {
        let containerPath = containerURL.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = containerPath.hasSuffix("/") ? containerPath : containerPath + "/"
        return sourcePath.hasPrefix(prefix)
    }
}
