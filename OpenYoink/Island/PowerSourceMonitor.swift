import Foundation
import IOKit.ps
import Observation

@MainActor
@Observable
final class PowerSourceMonitor: IslandModule {
    struct Snapshot: Equatable, Sendable {
        var hasBattery: Bool
        var percentage: Int
        var isCharging: Bool
        var isConnectedToPower: Bool

        static let unavailable = Snapshot(hasBattery: false,
                                          percentage: 0,
                                          isCharging: false,
                                          isConnectedToPower: false)
    }

    let descriptor = IslandModuleDescriptor(
        id: .battery,
        title: String(localized: "Battery"),
        systemImage: "battery.75percent",
        order: 3,
        isCore: false
    )

    @ObservationIgnored
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var lastAlertBand: Int?
    private let nowProvider: @MainActor () -> Date
    private let fullChargeAlertEnabled: @MainActor () -> Bool
    private(set) var snapshot: Snapshot = .unavailable
    private(set) var isRunning = false
    var onActivity: (@MainActor (IslandActivity?) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    init(now: @escaping @MainActor () -> Date = Date.init,
         fullChargeAlertEnabled: @escaping @MainActor () -> Bool = { false }) {
        self.nowProvider = now
        self.fullChargeAlertEnabled = fullChargeAlertEnabled
    }

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        // Desktops and external-only displays have no battery transitions to
        // observe. Keep the unavailable snapshot visible without retaining an
        // otherwise idle run-loop source.
        guard snapshot.hasBattery else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
            }
        }, context) else { return }
        let source = unmanaged.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
        onActivity?(nil)
    }

    func refresh() {
        process(Self.readSnapshot())
    }

    /// Internal deterministic seam for pure unit tests and future power-event
    /// adapters. Production still enters only through the IOKit notification.
    func process(_ current: Snapshot) {
        let previous = snapshot
        snapshot = current
        evaluateActivity(previous: previous, current: current)
        onStateChange?()
    }

    static func snapshot(from description: [String: Any]?) -> Snapshot {
        guard let description else { return .unavailable }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 0
        guard maximum > 0 else { return .unavailable }
        let percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        let state = description[kIOPSPowerSourceStateKey] as? String
        let onAC = state == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        return Snapshot(hasBattery: true,
                        percentage: percentage,
                        isCharging: charging,
                        isConnectedToPower: onAC)
    }

    private static func readSnapshot() -> Snapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            return snapshot(from: description)
        }
        return .unavailable
    }

    private func evaluateActivity(previous: Snapshot, current: Snapshot) {
        guard current.hasBattery else {
            lastAlertBand = nil
            onActivity?(nil)
            return
        }

        let alertBand: Int? = if current.percentage <= 10 {
            10
        } else if current.percentage <= 20 {
            20
        } else {
            nil
        }
        if alertBand != lastAlertBand, let alertBand {
            lastAlertBand = alertBand
            onActivity?(.init(
                id: "battery.low",
                moduleID: .battery,
                priority: .criticalBattery,
                title: alertBand == 10
                    ? String(localized: "Battery critically low")
                    : String(localized: "Battery low"),
                detail: "\(current.percentage)%",
                systemImage: "battery.25percent",
                expiresAt: nil
            ))
            return
        } else if alertBand == nil, lastAlertBand != nil {
            lastAlertBand = nil
            onActivity?(nil)
        }

        guard previous.hasBattery else { return }
        if previous.isConnectedToPower != current.isConnectedToPower {
            onActivity?(.init(
                id: "battery.power-change",
                moduleID: .battery,
                priority: .powerChange,
                title: current.isConnectedToPower
                    ? String(localized: "Power connected")
                    : String(localized: "Running on battery"),
                detail: "\(current.percentage)%",
                systemImage: current.isConnectedToPower ? "bolt.fill" : "battery.75percent",
                expiresAt: nowProvider().addingTimeInterval(2.5)
            ))
        } else if fullChargeAlertEnabled(),
                  previous.percentage < 100,
                  current.percentage == 100 {
            onActivity?(.init(id: "battery.full", moduleID: .battery,
                              priority: .powerChange,
                              title: String(localized: "Battery fully charged"),
                              detail: nil, systemImage: "battery.100percent",
                              expiresAt: nowProvider().addingTimeInterval(2.5)))
        }
    }
}
