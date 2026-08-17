import AppKit
import SwiftUI

/// 负责 shelf 面板的显示/隐藏（滑入滑出 + 透明度组合动画）、
/// 基于鼠标所在屏幕的 frame 计算，以及屏幕参数变化时的重新布局。
/// S6 起同时承担：Quick Look 会话持有（`QuickLookCoordinator`）与卡片键盘
/// 事件分派（空格/Delete/Esc，经 `ShelfPanel.onKeyDown` 回调）。
///
/// 公开 API 约定（S7 触发器、S8 设置均通过这里驱动面板）：
/// - `toggleShelf(animated:)` / `showShelf(animated:)` / `hideShelf(animated:)`
/// - `isShelfVisible: Bool`（只读，实际状态存于 `AppState`）
@MainActor
final class ShelfWindowController: NSObject {
    private static let animationDuration: TimeInterval = 0.2

    private let appState: AppState
    /// S8: shelf 位置/宽度/autoHide 等布局与行为设置的来源（原
    /// `static let shelfWidth` 占位常量已移除，宽度由此供给）。
    private let settings: SettingsStore
    /// Shelf 数据（S3 起注入 ShelfView 的 @Environment）。
    /// S4: DragContainerView（NSDraggingDestination 桥接）同样持有此 store。
    private let store: ShelfStore
    /// S4: 拖入分派（pasteboard → ShelfItem），供 DragContainerView 调用。
    private let importCoordinator: DropImportCoordinator
    /// S4: 拖入悬停高亮/插入位置状态，DragContainerView 驱动、ShelfView 渲染。
    private let dropTargetState = DropTargetState()
    /// S5: 拖出总控（卡片 mouseDragged → NSDraggingSession；结束后按设置策略
    /// 移除/保留/询问（S8 .ask NSAlert）并记入最近历史；S8 起经
    /// onSuccessfulDrop 回调接 autoHide）。
    private let dragOutController: DragOutController
    /// S6: 物化临时文件目录（注入 SwiftUI 环境，供卡片菜单的 text 项操作使用）。
    private let tempFileService: TempFileService
    /// S6: Quick Look 会话（QLPreviewPanel 数据源/代理；空格/双击/右键入口
    /// 汇聚于此，随窗口控制器长期存活）。
    private let quickLookCoordinator: QuickLookCoordinator

    private lazy var panel: ShelfPanel = {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: settings.shelfWidth, height: 600)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // S4: DragContainerView（NSDraggingDestination）包裹 hosting 视图。
        let hostingController = NSHostingController(
            rootView: ShelfView()
                .environment(store)
                .environment(dropTargetState)
                .environment(\.bookmarkService, importCoordinator.bookmarkService)
                .environment(\.dragOutController, dragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
        )
        panel.contentView = DragContainerView(
            store: store,
            coordinator: importCoordinator,
            dropTargetState: dropTargetState,
            contentViewController: hostingController
        )
        // S6: 键盘链路入口 —— 卡片单击已让面板成为 key，未被内容消费的
        // keyDown 到达这里（空格/Delete/Esc，见 handleItemKeyDown）。
        panel.onKeyDown = { [weak self] event in
            self?.handleItemKeyDown(event) ?? false
        }
        return panel
    }()

    var isShelfVisible: Bool {
        appState.isShelfVisible
    }

