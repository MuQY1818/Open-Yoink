import AppKit
import OSLog
import UniformTypeIdentifiers

/// 一次拖入的分派结果：同步产出的项目 + 仍在后台物化的数量。
struct DropImportResult: Equatable, Sendable {
    /// 已可直接入架的项目（fileURL / URL / 文本路径同步产出）。
    var items: [ShelfItem]
    /// 已派发到后台、稍后经 `onAsyncItemReady` 回调产出的物化任务数
    /// （file promise 与图片数据路径）。
    var pendingMaterializations: Int

    /// 是否有任何内容被处理（决定 `performDragOperation` 的返回值）。
    var handled: Bool { !items.isEmpty || pendingMaterializations > 0 }

    static let unhandled = DropImportResult(items: [], pendingMaterializations: 0)
}

/// 把 `NSPasteboard`（来自 `NSDraggingInfo`）转成 `[ShelfItem]` 的纯逻辑层。
///
/// 与 AppKit 拖放协议解耦：输入是 pasteboard，输出是同步 items + 异步物化
/// 回调，便于单测（测试中可直接构造 `NSPasteboard(name:)` 实例喂数据）。
///
/// 处理顺序严格遵循调研报告 F-03 与实施计划 §2.3：
/// **file promise → fileURL → 图片数据 → URL → 文本**。高优先级类别声明了
/// 类型但实际读不到内容时（极少数来源的怪异行为），按顺序回退到下一类别，
/// 不会直接丢弃整个拖放。
///
/// 已知限制（v1，注释而非实现）：
/// - HTML/RTF 原文不存储；文本族只取 plain text 表示。仅含 HTML/RTF 而无
///   plain text 的拖放本步不产出项目。
/// - 来源应用：跨应用拖拽时 `NSDraggingInfo.draggingSource` 为 nil，本层
///   只看到 pasteboard，v1 统一留 `sourceApp = nil`。
/// - 目录拖入按单项目处理（`kind = .folder`），不展开递归。
@MainActor
final class DropImportCoordinator {
    /// 物化图片项目的默认显示名（落盘文件名带 UUID 前缀，显示名保持干净）。
    /// S10: 用户可见，走 catalog 本地化；保持计算属性以兼容既有引用（含单测）。
    nonisolated static var materializedImageDisplayName: String {
        String(localized: "Dropped Image.png")
    }

