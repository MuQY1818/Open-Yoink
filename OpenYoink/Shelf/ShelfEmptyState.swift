import SwiftUI

/// 空状态（实施计划 §3）：居中插画位 + 投放提示 + 快捷键提示 + 半透明虚线边框。
///
/// 虚线边框暗示可投放区域；S4 拖入悬停时由 ShelfView 的落点高亮
/// （`DropTargetState.isTargeted` 驱动）接管强调态。文案走 Localizable.xcstrings（S10）；
/// D9: 整体合并为单个可访问性元素，VoiceOver 一次读完提示与快捷键。
struct ShelfEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("Drop files here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // F-05: 双模式拖入提示（直接拖入 = 引用；⌘ 拖入 = 移入原文件）。
                Text("Hold ⌘ while dropping to move the original here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("⌘⇧Space to toggle the shelf")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shelf.emptyState")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        }
        .padding(8)
    }
}

// MARK: - Previews

#Preview("Empty state") {
    ShelfEmptyState()
        .frame(width: 280, height: 400)
}
