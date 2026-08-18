import AppKit
import OSLog

/// 已存在文件的直接 pasteboard writer。
///
/// `NSFilePromiseProvider` 在真实 `NSDraggingSession` 中只保留系统 promise
/// 类型，子类覆写追加的 file URL / TIFF / 私有 token 会被 AppKit 丢弃。
/// 普通文件因此使用独立 writer，确保以下表示真实进入拖拽 pasteboard：
/// - `public.file-url`：Finder、Safari 与多数桌面目标；
/// - `NSFilenamesPboardType`：Chromium 的 macOS 文件上传路径；
/// - 可选 `public.tiff`：图片位图回退（惰性）；
/// - 可选 tutorial token：快速上手目标的会话校验。
nonisolated final class DirectFilePasteboardWriter: NSObject, NSPasteboardWriting {
    private let fileURL: URL
    private let tiffDataProvider: (@Sendable () -> Data?)?
    private let tutorialSessionToken: String?

    init(fileURL: URL,
         tiffDataProvider: (@Sendable () -> Data?)? = nil,
         tutorialSessionToken: String? = nil) {
        self.fileURL = fileURL
        self.tiffDataProvider = tiffDataProvider
        self.tutorialSessionToken = tutorialSessionToken
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var result: [NSPasteboard.PasteboardType] = [
            PasteboardTypes.fileURL,
            PasteboardTypes.legacyFilenames,
        ]
        if tiffDataProvider != nil {
            result.append(PasteboardTypes.tiff)
        }
        if tutorialSessionToken != nil {
            result.append(PasteboardTypes.tutorialSession)
        }
        return result
    }

    /// URL、兼容文件名与 tutorial token 都很小，立即写入可避免跨进程目标
    /// 请求时 writer 生命周期或特殊拖拽路由造成缺失。TIFF 可能较大，继续按
    /// pasteboard promise 惰性生成。
    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == PasteboardTypes.tiff ? .promised : []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case PasteboardTypes.fileURL:
            fileURL.absoluteString as NSString
        case PasteboardTypes.legacyFilenames:
            [fileURL.path] as NSArray
        case PasteboardTypes.tiff where tiffDataProvider != nil:
            tiffDataProvider?()
        case PasteboardTypes.tutorialSession where tutorialSessionToken != nil:
            tutorialSessionToken as NSString?
        default:
            nil
        }
    }
}

/// 托管剪切项的 file-promise writer：目标真正写入成功后才确认交付，随后
/// `DeliveryCoordinator` 才会让项目离架并清理托管副本。
///
/// 本类刻意保持 **promise-only**。若同时广告 file URL，Finder 等目标可能
/// 直接读取源路径而不触发 promise delegate，应用就无法证明目标已落盘，移动
/// 语义会失去安全闭环。普通（非剪切）文件由 `DirectFilePasteboardWriter`
/// 提供直接表示，不使用本类。
///
/// 并发：provider 本体只在 MainActor 构造并交给 AppKit 拖拽会话；delegate
/// 回调发生在后台写队列（`operationQueue(for:)`），因此 delegate 只持有
/// Sendable 值（`Payload` 值类型、`BookmarkService`、`Logger`、`@Sendable`
/// 错误回调），非 Sendable 的 provider 不进入后台路径。
final class FilePromiseProvider: NSFilePromiseProvider {
    /// 一次 promise 写入所需的全部信息（值类型，Sendable）。
    struct Payload: Equatable, Sendable {
        /// 拖拽开始时解析出的源文件 URL（bookmark 可解析时为最新路径）。
        let sourceURL: URL
        /// 安全书签：写入时重新解析并获得沙箱访问权（文件可能在 shelf 停留
        /// 期间被移动；解析失败回退 `sourceURL`）。
        let bookmark: Data?
        /// 目标侧建议文件名（`fileNameForType`）：用 displayName 原文件名。
        let suggestedName: String
        /// 声明的 promised 内容 UTI（按扩展名经系统声明表推断并验证，文件夹为
        /// public.folder；见 `DragPayloadBuilder.promisedFileType` 的防御说明）。
        let promisedFileType: String
    }

    /// 强持有 delegate（`NSFilePromiseProvider.delegate` 是弱引用）。
    private let promiseDelegate: FilePromiseDelegate

