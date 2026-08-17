import SwiftUI

/// 空状态（实施计划 §3）：居中插画位 + 投放提示 + 快捷键提示 + 半透明虚线边框。
///
/// 虚线边框暗示可投放区域；S4 拖入悬停时由 ShelfView 的 `isDropTargeted`
/// 高亮接管强调态。文案先为英文，S10 统一提取到 Localizable.xcstrings。
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
                Text("⌘⇧Space to toggle the shelf")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
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
