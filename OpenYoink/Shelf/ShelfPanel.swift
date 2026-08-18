import AppKit

/// Shelf 面板窗口。窗口行为集中于此（见实施计划 §2.3）：
/// non-activating、borderless、浮动于其他窗口之上、跨 Space、全屏辅助，
/// 透明背景 + 圆角 + vibrancy 视觉由内容层（`ShelfView`）实现。
@MainActor
final class ShelfPanel: NSPanel {
    /// S6: 键盘事件回调（空格 Quick Look / Delete 移除 / Esc 取消选择或关 QL）。
    /// 由 ShelfWindowController 注入；返回 true 表示事件已消费。
    /// 卡片单击会让面板成为 key（见 CardDragSourceAnchorView.mouseUp），未被
    /// SwiftUI 内容消费的 keyDown 沿 responder chain 到达这里。
    var onKeyDown: ((NSEvent) -> Bool)?

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

    /// 修复（真机验收发现）：borderless 窗口默认 `canBecomeKeyWindow = false`，
    /// 导致 S6 的「卡片单击后 panel.makeKey()」静默失败（运行日志有
    /// `makeKeyWindow ... returned NO` 警告），空格 Quick Look / Delete / Esc
    /// 全部失效。面板需要接键盘事件但不抢 main 状态，故只放开 key。
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
