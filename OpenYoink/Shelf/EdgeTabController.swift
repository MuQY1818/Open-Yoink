import AppKit

/// EdgeTab：贴在屏幕边缘的常驻拉环（用户确认的交互设计）：
/// 1. 单击 → 展开/收起 shelf（`onToggleShelf`）；
/// 2. 拖文件到拉环上 → 复用 `DropImportCoordinator` 导入并唤出 shelf；
/// 3. 按住拖动 → 沿边上下移动（持久化 `shelfEdgeOffset`）；光标越过屏幕
///    中线逼近对缘（`ShelfLayoutEngine.shouldFlipSide`）→ 实时换边，抬起时
///    持久化 `shelfPosition`；
/// 4. 可见性状态机：`edgeTabEnabled && position != .custom && !isShelfVisible` ——
///    拉环只在 shelf 隐藏时出现（拉环与 shelf 是同一元素的两种状态，不同
///    时可见，用户确认）；shelf 展开后由面板**贴缘侧外缘隐形热区**承担
///    「同一点位再点收起」（见 ShelfView 的外缘收起热区）；custom 自由
///    位置模式无拉环（标题栏拖拽已覆盖，见 `WindowDragHandle`）；
/// 5. 拖拽进行中（`DragStartMonitor.isDragInProgress`）→ accent 描边/浅填充
///    + 轻微放大（`ShelfLayoutEngine.edgeTabEmphasisFrame`）的投放暗示。
///
/// 布局全部为 `ShelfLayoutEngine` 纯函数（frame/offset/换边/强调/驻点
/// frame），本类只做窗口与状态机；常态位贴附屏判定与 shelf 同规则（鼠标
/// 所在屏，见 `ShelfWindowController.screen(containing:)`），驻点位取
/// shelf 面板所在屏（`layoutVisibleFrame`）。
@MainActor
final class EdgeTabController: NSObject {
    private static let fadeDuration: TimeInterval = 0.18
    private static let emphasisDuration: TimeInterval = 0.15
    /// 驻点/回位等 frame 迁移时长（与 ShelfWindowController 显隐动画同拍）。
    private static let moveDuration: TimeInterval = 0.2

    private let appState: AppState
    private let settings: SettingsStore
    private let store: ShelfStore
    private let importCoordinator: DropImportCoordinator
    private let dragStartMonitor: DragStartMonitor
    private let onToggleShelf: @MainActor () -> Void
    private let onShowShelf: @MainActor () -> Void

    /// 拉环正被按住拖动（重定位会话进行中）。镜像到
    /// `AppState.isEdgeTabBeingDragged` 供拖拽触发器抑制唤出（拖动拉环
    /// 本身不应唤出 shelf）；本标志仅用于本地强调态与布局门控。
    private var isTabBeingDragged = false

    /// 投放悬停（文件拖拽正悬停在拉环上且内容可导入）。
    private var isDropTargeted = false
    /// 当前已应用的强调态（用于变化检测，避免重复动画）。
    private var isEmphasized = false

