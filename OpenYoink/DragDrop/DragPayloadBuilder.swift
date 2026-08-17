import AppKit
import UniformTypeIdentifiers

/// 拖出 payload 组装：ShelfItem → pasteboard writer 多表示 / `[NSDraggingItem]`
/// （实施计划 §2.3「拖出」、调研报告 F-04）。
///
/// ## 双表示技术路线（文件/文件夹/图片）
///
/// 一个拖出项目 = 一个 `NSDraggingItem` = 一个 pasteboard writer。文件类项目的
/// writer 是 `FilePromiseProvider`（NSFilePromiseProvider 子类），同时承载：
/// 1. **`public.file-url` 直接表示**（子类覆写追加；值为 URL 字符串）。
///    Finder 及绝大多数桌面目标读取它，获得真实文件语义（Finder 内部按 copy
///    处理；我们不声明 .move，见 `DragSessionController`）。
/// 2. **file promise 表示**（父类机制）：只认 promise 的目标（部分浏览器上传区、
///    Mail 附件区，调研报告 §6.3）走 promise 机制，由 delegate 在后台队列复制
///    源文件（`FilePromiseProvider.writeCopy`）。
/// 3. 图片项另加 **`public.tiff` 位图回退**（计划 §2.3，惰性加载）。
///
/// SDK 现实与取舍（相对计划 §2.3 原文「同一 NSItemProvider 同时注册 fileURL
/// 与 promise 表示」的调整）：
/// - macOS 26 SDK 起 `NSFilePromiseProvider` 不再继承 `NSItemProvider`
///   （声明为 `NSObject <NSPasteboardWriting>`），且 `NSItemProvider` 本身也
///   不再具备 `NSPasteboardWriting` 一致性，「同一 provider 追加注册」与
///   「NSItemProvider 直接做 drag writer」均不可用；
/// - 改为 `FilePromiseProvider` 子类覆写 `writableTypes` /
///   `pasteboardPropertyList` 追加 fileURL/tiff 表示 —— writer 仍是真正的
///   NSFilePromiseProvider，promise 跨进程路由不受影响（独立探针验证：
///   writeObjects 后 file-url 与 promise 类型族同时出现在 advertised types）；
/// - 文本/URL 项用 `NSPasteboardItem` 直接写类型（同一 NSDraggingItem 契约）。
/// 浏览器先看到 file-url 即可直接映射 `DataTransfer.files`，promise 作为兜底
/// （调研报告 §6.1：fileURL + promise 至少一路成功即可）。
///
/// ## 纯函数部分
/// `strategy(for:)` / `flattenedItems(_:)` / `promisedFileType(for:)` 不构造
/// AppKit 对象，单测直接断言策略与展开语义。
enum DragPayloadBuilder {
    /// 各 kind 的表示策略。
    enum Strategy: Equatable, Sendable {
        /// 文件/文件夹：`public.file-url` + file promise。
        case fileBacked
        /// 图片：fileBacked + `public.tiff` 位图回退（计划 §2.3）。
        case fileBackedImage
        /// 纯文本：`public.utf8-plain-text`（当前模型只存 plain；拖入侧 v1
        /// 未保留 HTML/RTF 原文，故此处无富文本表示可注册）。
        case plainText
        /// Web URL：`public.url` + plain text。
        case webURL
    }

    /// stack 不整体拖出（由 `flattenedItems` 展开为子项），故返回 nil。
    static func strategy(for item: ShelfItem) -> Strategy? {
        switch item.kind {
        case .file, .folder: .fileBacked
        case .image: .fileBackedImage
        case .text: .plainText
        case .url: .webURL
        case .stack: nil
        }
    }

    /// 展开 stack 为全部子项（递归，防御嵌套 stack），非 stack 项目原样保留、
    /// 顺序不变。语义：stack 卡片拖出 = 拖出其全部子项（计划 §2.3）。
    static func flattenedItems(_ items: [ShelfItem]) -> [ShelfItem] {
        items.flatMap { item -> [ShelfItem] in
            guard item.kind == .stack, let children = item.children, !children.isEmpty else {
                return [item]
            }
            return flattenedItems(children)
        }
    }

    /// promise 声明的内容 UTI：文件夹 → `public.folder`；其余按扩展名经系统
    /// 声明表推断；无/未知扩展名回退 `public.data`。
    ///
    /// 防御说明（macOS 26 实测）：`NSFilePromiseProvider.init(fileType:)` 对不
    /// 符合 kUTTypeData/kUTTypeDirectory 的 fileType 抛 NSException（Swift 无法
    /// 捕获，直接崩进程），且部分规范 UTI（如 `public.pdf`）在 macOS 26 已不
    /// 再声明（`UTType("public.pdf") == nil`）。因此只接受
    /// `UTType(filenameExtension:)` 返回的、已验证 conforms(to: .data/.directory)
    /// 的类型；`UTType` 静态成员（如 `UTType.pdf`）的 identifier 不可直接用。
    static func promisedFileType(for item: ShelfItem) -> String {
        if item.kind == .folder {
            return UTType.folder.identifier
        }
        if let path = item.path {
            let pathExtension = URL(fileURLWithPath: path).pathExtension
            if !pathExtension.isEmpty,
               let type = UTType(filenameExtension: pathExtension),
               type.conforms(to: .data) || type.conforms(to: .directory) {
                return type.identifier
            }
        }
        return UTType.data.identifier
    }

