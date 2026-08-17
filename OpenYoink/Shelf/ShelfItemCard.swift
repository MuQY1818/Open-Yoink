import AppKit
import QuickLookThumbnailing
import SwiftUI

/// 单项目卡片（实施计划 §3：12pt 圆角、缩略图区、单行截断名称 + 来源应用小图标）。
///
/// 缩略图策略：file/folder/image 异步走 `QLThumbnailGenerator` 真实缩略图，
/// 失败或加载中回退 `NSWorkspace.icon(forFile:)`；text 显示文本片段预览；
/// url 显示 SF Symbol 链接占位。`isStale`（bookmark 失效）项目整体降透明度，
/// 并在左上角叠加感叹号角标。
///
/// 右键菜单：Quick Look / Open / Show in Finder 为 S6 占位（disabled + TODO），
/// 「Remove from Shelf」直接可用（`ShelfStore.remove(ids:)` 由调用方封装注入）。
///
/// 拖出预留（S5）：卡片底层挂了 `CardDragSourceBridge`（NSViewRepresentable）作为
/// 视图层级锚点；真正的 NSDraggingSource 在 S5 实现，按 §2.1 决策不走 SwiftUI onDrag。
struct ShelfItemCard: View {
    /// 展示的项目。
    let item: ShelfItem
    /// 选中态（§3：accent color 描边 + 浅色填充）。
    let isSelected: Bool
    /// 点击回调；additive 为 true 表示 ⌘点击（切换选中），否则单选。
    let onSelect: (_ additive: Bool) -> Void
    /// 「Remove from Shelf」。为 nil 时右键菜单不含移除项（如 Stack 浮层中的子项，
    /// 其移除语义随 S5/S6 的 unstack/批量操作一起设计）。
    var onRemove: (() -> Void)?
    /// 决定缩略图内容的项目；默认与 `item` 相同。Stack 卡片传入第一个文件类子项。
    var thumbnailItem: ShelfItem?

    /// QL / Workspace 缩略图（已合成 SwiftUI Image，Sendable，跨任务传递安全）。
    @State private var thumbnail: Image?
    /// 来源应用小图标（按 `sourceApp.bundleID` 经 LaunchServices 解析）。
    @State private var sourceAppIcon: NSImage?

    static let cornerRadius: CGFloat = 12
    /// 缩略图区高度（点）；宽度随网格列（~88pt）。
    static let thumbnailHeight: CGFloat = 52

    init(item: ShelfItem,
         isSelected: Bool,
         onSelect: @escaping (_ additive: Bool) -> Void,
         onRemove: (() -> Void)? = nil,
         thumbnailItem: ShelfItem? = nil) {
        self.item = item
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.thumbnailItem = thumbnailItem
    }

    var body: some View {
        VStack(spacing: 5) {
            thumbnailArea
            nameRow
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background { surface }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .opacity(item.isStale ? 0.55 : 1)
        .overlay(alignment: .topLeading) { staleBadge }
        // S5 拖出锚点：透明 NSView，hitTest 透传，不拦截任何事件。
        .background { CardDragSourceBridge(itemID: item.id) }
        .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.command)) }
        .contextMenu { contextMenu }
        .task(id: item.id) { await loadAssets() }
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

    // MARK: - Name row

    /// 名称行：来源应用 12pt 小图标 + 单行中间截断名称（§3）。
    private var nameRow: some View {
        HStack(spacing: 3) {
            if let sourceAppIcon {
                Image(nsImage: sourceAppIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
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

    /// isStale 角标（bookmark 失效，文件可能被移动/删除；S4 起由 BookmarkService 标记）。
    @ViewBuilder
    private var staleBadge: some View {
        if item.isStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemYellow))
                .padding(4)
                .background { Circle().fill(Color(nsColor: .windowBackgroundColor)) }
                .padding(5)
                .help("File unavailable — it may have been moved or deleted.")
                .allowsHitTesting(false)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        // TODO(S6): 以下三项在 QuickLookCoordinator（QLPreviewPanel 数据源/代理）
        // 与项目操作接入后启用。
        Button("Quick Look") { /* TODO(S6): QuickLookCoordinator.toggle(for: selection) */ }
            .disabled(true)
        Button("Open") { /* TODO(S6): NSWorkspace.shared.open(item.fileURL) */ }
            .disabled(true)
        Button("Show in Finder") { /* TODO(S6): NSWorkspace.activateFileViewerSelecting */ }
            .disabled(true)
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
            pointSize: CGSize(width: 88, height: Self.thumbnailHeight)
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
    @MainActor
    static func thumbnail(for item: ShelfItem, pointSize: CGSize) async -> Image? {
        guard let url = item.fileURL else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cgImage = await quickLookThumbnail(for: url, pointSize: pointSize, scale: scale) {
            return Image(decorative: cgImage, scale: scale)
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
        // 沙箱注意：应用重启后需先解析 security-scoped bookmark 才有文件读取权限，
        // S4 接入 BookmarkService 后此处自然受益。生成失败/无缩略图时返回 nil，
        // 由调用方回退到 NSWorkspace 图标。
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }
}

// MARK: - CardDragSourceBridge (S5 预留)

/// S5 拖出桥接点：每张卡片内嵌一个透明 NSView 作为视图层级锚点。
///
/// 当前完全惰性：`hitTest` 返回 nil，不参与事件分发，不影响点击/右键菜单。
/// S5 将在此 NSView 上实现 `NSDraggingSource`（mouseDown 跟踪 +
/// `beginDraggingSession`），并对接 `DragPayloadBuilder`（fileURL +
/// NSFilePromiseProvider 双表示）。按实施计划 §2.1，跨应用拖放不使用 SwiftUI onDrag。
struct CardDragSourceBridge: NSViewRepresentable {
    /// 锚点对应的项目 id；S5 据此组装 drag payload（多选时读取 store.selection）。
    let itemID: UUID

    func makeNSView(context: Context) -> CardDragSourceAnchorView {
        CardDragSourceAnchorView()
    }

    func updateNSView(_ nsView: CardDragSourceAnchorView, context: Context) {}
}

/// `CardDragSourceBridge` 的底层 NSView。TODO(S5): 在此实现 NSDraggingSource。
final class CardDragSourceAnchorView: NSView {
    /// 事件全部透传给下层 SwiftUI 内容；本视图仅为拖出锚点。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
