import AppKit

/// Pure dwell tracker for the edge trigger, decoupled from AppKit for unit
/// testing.
///
/// The cursor must stay inside the edge band continuously for `dwellTime`.
/// The tracker fires at most once per band entry: leaving the band (or
/// `reset()`) is the only way to re-arm it, so a cursor resting on the edge
/// can never retrigger in a loop.
struct EdgeDwellTracker: Sendable, Equatable {
    /// Continuous dwell time (seconds) required before firing.
    let dwellTime: TimeInterval

    private var entryTime: TimeInterval?
    private var hasFired = false

    init(dwellTime: TimeInterval) {
        self.dwellTime = dwellTime
    }

    /// Feeds one sample. Returns `true` exactly once per band entry, at the
    /// moment the dwell threshold is reached.
    mutating func addSample(isInside: Bool, at time: TimeInterval) -> Bool {
        guard isInside else {
            entryTime = nil
            hasFired = false
            return false
        }
        guard !hasFired else { return false }
        guard let entry = entryTime else {
            entryTime = time
            return false
        }
        guard time - entry >= dwellTime else { return false }
        hasFired = true
        return true
    }

    /// Re-arms the tracker (same effect as the cursor leaving the band).
    mutating func reset() {
        entryTime = nil
        hasFired = false
    }
}

/// Screen-edge dwell trigger (S7): resting the cursor on the edge the shelf
/// attaches to for longer than the sensitivity-dependent dwell time shows
/// the shelf.
///
/// The screen under the cursor is resolved with
/// `ShelfWindowController.screen(containing:)` — the same rule the shelf
/// layout uses — so the trigger edge always matches the edge the panel will
/// appear on.
///
/// Registration lifecycle mirrors `MouseShakeMonitor`: monitors exist only
/// between `start` and `stop`.
@MainActor
final class EdgeTriggerMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    private var tracker: EdgeDwellTracker?
    private var side: SettingsStore.ShelfPosition = .right
    private var bandWidth: CGFloat = 4
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Suppression gate (shelf already visible, frontmost app ignored),
    /// evaluated only when the dwell completes.
    private let shouldSuppress: @MainActor () -> Bool
    private let onTrigger: @MainActor () -> Void

    init(shouldSuppress: @escaping @MainActor () -> Bool,
         onTrigger: @escaping @MainActor () -> Void) {
        self.shouldSuppress = shouldSuppress
        self.onTrigger = onTrigger
    }

    /// (Re)starts monitoring. Idempotent for unchanged configuration.
    func start(side: SettingsStore.ShelfPosition, dwellTime: TimeInterval, bandWidth: CGFloat) {
        let unchanged = isMonitoring
            && self.side == side
            && tracker?.dwellTime == dwellTime
            && self.bandWidth == bandWidth
        guard !unchanged else { return }
        stop()

        self.side = side
        self.bandWidth = bandWidth
        tracker = EdgeDwellTracker(dwellTime: dwellTime)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            let timestamp = event.timestamp
            Task { @MainActor in
                self.handleMouseMoved(to: location, at: timestamp)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            let timestamp = event.timestamp
            Task { @MainActor in
                self.handleMouseMoved(to: location, at: timestamp)
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
    }

    private func handleMouseMoved(to point: CGPoint, at timestamp: TimeInterval) {
        guard isMonitoring else { return }
        let screen = ShelfWindowController.screen(containing: point)
        let inside = Self.isInsideEdgeBand(point,
                                           screenFrame: screen.frame,
                                           side: side,
                                           bandWidth: bandWidth)
        guard tracker?.addSample(isInside: inside, at: timestamp) == true else { return }
        // A suppressed completion (shelf already visible, or the frontmost app
        // is on the ignore list) still counts as fired: the tracker stays
        // latched until the cursor leaves and re-enters the band, which keeps
        // a resting cursor from re-showing a shelf the user just dismissed.
        guard !shouldSuppress() else { return }
        onTrigger()
    }

    /// Pure band test: full-height strip of `bandWidth` points along the
    /// given side of `screenFrame`. Points outside the screen never count.
    /// Coordinates live in the global screen space of `NSEvent.mouseLocation`.
    /// S9: `.custom` 无贴附缘，永不命中（AppDelegate 在 custom 模式下也不
    /// 启动本监听；此分支仅保证纯函数对全枚举有定义）。
    nonisolated static func isInsideEdgeBand(_ point: CGPoint,
                                             screenFrame: CGRect,
                                             side: SettingsStore.ShelfPosition,
                                             bandWidth: CGFloat) -> Bool {
        guard screenFrame.contains(point) else { return false }
        switch side {
        case .right:
            return point.x >= screenFrame.maxX - bandWidth
        case .left:
            return point.x <= screenFrame.minX + bandWidth
        case .custom:
            return false
        }
    }
}
