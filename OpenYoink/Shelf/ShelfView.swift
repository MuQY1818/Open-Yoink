import AppKit
import SwiftUI

/// Shelf 根视图（S3：真实内容渲染）。
///
/// 视觉规范（实施计划 §3）：vibrancy 底（.hudWindow 材质）+ 16pt 圆角 +
/// 1pt 内描边（白 8%）；等宽网格（列宽 ~88pt、间距 12pt）纵向滚动；
/// 顶部极简标题栏（名称 + 项目计数）；空时显示 `ShelfEmptyState`。
/// 投影仍由窗口层（`ShelfPanel.hasShadow`）承担，此处不重画。
///
/// 交互：普通点击单选、⌘点击切换多选、空白处点击清除选择并收起 Stack；
/// 空白处拖拽出框选选框（C5：命中卡片纳入多选，⌘ 起拖为追加模式）；
/// 点击 Stack 卡片展开浮层（同时只展开一个），点击外部或再次点击收起。
///
/// S4：`isDropTargeted` / `dropInsertionIndex` 两个预留状态已收敛为
/// `@Environment(DropTargetState.self)`（DragContainerView 驱动高亮与插入指示线）；
/// 卡片弹入动画修饰器（spring, response 0.35, damping 0.7）已就位。
/// C6: 卡片 frame 经 `ShelfGridGeometry` 上报（窗口 .global 坐标），
/// DragContainerView 据此把拖入鼠标位置映射为行列插入下标。
/// D10: 拖入/物化失败的内联提示（`ShelfNoticeModel`）渲染在标题栏下方。
struct ShelfView: View {
    @Environment(ShelfStore.self) private var store

    /// S4: 拖入悬停高亮与插入指示线位置，由 DragContainerView
    /// （NSDraggingDestination 桥接）驱动。
    @Environment(DropTargetState.self) private var dropTargetState
    /// S9: custom 位置模式判定 + 拖动结束后的 frame 持久化（customShelfFrame）。
    @Environment(SettingsStore.self) private var settings
    /// S6: Quick Look 会话；选中变化时同步已打开的预览（nil 时为 no-op）。
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    /// C5/C6: 卡片网格几何（frame 上报 + 框选命中 + 拖入插入定位共用）。
    @Environment(ShelfGridGeometry.self) private var gridGeometry
    /// D10: 拖入/物化失败内联提示。
    @Environment(ShelfNoticeModel.self) private var notices
    /// 当前展开的 Stack id（同时只展开一个）。
    @State private var expandedStackID: UUID?

    /// C5 框选状态：起点/当前点均在窗口 .global 坐标系（与卡片 frame 一致）。
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    /// ⌘ 起拖（追加模式）时的基底选中集合；非追加为空白。
    @State private var marqueeBaseSelection: Set<UUID> = []

    /// 卡片弹入/让位动画（§3：spring, response 0.35, damping 0.7）。
    static let cardAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let cornerRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    /// 网格列宽基准（§3：~88pt 等宽列，adaptive 使 S8 宽度可调时自动增减列数）。
    static let columnWidth: CGFloat = 88

