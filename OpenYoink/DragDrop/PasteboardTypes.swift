import AppKit
import UniformTypeIdentifiers

/// 拖入/拖出共用的 pasteboard 类型常量与能力探测。
///
/// 能力探测全部为纯函数（输入类型数组、输出类别集合），不触碰具体
/// pasteboard 实例，因此可以在单测中直接断言分派顺序，而无需构造
/// 真实的拖拽会话。处理顺序遵循调研报告 F-03 与实施计划 §2.3：
/// file promise → fileURL → 图片数据 → URL → 文本；任务一起在其后追加
/// 兜底链（URL 变体 → 仅 HTML/RTF 物化 → 通用数据物化 → 字符串兜底，
/// 见 `DropImportCoordinator`），注册清单相应放宽为「万能拖入」
/// （各类型的 conformance 探针结论见 `PasteboardConformanceProbeTests`
/// 与本文件各常量注释）。
enum PasteboardTypes {
    // MARK: - Type constants

    /// `public.file-url` —— Finder 及多数应用的文件拖放表示。
    static let fileURL: NSPasteboard.PasteboardType = .fileURL
    /// Chromium's macOS file-upload drop path still reads the legacy
    /// filename-list flavor even when `public.file-url` is present. AppKit no
    /// longer exposes the deprecated constant to Swift, so keep the wire
    /// value local and advertise it only alongside a real direct file URL.
    static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
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
    /// `public.text`（通用文本超类型；注册后靠 conformance 覆盖 utf16 等其他文本 flavor）。
    static let text = NSPasteboard.PasteboardType(UTType.text.identifier)
    /// `text/uri-list` —— 非 UTI 的 MIME flavor（探针：`UTType("text/uri-list")` 为 nil，
    /// pasteboard 把它桥接为 dyn.* 动态类型）。浏览器多链接拖放的 URL 列表表示。
    static let uriList = NSPasteboard.PasteboardType("text/uri-list")
    /// `public.vcard`（联系人卡片，扩展名 vcf）。
    static let vCard = NSPasteboard.PasteboardType(UTType.vCard.identifier)
    /// `public.calendar-event`。探针结论：该类型在系统中 declared 但**无任何
    /// supertypes**，泛型注册（public.data 等）覆盖不到它，必须显式注册。
    static let calendarEvent = NSPasteboard.PasteboardType(UTType.calendarEvent.identifier)
    /// `public.email-message`。探针结论：仅 conforms to `public.message`，
    /// 不挂在 data/item 之下，必须显式注册（Mail 邮件拖放走此类型或 promise）。
    static let emailMessage = NSPasteboard.PasteboardType(UTType.emailMessage.identifier)
    /// `public.data` —— 泛型兜底。探针结论：`availableType(from:)` 沿 UTI
    /// conformance 展开（声明 public.png 的 pasteboard 命中 public.data/public.image，
    /// 甚至可转换出 public.tiff）；非 UTI 的 legacy flavor（text/uri-list、
    /// NSFilenamesPboardType 等）被桥接成 dyn.* 动态类型后同样命中 public.data。
    /// 未声明的反向域名自定义标识（系统不知其 conformance）例外，无法命中。
    static let data = NSPasteboard.PasteboardType(UTType.data.identifier)
    /// `public.item` —— 万物之根（含 URL 族；public.url conforms to public.item，
    /// 探针：声明 public.url 的 pasteboard 命中 public.item/public.data）。
    static let item = NSPasteboard.PasteboardType(UTType.item.identifier)
    /// `public.content`。
    static let content = NSPasteboard.PasteboardType(UTType.content.identifier)
    /// `public.file-contents`（NSFileContentsPboardType 的 UTI 形态；SDK 无
    /// 对应 `UTType` 静态属性，用字面量注册）。
    static let fileContents = NSPasteboard.PasteboardType("public.file-contents")
    /// 快速上手练习的进程私有令牌。它只用于确认同一 tutorial session 的
    /// 真实拖入/拖出，不携带文件内容，也不进入普通拖放注册清单。
    static let tutorialSession = NSPasteboard.PasteboardType("com.weijue.OpenYoink.tutorial-session")

    /// `NSFilePromiseReceiver` 可读取的 promise 类型（Apple 推荐直接用其
    /// `readableDraggedTypes` 注册，而不是手写 UTI 字符串）。
    static let filePromiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// 图片数据族，按物化时的优先顺序排列（PNG 免转换，TIFF 需转码）。
    static let imageTypes: [NSPasteboard.PasteboardType] = [png, tiff, image]
    /// 文本族。主链仅物化 plain text；仅含 HTML/RTF（无 plain text）的拖放由
    /// `DropImportCoordinator` 兜底链物化为 .html/.rtf 文件项（任务一）。
    static let textTypes: [NSPasteboard.PasteboardType] = [plainText, html, rtf]

    /// 宽兜底注册类型（任务一「万能拖入」）。注册后 AppKit 按 conformance 匹配
    /// 拖放类型（见上各常量注释的探针结论），几乎一切可拖内容都会抵达
    /// `draggingEntered`；读不出内容时的拒绝由 `DropImportCoordinator` 兜底链承担。
    /// 它们**不作为物化首选**（无语义/扩展名），仅在 `materializationCandidates`
    /// 的最后梯队出现（item 只声明 public.data 且确有 payload 时不丢内容）。
    static let genericFallbackTypes: [NSPasteboard.PasteboardType] = [data, item, content, fileContents]

