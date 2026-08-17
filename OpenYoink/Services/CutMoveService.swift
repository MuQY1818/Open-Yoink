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
/// 2. `copyItem` 到 `TempFileService.uniqueFileURL`（沙箱内安全区）；
/// 3. 校验副本就位（copy 无异常 + 存在性检查），副本不完整时清掉半成品；
/// 4. `FileManager.trashItem` 把原文件进废纸篓（可恢复，比 removeItem
///    安全）；trash 失败（只读卷等）→ 清掉副本、原文件不动、回退引用模式；
/// 5. 全部成功 → `isCut = true`、bookmark 指向保管副本（`cleanupOrphans`
///    按引用保留，保管文件自动受保护）。
///
/// `trashOriginal` 与 `containerURL` 可注入：单测用 mock 验证编排顺序与分支
/// （测试宿主里 trashItem 未必可用），并自定义「容器内」判定边界。
final class CutMoveService: Sendable {
    /// 搬运失败回退引用模式的原因。
    enum FallbackReason: Equatable, Sendable {
        /// 源已在 app 容器内（防套娃），静默回退，无需提示。
        case sourceInsideContainer
        /// 复制到保管目录失败（或副本就位校验失败）：原文件不动。
        case copyFailed
        /// 副本已就位但原文件进废纸篓失败（只读卷等）：副本已清，原文件不动。
        case trashFailed
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
    /// 「app 容器内」判定根（默认 app 容器 Data 根；测试注入临时目录）。
    let containerURL: URL
    /// 原文件进废纸篓；测试注入 mock 验证编排与失败分支。
    let trashOriginal: @Sendable (URL) throws -> Void

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "CutMove")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         containerURL: URL? = nil,
         trashOriginal: (@Sendable (URL) throws -> Void)? = nil) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        // 容器 Data 根 = `~/Library/Containers/<id>/Data`；非沙箱（测试宿主）
        // 下回退为用户 Library 的父目录语义不可靠，故测试必须注入。
        self.containerURL = containerURL
            ?? AppDirectories.applicationSupport()  // <Data>/Library/Application Support/OpenYoink
                .deletingLastPathComponent()        // <Data>/Library/Application Support
                .deletingLastPathComponent()        // <Data>/Library
                .deletingLastPathComponent()        // <Data>
        self.trashOriginal = trashOriginal ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// 搬运一个文件/文件夹。任何路径都不会删除副本之外的任何东西；
    /// 失败时原文件保持不动。
    func makeCutItem(for sourceURL: URL, displayName: String) -> Outcome {
        let referenceItem = DropImportCoordinator.makeFileBackedItem(
            for: sourceURL,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )

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

        // 4. 原文件进废纸篓（可恢复）。失败：清掉副本，原文件不动，回退引用。
        do {
            try trashOriginal(sourceURL)
        } catch {
            logger.error("Cut move: trash failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .trashFailed)
        }

        // 5. 成功：item 指向保管副本，isCut = true。displayName 保持原名
        //    （保管文件名带 UUID 前缀，不暴露给用户）。
        var item = DropImportCoordinator.makeFileBackedItem(
            for: destination,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        item.isCut = true
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
