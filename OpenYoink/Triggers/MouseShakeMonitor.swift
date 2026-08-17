import AppKit

/// Pure mouse-shake heuristic, decoupled from AppKit for unit testing
/// (plan §6 「全局摇动误触」 countermeasure).
///
/// A shake is a rapid horizontal back-and-forth: `requiredReversals` direction
/// reversals within `window` seconds, where the cursor must travel at least
/// `minSegmentDistance` in the new direction before a reversal counts.
///
/// - Straight lines never reverse → no hit.
/// - Slow wobbles fall out of the time window → no hit.
/// - Sub-threshold jitter never confirms a segment → no hit.
///
/// Only the x axis is considered: the shelf lives on a vertical screen edge,
/// so the gesture to reveal it is horizontal. Diagonal shakes still register
/// through their x component.
struct ShakeDetector: Sendable {
    /// Tunables of the heuristic; three presets come from
    /// `TriggerSensitivity.shakeParameters`.
    struct Parameters: Sendable, Equatable {
        /// Time window in which the reversals must occur, in seconds.
        var window: TimeInterval
        /// Direction reversals required within `window`.
        var requiredReversals: Int
        /// Minimum travel (pt) in one direction for a segment to count.
        var minSegmentDistance: CGFloat
    }

    private let parameters: Parameters

    private var lastPoint: CGPoint?
    /// Confirmed travel direction on the x axis (-1/+1; 0 = not yet confirmed).
    private var direction = 0
    /// Distance accumulated against the confirmed direction; a reversal is
    /// counted once this reaches `minSegmentDistance`.
    private var opposingDistance: CGFloat = 0
    /// Accumulators used before the first direction is confirmed.
    private var pendingSign = 0
    private var pendingDistance: CGFloat = 0
    /// Timestamps of counted reversals, pruned to the window.
    private var reversalTimes: [TimeInterval] = []

    init(parameters: Parameters) {
        self.parameters = parameters
    }

    /// Clears all gesture state (also called internally after a hit).
    mutating func reset() {
        lastPoint = nil
        direction = 0
        opposingDistance = 0
        pendingSign = 0
        pendingDistance = 0
        reversalTimes.removeAll()
    }

    /// Feeds one cursor sample. Returns `true` exactly once when the
    /// trajectory completes a shake; the detector then resets itself and the
    /// next gesture starts from scratch.
    mutating func addSample(_ point: CGPoint, at time: TimeInterval) -> Bool {
        defer { lastPoint = point }
        guard let last = lastPoint else { return false }
        let dx = point.x - last.x
        guard dx != 0 else { return false }
        let sign = dx > 0 ? 1 : -1
        let magnitude = abs(dx)

        if direction == 0 {
            // No confirmed direction yet: accumulate in one sign until the
            // segment threshold confirms it; a flip restarts the accumulator
            // so sub-threshold jitter can never build up.
            if sign == pendingSign {
                pendingDistance += magnitude
            } else {
                pendingSign = sign
                pendingDistance = magnitude
            }
            if pendingDistance >= parameters.minSegmentDistance {
                direction = pendingSign
                opposingDistance = 0
            }
            return false
        }

        if sign == direction {
            // Continuing in the confirmed direction cancels any half-formed
            // opposing segment.
            opposingDistance = 0
            return false
        }

        opposingDistance += magnitude
        guard opposingDistance >= parameters.minSegmentDistance else { return false }

        // Confirmed reversal: the cursor travelled a full segment against the
        // previous direction.
        direction = -direction
        opposingDistance = 0
        reversalTimes.append(time)
        let cutoff = time - parameters.window
        reversalTimes.removeAll { $0 < cutoff }

        guard reversalTimes.count >= parameters.requiredReversals else { return false }
        reset()
        return true
    }
}

/// Global mouse-shake trigger (S7). Registers `mouseMoved` monitors only
/// while started; `stop()` removes them so a disabled trigger leaves no
/// event registration behind (plan §2.3).
///
/// Two monitors feed the same detector: the global monitor sees cursor
/// movement in other apps, the local monitor covers movement over our own
/// windows (the global one skips those). Both handlers are non-isolated;
/// they extract `Sendable` primitives (position + timestamp) and hop to the
/// MainActor, mirroring the established pattern in `AppDelegate`.
@MainActor
final class MouseShakeMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    private var detector: ShakeDetector?
    private var activeParameters: ShakeDetector.Parameters?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Ignore-list gate, evaluated only at the moment the heuristic fires.
    private let shouldSuppress: @MainActor () -> Bool
    private let onTrigger: @MainActor () -> Void

    init(shouldSuppress: @escaping @MainActor () -> Bool,
         onTrigger: @escaping @MainActor () -> Void) {
        self.shouldSuppress = shouldSuppress
        self.onTrigger = onTrigger
    }

    /// (Re)starts monitoring with the given parameters. Idempotent: calling
    /// `start` again with unchanged parameters keeps the current monitors.
    func start(parameters: ShakeDetector.Parameters) {
        guard !isMonitoring || activeParameters != parameters else { return }
        stop()
        detector = ShakeDetector(parameters: parameters)
        activeParameters = parameters

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
        detector = nil
        activeParameters = nil
        isMonitoring = false
    }

    private func handleMouseMoved(to point: CGPoint, at timestamp: TimeInterval) {
        guard isMonitoring, detector?.addSample(point, at: timestamp) == true else { return }
        // The detector has reset itself on the hit, so a suppressed trigger
        // leaves no half-finished gesture behind.
        guard !shouldSuppress() else { return }
        onTrigger()
    }
}
