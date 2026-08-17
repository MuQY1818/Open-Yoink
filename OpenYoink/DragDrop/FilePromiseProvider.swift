import AppKit
import OSLog

/// 拖出侧 file promise：`NSFilePromiseProvider` 子类，把 shelf 上已存在的文件
/// 以「放下后才复制」的方式提供给只认 promise 的拖放目标（部分浏览器上传区、
/// Mail 附件区等；调研报告 §5.3 / F-04）。
///
/// 双表示策略（实施计划 §2.3「拖出」）：同一拖出项目的一个 writer 同时承载
/// - **file promise 表示**（本类本体）：只认 promise 的目标走 promise 机制，
///   由 delegate 在后台队列复制源文件（`writeCopy`）；
/// - **`public.file-url` 直接表示**：经覆写 `writableTypes(for:)` /
///   `pasteboardPropertyList(forType:)` 追加在同一个 writer 上 —— Finder 等
///   目标读 fileURL 获得真实文件语义（copy）。
///
/// 为什么用「子类覆写」而不是「组合 writer」：macOS 26 SDK 起
/// `NSFilePromiseProvider` 不再继承 `NSItemProvider`（SDK 头文件声明为
/// `NSObject <NSPasteboardWriting>`），而 promise 的跨进程路由依赖 writer
/// 本身就是 NSFilePromiseProvider；子类覆写既能追加类型又保住 promise 通路
/// （已用独立探针验证 writeObjects 后两类表示同时出现在 advertised types）。
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
    /// fileURL 直接表示的值（构造时已按 bookmark 解析为最新路径）。
    private let directFileURL: URL
    /// 图片项的 `public.tiff` 位图回退（惰性：目标请求时才读文件）。
    private let tiffDataProvider: (@Sendable () -> Data?)?

    init(payload: Payload,
         bookmarkService: BookmarkService,
         tiffDataProvider: (@Sendable () -> Data?)? = nil,
         onError: (@Sendable (Error) -> Void)? = nil) {
        let delegate = FilePromiseDelegate(payload: payload,
                                           bookmarkService: bookmarkService,
                                           onError: onError)
        self.promiseDelegate = delegate
        self.directFileURL = payload.sourceURL
        self.tiffDataProvider = tiffDataProvider
        // 不用 `super.init(fileType:delegate:)`：NSFilePromiseProvider 是 ObjC
        // 类簇，该初始化器内部回调动态类型的 `init()`，对 Swift 子类会触发
        // "unimplemented initializer" 陷阱（探针实测）。改为指定初始化器
        // `super.init()` + 后置设置 `fileType`/`delegate`（二者均为 readwrite）。
        super.init()
        fileType = payload.promisedFileType
        self.delegate = delegate
    }

    // MARK: - fileURL / tiff 附加表示

    /// 声明类型：fileURL（+tiff 回退）在前，promise 类型随后（去重保序）。
    /// fileURL 在前让「取最优表示」的目标优先拿到真实文件路径。
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var result: [NSPasteboard.PasteboardType] = [PasteboardTypes.fileURL]
        if tiffDataProvider != nil {
            result.append(PasteboardTypes.tiff)
        }
        for type in super.writableTypes(for: pasteboard) where !result.contains(type) {
            result.append(type)
        }
        return result
    }

    /// 按类型分派数据：fileURL → URL 字符串（与 NSURL 的 pasteboard 序列化
    /// 一致）；tiff → 惰性位图数据；其余（promise 类型族）交回父类。
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case PasteboardTypes.fileURL:
            return directFileURL.absoluteString as NSString
        case PasteboardTypes.tiff where tiffDataProvider != nil:
            return tiffDataProvider?()
        default:
            return super.pasteboardPropertyList(forType: type)
        }
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
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let payload: FilePromiseProvider.Payload
    private let bookmarkService: BookmarkService
    private let onError: (@Sendable (Error) -> Void)?
    private let writeQueue: OperationQueue
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "FilePromiseProvider")

    init(payload: FilePromiseProvider.Payload,
         bookmarkService: BookmarkService,
         onError: (@Sendable (Error) -> Void)?) {
        self.payload = payload
        self.bookmarkService = bookmarkService
        self.onError = onError
        let queue = OperationQueue()
        queue.name = "com.weijue.OpenYoink.FilePromiseWrite"
        queue.qualityOfService = .userInitiated
        self.writeQueue = queue
        super.init()
    }

    /// 目标侧建议文件名：displayName 原文件名（接收应用据此命名物化文件）。
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        payload.suggestedName
    }

    /// 写入发生的后台队列（计划 §2.3：userInitiated，不阻塞主线程）。
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    /// 在 `writeQueue` 上被调用：复制源文件到目标 URL。任何失败都回调非 nil
    /// error 并记日志、上报 `onError`，绝不抛出/崩溃。
    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try FilePromiseProvider.writeCopy(of: payload, to: url, bookmarkService: bookmarkService)
            completionHandler(nil)
        } catch {
            logger.error("File promise write failed for \(self.payload.suggestedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(error)
            completionHandler(error)
        }
    }
}