    /// 共享的书签服务（ShelfWindowController 把它注入 SwiftUI 环境，
    /// 供卡片缩略图/打开操作经 bookmark 解析文件访问权）。
    let bookmarkService: BookmarkService
    /// D10: 拖入/物化失败的内联提示中心（ShelfWindowController 注入 SwiftUI 环境，
    /// ShelfView 渲染标题栏下方的瞬态胶囊）。
    let noticeCenter: ShelfNoticeModel
    private let tempFileService: TempFileService
    private let promiseReceiver: FilePromiseReceiver
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "DropImport")

    init(bookmarkService: BookmarkService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel = ShelfNoticeModel()) {
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        self.noticeCenter = noticeCenter
        self.promiseReceiver = FilePromiseReceiver(tempFileService: tempFileService,
                                                   bookmarkService: bookmarkService,
                                                   noticeCenter: noticeCenter)
    }

    // MARK: - Entry point

    /// 分派一次拖入。同步可产出的项目放进返回值；file promise 与图片数据
    /// 在后台物化，完成后经 `onAsyncItemReady`（MainActor 上调用）逐个产出。
    @discardableResult
    func importItems(from pasteboard: NSPasteboard,
                     onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let types = pasteboard.types ?? []

        // 1. file promise 优先（高质量表示；F-03 明确建议先尝试 promise）。
        if PasteboardTypes.supports(.filePromise, types: types) {
            let pending = promiseReceiver.receivePromises(from: pasteboard, onItemReady: onAsyncItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
            // 声明了 promise 类型但 readObjects 拿不到 receiver：继续回退。
        }

        // 2. fileURL（Finder 文件/文件夹，及其他应用的文件表示）。
        if PasteboardTypes.supports(.fileURL, types: types) {
            let items = fileURLItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 3. 图片数据（无文件 URL 的位图）：物化 PNG 到 TempFileService 目录。
        if let imageType = PasteboardTypes.preferredImageType(in: types) {
            let pending = scheduleImageMaterialization(from: pasteboard,
                                                       preferredType: imageType,
                                                       onItemReady: onAsyncItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
        }

        // 4. URL。
        if PasteboardTypes.supports(.url, types: types) {
            let items = urlItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 5. 文本族（v1 只取 plain text，见类型注释）。
        if PasteboardTypes.supports(.text, types: types) {
            let items = textItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        logger.warning("Drop contained no importable content; declared types: \(types.map(\.rawValue), privacy: .public)")
        return .unhandled
    }

    // MARK: - fileURL

    private func fileURLItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.map { Self.makeFileBackedItem(for: $0, displayName: $0.lastPathComponent, bookmarkService: bookmarkService, logger: logger) }
    }

    // MARK: - Image data

    /// 提取各 pasteboard item 的图片 Data 后派发到后台物化。NSPasteboardItem
    /// 非 Sendable，Data 必须在本层（MainActor）就地取出，不跨 actor 传递原 item。
    private func scheduleImageMaterialization(from pasteboard: NSPasteboard,
                                              preferredType: NSPasteboard.PasteboardType,
                                              onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        let payloads: [(type: NSPasteboard.PasteboardType, data: Data)] =
            (pasteboard.pasteboardItems ?? []).compactMap { item in
                guard let type = PasteboardTypes.preferredImageType(in: item.types),
                      let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }

        // D10: 失败提示经 @MainActor 闭包桥回（@MainActor 闭包天然 Sendable，
        // 可安全捕获进 detached 任务；直接捕获 MainActor 类则违反严格并发）。
        let reportFailure: @MainActor () -> Void = { [noticeCenter] in
            noticeCenter.show(String(localized: "Couldn't add the dropped item."))
        }
        for payload in payloads {
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    guard let pngData = Self.pngData(from: payload.data, type: payload.type) else {
                        throw DropImportError.imageConversionFailed
                    }
                    let destination = try tempFileService.uniqueFileURL(suggestedName: Self.materializedImageDisplayName)
                    try pngData.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: Self.materializedImageDisplayName,
                                                       forcedKind: .image,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await onItemReady(item)
                } catch {
                    // 失败不崩溃、不静默：日志记录 + D10 内联提示，拖放本身仍视为已处理。
                    logger.error("Failed to materialize dropped image data: \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
        }
        return payloads.count
    }

    /// PNG 数据直接使用；TIFF / 通用 image 经 NSBitmapImageRep 转码为 PNG。
    /// 非隔离：转码在后台任务内就地完成，非 Sendable 的 NSBitmapImageRep 不跨 actor。
    private nonisolated static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == PasteboardTypes.png {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - URL

    private func urlItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(PasteboardTypes.url),
                  let string = item.string(forType: PasteboardTypes.url),
                  let url = URL(string: string),
                  url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? string,
                             urlString: string)
        }
    }

    // MARK: - Text

    private func textItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ShelfItem? in
            guard let text = item.string(forType: .string), !text.isEmpty else { return nil }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        // 少数来源只在整体 pasteboard 上提供 string（逐项读取为空）。
        if items.isEmpty,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)]
        }
        return items
    }

    /// 文本项目显示名：首行截断（60 字符），空白文本回退为本地化「Text」。
    static func displayName(forText text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return String(localized: "Text") }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Shared file-backed item construction

    /// file/folder/image 统一的构造入口：推断 kind + 立即创建安全书签。
    /// 非隔离，`FilePromiseReceiver` 的后台物化回调与图片物化任务也走这里。
    /// 书签创建失败不丢弃项目（仍有路径可作显示与回退提示），但记录日志。
    nonisolated static func makeFileBackedItem(for url: URL,
                                               displayName: String,
                                               forcedKind: ItemKind? = nil,
                                               promisedTypeIdentifiers: [String] = [],
                                               bookmarkService: BookmarkService,
                                               logger: Logger) -> ShelfItem {
        let kind = forcedKind ?? inferFileKind(for: url, promisedTypeIdentifiers: promisedTypeIdentifiers)
        let bookmark: Data?
        do {
            bookmark = try bookmarkService.createBookmark(for: url)
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            bookmark = nil
        }
        return ShelfItem(kind: kind, path: url.path, bookmark: bookmark, displayName: displayName)
    }

    /// kind 推断：folder（目录且非 package）→ image（扩展名 UTType 符合 image）
    /// → file。`promisedTypeIdentifiers` 是 file promise 来源在拖拽会话内声明的
    /// UTI（物化后扩展名可能不可靠时作为首要依据）。
    nonisolated static func inferFileKind(for url: URL, promisedTypeIdentifiers: [String] = []) -> ItemKind {
        for identifier in promisedTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .folder), !type.conforms(to: .package) { return .folder }
            if type.conforms(to: .image) { return .image }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            return .folder
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return .image
        }
        return .file
    }
}

/// 拖入物化错误。
enum DropImportError: LocalizedError {
    /// 拖入的位图数据无法转成 PNG。
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            String(localized: "Dropped image data could not be converted to PNG.")
        }
    }
}