    private let columns = [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Self.gridSpacing)]

    var body: some View {
        VisualEffectBackground(material: .hudWindow, cornerRadius: Self.cornerRadius)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .overlay { content }
            .overlay { dropTargetHighlight }
            .overlay { expandedStackOverlay }
            .overlay(alignment: .top) { noticeBanner }
            .animation(Self.cardAnimation, value: expandedStackID)
            .animation(.easeInOut(duration: 0.2), value: notices.message != nil)
            .padding(8)
            // C5: 框选选框在窗口 .global 坐标系 —— 必须挂在 padding 之后，
            // overlay 局部原点才与窗口内容原点（即 .global 原点）重合。
            .overlay(alignment: .topLeading) { marqueeOverlay }
            // 项目集合变化后清除拖入视觉残留（S4 拖放完成后同样走这里复位）。
            .onChange(of: store.items) {
                dropTargetState.reset()
            }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 4) {
            header
            if store.items.isEmpty {
                ShelfEmptyState()
            } else {
                itemGrid
            }
        }
        .padding(8)
        .background {
            // 空白处点击：清除选择并收起 Stack（卡片自身的点击优先命中，不会触达这里）。
            // C5: 同一背景上挂框选拖拽手势 —— 起始于卡片的事件被
            // CardDragSourceAnchorView 接管、不会到达这里，天然避开与卡片拖出冲突；
            // macOS 上滚动走 scroll wheel 事件，与左键拖拽手势无冲突。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: clearSelectionAndCollapse)
                .gesture(marqueeGesture)
        }
    }

    /// 顶部极简标题栏：shelf 名称 + 项目计数（有多选时显示「选中/总数」）。
    /// S9: custom 位置模式下整栏覆盖 WindowDragHandle（拖动把手），标题前
    /// 加抓握符号提示可拖；拖动结束的最终 frame 持久化到 customShelfFrame。
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if isCustomPosition {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Drag to move"))
            }
            Text("Shelf")
                .font(.headline)
            Spacer()
            Text(countCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .overlay {
            if isCustomPosition {
                WindowDragHandle { frame in
                    settings.customShelfFrame = frame
                }
            }
        }
    }

    private var isCustomPosition: Bool {
        settings.shelfPosition == .custom
    }

    private var countCaption: String {
        store.selection.isEmpty
            ? "\(store.items.count)"
            : String(localized: "\(store.selection.count) of \(store.items.count)")
    }

    // MARK: - Grid

    private var itemGrid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(store.items) { item in
                    gridCell(for: item)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            // 卡片弹入 / 删除淡出 / 重排让位统一走 §3 的 spring 动画。
            .animation(Self.cardAnimation, value: store.items)
            .animation(Self.cardAnimation, value: store.selection)
        }
        .scrollIndicators(.hidden)
    }

    private func gridCell(for item: ShelfItem) -> some View {
        let index = store.index(ofItemWithID: item.id)
        return cellContent(for: item)
            // C5/C6: 上报卡片在窗口 .global 坐标系中的 frame（含滚动偏移），
            // 供框选命中与拖入插入定位使用；cell 离屏/移除时清除，避免陈旧几何。
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                gridGeometry.cardFrames[item.id] = frame
            }
            .onDisappear {
                gridGeometry.cardFrames.removeValue(forKey: item.id)
            }
            // S4: 插入指示线 —— insertionIndex 命中时画在卡片前缘。
            .overlay(alignment: .leading) {
                if dropTargetState.insertionIndex != nil, dropTargetState.insertionIndex == index {
                    insertionIndicator
                        .padding(.leading, -(Self.gridSpacing / 2 + 3))
                }
            }
            // S4: 插入位置指向末尾时画在末卡片后缘。
            .overlay(alignment: .trailing) {
                if dropTargetState.insertionIndex == store.items.count, index == store.items.count - 1 {
                    insertionIndicator
                        .padding(.trailing, -(Self.gridSpacing / 2 + 3))
                }
            }
    }

    @ViewBuilder
    private func cellContent(for item: ShelfItem) -> some View {
        if item.kind == .stack {
            ShelfStackView(
                item: item,
                isSelected: store.selection.contains(item.id),
                isExpanded: expandedStackID == item.id,
                onSelect: { additive in select(item.id, additive: additive) },
                onToggleExpanded: { toggleStackExpansion(item.id) },
                onRemove: { store.remove(ids: [item.id]) },
                dragContentsProvider: dragContents(for:)
            )
        } else {
            ShelfItemCard(
                item: item,
                isSelected: store.selection.contains(item.id),
                onSelect: { additive in select(item.id, additive: additive) },
                onRemove: { store.remove(ids: [item.id]) },
                dragContentsProvider: dragContents(for:)
            )
        }
    }

    /// S5：顶层卡片拖出内容 —— 被拖卡片在当前多选中时整批拖出（stack 由
    /// DragPayloadBuilder 展开为子项），否则仅拖该卡片。
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let dragged = store.selection.contains(anchor.id) ? store.selectedItems : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: Set(dragged.map(\.id)))
    }

    /// S4: 拖入插入指示线（accent 竖条）。
    private var insertionIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .allowsHitTesting(false)
    }

    // MARK: - Drop highlight (S4 预留)

    /// S4: DragContainerView 拖入悬停时 `dropTargetState.isTargeted == true`，
    /// 整面板 accent 描边 + 浅填充提示可投放。
    @ViewBuilder
    private var dropTargetHighlight: some View {
        if dropTargetState.isTargeted {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Color.accentColor.opacity(0.12))
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: - Stack expansion

    @ViewBuilder
    private var expandedStackOverlay: some View {
        if let stackID = expandedStackID,
           let stack = store.item(withID: stackID),
           stack.kind == .stack {
            // 半透明遮罩：点击外部收起。
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture(perform: collapseStack)
                .overlay {
                    ShelfStackExpandedView(
                        stack: stack,
                        onDismiss: collapseStack,
                        // UX4: 子项 ✕ 从 stack 移除；stack 解散/消失后本浮层
                        // 因 item(withID:) 返回 nil 自动收起。
                        onRemoveChild: { childID in
                            store.removeChild(childID, fromStack: stackID)
                        }
                    )
                    .padding(8)
                }
                .transition(.opacity)
        }
    }

    private func toggleStackExpansion(_ id: UUID) {
        withAnimation(Self.cardAnimation) {
            expandedStackID = expandedStackID == id ? nil : id
        }
    }

    private func collapseStack() {
        withAnimation(Self.cardAnimation) {
            expandedStackID = nil
        }
    }

    // MARK: - Selection

    private func select(_ id: UUID, additive: Bool) {
        if additive {
            store.toggleSelection(id)
        } else {
            store.select(id)
        }
        // S6: Quick Look 面板打开期间，预览跟随选中变化（含 ⌘点击增减多选）。
        quickLookCoordinator?.refreshPreview(contextItem: store.item(withID: id))
    }

    private func clearSelectionAndCollapse() {
        collapseStack()
        store.clearSelection()
    }

    // MARK: - Marquee selection (C5)

    /// 框选手势：只会在空白区起始（卡片区域左键事件被 CardDragSourceAnchorView
    /// 接管）。⌘ 起拖为追加模式 —— 以手势开始时的选中集合为基底并集命中项；
    /// 否则命中集合直接替换选择（选框缩小时选择随之收缩，标准框选行为）。
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeBaseSelection = NSEvent.modifierFlags.contains(.command)
                        ? store.selection : []
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaseSelection = []
            }
    }

    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let hits = Set(gridGeometry.cardFrames.lazy
            .filter { $0.value.intersects(rect) }
            .map(\.key))
        let newSelection = marqueeBaseSelection.union(hits)
        if newSelection != store.selection {
            store.setSelection(newSelection)
        }
    }

    /// 起终点归一化的选框矩形（.global 坐标）。
    private var marqueeRect: CGRect? {
        guard let marqueeStart, let marqueeCurrent else { return nil }
        return CGRect(x: min(marqueeStart.x, marqueeCurrent.x),
                      y: min(marqueeStart.y, marqueeCurrent.y),
                      width: abs(marqueeStart.x - marqueeCurrent.x),
                      height: abs(marqueeStart.y - marqueeCurrent.y))
    }

    /// 选框渲染（accent 浅填充 + 描边）；坐标与卡片 frame 同一 .global 空间，
    /// 直接按窗口原点偏移绘制（见 body 中 overlay 挂载位置的说明）。
    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Inline notice (D10)

    /// 拖入/物化失败的瞬态提示胶囊（标题栏下方，自动消失；选内联而非
    /// NSAlert 的理由见 `ShelfNoticeModel`）。
    @ViewBuilder
    private var noticeBanner: some View {
        if let message = notices.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { Capsule().fill(.regularMaterial) }
                .padding(.top, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
        }
    }
}

