import SwiftUI

/// 内缘收起把手（任务三）：shelf 贴屏幕缘时，在面板**朝屏幕中心一侧**的
/// 边距带内画一条窄竖把手（宽 14pt、随面板全高），点击收起 shelf。
///
/// 布局约束（任务硬性要求）：把手是覆盖在面板边距带（外层 8pt + 内容 8pt
/// padding，合计 16pt）上的独立窄列，**不挤占网格宽度** —— 因此
/// `ShelfLayoutEngine.columnCount` 的列数推算、`ShelfGridGeometry` 上报的
/// 卡片 frame（窗口 .global 坐标）、框选与拖入插入定位全部不受影响。
/// custom 自由位置模式不显示（`ShelfLayoutEngine.innerEdgeHandleSide` 判空）。
///
/// 视觉（按用户反馈两轮调整）：常态**整条透明**，只有低调的 secondary 色
/// chevron（指向屏幕缘，即收起方向）；hover 时**仅 chevron 变亮**——不加
/// 圆点/圆底等任何背景装饰（用户明确反馈圆圈不好看）。
/// 点击热区仍为整条窄列（`contentShape(Rectangle())`），可用性不受影响。
struct ShelfCollapseHandle: View {
    /// 把手贴附侧（决定 chevron 方向）。
    let side: ShelfLayoutEngine.InnerEdgeHandleSide
    /// 点击动作（ShelfWindowController.hideShelf 动画）。
    let action: @MainActor () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// chevron 指向屏幕缘（收起滑出方向）：把手在左缘（右锚）→ 向右。
    private var chevronName: String {
        side == .leading ? "chevron.right" : "chevron.left"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: chevronName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: ShelfLayoutEngine.innerEdgeHandleWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .accessibilityLabel(Text("Hide Shelf"))
        .accessibilityIdentifier("shelf.hide.handle")
        .help(Text("Hide Shelf"))
    }
}

/// 收起动作的环境注入（沿用本项目自定义 EnvironmentKey 模式；nil 缺省：
/// Preview/单测中把手渲染但点击为空操作）。
private struct ShelfHideActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    /// 内缘收起把手的收起动作；由 ShelfWindowController 在面板内容根上注入。
    var shelfHideAction: (@MainActor () -> Void)? {
        get { self[ShelfHideActionEnvironmentKey.self] }
        set { self[ShelfHideActionEnvironmentKey.self] = newValue }
    }
}
