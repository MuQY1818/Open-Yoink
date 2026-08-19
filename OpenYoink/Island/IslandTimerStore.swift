import Foundation
import Observation

@MainActor
@Observable
final class IslandTimerStore: IslandModule {
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
    }

    let descriptor = IslandModuleDescriptor(
        id: .timer,
        title: String(localized: "Timer"),
        systemImage: "timer",
        order: 2,
        isCore: false
    )

    private static let persistenceKey = "OpenYoink.islandTimerState"

    private let defaults: UserDefaults
    private let nowProvider: @MainActor () -> Date
    @ObservationIgnored
    nonisolated(unsafe) private var tickerTask: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var tick = 0
    var onActivity: (@MainActor (IslandActivity?) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.defaults = defaults
        self.nowProvider = now
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
        state = .running(endDate: nowProvider().addingTimeInterval(duration),
                         originalDuration: duration)
        persist()
        publishActivity()
        scheduleTickerIfNeeded()
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
                              title: String(localized: "Timer"),
                              detail: formattedRemaining,
                              systemImage: "timer", expiresAt: nil))
        case .finished:
            onActivity?(.init(id: "timer.finished", moduleID: .timer,
                              priority: .timerFinished,
                              title: String(localized: "Timer finished"),
                              detail: nil, systemImage: "timer",
                              expiresAt: nil))
        }
    }

    private func persist() {
        let value: PersistedState?
        switch state {
        case .idle:
            value = nil
        case let .running(endDate, originalDuration):
            value = .init(kind: .running, endDate: endDate, remaining: nil,
                          originalDuration: originalDuration)
        case let .paused(remaining, originalDuration):
            value = .init(kind: .paused, endDate: nil, remaining: remaining,
                          originalDuration: originalDuration)
        case let .finished(originalDuration):
            value = .init(kind: .finished, endDate: nil, remaining: nil,
                          originalDuration: originalDuration)
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
            if let endDate = value.endDate, endDate > nowProvider() {
                state = .running(endDate: endDate, originalDuration: value.originalDuration)
            } else {
                state = .finished(originalDuration: value.originalDuration)
            }
        case .paused:
            state = .paused(remaining: max(0, value.remaining ?? 0),
                            originalDuration: value.originalDuration)
        case .finished:
            state = .finished(originalDuration: value.originalDuration)
        }
        publishActivity()
    }
}
