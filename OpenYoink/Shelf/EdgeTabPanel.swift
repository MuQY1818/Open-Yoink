import AppKit

/// EdgeTab 拉环窗口：贴在屏幕边缘的常驻小长条（shelf 展开时驻点面板下角）。
///
/// 窗口行为与 `ShelfPanel` 同一套基线：non-activating、borderless、浮动、
/// 跨 Space、全屏辅助；透明背景，vibrancy/圆角/描边由内容层
/// （`EdgeTabView`）绘制。显示/隐藏与强调态动画由 `EdgeTabController`
/// 用 NSAnimationContext 显式驱动。
@MainActor
final class EdgeTabPanel: NSPanel {
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

        // 透明背景：朝内圆角 / vibrancy / 描边由 EdgeTabView 绘制。
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 淡入淡出与强调态 frame 动画由 EdgeTabController 显式驱动。
        animationBehavior = .none
    }
}
