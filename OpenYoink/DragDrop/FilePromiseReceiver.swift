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
/// 先把 staging 与预定物化路径写入 `PendingImportJournal` → 移动到物化目录
/// 顶层 → 创建 bookmark + ShelfItem → MainActor 同步持久化回调。只有 shelf
/// 快照落盘后才删除恢复记录。
///
/// 错误路径：接收阶段失败提示从来源重拖；一旦恢复记录已建立，移文件、书签
/// 或 shelf 持久化失败都会保留文件，并提供 Storage 中的真实重试入口。
@MainActor
final class FilePromiseReceiver {
    private let tempFileService: TempFileService
    private let bookmarkService: BookmarkService
    private let pendingImportJournal: PendingImportJournal
    private let transferStore: TransferStore
    private let operationQueue: OperationQueue
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "FilePromiseReceiver")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         pendingImportJournal: PendingImportJournal,
         transferStore: TransferStore = TransferStore()) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.pendingImportJournal = pendingImportJournal
        self.transferStore = transferStore
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
                         taskID: UUID,
                         onItemReady: @escaping @MainActor (ShelfItem) -> Bool) -> Int {
        guard let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else {
            return 0
        }

        var dispatched = 0
        // 评审 P1 修复：同一批拖入的所有 receiver 共享**一个** staging 目录
        // （NSFilePromiseReceiver.h:25「All file promisesReceiver's in a drag
        // must specify the same destination location」）。此前每个 receiver
        // 独立目录 + 回调即删——但 reader 回调是**逐文件**触发的（同一
        // receiver 可交付多个文件），首个文件完成就删目录会把后续文件
        // 仍需写入的位置抽空。现在共享目录且不在回调中清理：文件一到即
        // 移往物化目录顶层；staging 残留由启动时的按龄清理兜底。
        let stagingURL: URL
        do {
            stagingURL = try tempFileService.createPromiseStagingDirectory()
        } catch {
            logger.error("Failed to create promise staging directory: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        transferStore.beginImport(id: taskID, expectedCount: nil)
        var expectedFileCount = 0
        let reportSuccess: @MainActor (ShelfItem, UUID) -> Void = {
            [transferStore, pendingImportJournal, logger] item, recoveryID in
            if onItemReady(item) {
                do {
                    try pendingImportJournal.remove(id: recoveryID)
                } catch {
                    // The shelf item is already durable. Keeping a stale
                    // record is safe and startup reconciliation removes it.
                    logger.error("Failed to clear completed pending import \(recoveryID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            } else {
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .persistenceFailed,
                        itemName: item.displayName,
                        recoveryAction: .openStorageRecovery
                    )
                )
            }
        }
        let reportFailure: @MainActor (String?, RecoveryAction) -> Void = {
            [transferStore] itemName, recoveryAction in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .promiseReceiveFailed,
                    itemName: itemName,
                    recoveryAction: recoveryAction
                )
            )
        }
        for receiver in receivers {
            // `fileTypes` 仅在拖拽会话内有效，立即提取为值类型。
            let promisedTypes = receiver.fileTypes
            dispatched += 1
            // 回调在 operationQueue（后台）执行：只捕获 Sendable 的服务与值类型，
            // 不捕获 MainActor 隔离的 self；成功/失败均经闭包内 Task 跳回 MainActor。
            // 闭包必须显式 `@Sendable`（SE-0420：@Sendable 闭包恒为 nonisolated）——
            // 否则在 MainActor 上下文形成的闭包会携带 MainActor 隔离，被后台队列
            // 调用时触发 `_dispatch_assert_queue_fail`（SIGTRAP 闪退：从浏览器
            // 拖图片/GIF 经 promise 物化时必现）。
            receiver.receivePromisedFiles(
                atDestination: stagingURL,
                options: [:],
                operationQueue: operationQueue
            ) { @Sendable [tempFileService, bookmarkService, pendingImportJournal, logger] fileURL, error in
                Self.handleMaterializedPromise(
                    fileURL: fileURL,
                    error: error,
                    promisedTypes: promisedTypes,
                    tempFileService: tempFileService,
                    bookmarkService: bookmarkService,
                    pendingImportJournal: pendingImportJournal,
                    logger: logger,
                    completion: { item, recoveryID in
                        Task { @MainActor in
                            reportSuccess(item, recoveryID)
                        }
                    },
                    failure: { recoveryAction in
                        Task { @MainActor in
                            reportFailure(fileURL.lastPathComponent, recoveryAction)
                        }
                    }
                )
            }
            // `fileNames` becomes available after the promise is called in and
            // is a better count than `fileTypes` for legacy multi-file promises.
            // Keep one as the conservative minimum so cancellation still ends
            // the batch when a source reports no names.
            expectedFileCount += max(receiver.fileNames.count, 1)
        }
        transferStore.setExpectedCount(expectedFileCount, for: taskID)
        return dispatched
    }

    /// 后台物化完成处理（OperationQueue 上下文，非隔离）。
    /// 成功：移动到物化目录顶层 → kind 推断 + bookmark → completion。
    /// 失败：记日志 + failure 回调（D10 内联提示）。
    /// 回调逐文件触发，故**不触碰共享 staging 目录**（清理由启动时按龄兜底）。
    nonisolated static func handleMaterializedPromise(
        fileURL: URL?,
        error: Error?,
        promisedTypes: [String],
        tempFileService: TempFileService,
        bookmarkService: BookmarkService,
        pendingImportJournal: PendingImportJournal,
        logger: Logger,
        completion: (ShelfItem, UUID) -> Void,
        failure: (RecoveryAction) -> Void
    ) {
        if let error {
            logger.error("File promise materialization failed: \(error.localizedDescription, privacy: .public)")
            failure(.dragAgainFromSource)
            return
        }
        guard let fileURL else {
            logger.error("File promise delivered neither a file URL nor an error; dropping this receiver")
            failure(.dragAgainFromSource)
            return
        }

        var recoveryRecord: PendingImportJournal.Record?
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileURL.lastPathComponent)
            // This is the crash-safety boundary: both possible payload paths
            // are durable before the move begins.
            let record = try pendingImportJournal.create(
                stagingURL: fileURL,
                destinationURL: destination,
                displayName: fileURL.lastPathComponent,
                promisedTypeIdentifiers: promisedTypes
            )
            recoveryRecord = record
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let bookmark = try bookmarkService.createBookmark(for: destination)
            let item = ShelfItem(
                id: record.id,
                kind: DropImportCoordinator.inferFileKind(
                    for: destination,
                    promisedTypeIdentifiers: promisedTypes
                ),
                path: destination.path,
                bookmark: bookmark,
                // 显示名用 promise 来源提供的原始文件名，不带 UUID 前缀。
                displayName: record.displayName
            )
            completion(item, record.id)
        } catch {
            logger.error("Failed to finalize materialized promise \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failure(recoveryRecord == nil ? .dragAgainFromSource : .openStorageRecovery)
        }
    }
}
