import AppKit
import SwiftUI

/// Custom 位置模式的窗口拖动把手（S9，计划 §1.1 设置行收尾）。
///
/// 透明 NSView，盖在 ShelfView 顶部标题栏区域：mouseDown 直接进入 AppKit
/// 标准窗口拖动循环（`performDrag(with:)`，自带跨屏跟随与屏幕边界约束），
/// 鼠标抬起、拖动结束后经 `onDragEnded` 把窗口最终 frame（屏幕坐标）交给
/// 上层持久化。
///
/// 为什么不用 `isMovableByWindowBackground`：整面板背景可拖会与卡片拖出
/// （NSDraggingSession 源，mouseDragged 驱动）和 ScrollView 滚动抢手势；
/// 拖动入口收窄到标题栏区域后互不干扰。
@MainActor
final class WindowDragHandleView: NSView {
    /// 拖动结束回调（参数为窗口最终 frame，全局屏幕坐标）。
    var onDragEnded: ((NSRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowDragHandleView is created programmatically")
    }

    /// 点击即进入窗口拖动循环；面板 nonactivating，acceptsFirstMouse 保证
    /// 应用未激活时第一击同样可拖。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.performDrag(with: event)
        onDragEnded?(window.frame)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// SwiftUI 桥接（见 ShelfView.header，仅 custom 位置模式挂载）。
struct WindowDragHandle: NSViewRepresentable {
    var onDragEnded: @MainActor (NSRect) -> Void

    func makeNSView(context: Context) -> WindowDragHandleView {
        let view = WindowDragHandleView()
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }
}
