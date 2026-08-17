import AppKit

/// Shelf 面板窗口。窗口行为集中于此（见实施计划 §2.3）：
/// non-activating、borderless、浮动于其他窗口之上、跨 Space、全屏辅助，
/// 透明背景 + 圆角 + vibrancy 视觉由内容层（`ShelfView`）实现。
@MainActor
final class ShelfPanel: NSPanel {
    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: backingStoreType,
                   defer: flag)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // 透明背景：圆角 / vibrancy / 描边由 ShelfView 绘制，窗口阴影跟随内容形状。
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 显示/隐藏动画由 ShelfWindowController 用 NSAnimationContext 显式驱动。
        animationBehavior = .none
    }
}