    // MARK: - Writer construction

    /// 单个项目的 pasteboard writer。无法构造（text 无内容、url 无地址、
    /// file 无路径、stack 未展开）时返回 nil。
    @MainActor
    static func makePasteboardWriter(for item: ShelfItem, bookmarkService: BookmarkService) -> NSPasteboardWriting? {
        switch strategy(for: item) {
        case .fileBacked, .fileBackedImage:
            return makeFileBackedWriter(for: item, bookmarkService: bookmarkService)
        case .plainText:
            return makeTextItem(for: item)
        case .webURL:
            return makeURLItem(for: item)
        case nil:
            return nil
        }
    }

    /// 组装 `[NSDraggingItem]`：每个可拖项目一个；`frame` 为被拖卡片在源视图
    /// 坐标系中的位置（多项目共用同一 frame，系统负责聚拢呈现），图像为
    /// 系统图标合成（NSWorkspace 图标 / SF Symbol，见 `dragImage`）。
    @MainActor
    static func makeDraggingItems(for items: [ShelfItem],
                                  frame: NSRect,
                                  bookmarkService: BookmarkService) -> [NSDraggingItem] {
        flattenedItems(items).compactMap { item in
            guard let writer = makePasteboardWriter(for: item, bookmarkService: bookmarkService) else {
                return nil
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            draggingItem.setDraggingFrame(frame, contents: dragImage(for: item))
            return draggingItem
        }
    }

    /// 拖拽图像：文件类用 `NSWorkspace.icon(forFile:)`（同步、不需要文件读
    /// 权限），文本/URL 用与卡片占位一致的 SF Symbol。统一 64pt。
    /// （卡片缩略图是异步加载的 SwiftUI Image，无法同步回取 NSImage；
    /// 系统图标在拖拽启动的同步路径上足够清晰且零延迟。）
    @MainActor
    static func dragImage(for item: ShelfItem) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        if let path = item.path {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = size
            return icon
        }
        let symbolName = switch item.kind {
        case .text: "doc.text"
        case .url: "link"
        default: "doc"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.size = size
        return image
    }

    // MARK: - File/folder/image

    /// 文件类：`FilePromiseProvider`（promise 表示 + 覆写追加 fileURL 直接
    /// 表示 + 图片项的 public.tiff 位图回退）。
    @MainActor
    private static func makeFileBackedWriter(for item: ShelfItem,
                                             bookmarkService: BookmarkService) -> NSPasteboardWriting? {
        guard let path = item.path else { return nil }
        // 拖拽开始时解析 bookmark 取最新路径（文件可能在 shelf 停留期间被
        // 移动）；解析失败回退存储路径，promise 写入时会再尝试解析一次。
        let sourceURL: URL
        if let bookmark = item.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            sourceURL = resolved.url
        } else {
            sourceURL = URL(fileURLWithPath: path)
        }
        let bookmark = item.bookmark
        let includeImageFallback = strategy(for: item) == .fileBackedImage
        let tiffDataProvider: (@Sendable () -> Data?)?
        if includeImageFallback {
            // 惰性：目标请求 public.tiff 时才读文件。
            tiffDataProvider = { tiffData(sourceURL: sourceURL, bookmark: bookmark, bookmarkService: bookmarkService) }
        } else {
            tiffDataProvider = nil
        }
        return FilePromiseProvider(
            payload: FilePromiseProvider.Payload(
                sourceURL: sourceURL,
                bookmark: bookmark,
                suggestedName: item.displayName,
                promisedFileType: promisedFileType(for: item)
            ),
            bookmarkService: bookmarkService,
            tiffDataProvider: tiffDataProvider
        )
    }

    /// 图片位图回退：在安全作用域内读图并导出 TIFF 数据。NSImage 非 Sendable，
    /// 就地创建就地提取 Data（Sendable），不跨 actor。
    nonisolated static func tiffData(sourceURL: URL, bookmark: Data?, bookmarkService: BookmarkService) -> Data? {
        var url = sourceURL
        if let bookmark, let resolved = try? bookmarkService.resolve(bookmark) {
            url = resolved.url
        }
        return bookmarkService.withSecurityScopedAccess(to: url) {
            NSImage(contentsOf: url)?.tiffRepresentation
        }
    }

    // MARK: - Text

    /// 纯文本：`public.utf8-plain-text`（NSPasteboardItem 直接写类型）。
    @MainActor
    private static func makeTextItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let text = item.text, !text.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(text, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }

    // MARK: - URL

    /// Web URL：`public.url`（URL 字符串）+ plain text 回退（文本框/地址栏）。
    /// 不写 `public.file-url`：对 http(s) URL 那是错误表示，可能误导 Finder
    /// 类目标。
    @MainActor
    private static func makeURLItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let urlString = item.urlString, URL(string: urlString) != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(urlString, forType: PasteboardTypes.url)
        pasteboardItem.setString(urlString, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }
}
