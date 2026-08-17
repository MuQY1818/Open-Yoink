import AppKit
import SwiftUI

/// 负责 shelf 面板的显示/隐藏（滑入滑出 + 透明度组合动画）、
/// 基于鼠标所在屏幕的 frame 计算，以及屏幕参数变化时的重新布局。
///
/// 公开 API 约定（S7 触发器、S8 设置均通过这里驱动面板）：
/// - `toggleShelf(animated:)` / `showShelf(animated:)` / `hideShelf(animated:)`
/// - `isShelfVisible: Bool`（只读，实际状态存于 `AppState`）
@MainActor
final class ShelfWindowController: NSObject {
    /// 面板宽度占位常量。S8: 改为从 SettingsStore 读取。
    static let shelfWidth: CGFloat = 320
    private static let animationDuration: TimeInterval = 0.2

    private let appState: AppState
    /// Shelf 数据（S3 起注入 ShelfView 的 @Environment）。
    /// S4: DragContainerView（NSDraggingDestination 桥接）同样持有此 store。
    private let store: ShelfStore

    private lazy var panel: ShelfPanel = {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.shelfWidth, height: 600)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: ShelfView().environment(store))
        return panel
    }()

    var isShelfVisible: Bool {
        appState.isShelfVisible
    }

    init(appState: AppState, store: ShelfStore) {
        self.appState = appState
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func toggleShelf(animated: Bool = true) {
        if appState.isShelfVisible {
            hideShelf(animated: animated)
        } else {
            showShelf(animated: animated)
        }
    }

    /// 从屏幕右缘滑入并淡入。
    func showShelf(animated: Bool = true) {
        appState.showShelf()
        let targetFrame = Self.targetFrame()
        guard animated else {
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: false)
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.setFrame(targetFrame.offsetBy(dx: Self.shelfWidth, dy: 0), display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    /// 向屏幕右缘滑出并淡出，结束后 orderOut。
    func hideShelf(animated: Bool = true) {
        appState.hideShelf()
        let targetFrame = panel.frame.offsetBy(dx: Self.shelfWidth, dy: 0)
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            // 隐藏期间若用户重新唤出，则不打断显示状态。
            MainActor.assumeIsolated {
                guard let self, !self.appState.isShelfVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    /// 默认布局：跟随鼠标所在屏幕，贴右缘、占满可见区域全高。
    /// S8: 位置（左/右/自定义）与宽度接设置后扩展此方法。
    private static func targetFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        return NSRect(x: visibleFrame.maxX - shelfWidth,
                      y: visibleFrame.minY,
                      width: shelfWidth,
                      height: visibleFrame.height)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard appState.isShelfVisible else { return }
        panel.setFrame(Self.targetFrame(), display: true)
    }
}
