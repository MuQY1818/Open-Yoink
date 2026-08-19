import Foundation
import Observation

enum IslandModuleID: String, CaseIterable, Codable, Sendable {
    case shelf
    case transfers
    case timer
    case battery
    case media
}

struct IslandModuleDescriptor: Identifiable, Equatable, Sendable {
    let id: IslandModuleID
    let title: String
    let systemImage: String
    let order: Int
    let isCore: Bool
}

enum IslandActivityPriority: Int, Comparable, Codable, Sendable {
    case shelfSummary = 10
    case selectedModule = 20
    case powerChange = 30
    case criticalBattery = 40
    case timerFinished = 50
    case transfer = 60
    case userDrag = 70

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct IslandActivity: Identifiable, Equatable, Sendable {
    let id: String
    let moduleID: IslandModuleID
    let priority: IslandActivityPriority
    let title: String
    let detail: String?
    let systemImage: String
    let expiresAt: Date?

    func isActive(at date: Date) -> Bool {
        expiresAt.map { $0 > date } ?? true
    }
}

enum IslandSurfaceState: Equatable, Sendable {
    case hidden
    case compact
    case expanded
    case pinned

    var isExpanded: Bool {
        self == .expanded || self == .pinned
    }
}

/// Internal-only module contract. v1.4.x deliberately does not load external
/// bundles; the protocol keeps first-party lifecycles consistent and gives a
/// future SDK a stable conceptual boundary.
@MainActor
protocol IslandModule: AnyObject {
    var descriptor: IslandModuleDescriptor { get }
    func start()
    func stop()
}

@MainActor
@Observable
final class IslandModuleRegistry {
    private(set) var descriptors: [IslandModuleDescriptor] = [
        .init(id: .shelf, title: String(localized: "Shelf"),
              systemImage: "tray.full", order: 0, isCore: true),
        .init(id: .transfers, title: String(localized: "Transfers"),
              systemImage: "arrow.up.arrow.down", order: 1, isCore: true),
        .init(id: .timer, title: String(localized: "Timer"),
              systemImage: "timer", order: 2, isCore: false),
        .init(id: .battery, title: String(localized: "Battery"),
              systemImage: "battery.75percent", order: 3, isCore: false),
        .init(id: .media, title: String(localized: "Now Playing"),
              systemImage: "play.circle", order: 4, isCore: false),
    ]

    private(set) var enabledIDs: Set<IslandModuleID> = [.shelf, .transfers]

    func apply(settings: SettingsStore) {
        var enabled: Set<IslandModuleID> = [.shelf, .transfers]
        if settings.islandTimerEnabled { enabled.insert(.timer) }
        if settings.islandBatteryEnabled { enabled.insert(.battery) }
        if settings.islandMediaEnabled { enabled.insert(.media) }
        enabledIDs = enabled
    }

    var enabledDescriptors: [IslandModuleDescriptor] {
        descriptors
            .filter { enabledIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    func isEnabled(_ id: IslandModuleID) -> Bool {
        enabledIDs.contains(id)
    }
}

@MainActor
@Observable
final class IslandActivityCoordinator {
    private(set) var surfaceState: IslandSurfaceState = .compact
    var currentLayout: IslandGeometryResolver.Layout?
    /// Visual-only hover state. It intentionally does not call
    /// `onStateDidChange`, because pointer movement must never resize the panel.
    var isPointerHovering = false
    var selectedModule: IslandModuleID = .shelf {
        didSet {
            guard oldValue != selectedModule else { return }
            onStateDidChange?()
        }
    }
    private(set) var activities: [String: IslandActivity] = [:]
    private var stateBeforeDrag: IslandSurfaceState?
    private var moduleBeforeDrag: IslandModuleID?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    var onStateDidChange: (@MainActor () -> Void)?

    func setSurfaceState(_ state: IslandSurfaceState) {
        guard surfaceState != state else { return }
        surfaceState = state
        if state.isExpanded { isPointerHovering = false }
        onStateDidChange?()
    }

    func setPointerHovering(_ hovering: Bool) {
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
    }

    func show(module: IslandModuleID = .shelf, pinned: Bool = false) {
        selectedModule = module
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func toggle() {
        if surfaceState.isExpanded {
            collapse()
        } else {
            show(module: selectedModule)
        }
    }

    func collapse() {
        setSurfaceState(.compact)
    }

    func setPinned(_ pinned: Bool) {
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func hide() {
        setSurfaceState(.hidden)
    }

    func publish(_ activity: IslandActivity?) {
        guard let activity else { return }
        activities[activity.id] = activity
        scheduleExpiry()
        onStateDidChange?()
    }

    func removeActivity(id: String) {
        guard activities.removeValue(forKey: id) != nil else { return }
        scheduleExpiry()
        onStateDidChange?()
    }

    func removeActivities(for moduleID: IslandModuleID) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.moduleID != moduleID }
        if activities.count != previousCount {
            scheduleExpiry()
            onStateDidChange?()
        }
    }

    func primaryActivity(at date: Date = Date()) -> IslandActivity? {
        activities.values
            .filter { $0.isActive(at: date) }
            .filter { activity in
                activity.priority != .selectedModule
                    || activity.moduleID == selectedModule
            }
            .max { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id < rhs.id
            }
    }

    func pruneExpired(at date: Date = Date()) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.isActive(at: date) }
        scheduleExpiry()
        if activities.count != previousCount { onStateDidChange?() }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let nextExpiry = activities.values.compactMap(\.expiresAt).min() else {
            expiryTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
        }
    }

    func beginDrag() {
        if stateBeforeDrag == nil {
            stateBeforeDrag = surfaceState
            moduleBeforeDrag = selectedModule
        }
        selectedModule = .shelf
        publish(.init(id: "drag", moduleID: .shelf, priority: .userDrag,
                      title: String(localized: "Drop into OpenYoink"), detail: nil,
                      systemImage: "arrow.down.to.line", expiresAt: nil))
        setSurfaceState(.expanded)
    }

    func endDrag(imported: Bool) {
        removeActivity(id: "drag")
        defer {
            stateBeforeDrag = nil
            moduleBeforeDrag = nil
        }
        guard !imported else {
            setSurfaceState(.expanded)
            return
        }
        if let moduleBeforeDrag { selectedModule = moduleBeforeDrag }
        setSurfaceState(stateBeforeDrag ?? .compact)
    }
}
