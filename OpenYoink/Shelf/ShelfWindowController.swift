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
    private let classicDropTargetState = DropTargetState()
    private let islandDropTargetState = DropTargetState()
    /// C5/C6: 卡片网格几何（ShelfView 上报 frame；DragContainerView 拖入定位、
    /// ShelfView 框选命中共用）。
    private let classicGridGeometry = ShelfGridGeometry()
    private let islandGridGeometry = ShelfGridGeometry()
    /// Runtime focus/expanded-stack state shared with SwiftUI card rendering.
    private let interaction = ShelfInteractionState()
    /// S5: 拖出总控（卡片 mouseDragged → NSDraggingSession；结束后按设置策略
    /// 移除/保留/询问（S8 .ask NSAlert）并记入最近历史；S8 起经
    /// onSuccessfulDrop 回调接 autoHide）。
    private let classicDragOutController: DragOutController
    private let islandDragOutController: DragOutController
    /// S6: 物化临时文件目录（注入 SwiftUI 环境，供卡片菜单的 text 项操作使用）。
    private let tempFileService: TempFileService
    /// S6: Quick Look 会话（QLPreviewPanel 数据源/代理；空格/双击/右键入口
    /// 汇聚于此，随窗口控制器长期存活）。
    private let quickLookCoordinator: QuickLookCoordinator
    /// v1.2: distinguishes external references from managed-copy loss and owns
    /// the safe user-driven recovery actions.
    private let itemRecoveryController: ItemRecoveryController
    /// v1.3: shared non-destructive selection actions and the retained AppKit
    /// share-session lifecycle.
    private let shelfActionRunner: ShelfActionRunner
    /// Batch-level VoiceOver announcements live for the controller lifetime so
    /// SwiftUI redraws cannot repeat already spoken events.
    private let accessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()
    /// 任务二：拖拽进行中状态（`DragStartMonitor.isDragInProgress`），供给
    /// 空架自动隐藏的门控 —— 拖拽期间任何自动显隐不得收起已可见的 shelf。
    private let dragStartMonitor: DragStartMonitor
    /// Expanded Island's visible Settings control uses the app's retained,
    /// LSUIElement-safe settings window rather than SwiftUI's response-chain
    /// action, which can silently fail for a non-activating panel.
    private let onOpenSettings: @MainActor () -> Void
    /// v1.4: the classic shelf and Island share one dependency graph and one
    /// ShelfStore, but each owns an independent panel and visibility state.
    let islandActivityCoordinator: IslandActivityCoordinator
    let islandModuleRegistry: IslandModuleRegistry
    let islandTimerStore: IslandTimerStore
    let powerSourceMonitor: PowerSourceMonitor
    let nowPlayingModuleStore: NowPlayingModuleStore
    let systemStatusModuleStore: SystemStatusModuleStore
    let islandModuleContainer: IslandModuleContainer
    private let transfersModuleRuntime: TransfersModuleRuntime
    private let timerModuleRuntime: CallbackIslandModuleRuntime
    private let batteryModuleRuntime: CallbackIslandModuleRuntime
    private let mediaModuleRuntime: CallbackIslandModuleRuntime
    private var islandGlobalMonitor: Any?
    private var islandLocalMonitor: Any?
    private var islandHoverTask: Task<Void, Never>?
    private var islandLayoutTask: Task<Void, Never>?
    private var classicHoverPreviewState = ClassicShelfHoverPreviewStateMachine()
    private var classicHoverExitTask: Task<Void, Never>?
    private var classicHoverGlobalMonitor: Any?
    private var classicHoverLocalMonitor: Any?
    private var isOpeningClassicHoverPreview = false
    /// 快速上手期间只暂停自动隐藏，不改写用户的 autoHide 设置。
    private var onboardingPresentationCount = 0
    /// Freeze compact-height changes during global-coordinate marquee gestures;
    /// the task also coalesces select+expand into one layout pass.
    private var isMarqueeSelectionActive = false
    private var quickActionLayoutPending = false
    private var quickActionLayoutTask: Task<Void, Never>?

    struct OnboardingPresentationSnapshot: Equatable, Sendable {
        fileprivate let surface: SettingsStore.PreferredShelfSurface
        fileprivate let wasVisible: Bool
    }

    private lazy var classicPanel: ShelfPanel = makePanel(
        presentationStyle: .classic,
        dropTargetState: classicDropTargetState,
        gridGeometry: classicGridGeometry,
        dragOutController: classicDragOutController
    )

    private lazy var islandPanel: ShelfPanel = makePanel(
        presentationStyle: .island,
        dropTargetState: islandDropTargetState,
        gridGeometry: islandGridGeometry,
        dragOutController: islandDragOutController
    )

    private func makePanel(
        presentationStyle: ShelfPresentationStyle,
        dropTargetState: DropTargetState,
        gridGeometry: ShelfGridGeometry,
        dragOutController: DragOutController
    ) -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: settings.shelfWidth, height: 600)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // S4: DragContainerView（NSDraggingDestination）包裹 hosting 视图。
        let hostingController = NSHostingController(
            rootView: ShelfPresentationRootView(
                presentationStyle: presentationStyle,
                onPerformRecovery: { [weak self] action in
                    self?.itemRecoveryController.perform(action)
                },
                onOpenSettings: { [weak self] in
                    self?.onOpenSettings()
                }
            )
                .environment(store)
                .environment(dropTargetState)
                .environment(settings)
                .environment(gridGeometry)
                .environment(interaction)
                .environment(importCoordinator.noticeCenter)
                .environment(importCoordinator.transferStore)
                .environment(islandActivityCoordinator)
                .environment(islandModuleRegistry)
                .environment(islandModuleContainer)
                .environment(islandTimerStore)
                .environment(powerSourceMonitor)
                .environment(nowPlayingModuleStore)
                .environment(systemStatusModuleStore)
                .environment(\.bookmarkService, importCoordinator.bookmarkService)
                .environment(\.dragOutController, dragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
                .environment(\.itemRecoveryController, itemRecoveryController)
                .environment(\.shelfActionRunner, shelfActionRunner)
                .environment(\.accessibilityAnnouncementCenter,
                              accessibilityAnnouncementCenter)
                // 任务三：内缘收起把手点击 → 走标准 hideShelf 滑出动画。
                .environment(\.shelfHideAction, { [weak self] in
                    if presentationStyle == .island {
                        self?.collapseIsland(animated: true)
                    } else {
                        self?.hideShelf(animated: true)
                    }
                })
                .environment(\.shelfMarqueeActivityAction, { [weak self] isActive in
                    guard presentationStyle == .classic else { return }
                    self?.setMarqueeSelectionActive(isActive)
                })
        )
        panel.contentView = DragContainerView(
            store: store,
            coordinator: importCoordinator,
            dropTargetState: dropTargetState,
            gridGeometry: gridGeometry,
            contentViewController: hostingController
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        // S6: 键盘链路入口 —— 卡片单击已让面板成为 key，未被内容消费的
        // keyDown 到达这里（空格/Delete/Esc，见 handleItemKeyDown）。
        panel.onKeyDown = { [weak self] event in
            self?.handleItemKeyDown(event, in: panel) ?? false
        }
        return panel
    }

    var isShelfVisible: Bool {
        appState.isShelfVisible
    }

    var isIslandExpanded: Bool {
        islandActivityCoordinator.surfaceState.isExpanded
    }

    var isPreferredShelfExpanded: Bool {
        switch effectivePreferredShelfSurface {
        case .classic: appState.isShelfVisible
        case .island: islandActivityCoordinator.surfaceState.isExpanded
        case nil: false
        }
    }

    init(appState: AppState,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         tempFileService: TempFileService,
         settings: SettingsStore,
         recents: RecentItemsService,
         deliveryCoordinator: DeliveryCoordinator,
         dragStartMonitor: DragStartMonitor,
         onOpenSettings: @escaping @MainActor () -> Void = {},
         onOpenStorageRecovery: @escaping @MainActor () -> Void = {},
         tutorialTokenForItem: @escaping @MainActor (UUID) -> String? = { _ in nil }) {
        self.appState = appState
        self.store = store
        self.importCoordinator = importCoordinator
        self.tempFileService = tempFileService
        self.settings = settings
        self.dragStartMonitor = dragStartMonitor
        self.onOpenSettings = onOpenSettings
        let islandActivityCoordinator = IslandActivityCoordinator()
        let islandModuleRegistry = IslandModuleRegistry()
        let islandTimerStore = IslandTimerStore(defaults: settings.defaultsStore)
        let powerSourceMonitor = PowerSourceMonitor(
            fullChargeAlertEnabled: { settings.islandFullChargeAlertEnabled }
        )
        let nowPlayingModuleStore = NowPlayingModuleStore(
            sourceFactory: { NowPlayingSourceFactory.bundled() }
        )
        let systemStatusModuleStore = SystemStatusModuleStore(
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .system
            }
        )
        let shelfRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .shelf)!
        )
        let transfersModuleRuntime = TransfersModuleRuntime(
            transferStore: importCoordinator.transferStore
        )
        let timerModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: islandTimerStore.descriptor,
            start: { islandTimerStore.start() },
            stop: { islandTimerStore.stop() }
        )
        let batteryModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: powerSourceMonitor.descriptor,
            start: { powerSourceMonitor.start() },
            stop: { powerSourceMonitor.stop() }
        )
        let mediaModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: nowPlayingModuleStore.descriptor,
            start: { nowPlayingModuleStore.start() },
            stop: { nowPlayingModuleStore.stop() }
        )
        self.islandActivityCoordinator = islandActivityCoordinator
        self.islandModuleRegistry = islandModuleRegistry
        self.islandTimerStore = islandTimerStore
        self.powerSourceMonitor = powerSourceMonitor
        self.nowPlayingModuleStore = nowPlayingModuleStore
        self.systemStatusModuleStore = systemStatusModuleStore
        self.transfersModuleRuntime = transfersModuleRuntime
        self.timerModuleRuntime = timerModuleRuntime
        self.batteryModuleRuntime = batteryModuleRuntime
        self.mediaModuleRuntime = mediaModuleRuntime
        self.islandModuleContainer = IslandModuleContainer(
            registrations: [
                IslandModuleRegistration(
                    descriptor: shelfRuntime.descriptor,
                    runtime: shelfRuntime,
                    makeContentView: { _ in AnyView(IslandShelfModuleView()) }
                ),
                IslandModuleRegistration(
                    descriptor: transfersModuleRuntime.descriptor,
                    runtime: transfersModuleRuntime,
                    makeContentView: { context in
                        AnyView(IslandTransfersView(
                            onPerformRecovery: context.onPerformRecovery
                        ))
                    }
                ),
                IslandModuleRegistration(
                    descriptor: timerModuleRuntime.descriptor,
                    runtime: timerModuleRuntime,
                    makeContentView: { _ in AnyView(IslandTimerView()) }
                ),
                IslandModuleRegistration(
                    descriptor: batteryModuleRuntime.descriptor,
                    runtime: batteryModuleRuntime,
                    makeContentView: { _ in AnyView(IslandBatteryView()) }
                ),
                IslandModuleRegistration(
                    descriptor: systemStatusModuleStore.descriptor,
                    runtime: systemStatusModuleStore,
                    makeContentView: { _ in AnyView(IslandSystemStatusView()) }
                ),
                IslandModuleRegistration(
                    descriptor: mediaModuleRuntime.descriptor,
                    runtime: mediaModuleRuntime,
                    makeContentView: { _ in AnyView(IslandNowPlayingView()) }
                ),
            ],
            coordinator: islandActivityCoordinator
        )
        self.classicDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.islandDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: importCoordinator.bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.quickLookCoordinator = QuickLookCoordinator(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            tempFileService: tempFileService
        )
        self.itemRecoveryController = ItemRecoveryController(
            store: store,
            bookmarkService: importCoordinator.bookmarkService,
            notices: importCoordinator.noticeCenter,
            openStorageRecovery: onOpenStorageRecovery
        )
        self.shelfActionRunner = ShelfActionRunner(
            bookmarkService: importCoordinator.bookmarkService,
            notices: importCoordinator.noticeCenter
        )
        super.init()
        islandActivityCoordinator.onSurfaceStateWillChange = { [weak self] oldState, newState in
            self?.prepareIslandPanelTransition(from: oldState, to: newState)
        }
        islandActivityCoordinator.onStateDidChange = { [weak self] in
            self?.scheduleIslandLayoutUpdate()
        }
        islandTimerStore.onActivity = { [weak self] activity in
            self?.timerModuleRuntime.replaceActivity(activity)
            if activity?.priority == .timerFinished,
               let self,
               self.settings.islandEnabled,
               self.islandActivityCoordinator.surfaceState != .pinned {
                self.islandActivityCoordinator.show(module: .timer)
            }
        }
        powerSourceMonitor.onActivity = { [weak self] activity in
            self?.batteryModuleRuntime.replaceActivity(activity)
        }
        nowPlayingModuleStore.onActivity = { [weak self] activity in
            self?.mediaModuleRuntime.replaceActivity(activity)
        }
        // UX5/UX6: 项目增删 → 紧凑高度动画过渡 + 空架自动隐藏裁决。
        store.onItemsDidChange = { [weak self] in
            self?.handleItemsDidChange()
        }
        store.onSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        interaction.onActionSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        importCoordinator.transferStore.onVisibilityDidChange = { [weak self] in
            self?.handleActivityVisibilityDidChange()
        }
        // S8: autoHide —— 拖出成功（operation 非空）且设置开启时隐藏 shelf。
        // 回调在 DragSessionController.draggingSession(endedAt:) 里按
        // 「实际发生 drop」判定后触发；隐藏与否在此处按最新设置裁决。
        classicDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.hideShelf(animated: true)
        }
        islandDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.collapseIsland(animated: true)
        }
        // S6: QL 面板关闭后让 ShelfPanel 重新成为 key（nonactivating：只接
        // 键盘焦点、不激活应用），空格/Delete/Esc 保持可用。闭包内访问 panel
        // 发生在 QL 关闭时，面板早已创建，不影响 lazy 语义。
        quickLookCoordinator.onPanelClosed = { [weak self] in
            guard let self,
                  self.appState.isShelfVisible
                    || self.islandActivityCoordinator.surfaceState.isExpanded else { return }
            if self.islandActivityCoordinator.surfaceState.isExpanded {
                self.islandPanel.makeKey()
            } else if self.classicPanel.isVisible {
                self.classicPanel.makeKey()
            }
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
        quickActionLayoutTask?.cancel()
        islandHoverTask?.cancel()
        islandLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func shutdown() {
        quickActionLayoutTask?.cancel()
        islandHoverTask?.cancel()
        islandLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        stopClassicHoverPreviewMonitoring()
        stopIslandModules()
        stopIslandEventMonitoring()
    }

    func toggleShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated)
            }
        case .island:
            islandActivityCoordinator.toggle()
        case nil:
            break
        }
    }

    /// Global-hot-key entry point: showing the shelf also makes its
    /// nonactivating panel key so the user can continue entirely by keyboard.
    func toggleShelfForKeyboard(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                    classicPanel.makeKey()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated, takeKeyboardFocus: true)
            }
        case .island:
            if islandActivityCoordinator.surfaceState.isExpanded {
                collapseIsland(animated: animated)
            } else {
                showIslandShelf(animated: animated, takeKeyboardFocus: true)
            }
        case nil:
            break
        }
    }

    func showPreferredShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        switch effectivePreferredShelfSurface {
        case .classic:
            showShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case .island:
            showIslandShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case nil:
            break
        }
    }

    func hidePreferredShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic: hideShelf(animated: animated)
        case .island: collapseIsland(animated: animated)
        case nil: break
        }
    }

    /// 从贴附缘滑入并淡入（贴左缘时自左侧滑入，贴右缘时自右侧滑入）。
    func showShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isOpeningClassicHoverPreview {
            performClassicHoverActions(
                classicHoverPreviewState.handle(.persistentInteraction)
            )
        }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        guard settings.classicShelfEnabled else { return }
        appState.showShelf()
        let targetFrame = classicTargetFrame()
        guard animated else {
            classicPanel.alphaValue = 1
            classicPanel.setFrame(targetFrame, display: false)
            classicPanel.orderFront(nil)
            if takeKeyboardFocus { classicPanel.makeKey() }
            return
        }
        classicPanel.alphaValue = 0
        classicPanel.setFrame(classicHiddenFrame(for: targetFrame), display: false)
        classicPanel.orderFront(nil)
        if takeKeyboardFocus { classicPanel.makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            classicPanel.animator().alphaValue = 1
            classicPanel.animator().setFrame(targetFrame, display: true)
        }
    }

    func showIslandShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        islandActivityCoordinator.show(module: .shelf)
        islandPanel.orderFront(nil)
        if takeKeyboardFocus { islandPanel.makeKey() }
    }

    /// 快速上手获得一个显示租约：记录进入前可见性、暂停所有自动隐藏并显示
    /// shelf。租约结束时恢复原可见性，不写任何用户设置。
    func beginOnboardingPresentation() -> OnboardingPresentationSnapshot {
        let surface = effectivePreferredShelfSurface ?? .classic
        let wasVisible = surface == .classic
            ? appState.isShelfVisible
            : islandActivityCoordinator.surfaceState.isExpanded
        let snapshot = OnboardingPresentationSnapshot(surface: surface, wasVisible: wasVisible)
        onboardingPresentationCount += 1
        if !wasVisible {
            if surface == .island {
                showIslandShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            } else {
                showShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
        return snapshot
    }

    func endOnboardingPresentation(_ snapshot: OnboardingPresentationSnapshot) {
        onboardingPresentationCount = max(0, onboardingPresentationCount - 1)
        guard onboardingPresentationCount == 0, !snapshot.wasVisible else { return }
        if snapshot.surface == .island {
            collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else if appState.isShelfVisible {
            hideShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// 引导面板布局使用。隐藏时返回当前设置对应的目标 frame，不要求先创建
    /// 或展示 NSPanel。
    var visibleOrTargetFrame: CGRect {
        if effectivePreferredShelfSurface == .island {
            return islandActivityCoordinator.surfaceState.isExpanded
                ? islandPanel.frame : islandTargetFrame()
        }
        return appState.isShelfVisible ? classicPanel.frame : classicTargetFrame()
    }

    /// 向贴附缘滑出并淡出，结束后 orderOut。
    func hideShelf(animated: Bool = true) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        performClassicHoverActions(classicHoverPreviewState.handle(.shelfHidden))
        stopClassicHoverPreviewMonitoring()
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = nil
        quickActionLayoutPending = false
        isMarqueeSelectionActive = false
        appState.hideShelf()
        // S6: shelf 隐藏时关掉 Quick Look 并释放会话资源（不恢复键盘焦点）。
        quickLookCoordinator.closeForShelfHide()
        let targetFrame = classicHiddenFrame(for: classicPanel.frame)
        guard animated else {
            classicPanel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            classicPanel.animator().alphaValue = 0
            classicPanel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            // 隐藏期间若用户重新唤出，则不打断显示状态。
            MainActor.assumeIsolated {
                guard let self, !self.appState.isShelfVisible else { return }
                self.classicPanel.orderOut(nil)
            }
        })
    }

    func collapseIsland(animated: Bool = true) {
        guard settings.islandEnabled else { return }
        quickLookCoordinator.closeForShelfHide()
        islandActivityCoordinator.collapse()
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandPanel.setFrame(islandTargetFrame(), display: true)
            islandPanel.orderFront(nil)
        }
    }

    // MARK: - Classic shelf hover preview

    /// EdgeTabController forwards pointer changes here so the preview state is
    /// shared with the actual shelf window and all persistent interactions.
    func classicEdgeTabHoverChanged(_ hovering: Bool) {
        guard settings.classicShelfHoverRevealEnabled,
              settings.classicShelfEnabled,
              settings.edgeTabEnabled,
              settings.shelfPosition != .custom,
              !dragStartMonitor.isDragInProgress,
              !IgnoreListService.frontmostAppIsIgnored(
                in: settings.ignoredAppBundleIDs
              ) else {
            suppressClassicHoverPreview()
            return
        }
        let event: ClassicShelfHoverPreviewStateMachine.Event = hovering
            ? .tabEntered : .tabExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    func suppressClassicHoverPreview() {
        performClassicHoverActions(classicHoverPreviewState.handle(.suppress))
    }

    func promoteClassicHoverPreviewIfNeeded() {
        guard classicHoverPreviewState.isPreview else { return }
        promoteClassicHoverPreview()
    }

    private func promoteClassicHoverPreview() {
        performClassicHoverActions(
            classicHoverPreviewState.handle(.persistentInteraction)
        )
    }

    private func performClassicHoverActions(
        _ actions: [ClassicShelfHoverPreviewStateMachine.Action]
    ) {
        for action in actions {
            switch action {
            case .scheduleDwell:
                // `mouseEntered` already expresses the user's proximity
                // intent. Reveal in the same event turn; only mouse exit keeps
                // a grace period so crossing from the tab into the shelf does
                // not make the panel flicker.
                performClassicHoverActions(
                    classicHoverPreviewState.handle(.dwellElapsed)
                )
            case .cancelDwell:
                continue
            case .showPreview:
                guard !appState.isShelfVisible else { continue }
                isOpeningClassicHoverPreview = true
                showShelf(animated: true, takeKeyboardFocus: false)
                isOpeningClassicHoverPreview = false
                startClassicHoverPreviewMonitoring()
                updateClassicHoverPreviewPointer(at: NSEvent.mouseLocation)
            case .scheduleExit:
                guard classicHoverExitTask == nil else { continue }
                classicHoverExitTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !Task.isCancelled else { return }
                    self.classicHoverExitTask = nil
                    self.performClassicHoverActions(
                        self.classicHoverPreviewState.handle(.exitElapsed)
                    )
                }
            case .cancelExit:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
            case .hidePreview:
                stopClassicHoverPreviewMonitoring()
                if appState.isShelfVisible { hideShelf(animated: true) }
            case .promoteToPersistent:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
                stopClassicHoverPreviewMonitoring()
            }
        }
    }

    private func startClassicHoverPreviewMonitoring() {
        guard classicHoverGlobalMonitor == nil, classicHoverLocalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged,
        ]
        classicHoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
        }
        classicHoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
            return event
        }
    }

    private func stopClassicHoverPreviewMonitoring() {
        if let classicHoverGlobalMonitor {
            NSEvent.removeMonitor(classicHoverGlobalMonitor)
            self.classicHoverGlobalMonitor = nil
        }
        if let classicHoverLocalMonitor {
            NSEvent.removeMonitor(classicHoverLocalMonitor)
            self.classicHoverLocalMonitor = nil
        }
    }

    private func handleClassicHoverPreviewEvent(_ event: NSEvent, at point: CGPoint) {
        guard classicHoverPreviewState.isPreview else { return }
        guard !IgnoreListService.frontmostAppIsIgnored(
            in: settings.ignoredAppBundleIDs
        ) else {
            suppressClassicHoverPreview()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged:
            if classicPanel.frame.contains(point) { promoteClassicHoverPreview() }
        case .mouseMoved:
            updateClassicHoverPreviewPointer(at: point)
        default:
            break
        }
    }

    private func updateClassicHoverPreviewPointer(at point: CGPoint) {
        let event: ClassicShelfHoverPreviewStateMachine.Event = classicPanel.frame
            .insetBy(dx: -2, dy: -2).contains(point) ? .shelfEntered : .shelfExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    private var effectivePreferredShelfSurface: SettingsStore.PreferredShelfSurface? {
        settings.effectivePreferredShelfSurface
    }

    // MARK: - Item keyboard handling (S6)

    /// Complete keyboard path for the visible shelf. Focus remains independent
    /// from multi-selection; only Shift+Arrow extends selection.
    ///
    /// 事件到达前提：卡片单击让面板成为 key（CardDragSourceAnchorView.mouseUp）。
    /// 带修饰键的组合一律放行（⌘⇧Space 等由 AppDelegate 的快捷键监听处理）；
    /// QL 面板为 key 时键盘事件由 QL 自己接管（空格/Esc 关闭、方向键翻页），
    /// 不会到达这里。
    private func handleItemKeyDown(_ event: NSEvent, in sourcePanel: ShelfPanel) -> Bool {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])

        // The global summon shortcut is user-configurable and may equal one
        // of the fixed quick-action combinations below. In that case it keeps
        // priority; never execute a shelf action from the same key press.
        if settings.hotKeyEnabled,
           let globalShortcut = settings.hotKeyShortcut,
           HotKeyMonitor.matches(event, shortcut: globalShortcut) {
            return false
        }

        if modifiers == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            return performKeyboardAction(.copyPath)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            return performKeyboardAction(.revealInFinder)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            return performKeyboardAction(.share, relativeTo: sourcePanel.contentView)
        }

        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                selectAllVisibleItems()
                return true
            case "c":
                return copyKeyboardItems()
            default:
                return false
            }
        }

        if modifiers.isEmpty || modifiers == .shift {
            let extending = modifiers == .shift
            let direction: ShelfArrowDirection?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                return moveKeyboardFocus(
                    direction,
                    extendingSelection: extending,
                    panelWidth: sourcePanel.frame.width
                )
            }
        }

        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49: // Space
            return quickLookCoordinator.toggle(contextItem: focusedItem())
        case 36, 76: // Return / keypad Enter
            return openFocusedItem()
        case 51, 117: // Delete / Forward Delete
            return removeKeyboardItems()
        case 53: // Escape
            if quickLookCoordinator.isPreviewing {
                quickLookCoordinator.dismiss()
                return true
            }
            if sourcePanel === islandPanel {
                collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                return true
            }
            if interaction.expandedStackID != nil {
                interaction.exitStack()
                return true
            }
            if !store.selection.isEmpty {
                store.clearSelection()
                return true
            }
            hideShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return true
        default:
            return false
        }
    }

    private func visibleKeyboardItems() -> [ShelfItem] {
        interaction.visibleItems(in: store.items)
    }

    private func focusedItem() -> ShelfItem? {
        let visible = visibleKeyboardItems()
        if let focusedItemID = interaction.focusedItemID,
           let item = visible.first(where: { $0.id == focusedItemID }) {
            return item
        }
        return nil
    }

    private func moveKeyboardFocus(_ direction: ShelfArrowDirection,
                                   extendingSelection: Bool,
                                   panelWidth: CGFloat) -> Bool {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return false }
        let currentIndex: Int
        if let focusedItemID = interaction.focusedItemID,
           let index = visible.firstIndex(where: { $0.id == focusedItemID }) {
            currentIndex = index
        } else if interaction.expandedStackID == nil,
                  let selected = visible.firstIndex(where: { store.selection.contains($0.id) }) {
            currentIndex = selected
        } else {
            currentIndex = 0
        }
        let destination = ShelfKeyboardNavigator.destinationIndex(
            currentIndex: currentIndex,
            itemCount: visible.count,
            columnCount: ShelfLayoutEngine.columnCount(forPanelWidth: panelWidth),
            direction: direction
        )
        interaction.focusedItemID = visible[destination].id
        if extendingSelection {
            let extendingIDs: Set<UUID> = [visible[currentIndex].id, visible[destination].id]
            if interaction.expandedStackID != nil {
                interaction.childSelection.formUnion(extendingIDs)
            } else {
                store.setSelection(store.selection.union(extendingIDs))
            }
        }
        return true
    }

    private func selectAllVisibleItems() {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return }
        if interaction.expandedStackID != nil {
            interaction.childSelection = Set(visible.map(\.id))
        } else {
            store.selectAll()
        }
        if interaction.focusedItemID == nil {
            interaction.focusedItemID = visible[0].id
        }
    }

    private func keyboardActionItems() -> [ShelfItem] {
        let visible = visibleKeyboardItems()
        if interaction.expandedStackID != nil {
            let selected = visible.filter { interaction.childSelection.contains($0.id) }
            if !selected.isEmpty { return selected }
        } else {
            let selected = visible.filter { store.selection.contains($0.id) }
            if !selected.isEmpty { return selected }
        }
        guard let focusedItemID = interaction.focusedItemID,
              let focused = visible.first(where: { $0.id == focusedItemID }) else { return [] }
        return [focused]
    }

    private func copyKeyboardItems() -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let result = ClipboardController.copy(
            items,
            bookmarkService: importCoordinator.bookmarkService
        )
        importCoordinator.noticeCenter.show(ClipboardController.statusMessage(for: result))
        return true
    }

    private func performKeyboardAction(_ action: ShelfAction,
                                       relativeTo anchorView: NSView? = nil) -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty, ShelfActionCatalog.canPerform(action, on: items) else {
            return false
        }
        shelfActionRunner.perform(action, on: items, relativeTo: anchorView)
        return true
    }

    private func openFocusedItem() -> Bool {
        guard let item = focusedItem() else { return false }
        if item.availability != .available {
            itemRecoveryController.recover(item)
            return true
        }
        if item.kind == .stack {
            if interaction.expandedStackID == item.id {
                interaction.exitStack()
            } else {
                interaction.enterStack(item)
            }
            return true
        }
        guard ItemActions.canOpen(item) else { return false }
        ItemActions.open(item,
                         bookmarkService: importCoordinator.bookmarkService,
                         tempFileService: tempFileService)
        return true
    }

    private func removeKeyboardItems() -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let ids = Set(items.map(\.id))
        if let stackID = interaction.expandedStackID {
            guard store.removeChildren(ids: ids, fromStack: stackID) else { return false }
            interaction.childSelection.subtract(ids)
        } else {
            store.remove(ids: ids)
        }
        interaction.normalize(for: store.items)
        quickLookCoordinator.refreshPreview(contextItem: focusedItem())
        return true
    }

    // MARK: - Layout

    /// 位置与宽度由 SettingsStore 供给；纯计算收敛在 `ShelfLayoutEngine`（S9）。
    /// 左/右跟随鼠标所在屏幕（鼠标屏被拔掉回退主屏），贴设定缘；UX5 起高度
    /// 贴合内容（按 `store.items.count` 推算行数，上限可见高度 80%）；EdgeTab
    /// 起垂直位置按 `shelfEdgeOffset`（0 = 底缘、1 = 顶缘，默认 0.5 居中）；
    /// custom 用校验后的持久化 frame（首次/所在屏被拔掉时从目标屏
    /// 右缘默认 frame 起步）。
    private func classicTargetFrame() -> NSRect {
        ShelfLayoutEngine.targetFrame(
            position: settings.shelfPosition,
            width: settings.shelfWidth,
            itemCount: store.items.count,
            hasActivity: importCoordinator.transferStore.hasVisibleActivity,
            hasQuickActions: hasVisibleQuickActions,
            mouseLocation: NSEvent.mouseLocation,
            screens: Self.screenGeometries(),
            persistedCustomFrame: settings.customShelfFrame,
            edgeOffset: CGFloat(settings.shelfEdgeOffset)
        )
    }

    private func islandTargetFrame() -> NSRect {
        let layout = islandLayout()
        islandActivityCoordinator.currentLayout = layout
        return islandActivityCoordinator.surfaceState.isExpanded
            ? layout.expandedFrame : layout.compactFrame
    }

    private func prepareIslandPanelTransition(
        from oldState: IslandSurfaceState,
        to newState: IslandSurfaceState
    ) {
        guard settings.islandEnabled,
              !oldState.isExpanded,
              newState.isExpanded else { return }
        // A selected-module change can already have queued a compact layout
        // pass. Cancel it so no stale frame is applied between preparation and
        // the actual surface-state mutation.
        islandLayoutTask?.cancel()
        islandLayoutTask = nil

        let layout = islandLayout()
        islandActivityCoordinator.currentLayout = layout
        // Give SwiftUI a fixed, top-centred canvas before the visible morph
        // starts. The compact surface remains centred inside this transparent
        // canvas, while its mask grows to the expanded size. Animating the
        // AppKit window and SwiftUI hierarchy at the same time made hosting-view
        // relayout appear as a lateral jump from the right.
        islandPanel.setFrame(layout.expandedFrame, display: true)
        islandPanel.orderFront(nil)
    }

    private var hasVisibleQuickActions: Bool {
        let items = ShelfActionSelectionResolver.explicitItems(
            topLevelItems: store.items,
            topLevelSelection: store.selection,
            expandedStackID: interaction.expandedStackID,
            childSelection: interaction.childSelection
        )
        return ShelfActionCatalog.hasAnyAction(for: items)
    }

    /// 隐藏态 frame：左/右向贴附缘方向平移一个面板宽度；custom 原位（淡出）。
    private func classicHiddenFrame(for frame: NSRect) -> NSRect {
        ShelfLayoutEngine.hiddenFrame(for: frame, position: settings.shelfPosition)
    }

    private func islandLayout(at point: CGPoint = NSEvent.mouseLocation)
        -> IslandGeometryResolver.Layout {
        if let screen = IslandScreenCatalog.selectedScreen(
            for: settings.islandDisplayTarget,
            pointerPoint: point
        ) {
            return IslandGeometryResolver.resolve(
                screen: IslandScreenCatalog.geometry(for: screen)
            )
        }
        return IslandGeometryResolver.resolve(screen: .init(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        ))
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
        if appState.isShelfVisible {
            classicPanel.setFrame(classicTargetFrame(), display: true)
        }
        if settings.islandEnabled {
            islandPanel.setFrame(islandTargetFrame(), display: true)
        }
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
        if settings.islandEnabled {
            islandPanel.setFrame(islandTargetFrame(), display: true)
            islandPanel.orderFront(nil)
        }
        guard appState.isShelfVisible else { return }
        let corrected = ShelfLayoutEngine.onscreenCorrection(for: classicPanel.frame,
                                                             screens: Self.screenGeometries())
            ?? classicTargetFrame()
        guard corrected != classicPanel.frame else { return }
        classicPanel.setFrame(corrected, display: true)
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
        applyPresentationSettings(animated: true)
        guard appState.isShelfVisible else { return }
        let target = classicTargetFrame()
        guard target != classicPanel.frame else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            classicPanel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            classicPanel.animator().setFrame(target, display: true)
        }
    }

    /// UX5/UX6: items 变更（store.onItemsDidChange 钩子）统一处理：
    /// 1. UX5 紧凑高度 —— 可见时数量变化动画过渡到新目标 frame（custom
    ///    位置的目标 frame 不含内容高度，天然 no-op）；
    /// 2. UX6 空架自动隐藏 —— 非空→空迁移且设置开启时动画收回。
    ///    任务二：拖拽进行中不收回（不变式见 EmptyShelfAutoHideRule）。
    private func handleItemsDidChange() {
        interaction.normalize(for: store.items)
        let shouldAutoHide = emptyAutoHideRule.evaluate(
            itemCount: store.items.count,
            isVisible: appState.isShelfVisible,
            isEnabled: settings.autoHideWhenEmpty && onboardingPresentationCount == 0,
            isDragInProgress: dragStartMonitor.isDragInProgress
        )
        if appState.isShelfVisible {
            let target = classicTargetFrame()
            if target != classicPanel.frame {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    classicPanel.setFrame(target, display: true)
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Self.animationDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        classicPanel.animator().setFrame(target, display: true)
                    }
                }
            }
        }
        // 空架隐藏放在高度动画之后裁决：两者同帧时隐藏优先（隐藏动画覆盖）。
        if shouldAutoHide {
            hideShelf(animated: true)
        }
    }

    /// ActivityStrip changes compact height but must not participate in the
    /// non-empty → empty auto-hide state machine.
    private func handleActivityVisibilityDidChange() {
        transfersModuleRuntime.refresh()
        guard appState.isShelfVisible else { return }
        let target = classicTargetFrame()
        guard target != classicPanel.frame else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            classicPanel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            classicPanel.animator().setFrame(target, display: true)
        }
    }

    /// Explicit top-level or expanded-stack selection changes only affect the
    /// quick-action row. They do not enter the item persistence or empty-shelf
    /// auto-hide state machines.
    private func handleQuickActionVisibilityDidChange() {
        guard appState.isShelfVisible else { return }
        if isMarqueeSelectionActive {
            quickActionLayoutPending = true
            quickActionLayoutTask?.cancel()
            quickActionLayoutTask = nil
            return
        }

        quickActionLayoutPending = false
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.applyQuickActionLayoutChange()
        }
    }

    private func setMarqueeSelectionActive(_ isActive: Bool) {
        isMarqueeSelectionActive = isActive
        if !isActive, quickActionLayoutPending {
            handleQuickActionVisibilityDidChange()
        }
    }

    private func applyQuickActionLayoutChange() {
        quickActionLayoutTask = nil
        guard appState.isShelfVisible else { return }
        let target = classicTargetFrame()
        guard target != classicPanel.frame else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            classicPanel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            classicPanel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Island presentation

    /// Applies two independent surface preferences over the same ShelfStore.
    /// Enabling or disabling one surface never changes the other's visibility
    /// or deletes shelf content.
    func applyPresentationSettings(animated: Bool = false) {
        islandModuleRegistry.apply(settings: settings)
        classicPanel.allowsTopEdgeOverlap = false
        classicPanel.level = .floating
        classicPanel.hasShadow = true
        if settings.classicShelfEnabled {
            if appState.isShelfVisible {
                classicPanel.alphaValue = 1
                classicPanel.setFrame(classicTargetFrame(), display: true)
                classicPanel.orderFront(nil)
            }
        } else {
            appState.hideShelf()
            classicPanel.orderOut(nil)
        }

        if settings.islandEnabled {
            // A regular floating panel is constrained below the menu bar by AppKit.
            // Island chrome must occupy the camera-housing band itself, matching
            // status-item z-order while staying below screen-saver windows so drag
            // sessions keep reaching it.
            islandPanel.allowsTopEdgeOverlap = true
            islandPanel.level = NSWindow.Level(
                rawValue: NSWindow.Level.statusBar.rawValue + 8
            )
            islandPanel.hasShadow = false
            startEnabledIslandModules()
            startIslandEventMonitoring()
            if islandActivityCoordinator.surfaceState == .hidden {
                islandActivityCoordinator.setSurfaceState(.compact)
            }
            if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule),
               let fallback = islandModuleRegistry.enabledDescriptors.first?.id {
                islandActivityCoordinator.selectedModule = fallback
            }
            islandPanel.alphaValue = 1
            islandPanel.setFrame(islandTargetFrame(), display: true)
            islandPanel.orderFront(nil)
        } else {
            stopIslandModules()
            stopIslandEventMonitoring()
            islandActivityCoordinator.hide()
            islandPanel.orderOut(nil)
        }
    }

    func islandDragApproachedTop(at point: CGPoint) -> Bool {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return false }
        let layout = islandLayout(at: point)
        guard layout.activationFrame.contains(point) else { return false }
        islandActivityCoordinator.currentLayout = layout
        if !islandActivityCoordinator.surfaceState.isExpanded {
            islandActivityCoordinator.beginDrag()
            return true
        }
        return false
    }

    func islandDragEnded(imported: Bool) {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return }
        islandActivityCoordinator.endDrag(imported: imported)
    }

    private func startEnabledIslandModules() {
        if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            islandActivityCoordinator.selectedModule =
                islandModuleRegistry.enabledDescriptors.first?.id ?? .transfers
        }
        islandModuleContainer.apply(
            configuration: settings.islandModuleConfiguration,
            isActive: true
        )
    }

    private func stopIslandModules() {
        islandModuleContainer.stopAll()
    }

    private func scheduleIslandLayoutUpdate() {
        guard settings.islandEnabled else { return }
        islandLayoutTask?.cancel()
        islandLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            let target = self.islandTargetFrame()
            self.islandPanel.orderFront(nil)
            guard target != self.islandPanel.frame else { return }

            if !self.islandActivityCoordinator.surfaceState.isExpanded,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Keep the expanded canvas until the visible surface has
                // finished folding into its compact top-centred silhouette.
                // The final frame change is then visually inert because both
                // frames share the exact same top-centre anchor.
                try? await Task.sleep(for: .seconds(
                    max(IslandMotion.collapseContentDuration,
                        IslandMotion.collapseWindowDuration)
                ))
                guard !Task.isCancelled,
                      !self.islandActivityCoordinator.surfaceState.isExpanded else {
                    return
                }
                self.islandPanel.setFrame(target, display: true)
                return
            }
            self.animateIsland(to: target)
        }
    }

    private func animateIsland(to target: NSRect) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandPanel.setFrame(target, display: true)
            return
        }
        let isExpanding = target.height > islandPanel.frame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isExpanding
                ? IslandMotion.expandWindowDuration
                : IslandMotion.collapseWindowDuration
            context.timingFunction = isExpanding
                ? CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.18, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.20, 1.0)
            islandPanel.animator().setFrame(target, display: true)
        }
    }

    private func startIslandEventMonitoring() {
        guard islandGlobalMonitor == nil, islandLocalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .mouseMoved]
        islandGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleIslandEvent(event, at: point) }
        }
        islandLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleIslandEvent(event, at: point) }
            return event
        }
    }

    private func stopIslandEventMonitoring() {
        if let islandGlobalMonitor {
            NSEvent.removeMonitor(islandGlobalMonitor)
            self.islandGlobalMonitor = nil
        }
        if let islandLocalMonitor {
            NSEvent.removeMonitor(islandLocalMonitor)
            self.islandLocalMonitor = nil
        }
        islandHoverTask?.cancel()
        islandHoverTask = nil
        islandActivityCoordinator.setPointerHovering(false)
    }

    private func handleIslandEvent(_ event: NSEvent, at point: CGPoint) {
        guard settings.islandEnabled else { return }
        switch event.type {
        case .leftMouseDown:
            if !islandActivityCoordinator.surfaceState.isExpanded {
                let layout = islandLayout(at: point)
                guard layout.compactFrame.contains(point) else { return }
                // The right music wing owns a direct play/pause action. Let
                // its SwiftUI button consume the click instead of expanding.
                guard !isCompactMediaTransportHit(point, layout: layout) else { return }
                islandActivityCoordinator.currentLayout = layout
                islandActivityCoordinator.show(module: effectiveIslandOpenModule)
                return
            }
            guard islandActivityCoordinator.surfaceState == .expanded,
                  !islandPanel.frame.contains(point) else { return }
            collapseIsland(animated: true)
        case .mouseMoved:
            let layout = islandLayout(at: point)
            if !islandActivityCoordinator.surfaceState.isExpanded {
                if islandActivityCoordinator.currentLayout?.compactFrame != layout.compactFrame {
                    islandActivityCoordinator.currentLayout = layout
                    islandPanel.setFrame(layout.compactFrame, display: true)
                }
            }
            islandActivityCoordinator.setPointerHovering(
                !islandActivityCoordinator.surfaceState.isExpanded
                    && layout.compactFrame.contains(point)
            )
            guard settings.islandHoverRevealEnabled,
                  islandActivityCoordinator.canRevealOnHover,
                  !islandActivityCoordinator.surfaceState.isExpanded else {
                islandHoverTask?.cancel()
                islandHoverTask = nil
                return
            }
            guard layout.compactFrame.insetBy(dx: -4, dy: -4).contains(point) else {
                islandHoverTask?.cancel()
                islandHoverTask = nil
                return
            }
            guard islandHoverTask == nil else { return }
            islandHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.islandHoverTask = nil
                self.islandActivityCoordinator.show(module: self.effectiveIslandOpenModule)
            }
        default:
            break
        }
    }

    private var effectiveIslandOpenModule: IslandModuleID {
        if let activity = islandActivityCoordinator.primaryActivity(),
           islandModuleRegistry.isEnabled(activity.moduleID) {
            return activity.moduleID
        }
        if islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            return islandActivityCoordinator.selectedModule
        }
        return islandModuleRegistry.enabledDescriptors.first?.id ?? .transfers
    }

    private func isCompactMediaTransportHit(
        _ point: CGPoint,
        layout: IslandGeometryResolver.Layout
    ) -> Bool {
        guard islandActivityCoordinator.primaryActivity()?.moduleID == .media,
              nowPlayingModuleStore.snapshot != nil,
              nowPlayingModuleStore.supportsTransportControls else { return false }
        let controlWidth = layout.hasPhysicalNotch
            ? IslandGeometryResolver.compactWingWidth
            : 48
        let frame = CGRect(x: layout.compactFrame.maxX - controlWidth,
                           y: layout.compactFrame.minY,
                           width: controlWidth,
                           height: layout.compactFrame.height)
        return frame.contains(point)
    }
}
