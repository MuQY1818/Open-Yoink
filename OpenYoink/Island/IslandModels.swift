import Foundation
import Observation
@_exported import OpenYoinkModuleCore

extension IslandModuleID {
    static let shelf = Self(rawValue: "shelf")
    static let transfers = Self(rawValue: "transfers")
    static let timer = Self(rawValue: "timer")
    static let battery = Self(rawValue: "battery")
    static let media = Self(rawValue: "media")
    static let system = Self(rawValue: "system")
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

/// Shared timing keeps the SwiftUI silhouette transition and the AppKit panel
/// resize in one rhythm. On collapse the visible surface finishes tucking into
/// the notch before the now-transparent window footprint is reduced.
enum IslandMotion {
    /// Match the Web demo's continuous notch morph: the AppKit canvas and the
    /// SwiftUI reveal share a single, velocity-preserving visual rhythm.
    static let expandContentDuration: TimeInterval = 0.38
    static let expandWindowDuration: TimeInterval = 0.38
    /// Exit remains a little quicker, but still visibly morphs back into the
    /// compact surface rather than disappearing before the window shrinks.
    static let collapseContentDuration: TimeInterval = 0.28
    static let collapseWindowDuration: TimeInterval = 0.30
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
        .init(id: .system, title: String(localized: "System Status"),
              systemImage: "gauge.with.dots.needle.67percent", order: 4, isCore: false),
        .init(id: .media, title: String(localized: "Now Playing"),
              systemImage: "music.note", order: 5, isCore: false),
    ]

    private(set) var enabledIDs: Set<IslandModuleID> = [.shelf, .transfers]

    func apply(settings: SettingsStore) {
        enabledIDs = Set(settings.islandModuleConfiguration.enabledModuleIDs)
    }

    var enabledDescriptors: [IslandModuleDescriptor] {
        descriptors
            .filter { enabledIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    func isEnabled(_ id: IslandModuleID) -> Bool {
        enabledIDs.contains(id)
    }

    func descriptor(for id: IslandModuleID) -> IslandModuleDescriptor? {
        descriptors.first { $0.id == id }
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
    /// A deliberate collapse must win over hover reveal until the pointer has
    /// actually left the compact surface. Without this latch, the mouse-move
    /// monitor immediately schedules another expansion while the click is
    /// still resting on the notch, which can look like the click selected the
    /// current activity's module instead of collapsing.
    private(set) var isHoverRevealSuppressed = false
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

    var onSurfaceStateWillChange: (@MainActor (
        IslandSurfaceState,
        IslandSurfaceState
    ) -> Void)?
    var onStateDidChange: (@MainActor () -> Void)?

    func setSurfaceState(_ state: IslandSurfaceState) {
        guard surfaceState != state else { return }
        let previousState = surfaceState
        onSurfaceStateWillChange?(previousState, state)
        surfaceState = state
        if state.isExpanded {
            isPointerHovering = false
            isHoverRevealSuppressed = false
        }
        onStateDidChange?()
    }

    func setPointerHovering(_ hovering: Bool) {
        // Clear the deliberate-collapse latch on exit even if the visual
        // hover value was already false. The next genuine pointer entry may
        // then reveal the Island normally.
        if !hovering { isHoverRevealSuppressed = false }
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
    }

    var canRevealOnHover: Bool {
        !isHoverRevealSuppressed
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

    func collapse(suppressHoverUntilPointerExit: Bool = true) {
        isHoverRevealSuppressed = suppressHoverUntilPointerExit
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
