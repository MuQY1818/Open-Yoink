import Foundation
import Observation

@MainActor
@Observable
final class IslandTimerStore: IslandModule {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case focus
        case shortBreak
        case longBreak

        var defaultMinutes: Int {
            switch self {
            case .focus: 25
            case .shortBreak: 5
            case .longBreak: 15
            }
        }

        var title: String {
            switch self {
            case .focus: String(localized: "Focus")
            case .shortBreak: String(localized: "Short break")
            case .longBreak: String(localized: "Long break")
            }
        }

        var systemImage: String {
            switch self {
            case .focus: "scope"
            case .shortBreak: "cup.and.saucer.fill"
            case .longBreak: "leaf.fill"
            }
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case running(endDate: Date, originalDuration: TimeInterval)
        case paused(remaining: TimeInterval, originalDuration: TimeInterval)
        case finished(originalDuration: TimeInterval)
    }

    private struct PersistedState: Codable {
        enum Kind: String, Codable { case running, paused, finished }
        var kind: Kind
        var endDate: Date?
        var remaining: TimeInterval?
        var originalDuration: TimeInterval
        var sessionID: UUID?
    }

    private struct PersistedConfiguration: Codable {
        var mode: Mode
        var goal: String
    }

    let descriptor = IslandModuleDescriptor(
        id: .timer,
        title: String(localized: "Timer"),
        systemImage: "timer",
        order: 2,
        isCore: false
    )

    private static let persistenceKey = "OpenYoink.islandTimerState"
    private static let configurationKey = "OpenYoink.islandTimerConfiguration"
    private static let historyKey = "OpenYoink.islandFocusHistory"
    private static let maximumHistoryCount = 2_000

    private let defaults: UserDefaults
    private let nowProvider: @MainActor () -> Date
    @ObservationIgnored
    nonisolated(unsafe) private var tickerTask: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var tick = 0
    private(set) var mode: Mode = .focus
    private(set) var goal = ""
    private(set) var sessions: [IslandFocusSession] = []
    private var activeSessionID: UUID?
    var onActivity: (@MainActor (IslandActivity?) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.defaults = defaults
        self.nowProvider = now
        restoreConfiguration()
        restoreHistory()
        restore()
    }

    deinit {
        tickerTask?.cancel()
    }

    func start() {
        updateForCurrentTime()
        publishActivity()
        scheduleTickerIfNeeded()
    }

    func stop() {
        tickerTask?.cancel()
        tickerTask = nil
        onActivity?(nil)
    }

    func start(minutes: Double) {
        start(duration: max(1, minutes * 60))
    }

    func start(duration: TimeInterval) {
        let duration = max(1, duration)
        activeSessionID = UUID()
        state = .running(endDate: nowProvider().addingTimeInterval(duration),
                         originalDuration: duration)
        persist()
        publishActivity()
        scheduleTickerIfNeeded()
        onStateChange?()
    }

    func selectMode(_ mode: Mode) {
        guard state == .idle, self.mode != mode else { return }
        self.mode = mode
        persistConfiguration()
        publishActivity()
        onStateChange?()
    }

    func setGoal(_ goal: String) {
        let sanitized = String(goal.prefix(80))
        guard self.goal != sanitized else { return }
        self.goal = sanitized
        persistConfiguration()
        publishActivity()
        onStateChange?()
    }

    func pause() {
        guard case let .running(endDate, originalDuration) = state else { return }
        state = .paused(remaining: max(0, endDate.timeIntervalSince(nowProvider())),
                        originalDuration: originalDuration)
        stop()
        persist()
        publishActivity()
        onStateChange?()
    }

    func resume() {
        guard case let .paused(remaining, originalDuration) = state else { return }
        state = .running(endDate: nowProvider().addingTimeInterval(max(1, remaining)),
                         originalDuration: originalDuration)
        persist()
        publishActivity()
        scheduleTickerIfNeeded()
        onStateChange?()
    }

    func reset() {
        stop()
        state = .idle
        activeSessionID = nil
        defaults.removeObject(forKey: Self.persistenceKey)
        onActivity?(nil)
        onStateChange?()
    }

    func acknowledgeFinished() {
        guard case .finished = state else { return }
        reset()
    }

    func remaining(at date: Date? = nil) -> TimeInterval {
        let date = date ?? nowProvider()
        switch state {
        case .idle, .finished:
            return 0
        case let .running(endDate, _):
            // `endDate` itself stays constant while a timer is running. Read
            // the observable tick so SwiftUI invalidates countdown text and
            // progress every time the low-frequency ticker advances.
            _ = tick
            return max(0, endDate.timeIntervalSince(date))
        case let .paused(remaining, _):
            return max(0, remaining)
        }
    }