    private lazy var panel: EdgeTabPanel = {
        let panel = EdgeTabPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                             height: ShelfLayoutEngine.edgeTabHeight)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = tabView
        panel.setAccessibilityLabel(String(localized: "Show Shelf"))
        return panel
    }()

    private lazy var tabView: EdgeTabView = {
        let view = EdgeTabView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                                          height: ShelfLayoutEngine.edgeTabHeight)))
        view.position = settings.shelfPosition
        view.onClick = { [weak self] in
            self?.onToggleShelf()
        }
        view.onReposition = { [weak self] offset, position in
            self?.finishReposition(offset: offset, position: position)
        }
        view.onRepositionStateChanged = { [weak self] active in
            guard let self else { return }
            self.isTabBeingDragged = active
            self.appState.setEdgeTabBeingDragged(active)
            // 只置标志、不重估强调态：抬起时拖拽监视器的 isDragInProgress
            // 要到下一 runloop 才复位，此时重估会闪一帧投放暗示；拖拽结束
            // 的 observation 回调随后会做最终评估。
        }
        view.onDropTargetChanged = { [weak self] targeted in
            guard let self, self.isDropTargeted != targeted else { return }
            self.isDropTargeted = targeted
            self.updateEmphasis(animated: true)
        }
        view.onDrop = { [weak self] pasteboard in
            self?.handleDrop(pasteboard) ?? false
        }
        return view
    }()

    init(appState: AppState,
         settings: SettingsStore,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         dragStartMonitor: DragStartMonitor,
         onToggleShelf: @escaping @MainActor () -> Void,
         onShowShelf: @escaping @MainActor () -> Void) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.importCoordinator = importCoordinator
        self.dragStartMonitor = dragStartMonitor
        self.onToggleShelf = onToggleShelf
        self.onShowShelf = onShowShelf
        super.init()
        beginObservation()
        // 设置变更（edgeTabEnabled / shelfPosition / shelfEdgeOffset —— 含
        // 拖动拉环抬起时的持久化写）统一重估。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // 插拔屏/改分辨率 → 按新几何重算（所在屏被拔掉时回退鼠标屏/主屏）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 初始评估（启动时 shelf 隐藏 → 拉环立即就位，无动画）。
        applyState(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility state machine

    /// 拉环应在位 ⇔ 设置开启 && 非 custom（custom 无贴附缘）&& shelf 隐藏
    /// （拉环与 shelf 互斥：shelf 展开时由面板外缘隐形热区承担同点位收起）。
    private var shouldBeVisible: Bool {
        settings.edgeTabEnabled && settings.shelfPosition != .custom && !appState.isShelfVisible
    }

    /// 统一状态评估：可见性 / 设置 / 屏幕参数 / 拖拽状态变更后调用。
    private func applyState(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // 贴附侧同步给视图（圆角朝向 / 换边基准）；拖动会话期间位置由手势
        // 自管（可能已实时换边但尚未持久化），此处不覆盖。
        if !isTabBeingDragged {
            tabView.position = settings.shelfPosition
        }
        guard shouldBeVisible else {
            // 隐藏时强制清强调态：下次 showTab 总是从常态 frame 起步，
            // 再由 updateEmphasis 按需放大（避免带着陈旧的放大 frame 出现）。
            if isEmphasized {
                isEmphasized = false
                tabView.isEmphasized = false
            }
            hideTab(animated: animated)
            return
        }
        let target = currentTargetFrame()
        if panel.isVisible {
            // 拖动拉环期间 frame 由手势直控，此处不抢夺。常态位迁移（设置/
            // 屏幕参数变更）动画过渡。
            if !isTabBeingDragged, panel.frame != target {
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Self.moveDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        panel.animator().setFrame(target, display: true)
                    }
                } else {
                    panel.setFrame(target, display: true)
                }
            }
        } else {
            showTab(target, animated: animated)
        }
        updateEmphasis(animated: animated)
    }

    private func showTab(_ frame: NSRect, animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(frame, display: false)
        guard animated else {
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideTab(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 淡出期间若状态又变为应在位（设置重新开启），不抢断。
            MainActor.assumeIsolated {
                guard let self, !self.shouldBeVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    /// 拉环目标屏（与 shelf 同规则：鼠标所在屏，被拔掉回退主屏）。
    private func targetVisibleFrame() -> CGRect {
        ShelfWindowController.screen(containing: NSEvent.mouseLocation).visibleFrame
    }

    /// 常态 frame：边缘常态位（custom 的 nil 只在状态机失守时出现，兜底
    /// 一个原点 frame）。
    private func baseFrame() -> NSRect {
        return ShelfLayoutEngine.edgeTabFrame(position: settings.shelfPosition,
                                              offset: CGFloat(settings.shelfEdgeOffset),
                                              visibleFrame: targetVisibleFrame())
            ?? NSRect(x: 0, y: 0,
                      width: ShelfLayoutEngine.edgeTabWidth,
                      height: ShelfLayoutEngine.edgeTabHeight)
    }

    /// 当前目标 frame：强调态取放大 frame。
    private func currentTargetFrame() -> NSRect {
        let base = baseFrame()
        guard isEmphasized else { return base }
        return ShelfLayoutEngine.edgeTabEmphasisFrame(from: base,
                                                      position: settings.shelfPosition,
                                                      visibleFrame: targetVisibleFrame())
    }

    // MARK: - Emphasis (drag affordance / drop hover)

    /// 强调态 = 投放悬停 ||（拖拽进行中且非拖动拉环本身）。变化时同步视图
    /// 高亮并动画切换 frame（常态 ↔ 轻微放大）。
    private func updateEmphasis(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let emphasized = panel.isVisible
            && (isDropTargeted || (dragStartMonitor.isDragInProgress && !isTabBeingDragged))
        guard emphasized != isEmphasized else { return }
        isEmphasized = emphasized
        tabView.isEmphasized = emphasized
        let target = currentTargetFrame()
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.emphasisDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Gesture results

    /// 拖动结束（位移 ≥ 阈值）：持久化 offset 与贴附侧。写 UserDefaults 经
    /// didChangeNotification 触发 applyState 重布局 —— 目标 frame 与手势
    /// 终点一致，无视觉跳变。
    private func finishReposition(offset: CGFloat, position: SettingsStore.ShelfPosition) {
        settings.shelfEdgeOffset = Double(offset)
        if settings.shelfPosition != position {
            settings.shelfPosition = position
        }
    }

    /// 拖放上拉环：复用拖入分派（含 ⌘ 剪切模式，与 `DragContainerView` 同一
    /// 判定）；同步 items 直接入架，异步物化逐个追加；有内容被处理即唤出
    /// shelf 给出反馈。
    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        let mode = DropImportCoordinator.dropMode(for: pasteboard, modifiers: NSEvent.modifierFlags)
        let result = importCoordinator.importItems(
            from: pasteboard,
            mode: mode,
            onManagedMoveReady: { [store, importCoordinator] item in
                do {
                    try store.addAndPersistNow(item)
                    importCoordinator.markManagedMoveCommitted(itemID: item.id)
                    return true
                } catch {
                    store.add(item)
                    importCoordinator.noticeCenter.show(String(localized: "The moved item is being kept for recovery because the shelf could not be saved immediately."))
                    return false
                }
            },
            onPromisedItemReady: { [store, importCoordinator] item in
                do {
                    try store.addAndPersistNow(item)
                    return true
                } catch {
                    importCoordinator.noticeCenter.show(String(localized: "The received file was kept safely. Open Recovery to finish importing it."))
                    return false
                }
            }
        ) { [store] item in
            store.add(item)
        }
        guard result.handled else { return false }
        store.add(contentsOf: result.items)
        onShowShelf()
        return true
    }

    // MARK: - Observation

    /// 跟踪 shelf 可见性与拖拽进行中状态。withObservationTracking 的
    /// onChange 只触发一次，每次变更后重新注册；onChange 是 @Sendable
    /// 非隔离闭包，桥回 MainActor 读最新值（同 userDefaultsDidChange 的
    /// 桥接模式）。applyState 读的是最新值而非增量，多次变更合并安全。
    private func beginObservation() {
        withObservationTracking {
            _ = appState.isShelfVisible
            _ = dragStartMonitor.isDragInProgress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyState(animated: true)
                self.beginObservation()
            }
        }
    }

    /// 必须 nonisolated：通知按投递线程同步回调（同 ShelfWindowController /
    /// AppDelegate 的说明）。
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyState(animated: true)
        }
    }

    @objc private nonisolated func screenParametersDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyState(animated: true)
        }
    }
}

