import SwiftUI

/// Stack 卡片（实施计划 §3：右上角数量角标）。
///
/// 外观复用 `ShelfItemCard`（12pt 圆角、选中态），缩略图取第一个文件类子项的
/// 真实缩略图，无则显示 stack 占位符号；右上角叠加数量角标。
///
/// 点击语义：普通点击 = 单选该 Stack 并展开/收起浮层；⌘点击 = 仅切换选中
/// （多选语义与普通卡片一致，不展开）。展开浮层由 ShelfView 以 overlay 呈现。
struct ShelfStackView: View {
    let item: ShelfItem
    let isSelected: Bool
    /// 浮层展开中：卡片保持 accent 高亮，提示「再次点击收起」。
    let isExpanded: Bool
    /// additive 为 true 表示 ⌘点击（切换选中），否则单选。
    let onSelect: (_ additive: Bool) -> Void
    let onToggleExpanded: () -> Void
    var onRemove: (() -> Void)?
    /// S5 拖出内容计算（多选整批/stack 语义由 ShelfView 决定）。
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    var body: some View {
        ShelfItemCard(
            item: item,
            isSelected: isSelected || isExpanded,
            onSelect: { additive in
                if additive {
                    onSelect(true)
                } else {
                    onSelect(false)
                    onToggleExpanded()
                }
            },
            onRemove: onRemove,
            thumbnailItem: item.children?.first(where: { $0.fileURL != nil }),
            dragContentsProvider: dragContentsProvider
        )
        .overlay(alignment: .topTrailing) { countBadge }
    }

    /// 数量角标（accent 胶囊，右上角）。
    private var countBadge: some View {
        Text("\(item.children?.count ?? 0)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background { Capsule().fill(Color.accentColor) }
            .padding(5)
            .allowsHitTesting(false)
    }
}

/// Stack 展开浮层（§3：.ultraThinMaterial 背景 + 等宽网格排列子项）。
///
/// 由 ShelfView 以全区域 overlay 承载（点击外部遮罩收起）。子项支持多选
/// （⌘点击切换、普通点击单选），选择存于局部状态 `childSelection` —— 子项
/// 不属于顶层 `ShelfStore.items`，故不走 store.selection。
/// S5：子项卡片可拖出（命中 childSelection 多选时整批拖出）；子项拖出
/// 不从 stack 移除（移除语义随 S6 的 stack 批量操作一起设计）。
struct ShelfStackExpandedView: View {
    let stack: ShelfItem
    let onDismiss: () -> Void

    /// 子项局部多选集合（S5 批量拖出读取）。
    @State private var childSelection: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(stack.children ?? []) { child in
                        ShelfItemCard(
                            item: child,
                            isSelected: childSelection.contains(child.id),
                            onSelect: { additive in
                                if additive {
                                    childSelection.formSymmetricDifference([child.id])
                                } else {
                                    childSelection = [child.id]
                                }
                            },
                            // 子项不提供「移除」：store 移除 API 面向顶层项目，
                            // Stack 内移除随 S6 的 unstack/批量操作一起设计。
                            dragContentsProvider: dragContents(for:)
                        )
                    }
                }
                .padding(2)
                .animation(ShelfView.cardAnimation, value: childSelection)
            }
            .frame(maxHeight: 320)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    /// S5：子项拖出内容 —— 命中多选时整批，否则单子项；topLevelIDs 为空
    /// （子项不从 stack 移除）。
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let children = stack.children ?? []
        let dragged = childSelection.contains(anchor.id) && childSelection.count > 1
            ? children.filter { childSelection.contains($0.id) }
            : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: [])
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(stack.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(stack.children?.count ?? 0) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse stack")
            .accessibilityLabel(Text("Collapse stack"))
        }
    }
}

// MARK: - Previews

#Preview("Stack card") {
    let stack = ShelfPreviewFixtures.sampleStack()
    ShelfStackView(item: stack,
                   isSelected: false,
                   isExpanded: false,
                   onSelect: { _ in },
                   onToggleExpanded: {},
                   onRemove: {})
        .frame(width: 100)
        .padding()
}

#Preview("Stack expanded") {
    ShelfStackExpandedView(stack: ShelfPreviewFixtures.sampleStack(), onDismiss: {})
        .frame(width: 288)
        .padding()
}