    var progress: Double {
        let original: TimeInterval
        switch state {
        case let .running(_, duration), let .paused(_, duration), let .finished(duration):
            original = duration
        case .idle:
            return 0
        }
        guard original > 0 else { return 0 }
        return min(1, max(0, 1 - remaining() / original))
    }

    /// Fraction of the selected duration still remaining. The Island timer
    /// visual uses a shrinking ring, which maps more directly to a countdown
    /// than the elapsed-progress value above.
    var remainingFraction: Double {
        1 - progress
    }

    var formattedRemaining: String {
        let total = Int(remaining().rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func updateForCurrentTime() {
        guard case let .running(endDate, originalDuration) = state else { return }
        guard endDate <= nowProvider() else {
            tick &+= 1
            publishActivity()
            return
        }
        completeTimer(at: endDate, originalDuration: originalDuration)
    }

    private func completeTimer(at completionDate: Date,
                               originalDuration: TimeInterval) {
        let sessionID = activeSessionID ?? UUID()
        activeSessionID = sessionID
        recordFocusSession(id: sessionID,
                           completedAt: completionDate,
                           duration: originalDuration)
        state = .finished(originalDuration: originalDuration)
        stop()
        persist()
        publishActivity()
        onStateChange?()
    }

    private func scheduleTickerIfNeeded() {
        tickerTask?.cancel()
        guard case .running = state else {
            tickerTask = nil
            return
        }
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.updateForCurrentTime()
                guard case .running = self.state else { return }
            }
        }
    }

    private func publishActivity() {
        switch state {
        case .idle:
            onActivity?(nil)
        case .running, .paused:
            onActivity?(.init(id: "timer.running", moduleID: .timer,
                              priority: .selectedModule,
                              title: activityTitle,
                              detail: formattedRemaining,
                              systemImage: mode.systemImage, expiresAt: nil))
        case .finished:
            onActivity?(.init(id: "timer.finished", moduleID: .timer,
                              priority: .timerFinished,
                              title: String(localized: "Timer finished"),
                              detail: nil, systemImage: "timer",
                              expiresAt: nil))
        }
    }

    private var activityTitle: String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .focus, !trimmedGoal.isEmpty { return trimmedGoal }
        return mode.title
    }

    private func persistConfiguration() {
        let value = PersistedConfiguration(mode: mode, goal: goal)
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }

    private func recordFocusSession(id: UUID,
                                    completedAt: Date,
                                    duration: TimeInterval) {
        guard mode == .focus,
              !sessions.contains(where: { $0.id == id }) else { return }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions.append(.init(id: id,
                              completedAt: completedAt,
                              duration: duration,
                              goal: trimmedGoal.isEmpty ? nil : trimmedGoal))
        sessions.sort { $0.completedAt < $1.completedAt }
        if sessions.count > Self.maximumHistoryCount {
            sessions.removeFirst(sessions.count - Self.maximumHistoryCount)
        }
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    private func restoreHistory() {
        guard let data = defaults.data(forKey: Self.historyKey),
              let restored = try? JSONDecoder().decode([IslandFocusSession].self,
                                                       from: data) else { return }
        sessions = Array(restored.sorted { $0.completedAt < $1.completedAt }
            .suffix(Self.maximumHistoryCount))
    }

    private func restoreConfiguration() {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let value = try? JSONDecoder().decode(PersistedConfiguration.self,
                                                     from: data) else { return }
        mode = value.mode
        goal = String(value.goal.prefix(80))
    }

    private func persist() {
        let value: PersistedState?
        switch state {
        case .idle:
            value = nil
        case let .running(endDate, originalDuration):
            value = .init(kind: .running, endDate: endDate, remaining: nil,
                          originalDuration: originalDuration,
                          sessionID: activeSessionID)
        case let .paused(remaining, originalDuration):
            value = .init(kind: .paused, endDate: nil, remaining: remaining,
                          originalDuration: originalDuration,
                          sessionID: activeSessionID)
        case let .finished(originalDuration):
            value = .init(kind: .finished, endDate: nil, remaining: nil,
                          originalDuration: originalDuration,
                          sessionID: activeSessionID)
        }
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: Self.persistenceKey)
            return
        }
        defaults.set(data, forKey: Self.persistenceKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let value = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            state = .idle
            return
        }
        switch value.kind {
        case .running:
            activeSessionID = value.sessionID ?? UUID()
            if let endDate = value.endDate, endDate > nowProvider() {
                state = .running(endDate: endDate, originalDuration: value.originalDuration)
            } else {
                completeTimer(at: value.endDate ?? nowProvider(),
                              originalDuration: value.originalDuration)
                return
            }
        case .paused:
            activeSessionID = value.sessionID ?? UUID()
            state = .paused(remaining: max(0, value.remaining ?? 0),
                            originalDuration: value.originalDuration)
        case .finished:
            activeSessionID = value.sessionID
            state = .finished(originalDuration: value.originalDuration)
        }
        publishActivity()
    }
}