    init(appState: AppState,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         tempFileService: TempFileService,
         settings: SettingsStore,
         recents: RecentItemsService) {
        self.appState = appState
        self.store = store
        self.importCoordinator = importCoordinator
        self.tempFileService = tempFileService
        self.settings = settings
        self.dragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService
        )
        self.quickLookCoordinator = QuickLookCoordinator(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            tempFileService: tempFileService
        )
        super.init()
        // S8: autoHide —— 拖出成功（operation 非空）且设置开启时隐藏 shelf。
        // 回调在 DragSessionController.draggingSession(endedAt:) 里按
        // 「实际发生 drop」判定后触发；隐藏与否在此处按最新设置裁决。
        dragOutController.onSuccessfulDrop = { [weak self] in
            guard let self, self.settings.autoHide else { return }
            self.hideShelf(animated: true)
        }
        // S6: QL 面板关闭后让 ShelfPanel 重新成为 key（nonactivating：只接
        // 键盘焦点、不激活应用），空格/Delete/Esc 保持可用。闭包内访问 panel
        // 发生在 QL 关闭时，面板早已创建，不影响 lazy 语义。
        quickLookCoordinator.onPanelClosed = { [weak self] in
            guard let self, self.appState.isShelfVisible else { return }
            self.panel.makeKey()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // S8: 位置/宽度设置变更时动画过渡到新 frame（见 applyLayoutSettings）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
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

    /// 从贴附缘滑入并淡入（贴左缘时自左侧滑入，贴右缘时自右侧滑入）。
    func showShelf(animated: Bool = true) {
        appState.showShelf()
        let targetFrame = targetFrame()
        guard animated else {
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: false)
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.setFrame(hiddenFrame(for: targetFrame), display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    /// 向贴附缘滑出并淡出，结束后 orderOut。
    func hideShelf(animated: Bool = true) {
        appState.hideShelf()
        // S6: shelf 隐藏时关掉 Quick Look 并释放会话资源（不恢复键盘焦点）。
        quickLookCoordinator.closeForShelfHide()
        let targetFrame = hiddenFrame(for: panel.frame)
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

    // MARK: - Item keyboard handling (S6)

    /// ShelfPanel.keyDown 回调：空格切换 Quick Look（当前选中集合）、
    /// Delete/Forward Delete 移除选中项（不删原文件，纯 store.remove）、
    /// Esc 先关已打开的 QL 面板、其次取消选择。
    ///
    /// 事件到达前提：卡片单击让面板成为 key（CardDragSourceAnchorView.mouseUp）。
    /// 带修饰键的组合一律放行（⌘⇧Space 等由 AppDelegate 的快捷键监听处理）；
    /// QL 面板为 key 时键盘事件由 QL 自己接管（空格/Esc 关闭、方向键翻页），
    /// 不会到达这里。
    private func handleItemKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49: // Space
            return quickLookCoordinator.toggle(contextItem: nil)
        case 51, 117: // Delete / Forward Delete
            guard !store.selection.isEmpty else { return false }
            store.removeSelection()
            quickLookCoordinator.refreshPreview(contextItem: nil)
            return true
        case 53: // Escape
            if quickLookCoordinator.isPreviewing {
                quickLookCoordinator.dismiss()
                return true
            }
            guard !store.selection.isEmpty else { return false }
            store.clearSelection()
            return true
        default:
            return false
        }
    }

    // MARK: - Layout

    /// S8: 位置（左/右）与宽度均由 SettingsStore 供给；跟随鼠标所在屏幕，
    /// 贴设定缘、占满可见区域全高。
    private func targetFrame() -> NSRect {
        let visibleFrame = Self.screenUnderMouse().visibleFrame
        let width = CGFloat(settings.shelfWidth)
        let x = switch settings.shelfPosition {
        case .left: visibleFrame.minX
        case .right: visibleFrame.maxX - width
        }
        return NSRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
    }

    /// 隐藏态 frame：向贴附缘方向平移一个面板宽度（滑出方向随位置反转）。
    private func hiddenFrame(for visibleFrame: NSRect) -> NSRect {
        switch settings.shelfPosition {
        case .right:
            return visibleFrame.offsetBy(dx: visibleFrame.width, dy: 0)
        case .left:
            return visibleFrame.offsetBy(dx: -visibleFrame.width, dy: 0)
        }
    }

    /// 包含指定点的屏幕（回退主屏）。S7 的 EdgeTriggerMonitor 与本类布局
    /// 共用「鼠标所在屏幕」判定，保证边缘触发的一侧与 shelf 出现的一侧一致。
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

    static func screenUnderMouse() -> NSScreen {
        screen(containing: NSEvent.mouseLocation)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard appState.isShelfVisible else { return }
        panel.setFrame(targetFrame(), display: true)
    }

    /// S8: 设置变更 → 可见时动画过渡到新 frame。任何 UserDefaults 写入都会
    /// 投递该通知，frame 未实际变化时直接返回，无关设置项不会触发布局动画。
    ///
    /// 必须 nonisolated：通知按投递线程同步回调，投递方可能是任意线程；
    /// 选择器方法若保留 MainActor 隔离会在投递线程上触发隔离断言
    /// （同 AppDelegate.userDefaultsDidChange 的说明）。
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyLayoutSettings()
        }
    }

    private func applyLayoutSettings() {
        guard appState.isShelfVisible else { return }
        let target = targetFrame()
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}
