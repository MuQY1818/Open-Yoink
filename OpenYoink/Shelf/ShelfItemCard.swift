import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Visible, non-color-only card state. Completed transfers deliberately resolve
/// to nil so the normal ready card remains quiet.
enum ShelfCardVisualStatus: Equatable {
    case receiving
    case delivering
    case destinationAccepted
    case deliveryFailed
    case managedCopy

    static func resolve(item: ShelfItem,
                        transferStatus: TransferItemAccessibilityStatus?) -> Self? {
        switch transferStatus {
        case .receiving: return .receiving
        case .delivering: return .delivering
        case .destinationAccepted: return .destinationAccepted
        case .deliveryFailed: return .deliveryFailed
        case .added, .delivered: break
        case nil: break
        }
        return item.isCut ? .managedCopy : nil
    }

    var title: String {
        switch self {
        case .receiving: String(localized: "Receiving…")
        case .delivering: String(localized: "Delivering…")
        case .destinationAccepted: String(localized: "Destination accepted")
        case .deliveryFailed: String(localized: "Not delivered")
        case .managedCopy: String(localized: "Managed copy · Original in Trash")
        }
    }

    var symbolName: String {
        switch self {
        case .receiving: "arrow.down.circle"
        case .delivering: "arrow.up.circle"
        case .destinationAccepted: "checkmark.circle"
        case .deliveryFailed: "exclamationmark.triangle.fill"
        case .managedCopy: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .receiving, .delivering, .destinationAccepted: .secondary
        case .deliveryFailed: .red
        case .managedCopy: .orange
        }
    }
}

/// 单项目卡片（12pt 圆角、缩略图区、两行名称、语义状态 + 来源应用小图标）。
///
/// 缩略图策略：file/folder/image 异步走 `QLThumbnailGenerator` 真实缩略图，
/// 失败或加载中回退 `NSWorkspace.icon(forFile:)`；text 显示文本片段预览；
/// url 显示 SF Symbol 链接占位。`isStale`（bookmark 失效）项目整体降透明度，
/// 并在左上角叠加感叹号角标。
///
/// 右键菜单（S6）：Quick Look / Open / Show in Finder（按 kind 与 stale 状态
/// 自动禁用，stale 项改显示「File Unavailable」），「Remove from Shelf」直接可用
/// （`ShelfStore.remove(ids:)` 由调用方封装注入）。双击卡片 = Quick Look。
///
/// 拖出（S5）：卡片覆盖 `CardDragSourceBridge`（NSViewRepresentable）作为鼠标
/// 事件权威 —— mouseDragged 超阈值即开始 `NSDraggingSession`（按 §2.1 决策不走
/// SwiftUI onDrag），mouseUp 无拖拽回落为点击（单击选择并让面板成为 key 以接通
/// 空格/Delete/Esc 键盘链路；clickCount ≥ 2 双击触发 Quick Look）。拖拽内容与
/// 批量语义由 `dragContentsProvider`（父视图注入）决定，实际会话由环境里的
/// `DragOutController` 启动。
struct ShelfItemCard: View {
    /// 展示的项目。
    let item: ShelfItem
    /// 选中态（§3：accent color 描边 + 浅色填充）。
    let isSelected: Bool
    /// Keyboard focus is independent from multi-selection and gets its own ring.
    let isKeyboardFocused: Bool
    /// 点击回调；additive 为 true 表示 ⌘点击（切换选中），否则单选。
    let onSelect: (_ additive: Bool) -> Void
    /// 「Remove from Shelf」。同时驱动右键菜单移除项与 UX4 悬停 ✕ 按钮；
    /// 为 nil 时两者都不呈现（移除语义由父视图决定注入）。
    var onRemove: (() -> Void)?
    /// v1.2: safe recovery action selected by the parent (external reconnect,
    /// managed storage, or review a stack's unavailable children).
    var onRecover: (() -> Void)?
    /// One-shot copy action, exposed in the context menu and accessibility rotor.
    var onCopy: (() -> Void)?
    /// Runtime-only import/export state appended to the VoiceOver label.
    var transferStatus: TransferItemAccessibilityStatus?
    /// 决定缩略图内容的项目；默认与 `item` 相同。Stack 卡片传入第一个文件类子项。
    var thumbnailItem: ShelfItem?
    /// S5 拖出内容计算：给定被拖卡片项目，返回本次拖出的项目集合与涉及的顶层
    /// id（多选整批 / stack 语义由父视图决定）。nil 时拖出单卡项目。
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    /// QL / Workspace 缩略图（已合成 SwiftUI Image，Sendable，跨任务传递安全）。
    @State private var thumbnail: Image?
    /// 来源应用小图标（按 `sourceApp.bundleID` 经 LaunchServices 解析）。
    @State private var sourceAppIcon: NSImage?
    /// UX4: 卡片悬停态（驱动右上角 ✕ 移除按钮淡入淡出）。
    @State private var isHovering = false
    /// S4: 缩略图加载经 bookmark 解析文件访问权（见 `ThumbnailLoader`）。
    @Environment(\.bookmarkService) private var bookmarkService
    /// S5: 拖出总控；nil（Preview/单测）时拖拽关闭、点击不受影响。
    @Environment(\.dragOutController) private var dragOutController
    /// S6: Quick Look 会话；nil（Preview/单测）时 QL 入口禁用。
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    /// S6: text 项打开/定位需写临时 .txt（见 `ItemActions`）。
    @Environment(\.tempFileService) private var tempFileService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static let cornerRadius: CGFloat = 12
    /// 缩略图区高度（点）；宽度随网格列（~88pt）。
    static let thumbnailHeight: CGFloat = 52

