import SwiftUI

/// Shelf 根视图（S3：真实内容渲染）。
///
/// 视觉规范（实施计划 §3）：vibrancy 底（.hudWindow 材质）+ 16pt 圆角 +
/// 1pt 内描边（白 8%）；等宽网格（列宽 ~88pt、间距 12pt）纵向滚动；
/// 顶部极简标题栏（名称 + 项目计数）；空时显示 `ShelfEmptyState`。
/// 投影仍由窗口层（`ShelfPanel.hasShadow`）承担，此处不重画。
///
/// 交互：普通点击单选、⌘点击切换多选、空白处点击清除选择并收起 Stack；
/// 点击 Stack 卡片展开浮层（同时只展开一个），点击外部或再次点击收起。
///
/// S4：`isDropTargeted` / `dropInsertionIndex` 两个预留状态已收敛为
/// `@Environment(DropTargetState.self)`（DragContainerView 驱动高亮与插入指示线）；
/// 卡片弹入动画修饰器（spring, response 0.35, damping 0.7）已就位。
struct ShelfView: View {
    @Environment(ShelfStore.self) private var store

    /// S4: 拖入悬停高亮与插入指示线位置，由 DragContainerView
    /// （NSDraggingDestination 桥接）驱动。
    @Environment(DropTargetState.self) private var dropTargetState
    /// 当前展开的 Stack id（同时只展开一个）。
    @State private var expandedStackID: UUID?

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
            .animation(Self.cardAnimation, value: expandedStackID)
            .padding(8)
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
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: clearSelectionAndCollapse)
        }
    }

    /// 顶部极简标题栏：shelf 名称 + 项目计数（有多选时显示「选中/总数」）。
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Shelf") // S10: i18n
                .font(.headline)
            Spacer()
            Text(countCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var countCaption: String {
        store.selection.isEmpty
            ? "\(store.items.count)"
            : "\(store.selection.count) of \(store.items.count)"
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
                    ShelfStackExpandedView(stack: stack, onDismiss: collapseStack)
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
    }

    private func clearSelectionAndCollapse() {
        collapseStack()
        store.clearSelection()
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
        .frame(width: 320, height: 600)
}

#Preview("Empty shelf") {
    ShelfView()
        .environment(ShelfStore())
        .environment(DropTargetState())
        .frame(width: 320, height: 600)
}