    init(payload: Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)? = nil) {
        let delegate = FilePromiseDelegate(payload: payload,
                                           bookmarkService: bookmarkService,
                                           onPromiseRequested: onPromiseRequested,
                                           onDelivered: onDelivered,
                                           onError: onError)
        self.promiseDelegate = delegate
        // 不用 `super.init(fileType:delegate:)`：NSFilePromiseProvider 是 ObjC
        // 类簇，该初始化器内部回调动态类型的 `init()`，对 Swift 子类会触发
        // "unimplemented initializer" 陷阱（探针实测）。改为指定初始化器
        // `super.init()` + 后置设置 `fileType`/`delegate`（二者均为 readwrite）。
        super.init()
        fileType = payload.promisedFileType
        self.delegate = delegate
    }

    // MARK: - 写入逻辑

    /// promise 落盘核心逻辑（非隔离纯函数，单测直接调用）：
    /// bookmark 可解析则用最新路径，否则回退拖拽开始时的路径；
    /// 经 `withSecurityScopedAccess` 获得沙箱访问权后**复制**到目标 URL
    /// （copy 而非 move —— 任何情况下不动用户原文件）。
    /// 目标 URL 由接收应用在 drop 时提供，已含 `fileNameForType` 给出的文件名。
    nonisolated static func writeCopy(of payload: Payload,
                                      to destinationURL: URL,
                                      bookmarkService: BookmarkService) throws {
        var sourceURL = payload.sourceURL
        if let bookmark = payload.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            sourceURL = resolved.url
        }
        try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

/// `NSFilePromiseProviderDelegate` 实现。`writePromiseTo` 在
/// `operationQueue(for:)` 返回的后台队列（QoS .userInitiated，实施计划 §2.3
/// 「FilePromise 后台写入」）上执行，大文件复制不阻塞主线程。
///
/// 写失败路径不崩溃：错误经 OSLog 记录并回传给接收应用（completionHandler
/// 非 nil），同时经 `onError` 回调上报（预留 UI 订阅，S10 接卡片错误态）。
///
/// **必须 `nonisolated`**（真机崩溃修复）：目标应用请求 promise 内容时，系统
/// 经 `NSFileProviderXPCMessenger` 在**自己的 XPC 队列**上同步调用
/// `operationQueue(for:)` 等方法；本模块默认 MainActor 隔离会在非主队列触发
/// `_dispatch_assert_queue_fail`（SIGTRAP 闪退；QSpace Pro 等 promise 目标可
/// 触发）。三个方法只读不可变 Sendable 状态（payload / writeQueue），任何
/// 队列调用均安全。
nonisolated final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let payload: FilePromiseProvider.Payload
    private let bookmarkService: BookmarkService
    /// Called when the destination selects the promised-file representation.
    private let onPromiseRequested: (@Sendable () -> Void)?
    /// F-05: 写入完成（交付确认）回调，参数为目标 URL。剪切项据此移出
    /// shelf 并删除保管副本；回调在写队列上触发，订阅方需自行切 actor。
    private let onDelivered: (@Sendable (URL) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?
    private let writeQueue: OperationQueue
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "FilePromiseProvider")

    init(payload: FilePromiseProvider.Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)?) {
        self.payload = payload
        self.bookmarkService = bookmarkService
        self.onPromiseRequested = onPromiseRequested
        self.onDelivered = onDelivered
        self.onError = onError
        let queue = OperationQueue()
        queue.name = "com.weijue.OpenYoink.FilePromiseWrite"
        queue.qualityOfService = .userInitiated
        self.writeQueue = queue
        super.init()
    }

    /// 目标侧建议文件名：displayName 原文件名（接收应用据此命名物化文件）。
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return payload.suggestedName
    }

    /// 写入发生的后台队列（计划 §2.3：userInitiated，不阻塞主线程）。
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    /// 在 `writeQueue` 上被调用：复制源文件到目标 URL。任何失败都回调非 nil
    /// error 并记日志、上报 `onError`，绝不抛出/崩溃；成功先报 `onDelivered`
    /// （F-05 交付确认）再回调 nil error。
    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // This is the first reliable fact that the destination selected the
        // promise representation. `fileNameForType` may be queried while the
        // pasteboard is merely being prepared.
        onPromiseRequested?()
        do {
            try FilePromiseProvider.writeCopy(of: payload, to: url, bookmarkService: bookmarkService)
            onDelivered?(url)
            completionHandler(nil)
        } catch {
            logger.error("File promise write failed for \(self.payload.suggestedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(error)
            completionHandler(error)
        }
    }
}