    init(item: ShelfItem,
         isSelected: Bool,
         isKeyboardFocused: Bool = false,
         onSelect: @escaping (_ additive: Bool) -> Void,
         onRemove: (() -> Void)? = nil,
         onRecover: (() -> Void)? = nil,
         onCopy: (() -> Void)? = nil,
         transferStatus: TransferItemAccessibilityStatus? = nil,
         thumbnailItem: ShelfItem? = nil,
         dragContentsProvider: ((ShelfItem) -> DragOutContents)? = nil) {
        self.item = item
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onRecover = onRecover
        self.onCopy = onCopy
        self.transferStatus = transferStatus
        self.thumbnailItem = thumbnailItem
        self.dragContentsProvider = dragContentsProvider
    }

    var body: some View {
        VStack(spacing: 5) {
            if item.availability == .available {
                thumbnailArea
            } else {
                availabilityArea
            }
            nameRow
            if let status = ShelfCardVisualStatus.resolve(item: item,
                                                          transferStatus: transferStatus) {
                statusRow(status)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background { surface }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay { availabilityBorder }
        .overlay { keyboardFocusRing }
        .overlay(alignment: .topLeading) { selectionBadge }
        // S5 拖出事件层：透明 NSView 覆盖整卡，成为左键事件权威
        //（mouseDown 记录 → mouseDragged 超阈值开始拖拽；mouseUp 无拖拽回落为
        // 点击选择 / 双击 Quick Look）。右键（contextMenu）与滚动透传给 SwiftUI。
        .overlay {
            if item.availability == .available {
                CardDragSourceBridge(
                    itemID: item.id,
                    onClick: onSelect,
                    onDoubleClick: { quickLookCoordinator?.toggle(contextItem: item) },
                    onDragBegin: { sourceView, event in
                        guard let dragOutController else { return }
                        let contents = dragContentsProvider?(item)
                            ?? DragOutContents(items: [item], topLevelIDs: [item.id])
                        dragOutController.beginDrag(contents: contents,
                                                    originatingItemID: item.id,
                                                    from: sourceView,
                                                    event: event)
                    }
                )
            }
        }
        // UX4: 悬停 ✕ 移除按钮。z 序在拖出事件层之上 —— 命中测试先到达
        // SwiftUI Button，落在 ✕ 上的点击不会触发选择或拖出；未悬停时
        // 透明且关闭命中测试，不影响卡片的点击/拖拽/框选。
        .overlay(alignment: .topTrailing) { removeButton }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .contextMenu { contextMenu }
        // D9: 卡片作为整体暴露给 VoiceOver —— 名称 + 本地化 kind（stack 附带
        // 子项数）+ stale 态；选中态走 .isSelected trait；双击 = Quick Look。
        // UX4: 卡片忽略子元素（✕ 对 VoiceOver 不可见），移除操作改以自定义
        // action 暴露（rotor「操作」中可触发）。
        .accessibilityElement(children: item.availability == .available ? .ignore : .contain)
        .accessibilityIdentifier("shelf.item.\(item.id.uuidString)")
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(Text(cardAccessibilityHint))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if item.availability == .available,
               quickLookCoordinator != nil,
               ItemActions.canQuickLook(item) {
                Button("Quick Look") { quickLookCoordinator?.toggle(contextItem: item) }
            }
            if item.availability == .available, ItemActions.canOpen(item) {
                Button("Open") {
                    ItemActions.open(item,
                                     bookmarkService: bookmarkService,
                                     tempFileService: tempFileService)
                }
            }
            if item.availability == .available, ItemActions.canRevealInFinder(item) {
                Button("Show in Finder") {
                    ItemActions.revealInFinder(item,
                                               bookmarkService: bookmarkService,
                                               tempFileService: tempFileService)
                }
            }
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
            }
            if let onCopy {
                Button("Copy", action: onCopy)
            }
            if let onRemove {
                Button("Remove from Shelf", action: onRemove)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard item.availability != .available else { return }
            onSelect(NSEvent.modifierFlags.contains(.command))
        })
        .task(id: item) { await loadAssets() }
    }

