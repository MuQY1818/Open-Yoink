import Foundation

struct IslandFocusSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var completedAt: Date
    var duration: TimeInterval
    var goal: String?
}

enum IslandFocusPeriod: Int, CaseIterable, Hashable, Sendable {
    case morning
    case afternoon
    case evening

    static func period(for date: Date, calendar: Calendar = .current) -> Self {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }
}

enum IslandFocusStatistics {
    static func sessions(
        _ sessions: [IslandFocusSession],
        on date: Date,
        period: IslandFocusPeriod? = nil,
        calendar: Calendar = .current
    ) -> [IslandFocusSession] {
        sessions.filter { session in
            guard calendar.isDate(session.completedAt, inSameDayAs: date) else {
                return false
            }
            guard let period else { return true }
            return IslandFocusPeriod.period(for: session.completedAt,
                                            calendar: calendar) == period
        }
    }

    static func duration(
        _ sessions: [IslandFocusSession],
        on date: Date,
        period: IslandFocusPeriod? = nil,
        calendar: Calendar = .current
    ) -> TimeInterval {
        self.sessions(sessions, on: date, period: period, calendar: calendar)
            .reduce(0) { $0 + $1.duration }
    }

    static func currentStreak(
        _ sessions: [IslandFocusSession],
        at date: Date,
        calendar: Calendar = .current
    ) -> Int {
        var cursor = calendar.startOfDay(for: date)
        if duration(sessions, on: cursor, calendar: calendar) == 0,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }

        var streak = 0
        while duration(sessions, on: cursor, calendar: calendar) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1,
                                                to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
