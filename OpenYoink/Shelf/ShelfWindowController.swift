import AppKit
import SwiftUI

/// UX6: 空架自动隐藏裁决（纯逻辑，与 AppKit 解耦供单测）。
///
/// 基于「非空 → 空」的迁移而非「为空」状态：shelf 可见且 items 从 >0 变 0
/// （移除/拖出导致）→ 应动画隐藏。状态式实现（可见且为空即隐）会把用户
/// 在空架状态的手动唤出（快捷键/菜单/摇动/边缘 —— 显式意图）立刻收回，
/// 迁移式天然豁免该场景。首次评估只建立基线，不触发。
///
/// 任务二不变式：拖拽进行中（`isDragInProgress`）不自动隐藏已可见的 shelf ——
/// 真机验收怀疑「拖拽中 shelf 被意外隐藏导致 drop 落空」，典型场景是拖拽
/// 期间 items 从 >0 变 0（如另一只手按 Delete 清空）。被抑制的隐藏不补发：
/// 拖结束后 shelf 保持可见（空架），由用户显式收起，安全方向。
struct EmptyShelfAutoHideRule: Sendable, Equatable {
    private var previousCount: Int?

    /// 每次 items 变更时评估。返回 true = 应立即自动隐藏。
    /// 无论结果如何都记录本次数量作为下次基线。
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool) -> Bool {
        evaluate(itemCount: itemCount, isVisible: isVisible, isEnabled: isEnabled,
                 isDragInProgress: false)
    }

    /// 带拖拽状态门控的评估（任务二）：`isDragInProgress == true` 期间恒不触发，
    /// 基线照常更新（拖拽结束后的下一次变更以最新数量为基准裁决）。
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool,
                           isDragInProgress: Bool) -> Bool {
        defer { previousCount = itemCount }
        guard let previousCount else { return false }
        guard !isDragInProgress else { return false }
        return isEnabled && isVisible && previousCount > 0 && itemCount == 0
    }

    /// 清空基线（下一次评估只记录不触发）。
    mutating func reset() {
        previousCount = nil
    }
}

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
    /// UX6: 空架自动隐藏裁决状态（跨 items 变更保持上一轮数量基线）。
    private var emptyAutoHideRule = EmptyShelfAutoHideRule()
    /// S4: 拖入分派（pasteboard → ShelfItem），供 DragContainerView 调用。
    private let importCoordinator: DropImportCoordinator
    /// S4: 拖入悬停高亮/插入位置状态，DragContainerView 驱动、ShelfView 渲染。
    private let dropTargetState = DropTargetState()
    /// C5/C6: 卡片网格几何（ShelfView 上报 frame；DragContainerView 拖入定位、
    /// ShelfView 框选命中共用）。
    private let gridGeometry = ShelfGridGeometry()
    /// S5: 拖出总控（卡片 mouseDragged → NSDraggingSession；结束后按设置策略
    /// 移除/保留/询问（S8 .ask NSAlert）并记入最近历史；S8 起经
    /// onSuccessfulDrop 回调接 autoHide）。
    private let dragOutController: DragOutController
    /// S6: 物化临时文件目录（注入 SwiftUI 环境，供卡片菜单的 text 项操作使用）。
    private let tempFileService: TempFileService
    /// S6: Quick Look 会话（QLPreviewPanel 数据源/代理；空格/双击/右键入口
    /// 汇聚于此，随窗口控制器长期存活）。
    private let quickLookCoordinator: QuickLookCoordinator
    /// 任务二：拖拽进行中状态（`DragStartMonitor.isDragInProgress`），供给
    /// 空架自动隐藏的门控 —— 拖拽期间任何自动显隐不得收起已可见的 shelf。
    private let dragStartMonitor: DragStartMonitor

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
                .environment(settings)
                .environment(gridGeometry)
                .environment(importCoordinator.noticeCenter)
                .environment(\.bookmarkService, importCoordinator.bookmarkService)
                .environment(\.dragOutController, dragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
                // 任务三：内缘收起把手点击 → 走标准 hideShelf 滑出动画。
                .environment(\.shelfHideAction, { [weak self] in
                    self?.hideShelf(animated: true)
                })
        )
        panel.contentView = DragContainerView(
            store: store,
            coordinator: importCoordinator,
            dropTargetState: dropTargetState,
            gridGeometry: gridGeometry,
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
         recents: RecentItemsService,
         dragStartMonitor: DragStartMonitor) {
        self.appState = appState
        self.store = store
        self.importCoordinator = importCoordinator
        self.tempFileService = tempFileService
        self.settings = settings
        self.dragStartMonitor = dragStartMonitor
        self.dragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService,
            tempFileService: tempFileService,
            noticeCenter: importCoordinator.noticeCenter
        )
        self.quickLookCoordinator = QuickLookCoordinator(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            tempFileService: tempFileService
        )
        super.init()
        // UX5/UX6: 项目增删 → 紧凑高度动画过渡 + 空架自动隐藏裁决。
        store.onItemsDidChange = { [weak self] in
            self?.handleItemsDidChange()
        }
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
        // S9: Space 切换后的在位校正（见 revalidateFrameAfterSpaceChange）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
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

    /// 位置与宽度由 SettingsStore 供给；纯计算收敛在 `ShelfLayoutEngine`（S9）。
    /// 左/右跟随鼠标所在屏幕（鼠标屏被拔掉回退主屏），贴设定缘；UX5 起高度
    /// 贴合内容（按 `store.items.count` 推算行数，上限可见高度 80%）；EdgeTab
    /// 起垂直位置按 `shelfEdgeOffset`（0 = 底缘、1 = 顶缘，默认 0.5 居中）；
    /// custom 用校验后的持久化 frame（首次/所在屏被拔掉时从目标屏
    /// 右缘默认 frame 起步）。
    private func targetFrame() -> NSRect {
        ShelfLayoutEngine.targetFrame(
            position: settings.shelfPosition,
            width: settings.shelfWidth,
            itemCount: store.items.count,
            mouseLocation: NSEvent.mouseLocation,
            screens: Self.screenGeometries(),
            persistedCustomFrame: settings.customShelfFrame,
            edgeOffset: CGFloat(settings.shelfEdgeOffset)
        )
    }

    /// 隐藏态 frame：左/右向贴附缘方向平移一个面板宽度；custom 原位（淡出）。
    private func hiddenFrame(for frame: NSRect) -> NSRect {
        ShelfLayoutEngine.hiddenFrame(for: frame, position: settings.shelfPosition)
    }

    /// 当前屏幕几何快照（NSScreen → 纯值，供 ShelfLayoutEngine）。
    private static func screenGeometries() -> [ShelfLayoutEngine.ScreenGeometry] {
        NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// 包含指定点的屏幕（回退主屏）。S7 的 EdgeTriggerMonitor 与本类布局
    /// 共用「鼠标所在屏幕」判定，保证边缘触发的一侧与 shelf 出现的一侧一致。
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

    /// S9: 插拔屏/改分辨率 → 可见即按新几何重算 frame（鼠标所在屏被拔掉时
    /// ShelfLayoutEngine 回退主屏；custom frame 落出所有屏幕则回退右缘默认）。
    /// 隐藏态无持久目标，show 时自会按最新几何计算，这里无需动作。
    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard appState.isShelfVisible else { return }
        let target = targetFrame()
        panel.setFrame(target, display: true)
    }

    /// S9: Space 切换后的在位校正。canJoinAllSpaces + stationary 让面板留在原
    /// 全局坐标、跟随出现在每个 Space，屏幕几何并未变化 —— 因此只校验当前
    /// frame（落出可见区域时瞬时夹回，无动画），不按鼠标重新跟随，避免切
    /// Space 时 shelf 漂到鼠标所在屏。
    ///
    /// 必须 nonisolated：通知按投递线程同步回调（同 userDefaultsDidChange）。
    @objc private nonisolated func activeSpaceDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.revalidateFrameAfterSpaceChange()
        }
    }

    private func revalidateFrameAfterSpaceChange() {
        guard appState.isShelfVisible else { return }
        let corrected = ShelfLayoutEngine.onscreenCorrection(for: panel.frame,
                                                             screens: Self.screenGeometries())
            ?? targetFrame()
        guard corrected != panel.frame else { return }
        panel.setFrame(corrected, display: true)
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

    /// UX5/UX6: items 变更（store.onItemsDidChange 钩子）统一处理：
    /// 1. UX5 紧凑高度 —— 可见时数量变化动画过渡到新目标 frame（custom
    ///    位置的目标 frame 不含内容高度，天然 no-op）；
    /// 2. UX6 空架自动隐藏 —— 非空→空迁移且设置开启时动画收回。
    ///    任务二：拖拽进行中不收回（不变式见 EmptyShelfAutoHideRule）。
    private func handleItemsDidChange() {
        let shouldAutoHide = emptyAutoHideRule.evaluate(
            itemCount: store.items.count,
            isVisible: appState.isShelfVisible,
            isEnabled: settings.autoHideWhenEmpty,
            isDragInProgress: dragStartMonitor.isDragInProgress
        )
        if appState.isShelfVisible {
            let target = targetFrame()
            if target != panel.frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.animationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(target, display: true)
                }
            }
        }
        // 空架隐藏放在高度动画之后裁决：两者同帧时隐藏优先（隐藏动画覆盖）。
        if shouldAutoHide {
            hideShelf(animated: true)
        }
    }
}
