import AppKit
import OSLog

/// `NSFilePromiseReceiver` 处理：接收「放下后才生成文件」的拖入
/// （Photos、Safari 大图等来源），物化到 `TempFileService` 管理的目录，
/// 完成后生成 `ShelfItem`（kind 按 UTType 推断）+ 安全书签，回调到 MainActor
/// 入架。
///
/// 流程：performDragOperation 内同步取出 receiver（必须在拖拽会话内读取），
/// 为每个 receiver 建独立 staging 子目录 → `receivePromisedFiles` 在
/// `OperationQueue`（.userInitiated，不阻塞主线程）后台写入 → 完成后把文件
/// 移动到物化目录顶层（`uniqueFileURL`，与 `cleanupOrphans` 的顶层保留语义
/// 对齐）→ 创建 bookmark + ShelfItem → MainActor 回调。
///
/// 错误路径：物化失败/移文件失败/书签创建失败均记录日志，不崩溃、不静默丢
/// （staging 目录一律清理）。
@MainActor
final class FilePromiseReceiver {
    private let tempFileService: TempFileService
    private let bookmarkService: BookmarkService
    private let operationQueue: OperationQueue
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "FilePromiseReceiver")

    init(tempFileService: TempFileService, bookmarkService: BookmarkService) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "com.weijue.OpenYoink.FilePromiseReceive"
        // 计划 §2.3：promise 写入放后台队列，QoS userInitiated。
        self.operationQueue.qualityOfService = .userInitiated
    }

    /// 从拖入 pasteboard 取出全部 promise receiver 并派发物化。
    ///
    /// 必须在拖拽会话内调用（`performDragOperation` 中）——会话结束后
    /// pasteboard 与 receiver 的 `fileTypes` 均不再可靠。返回成功派发的
    /// receiver 数量；返回 0 表示声明了 promise 类型但读不到对象，调用方应
    /// 按优先级回退到 fileURL 等后续类别。
    func receivePromises(from pasteboard: NSPasteboard,
                         onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        guard let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else {
            return 0
        }

        var dispatched = 0
        for receiver in receivers {
            // `fileTypes` 仅在拖拽会话内有效，立即提取为值类型。
            let promisedTypes = receiver.fileTypes
            let stagingURL: URL
            do {
                stagingURL = try tempFileService.uniqueFileURL(suggestedName: "PromiseStaging")
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create promise staging directory: \(error.localizedDescription, privacy: .public)")
                continue
            }
            dispatched += 1
            // 回调在 operationQueue（后台）执行：只捕获 Sendable 的服务与值类型，
            // 不捕获 MainActor 隔离的 self。
            receiver.receivePromisedFiles(
                atDestination: stagingURL,
                options: [:],
                operationQueue: operationQueue
            ) { [tempFileService, bookmarkService, logger] fileURL, error in
                Self.handleMaterializedPromise(
                    fileURL: fileURL,
                    error: error,
                    promisedTypes: promisedTypes,
                    stagingURL: stagingURL,
                    tempFileService: tempFileService,
                    bookmarkService: bookmarkService,
                    logger: logger
                ) { item in
                    Task { @MainActor in
                        onItemReady(item)
                    }
                }
            }
        }
        return dispatched
    }

    /// 后台物化完成处理（OperationQueue 上下文，非隔离）。
    /// 成功：移动到物化目录顶层 → kind 推断 + bookmark → completion。
    /// 失败：记日志；staging 目录无论成败都清理。
    private nonisolated static func handleMaterializedPromise(
        fileURL: URL?,
        error: Error?,
        promisedTypes: [String],
        stagingURL: URL,
        tempFileService: TempFileService,
        bookmarkService: BookmarkService,
        logger: Logger,
        completion: (ShelfItem) -> Void
    ) {
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        if let error {
            logger.error("File promise materialization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let fileURL else {
            logger.error("File promise delivered neither a file URL nor an error; dropping this receiver")
            return
        }

        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileURL.lastPathComponent)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let item = DropImportCoordinator.makeFileBackedItem(
                for: destination,
                // 显示名用 promise 来源提供的原始文件名，不带 UUID 前缀。
                displayName: fileURL.lastPathComponent,
                promisedTypeIdentifiers: promisedTypes,
                bookmarkService: bookmarkService,
                logger: logger
            )
            completion(item)
        } catch {
            logger.error("Failed to finalize materialized promise \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
