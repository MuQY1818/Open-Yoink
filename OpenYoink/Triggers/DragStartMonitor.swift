import AppKit

/// UX1 拖拽开始识别（纯逻辑状态机，与 AppKit 解耦供单测）：
/// 左键按下记录起点 → 按住移动、与起点的直线位移达到阈值判定「拖拽开始」
/// （恰好回调一次）→ 左键抬起结束。
///
/// 阈值采用「与按下点的位移」而非「路径累计长度」：点击按住不放时手的微颤
/// 会累计路径长度但几乎不产生位移，位移判据不会把「按住不放」误判为拖拽。
struct DragGestureTracker: Sendable, Equatable {
    /// 状态机相位。
    enum Phase: String, Sendable, Equatable {
        /// 左键未按下。
        case idle
        /// 已按下、尚未确认拖拽（位移未达阈值）。
        case pressing
        /// 已确认拖拽（阈值已跨越、已回调）。
        case dragging
    }

    /// 拖拽判定位移阈值（点）。~8pt 与系统拖拽启动阈值同量级。
    static let defaultThreshold: CGFloat = 8

    private(set) var phase: Phase = .idle
    private var origin: CGPoint = .zero
    let threshold: CGFloat

    init(threshold: CGFloat = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// 左键按下：记录起点，进入 pressing。（漏抬起的防护：按下总是重置会话。）
    mutating func mouseDown(at point: CGPoint) {
        phase = .pressing
        origin = point
    }

    /// 按住移动采样。返回 `true` 恰好一次 —— 位移首次达到阈值的时刻；
    /// 此后本次拖拽的继续移动恒返回 `false`。
    mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard phase == .pressing else { return false }
        guard hypot(point.x - origin.x, point.y - origin.y) >= threshold else { return false }
        phase = .dragging
        return true
    }

    /// 左键抬起。返回 `true` 表示本次抬起结束了一个已确认的拖拽；
    /// 普通点击（未达阈值）返回 `false`。
    mutating func mouseUp() -> Bool {
        defer { phase = .idle }
        return phase == .dragging
    }

    /// 复位（停止监听时调用，丢弃半会话）。
    mutating func reset() {
        phase = .idle
    }
}

/// UX1/2: 一次拖拽会话中 shelf 自动显隐的裁决（纯逻辑，与 AppKit 解耦）。
///
/// 语义（用户确认）：
/// - 拖拽驱动唤出 shelf 时打 `shownAutomatically` 标记（仅当唤出前 shelf
///   不可见 —— 拖拽前已可见说明是用户手动唤出的，本轮不动它）；
/// - 本轮拖拽中有内容成功落入 shelf（`DropImportCoordinator.onImportHandled`）
///   → `noteImport()` 复位「无落入」假设；
/// - 拖拽结束：`shownAutomatically && !receivedImport` → 调用方自动收回。
struct DragAutoShowSession: Sendable, Equatable {
    /// 本轮是否处于已确认的拖拽会话中（mouseDown 阈值跨越 → mouseUp）。
    private(set) var isDragging = false
    /// 本轮拖拽是否触发了自动唤出（唤出时 shelf 原本不可见）。
    private(set) var shownAutomatically = false
    /// 本轮拖拽中是否已有内容成功入架。
    private(set) var receivedImport = false

    /// 拖拽开始（阈值跨越）：开启新会话，清空上一轮的全部标记。
    mutating func dragBegan() {
        isDragging = true
        shownAutomatically = false
        receivedImport = false
    }

    /// 标记「本次显示为拖拽驱动的自动唤出」。不在拖拽会话中（如快捷键
    /// 唤出、剪贴板保存唤出）时忽略 —— 那些是显式意图，不参与自动收回。
    mutating func markShownAutomatically() {
        guard isDragging else { return }
        shownAutomatically = true
    }

    /// 本轮有内容成功入架（同步导入或已派发异步物化）。
    mutating func noteImport() {
        receivedImport = true
    }