    /// UX4: 悬停浮现的移除小圆钮（SF Symbol xmark，material 底保证在各种
    /// 缩略图上可读）。点击 = 从 shelf 移除（`onRemove` 由父视图注入；
    /// 为 nil 时不渲染）。
    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background { Circle().fill(.regularMaterial) }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(isHovering || isKeyboardFocused ? 1 : 0)
            .allowsHitTesting(isHovering || isKeyboardFocused)
            .help("Remove from Shelf")
            .accessibilityLabel(Text("Remove from Shelf"))
            .accessibilityIdentifier("shelf.item.\(item.id.uuidString).remove")
        }
    }

    /// D9: VoiceOver 标签（如「Report.pdf, 文件」/「Screenshots, 堆叠, 3 个项目」）。
    /// F-05: 剪切项追加「拖出时将移动原文件」语义。
    private var cardAccessibilityLabel: Text {
        var label = "\(item.displayName), \(Self.localizedKindName(for: item.kind))"
        if item.kind == .stack, let count = item.children?.count {
            label += ", " + String(localized: "\(count) items")
        }
        if item.isCut {
            label += ", " + String(localized: "Managed copy; original file moved to Trash")
        }
        label += isSelected
            ? ", " + String(localized: "Selected")
            : ", " + String(localized: "Not selected")
        if isKeyboardFocused {
            label += ", " + String(localized: "Keyboard focus")
        }
        switch item.availability {
        case .available:
            label += ", " + String(localized: "Available")
        case .externalFileOffline:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Original file unavailable")
        case .managedCopyMissing:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Managed copy missing")
        }
        if let transferStatus {
            label += ", " + transferStatus.localizedDescription
        }
        return Text(label)
    }

    private var cardAccessibilityHint: String {
        if item.availability != .available {
            return availabilityActionHint
        }
        if item.kind == .stack {
            return String(localized: "Press Return to review the stack.")
        }
        return String(localized: "Press Space for Quick Look or Return to open.")
    }

    /// 本地化的 kind 名称（可访问性标签用）。
    static func localizedKindName(for kind: ItemKind) -> String {
        switch kind {
        case .file: String(localized: "File")
        case .folder: String(localized: "Folder")
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        case .url: String(localized: "Link")
        case .stack: String(localized: "Stack")
        }
    }

    // MARK: - Thumbnail area

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack {
            switch item.kind {
            case .text:
                textSnippetPreview
            case .url:
                urlPlaceholder
            case .file, .folder, .image, .stack:
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    kindPlaceholder
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.thumbnailHeight)
    }

    /// text 类型：文本片段预览样式（多行截断 + 文本底色）。
    private var textSnippetPreview: some View {
        Text(item.text ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
    }

    /// url 类型：SF Symbol 链接占位 + 域名（S10 可替换为真实 favicon）。
    private var urlPlaceholder: some View {
        VStack(spacing: 3) {
            Image(systemName: "link")
                .font(.title3)
            if let host = item.urlString.flatMap({ URL(string: $0)?.host() }) {
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 缩略图加载完成前的占位（按 kind 取符号）。
    private var kindPlaceholder: some View {
        Image(systemName: placeholderSymbolName)
            .font(.system(size: 26))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderSymbolName: String {
        switch item.kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .text: "doc.text"
        case .url: "link"
        case .stack: "square.stack.3d.up"
        }
    }

    // MARK: - Availability

    /// Fixed-height status content replaces the thumbnail for unavailable
    /// items, keeping the grid geometry stable while exposing a real button.
    private var availabilityArea: some View {
        VStack(spacing: 2) {
            Label(availabilityStatusText, systemImage: availabilitySymbolName)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(minHeight: 24)
                    .accessibilityIdentifier("shelf.item.\(item.id.uuidString).recover")
                    .accessibilityHint(Text(availabilityActionHint))
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.thumbnailHeight)
    }

    private var availabilityStatusText: String {
        if item.kind == .stack { return String(localized: "Items unavailable") }
        switch item.availability {
        case .available: return String(localized: "Available")
        case .externalFileOffline: return String(localized: "Original missing")
        case .managedCopyMissing: return String(localized: "Managed copy missing")
        }
    }

    private var availabilityActionTitle: String {
        if item.kind == .stack { return String(localized: "Review…") }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline: return String(localized: "Locate…")
        case .managedCopyMissing: return String(localized: "Recovery…")
        }
    }

    private var availabilityActionHint: String {
        if item.kind == .stack {
            return String(localized: "Expand the stack to review unavailable items.")
        }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline:
            return String(localized: "Locate the original file to reconnect it.")
        case .managedCopyMissing:
            return String(localized: "Open Storage settings to review recovery data.")
        }
    }

    private var availabilitySymbolName: String {
        switch item.availability {
        case .available: "checkmark.circle"
        case .externalFileOffline: "questionmark.folder"
        case .managedCopyMissing: "externaldrive.badge.exclamationmark"
        }
    }

    // MARK: - Name row

    /// 名称行：来源应用图标 + 最多两行名称。语义字体随系统文字大小变化；
    /// 卡片纵向扩展而不缩小文字。
    private var nameRow: some View {
        HStack(alignment: .top, spacing: 3) {
            if let sourceAppIcon {
                Image(nsImage: sourceAppIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// One concise semantic state line. Active transfer/failure takes
    /// precedence over the persistent managed-copy label; completed transfers
    /// return to the quiet ready state.
    private func statusRow(_ status: ShelfCardVisualStatus) -> some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .accessibilityIdentifier("shelf.item.\(item.id.uuidString).status")
    }

    // MARK: - Surfaces & badges

    /// 卡片底色与选中态（§3：accent 描边 + 浅色填充）；非选中用语义色弱底 + 细描边。
    private var surface: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(isSelected ? Color.accentColor.opacity(0.18)
                             : Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: isSelected ? 2 : 0.5)
            }
    }

    /// Unavailable state uses a dashed shape in addition to icon/text, so the
    /// distinction remains visible with “Differentiate Without Color”.
    @ViewBuilder
    private var availabilityBorder: some View {
        if item.availability != .available {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(
                    Color.primary.opacity(0.48),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var keyboardFocusRing: some View {
        if isKeyboardFocused {
            RoundedRectangle(cornerRadius: Self.cornerRadius - 2)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor),
                              lineWidth: colorSchemeContrast == .increased ? 4 : 3)
                .padding(2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected && differentiateWithoutColor {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Context menu

    /// S6 项目操作：Quick Look / Open / Show in Finder 按 kind 可用性禁用；
    /// stale 项（bookmark 失效）三者均无意义，改显示「File Unavailable」态。
    /// 可用性规则与操作实现见 `ItemActions`；Quick Look 命中多选时预览整个
    /// 选中集合（规则见 `QuickLookPreviewPlanner`）。
    @ViewBuilder
    private var contextMenu: some View {
        if item.availability != .available {
            Label(availabilityStatusText, systemImage: availabilitySymbolName)
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
            }
        } else {
            Button("Quick Look") { quickLookCoordinator?.toggle(contextItem: item) }
                .disabled(quickLookCoordinator == nil || !ItemActions.canQuickLook(item))
            Button("Open") {
                ItemActions.open(item, bookmarkService: bookmarkService, tempFileService: tempFileService)
            }
            .disabled(!ItemActions.canOpen(item))
            Button("Show in Finder") {
                ItemActions.revealInFinder(item, bookmarkService: bookmarkService, tempFileService: tempFileService)
            }
            .disabled(!ItemActions.canRevealInFinder(item))
        }
        if let onCopy {
            Button("Copy", action: onCopy)
        }
        if let onRemove {
            Divider()
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
    }

    // MARK: - Asset loading

    /// 加载缩略图与来源应用图标。QL 生成在后台执行，失败回退 NSWorkspace 图标。
    private func loadAssets() async {
        thumbnail = await ThumbnailLoader.thumbnail(
            for: thumbnailItem ?? item,
            pointSize: CGSize(width: 88, height: Self.thumbnailHeight),
            bookmarkService: bookmarkService
        )
        sourceAppIcon = ThumbnailLoader.sourceAppIcon(bundleID: item.sourceApp?.bundleID)
    }
}

// MARK: - ThumbnailLoader

/// 卡片缩略图加载：`QLThumbnailGenerator` 真实缩略图 + `NSWorkspace` 图标回退。
///
/// 并发说明（Swift 6 严格并发）：`QLThumbnailRepresentation`/`NSImage` 均非 Sendable。
/// QL 调用放在非隔离上下文执行（结果不跨 actor，仅把 `@unchecked Sendable` 的
/// `CGImage` 交回 MainActor）；NSWorkspace 图标在 MainActor 同步取用后即刻合成
/// SwiftUI `Image`（Sendable），因此对外只暴露 `Image`/`CGImage`。
enum ThumbnailLoader {
    /// file/folder/image（有磁盘路径的 kind）：优先 QL 真实缩略图，失败回退
    /// NSWorkspace 图标。无路径（text/url/stack 无文件子项）返回 nil，由卡片渲染占位。
    ///
    /// S4 起统一经 bookmark 解析：`item.bookmark` 存在时先解析出 URL 并
    /// `startAccessing`（沙箱下重启后只有解析 security-scoped bookmark 才有
    /// 文件读取权限），加载完成后配对 `stopAccessing`；解析失败回退原始路径。
    @MainActor
    static func thumbnail(for item: ShelfItem, pointSize: CGSize, bookmarkService: BookmarkService) async -> Image? {
        guard let baseURL = item.fileURL else { return nil }
        var url = baseURL
        var accessedURL: URL?
        if let bookmark = item.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            url = resolved.url
            if bookmarkService.startAccessing(url) {
                accessedURL = url
            }
        }
        defer {
            if let accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cgImage = await quickLookThumbnail(for: url, pointSize: pointSize, scale: scale) {
            // S10/C7: 登记到拖拽图像缓存，拖出时（同步路径）直接取用真实缩略图。
            DragImageCache.register(cgImage, for: item.id)
            return Image(decorative: cgImage, scale: scale)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var proposedRect = NSRect(origin: .zero, size: icon.size)
        if let cgIcon = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            DragImageCache.register(cgIcon, for: item.id)
        }
        return Image(nsImage: icon)
    }

    /// 来源应用小图标；bundleID 缺失或无法解析时返回 nil。
    @MainActor
    static func sourceAppIcon(bundleID: String?) -> NSImage? {
        guard let bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// QL 缩略图生成。非隔离：`QLThumbnailRepresentation` 非 Sendable，在此就地
    /// 提取 CGImage，避免非 Sendable 值跨 actor 传递。
    private nonisolated static func quickLookThumbnail(for url: URL,
                                                       pointSize: CGSize,
                                                       scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: pointSize, scale: scale, representationTypes: .thumbnail
        )
        // 调用方（thumbnail(for:pointSize:bookmarkService:)）已解析 bookmark 并
        // startAccessing，此处直接读取。生成失败/无缩略图时返回 nil，
        // 由调用方回退到 NSWorkspace 图标。
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }
}

// MARK: - DragImageCache (S10/C7)

/// 拖拽图像缓存：卡片缩略图（QL 真实缩略图 / NSWorkspace 图标回退）加载成功后
/// 按项目 id 登记 CGImage，供 `DragPayloadBuilder.dragImage` 在拖拽启动的
/// 同步路径上取用。CGImage 为不可变值类型（标注 Sendable 语义安全），跨
/// MainActor 边界传递无风险。
///
/// 容量封顶：超出即整体清空重建 —— 缓存未命中只是回退系统图标，代价低；
/// 逐条 LRU 对 64pt 小图得不偿失。text/url 项无文件缩略图，不进入缓存
/// （拖拽图像回退 SF Symbol，与卡片占位一致）。
@MainActor
enum DragImageCache {
    private static var images: [UUID: CGImage] = [:]
    private static let capacity = 256

    static func register(_ image: CGImage, for id: UUID) {
        if images.count >= capacity {
            images.removeAll()
        }
        images[id] = image
    }

    static func image(for id: UUID) -> CGImage? {
        images[id]
    }
}

// MARK: - BookmarkService environment

/// SwiftUI 环境注入 BookmarkService（卡片缩略图/后续打开操作经 bookmark 解析
/// 文件访问权）。默认值供 Preview 与测试使用；App 入口注入共享实例。
private struct BookmarkServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = BookmarkService()
}

extension EnvironmentValues {
    var bookmarkService: BookmarkService {
        get { self[BookmarkServiceEnvironmentKey.self] }
        set { self[BookmarkServiceEnvironmentKey.self] = newValue }
    }
}

// MARK: - CardDragSourceBridge (S5 拖出事件层)

/// S5 拖出桥接：每张卡片覆盖一个透明 NSView，作为卡片区域的鼠标事件权威。
///
/// 点击/拖拽/双击仲裁：
/// - `mouseDown` 记录按下位置；
/// - `mouseDragged` 位移超阈值（4pt）→ 回调 `onDragBegin`（由
///   `DragOutController` 启动 `beginDraggingSession`；多选整批/stack 展开
///   由卡片的 `dragContentsProvider` 决定）；
/// - `mouseUp` 且未拖拽 → 回落为点击：`clickCount >= 2` 回调 `onDoubleClick`
///   （S6 双击 Quick Look，首次点击已完成选择，不再重复切换）；否则单击 ——
///   先让所在窗口成为 key（nonactivating 面板只接键盘焦点、不激活应用，
///   接通空格/Delete/Esc 键盘链路），再回调 `onClick`（普通点击单选 /
///   ⌘点击 toggle，与 S3 语义一致）。
///
/// 右键（SwiftUI contextMenu）与滚动透传：`hitTest` 只在左键事件期间接管
/// （ctrl+click 视为右键）。一旦拖拽开始，后续事件由 NSDraggingSession 接管。
struct CardDragSourceBridge: NSViewRepresentable {
    /// 锚点对应的项目 id（调试/日志用）。
    let itemID: UUID
    /// 无拖拽的单击 mouseUp（点击选择）。闭包在 MainActor 词法上下文（View body）
    /// 中创建并继承其隔离；显式标注 @MainActor 参数类型会触发非 Sendable 函数
    /// 值的跨界转换检查，故保持普通类型。
    let onClick: (_ additive: Bool) -> Void
    /// 双击（S6：Quick Look）。
    let onDoubleClick: () -> Void
    /// mouseDragged 超阈值；参数为锚点视图与当前事件。
    let onDragBegin: (_ sourceView: NSView, _ event: NSEvent) -> Void

    func makeNSView(context: Context) -> CardDragSourceAnchorView {
        let view = CardDragSourceAnchorView()
        view.itemID = itemID
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragBegin = onDragBegin
        return view
    }

    func updateNSView(_ nsView: CardDragSourceAnchorView, context: Context) {
        nsView.itemID = itemID
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragBegin = onDragBegin
    }
}

/// `CardDragSourceBridge` 的底层 NSView。
final class CardDragSourceAnchorView: NSView {
    var itemID: UUID?
    var onClick: ((_ additive: Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegin: ((_ sourceView: NSView, _ event: NSEvent) -> Void)?

    /// 拖拽触发位移阈值（点）。
    static let dragThreshold: CGFloat = 4

    private var mouseDownLocation: NSPoint?
    private var dragStarted = false

    /// 左键事件（不含 ctrl+click，它等于右键）接管本视图；其余事件透传给
    /// 下层 SwiftUI 内容（contextMenu 依赖 rightMouseDown，滚动依赖 ScrollView）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return nil
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let downLocation = mouseDownLocation else { return }
        let location = event.locationInWindow
        let distance = hypot(location.x - downLocation.x, location.y - downLocation.y)
        guard distance >= Self.dragThreshold else { return }
        dragStarted = true
        onDragBegin?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragStarted = false
        }
        // 拖拽开始后手势由 NSDraggingSession 接管，正常不会再收到 mouseUp；
        // 防御性判断，避免把拖拽结束误当点击。
        guard !dragStarted else { return }
        // S6: 双击 → Quick Look（首次点击已完成选择，此处不再切换选择）。
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        // 无拖拽 → 点击选择。先让所在窗口成为 key：nonactivating 面板只接键盘
        // 焦点、不激活应用，是空格/Delete/Esc 键盘链路（ShelfPanel.keyDown）的入口。
        window?.makeKey()
        onClick?(event.modifierFlags.contains(.command))
    }
}

// MARK: - Previews

#Preview("Item cards") {
    let items = ShelfPreviewFixtures.sampleItems().filter { $0.kind != .stack }
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
        ForEach(items) { item in
            ShelfItemCard(item: item,
                          isSelected: item.kind == .image,
                          onSelect: { _ in },
                          onRemove: {})
        }
    }
    .padding()
    .frame(width: 320)
}