/// EdgeTab 内容视图：vibrancy 底（.hudWindow）+ 朝内圆角 + 1pt 内描边 +
/// 小号 tray SF Symbol（secondary 色）。三个职责：
/// 1. 鼠标手势（自管，不用 `performDrag` —— 要约束沿边移动 + 换边检测）：
///    mouseDown 记起点 → mouseDragged 沿边移动（实时夹取；过中线逼近对缘
///    实时换边，拉环吸附对缘同高度）→ mouseUp：位移 < 4pt 视为单击，
///    否则上报 offset/贴附侧持久化；
/// 2. NSDraggingDestination：注册 `PasteboardTypes.dragInTypes`，悬停/落下
///    经回调交给 EdgeTabController；
/// 3. 强调态外观（accent 描边 + 浅填充），由 controller 驱动。
@MainActor
final class EdgeTabView: NSView {
    /// 单击/拖动的位移判据（点）。
    static let clickThreshold: CGFloat = 4
    static let cornerRadius: CGFloat = 8

    /// 当前贴附侧（controller 布局时同步；拖动换边时本地即时更新），
    /// 决定圆角朝向与描边路径。custom 无拉环，仅作兜底（不翻转）。
    var position: SettingsStore.ShelfPosition = .right {
        didSet {
            guard oldValue != position else { return }
            updateCornering()
        }
    }

