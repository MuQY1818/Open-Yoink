import AppKit
import UniformTypeIdentifiers

/// 拖入/拖出共用的 pasteboard 类型常量与能力探测。
///
/// 能力探测全部为纯函数（输入类型数组、输出类别集合），不触碰具体
/// pasteboard 实例，因此可以在单测中直接断言分派顺序，而无需构造
/// 真实的拖拽会话。处理顺序遵循调研报告 F-03 与实施计划 §2.3：
/// file promise → fileURL → 图片数据 → URL → 文本。
enum PasteboardTypes {
    // MARK: - Type constants

    /// `public.file-url` —— Finder 及多数应用的文件拖放表示。
    static let fileURL: NSPasteboard.PasteboardType = .fileURL
    /// `public.utf8-plain-text`。
    static let plainText: NSPasteboard.PasteboardType = .string
    /// `public.html`。
    static let html = NSPasteboard.PasteboardType(UTType.html.identifier)
    /// `public.rtf`。
    static let rtf = NSPasteboard.PasteboardType(UTType.rtf.identifier)
    /// `public.png`。
    static let png = NSPasteboard.PasteboardType(UTType.png.identifier)
    /// `public.tiff`。
    static let tiff = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    /// `public.image`（通用图片数据）。
    static let image = NSPasteboard.PasteboardType(UTType.image.identifier)
    /// `public.url`。
    static let url = NSPasteboard.PasteboardType(UTType.url.identifier)

    /// `NSFilePromiseReceiver` 可读取的 promise 类型（Apple 推荐直接用其
    /// `readableDraggedTypes` 注册，而不是手写 UTI 字符串）。
    static let filePromiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// 图片数据族，按物化时的优先顺序排列（PNG 免转换，TIFF 需转码）。
    static let imageTypes: [NSPasteboard.PasteboardType] = [png, tiff, image]
    /// 文本族。v1 仅物化 plain text；HTML/RTF 只作为「这是文本类拖放」的信号。
    static let textTypes: [NSPasteboard.PasteboardType] = [plainText, html, rtf]

    /// `DragContainerView` 注册的全部拖入类型。
    static let dragInTypes: [NSPasteboard.PasteboardType] =
        filePromiseTypes + [fileURL] + imageTypes + [url] + textTypes

    // MARK: - Capability probing (pure functions)

    /// 拖入分派类别。`allCases` 的声明顺序即处理优先级（F-03）。
    enum Category: CaseIterable, Equatable, Sendable {
        /// 高质量 file promise（Photos / Safari 大图等「放下后才生成」的来源）。
        case filePromise
        /// 磁盘上已存在的文件/文件夹 URL。
        case fileURL
        /// 无文件 URL 的位图数据（PNG/TIFF/通用 image）。
        case image
        /// Web URL。
        case url
        /// 纯文本 / HTML / RTF。
        case text
    }

    /// 探测类型数组覆盖了哪些类别，返回按优先级排序的类别列表。
    static func availableCategories(in types: [NSPasteboard.PasteboardType]) -> [Category] {
        Category.allCases.filter { supports($0, types: types) }
    }

    /// 按优先级取最高的类别；无可处理类型时返回 nil（拖入应被拒绝）。
    static func preferredCategory(in types: [NSPasteboard.PasteboardType]) -> Category? {
        availableCategories(in: types).first
    }

    /// 类型数组是否支持指定类别。
    static func supports(_ category: Category, types: [NSPasteboard.PasteboardType]) -> Bool {
        switch category {
        case .filePromise:
            types.contains { filePromiseTypes.contains($0) }
        case .fileURL:
            types.contains(fileURL)
        case .image:
            types.contains { imageTypes.contains($0) }
        case .url:
            types.contains(url)
        case .text:
            types.contains { textTypes.contains($0) }
        }
    }

    /// 图片数据中优先物化的类型：PNG 直接落盘，TIFF/通用 image 需转码为 PNG。
    static func preferredImageType(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imageTypes.first { types.contains($0) }
    }
}