    /// 拖拽结束。返回 `true` = 本轮是自动唤出且没有任何内容落入，调用方
    /// 应动画收回 shelf；返回后会话复位（幂等，重复抬起安全）。
    mutating func dragEnded() -> Bool {
        defer {
            isDragging = false
            shownAutomatically = false
            receivedImport = false
        }
        return isDragging && shownAutomatically && !receivedImport
    }
}

/// UX1: 全局拖拽开始监听（计划外 UX 批次，对齐 Yoink「开始拖拽即出现」）。
///
/// 沙箱合规：`NSEvent.addGlobalMonitorForEvents` 监听
/// `leftMouseDown/leftMouseDragged/leftMouseUp` 无需 Accessibility 权限
/// （只读、不消费事件）。global monitor 覆盖其他应用内的拖拽，local
/// monitor 覆盖从本应用窗口（shelf 卡片拖出等）起始的拖拽。
///
/// 注册生命周期与 `MouseShakeMonitor` 一致：monitor 只存在于 `start` 与
/// `stop` 之间；`start` 幂等。识别核心 `DragGestureTracker` 为纯类型。
///
/// 回调语义：
/// - `onDragStart`：位移阈值首次跨越（忽略列表前台时经 `shouldSuppress` 抑制）；
/// - `onDragEnd`：已确认拖拽的左键抬起（不被抑制 —— 抑制即无会话，
///   配合 `DragAutoShowSession` 空转安全）。
///
/// EdgeTab: `isDragInProgress` 是可观察的「拖拽进行中」状态（阈值确认即置位，
/// 不受 `shouldSuppress` 影响 —— 抑制只挡唤出，不改变「正在拖拽」的事实），
/// 供边缘拉环做投放暗示高亮；抬起或 `stop()` 复位。
@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    /// EdgeTab: 已确认的拖拽会话进行中（阈值跨越 → 抬起）。
    private(set) var isDragInProgress = false

    private var tracker: DragGestureTracker?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Ignore-list gate, evaluated only at the moment a drag is confirmed.
    private let shouldSuppress: @MainActor () -> Bool
    private let onDragStart: @MainActor () -> Void
    private let onDragUpdate: @MainActor (CGPoint) -> Void
    private let onDragEnd: @MainActor () -> Void

    init(shouldSuppress: @escaping @MainActor () -> Bool,
         onDragStart: @escaping @MainActor () -> Void,
         onDragUpdate: @escaping @MainActor (CGPoint) -> Void = { _ in },
         onDragEnd: @escaping @MainActor () -> Void) {
        self.shouldSuppress = shouldSuppress
        self.onDragStart = onDragStart
        self.onDragUpdate = onDragUpdate
        self.onDragEnd = onDragEnd
    }

    /// Registers the monitors. Idempotent: starting while monitoring is a no-op.
    func start() {
        guard !isMonitoring else { return }
        tracker = DragGestureTracker()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            let type = event.type
            Task { @MainActor in
                self.handle(eventType: type, at: location)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            let type = event.type
            Task { @MainActor in
                self.handle(eventType: type, at: location)
            }
            return event
        }
        isMonitoring = true
    }

    /// Removes all event registrations.
    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        tracker = nil
        isMonitoring = false
        isDragInProgress = false
    }

    private func handle(eventType: NSEvent.EventType, at point: CGPoint) {
        guard isMonitoring else { return }
        switch eventType {
        case .leftMouseDown:
            tracker?.mouseDown(at: point)
        case .leftMouseDragged:
            let didBegin = tracker?.mouseDragged(to: point) == true
            guard tracker?.phase == .dragging else { return }
            // EdgeTab: 投放暗示状态与抑制无关 —— 被抑制（忽略列表 / 正在拖动
            // 拉环本身）的拖拽依然是「拖拽进行中」，只是不触发唤出。
            isDragInProgress = true
            // 抑制（忽略列表前台）只影响唤出，不破坏跟踪器状态：抬起时
            // onDragEnd 照常到达，会话裁决（未 dragBegan）空转。
            guard !shouldSuppress() else { return }
            if didBegin { onDragStart() }
            onDragUpdate(point)
        case .leftMouseUp:
            guard tracker?.mouseUp() == true else { return }
            isDragInProgress = false
            onDragEnd()
        default:
            break
        }
    }
}