/// NSVisualEffectView 桥接：SwiftUI material 无法直接指定 .hudWindow 材质。
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Preview fixtures

/// SwiftUI Preview mock 数据：覆盖 file/folder/image/text/url/stack/stale 各形态。
/// 路径指向系统自带文件，保证 NSWorkspace 图标在预览中可解析；缩略图走与
/// 运行时相同的 QL → 图标回退链路。
enum ShelfPreviewFixtures {
    @MainActor
    static func makeStore() -> ShelfStore {
        ShelfStore(items: sampleItems())
    }

    static func sampleItems() -> [ShelfItem] {
        let app = ShelfItem(
            kind: .file,
            path: "/System/Library/CoreServices/Finder.app",
            displayName: "Finder",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let folder = ShelfItem(
            kind: .folder,
            path: "/System/Library/CoreServices",
            displayName: "CoreServices"
        )
        let image = ShelfItem(
            kind: .image,
            path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
            displayName: "Finder.icns",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let text = ShelfItem(
            kind: .text,
            displayName: "Release notes draft",
            sourceApp: SourceAppInfo(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            text: "Ship S3 shelf UI: grid, cards, stacks, empty state.\nDrag-in lands in S4."
        )
        let url = ShelfItem(
            kind: .url,
            displayName: "Apple",
            sourceApp: SourceAppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            urlString: "https://www.apple.com"
        )
        var stale = ShelfItem(
            kind: .file,
            path: "/nonexistent/moved-file.png",
            displayName: "moved-file.png"
        )
        stale.isStale = true
        return [app, folder, image, text, url, sampleStack(), stale]
    }

    static func sampleStack() -> ShelfItem {
        ShelfItem(
            kind: .stack,
            displayName: "Screenshots",
            children: [
                ShelfItem(
                    kind: .image,
                    path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
                    displayName: "Finder.icns"
                ),
                ShelfItem(
                    kind: .file,
                    path: "/System/Library/CoreServices/Finder.app",
                    displayName: "Finder"
                ),
                ShelfItem(
                    kind: .url,
                    displayName: "Apple",
                    urlString: "https://www.apple.com"
                ),
            ]
        )
    }
}

// MARK: - Previews

#Preview("Shelf with items") {
    ShelfView()
        .environment(ShelfPreviewFixtures.makeStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .frame(width: 320, height: 600)
}

#Preview("Empty shelf") {
    ShelfView()
        .environment(ShelfStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .frame(width: 320, height: 600)
}