    /// `DragContainerView` / `EdgeTabView` 注册的全部拖入类型。
    /// 任务一起放宽：主链类型 + URL 变体/无 conformance 的具体类型 + 泛型兜底。
    static let dragInTypes: [NSPasteboard.PasteboardType] =
        filePromiseTypes + [fileURL] + imageTypes + [url] + textTypes
        + [text, uriList, vCard, calendarEvent, emailMessage]
        + genericFallbackTypes

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

    // MARK: - Drop-everything acceptance & generic materialization (任务一)

    /// 拖入高亮/接收判定（「Drop everything」语义）。宽兜底注册后，能抵达
    /// `draggingEntered` 的拖放几乎总能由兜底链物化出点什么 —— 只要声明了
    /// 任意类型就接受高亮；真正零内容（无任何类型声明）才拒绝。
    /// 自身拖出回落由调用方的 `draggingSource == nil` 守卫负责，不在此判定。
    static func hasImportableContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.isEmpty
    }

    /// 兜底链之外已由主链/专门分支处理的类型：通用物化候选中排除。
    /// （html/rtf 走富文本物化分支；plainText/url/fileURL/uri-list 各有专属路径。）
    static let handledElsewhereTypes: [NSPasteboard.PasteboardType] =
        [fileURL, url, uriList] + textTypes + filePromiseTypes

    /// 无 `preferredFilenameExtension` 的已知类型的扩展名兜底（探针 B：
    /// calendar-event / email-message 均无扩展名标签，但物化文件必须有正确
    /// 扩展名才能被 Calendar/Mail 等目标识别）。
    static let wellKnownExtensionFallback: [NSPasteboard.PasteboardType: String] = [
        calendarEvent: "ics",
        emailMessage: "eml",
    ]

    /// 通用物化候选：类型 + 所属梯队（1 最具体，3 最泛）。
    struct MaterializationCandidate: Equatable, Sendable {
        let type: NSPasteboard.PasteboardType
        /// 1 = 已声明非动态 UTI 且有扩展名；2 = 已声明非动态 UTI 无扩展名；
        /// 3 = 动态/桥接/legacy flavor 或泛型信号类型。
        let tier: Int
    }

    /// 通用数据物化的候选类型排序（纯函数；同梯队内保持声明顺序）：
    /// - tier1：已声明、非动态 UTI 且带 `preferredFilenameExtension`（最具体）；
    /// - tier2：已声明、非动态 UTI 但无扩展名（如 calendar-event/email-message）；
    /// - tier3：动态/桥接/legacy flavor 与泛型信号类型 —— data 也是内容，
    ///   item 只声明 public.data 且有 payload 时不丢（探针第 10 组）。
    ///   tier3 中若 `string(forType:)` 能读出非空内容，调用方应让给字符串兜底
    ///   分支产出文本项（比 .dat 更有用 —— 如 utf8-external-plain-text 这类
    ///   UTType 解析为 nil 的文本 flavor）。
    /// 文本族（已声明、conforms to .text 且无扩展名）与 URL 族不入选：交给
    /// 字符串兜底分支。`handledElsewhereTypes` 整体排除。
    static func materializationCandidates(in types: [NSPasteboard.PasteboardType]) -> [MaterializationCandidate] {
        let excluded = Set(handledElsewhereTypes)
        var tier1: [MaterializationCandidate] = []
        var tier2: [MaterializationCandidate] = []
        var tier3: [MaterializationCandidate] = []
        for type in types where !excluded.contains(type) {
            guard let utType = UTType(type.rawValue), !utType.isDynamic else {
                tier3.append(MaterializationCandidate(type: type, tier: 3)) // 非 UTI 字符串或 dyn.* 动态桥接 flavor
                continue
            }
            if utType.preferredFilenameExtension != nil {
                tier1.append(MaterializationCandidate(type: type, tier: 1))
            } else if genericFallbackTypes.contains(type) {
                tier3.append(MaterializationCandidate(type: type, tier: 3))
            } else if utType.conforms(to: .text) || utType.conforms(to: .url) {
                continue // 无扩展名的文本/URL 类：字符串兜底分支更合适
            } else {
                tier2.append(MaterializationCandidate(type: type, tier: 2))
            }
        }
        return tier1 + tier2 + tier3
    }

    /// 物化文件的扩展名：类型的 preferredFilenameExtension → 已知兜底表 → "dat"。
    static func materializationFileExtension(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let ext = utType.preferredFilenameExtension, !ext.isEmpty {
            return ext
        }
        return wellKnownExtensionFallback[type] ?? "dat"
    }

    /// 物化项目的显示名基名（不含扩展名）：类型的 localizedDescription
    /// （如 vCard → "electronic business card"），取不到时本地化「Dropped Item」。
    static func materializedDisplayBaseName(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let description = utType.localizedDescription, !description.isEmpty {
            return description
        }
        return String(localized: "Dropped Item")
    }
}