    /// 强调态（拖拽暗示 / 投放悬停）：accent 描边 + 浅填充，平滑过渡。
    var isEmphasized = false {
        didSet {
            guard oldValue != isEmphasized else { return }
            applyEmphasisAppearance(
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    /// 单击（位移 < clickThreshold 的抬起）。
    var onClick: (@MainActor () -> Void)?
    /// 拖动结束上报：最新 offset 与贴附侧（可能已换边）。
    var onReposition: (@MainActor (CGFloat, SettingsStore.ShelfPosition) -> Void)?
    /// 重定位会话开始/结束（controller 据此抑制拖拽唤出与强调态）。
    var onRepositionStateChanged: (@MainActor (Bool) -> Void)?
    /// 投放悬停变化。
    var onDropTargetChanged: (@MainActor (Bool) -> Void)?
    /// 投放处理（pasteboard → 导入）；返回是否已处理。
    var onDrop: (@MainActor (NSPasteboard) -> Bool)?

    private let vibrancyView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let strokeLayer = CAShapeLayer()

    // 手势状态（一次按下会话）。
    private var isRepositioning = false
    private var dragMoved = false
    private var dragStartCursor: CGPoint = .zero
    private var dragStartCenterY: CGFloat = 0
    private var pendingOffset: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        vibrancyView.material = .hudWindow
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        vibrancyView.layer?.cornerRadius = Self.cornerRadius
        vibrancyView.layer?.masksToBounds = true
        vibrancyView.setAccessibilityElement(false)
        vibrancyView.setAccessibilityHidden(true)
        addSubview(vibrancyView)

        iconView.image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: String(localized: "Show Shelf")
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // The containing EdgeTabView is the actual button and already exposes
        // a localized "Show Shelf" label. Keep the decorative symbol out of
        // the accessibility tree so audits and VoiceOver do not encounter a
        // second, unlabeled element for the same control.
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityHidden(true)
        addSubview(iconView)

        // 内描边/强调填充层：path 只对朝内两角加圆弧，inset 0.5。
        strokeLayer.lineWidth = 1
        strokeLayer.zPosition = 1
        layer?.addSublayer(strokeLayer)

        registerForDraggedTypes(PasteboardTypes.dragInTypes)

        setAccessibilityRole(.button)
        // 拉环只在 shelf 隐藏时出现，点击即展开（互斥模型，见 controller）。
        setAccessibilityLabel(String(localized: "Show Shelf"))

        updateCornering()
        applyEmphasisAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EdgeTabView is created programmatically")
    }

    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
        let iconSize: CGFloat = 16
        iconView.frame = NSRect(x: bounds.midX - iconSize / 2,
                                y: bounds.midY - iconSize / 2,
                                width: iconSize, height: iconSize)
        strokeLayer.frame = bounds
        updateStrokePath()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Mouse gesture (click / reposition / flip)

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartCursor = NSEvent.mouseLocation
        dragStartCenterY = window.frame.midY
        dragMoved = false
        isRepositioning = true
        onRepositionStateChanged?(true)
    }

    /// 沿边移动：y 由拖动位移驱动（起点中心 + Δy，经 offset 夹取）；
    /// x 始终吸附当前贴附缘 —— 过中线逼近对缘时实时换边（贴对缘同高度）。
    override func mouseDragged(with event: NSEvent) {
        guard isRepositioning, let window else { return }
        let cursor = NSEvent.mouseLocation
        if !dragMoved {
            let displacement = hypot(cursor.x - dragStartCursor.x, cursor.y - dragStartCursor.y)
            guard displacement >= Self.clickThreshold else { return }
            dragMoved = true
        }
        let screen = ShelfWindowController.screen(containing: cursor)
        if ShelfLayoutEngine.shouldFlipSide(position: position,
                                            cursorLocation: cursor,
                                            screenFrame: screen.frame) {
            position = position == .left ? .right : .left
        }
        let centerY = dragStartCenterY + (cursor.y - dragStartCursor.y)
        let offset = ShelfLayoutEngine.edgeTabOffset(forCenterY: centerY,
                                                     visibleFrame: screen.visibleFrame)
        pendingOffset = offset
        if let frame = ShelfLayoutEngine.edgeTabFrame(position: position, offset: offset,
                                                      visibleFrame: screen.visibleFrame) {
            window.setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isRepositioning else { return }
        isRepositioning = false
        onRepositionStateChanged?(false)
        if dragMoved {
            dragMoved = false
            onReposition?(pendingOffset, position)
        } else {
            onClick?()
        }
    }

    // MARK: - NSDraggingDestination

    /// 来自本应用卡片的拖出（draggingSource 非空）不接受 —— 与
    /// `DragContainerView` 同一规则，避免「拖出又放回」产生重复引用。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.isAcceptableDrop(sender) else { return [] }
        onDropTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.isAcceptableDrop(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    private static func isAcceptableDrop(_ sender: NSDraggingInfo) -> Bool {
        // 「Drop everything」语义同 DragContainerView（任务一）。
        sender.draggingSource == nil
            && PasteboardTypes.hasImportableContent(in: sender.draggingPasteboard.types ?? [])
    }

    // MARK: - Appearance

    /// 圆角朝向屏内：右缘拉环绕左两角，左缘拉环绕右两角（上下对称，
    /// 与图层坐标系是否翻转无关）。
    private func updateCornering() {
        let corners: CACornerMask = position == .left
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        vibrancyView.layer?.maskedCorners = corners
        updateStrokePath()
    }

    private func updateStrokePath() {
        let rect = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 0.5, dy: 0.5)
        strokeLayer.path = Self.innerRoundedPath(in: rect,
                                                 radius: Self.cornerRadius - 0.5,
                                                 position: position)
    }

    private func applyEmphasisAppearance(animated: Bool) {
        let stroke: CGColor = isEmphasized
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
        let fill: CGColor = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
        // 平滑过渡：显式 CATransaction 时长让颜色变化走隐式动画。
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        strokeLayer.strokeColor = stroke
        strokeLayer.fillColor = fill
        CATransaction.commit()
    }

    /// 只对朝内两角加圆弧的圆角矩形路径（贴缘侧直角）。路径上下对称，
    /// y-up / y-down 坐标系均正确。
    private static func innerRoundedPath(in rect: CGRect,
                                         radius: CGFloat,
                                         position: SettingsStore.ShelfPosition) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let path = CGMutablePath()
        switch position {
        case .right:
            // 朝内 = 左侧：左上、左下两角加圆弧。
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r,
                        startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
            path.closeSubpath()
        case .left:
            // 朝内 = 右侧：右上、右下两角加圆弧。
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX - r, y: maxY))
            path.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: maxX, y: minY + r))
            path.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r,
                        startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
            path.closeSubpath()
        case .custom:
            // 无拉环；完整圆角矩形兜底（不应到达）。
            path.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                                transform: nil))
        }
        return path
    }
}
