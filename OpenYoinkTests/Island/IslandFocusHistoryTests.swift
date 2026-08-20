import XCTest
@testable import OpenYoink

final class IslandFocusHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: day,
            hour: hour
        ))!
    }

    func testTimeOfDayPeriodsMatchFlowBuckets() {
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 4),
                                                calendar: calendar), .evening)
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 5),
                                                calendar: calendar), .morning)
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 11),
                                                calendar: calendar), .morning)
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 12),
                                                calendar: calendar), .afternoon)
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 17),
                                                calendar: calendar), .afternoon)
        XCTAssertEqual(IslandFocusPeriod.period(for: date(day: 20, hour: 18),
                                                calendar: calendar), .evening)
    }

    func testDurationAggregatesByDayAndPeriod() {
        let sessions = [
            IslandFocusSession(id: UUID(), completedAt: date(day: 20, hour: 8),
                               duration: 1_500, goal: nil),
            IslandFocusSession(id: UUID(), completedAt: date(day: 20, hour: 10),
                               duration: 900, goal: nil),
            IslandFocusSession(id: UUID(), completedAt: date(day: 20, hour: 14),
                               duration: 1_200, goal: nil),
            IslandFocusSession(id: UUID(), completedAt: date(day: 19, hour: 8),
                               duration: 7_200, goal: nil)
        ]

        XCTAssertEqual(IslandFocusStatistics.duration(
            sessions,
            on: date(day: 20, hour: 0),
            calendar: calendar
        ), 3_600, accuracy: 0.001)
        XCTAssertEqual(IslandFocusStatistics.duration(
            sessions,
            on: date(day: 20, hour: 0),
            period: .morning,
            calendar: calendar
        ), 2_400, accuracy: 0.001)
    }

    func testStreakIncludesYesterdayWhenTodayHasNoSession() {
        var sessions = [
            IslandFocusSession(id: UUID(), completedAt: date(day: 18, hour: 9),
                               duration: 1_500, goal: nil),
            IslandFocusSession(id: UUID(), completedAt: date(day: 19, hour: 9),
                               duration: 1_500, goal: nil),
            IslandFocusSession(id: UUID(), completedAt: date(day: 16, hour: 9),
                               duration: 1_500, goal: nil)
        ]

        XCTAssertEqual(IslandFocusStatistics.currentStreak(
            sessions,
            at: date(day: 20, hour: 12),
            calendar: calendar
        ), 2)

        sessions.append(IslandFocusSession(
            id: UUID(), completedAt: date(day: 20, hour: 10),
            duration: 1_500, goal: nil
        ))
        XCTAssertEqual(IslandFocusStatistics.currentStreak(
            sessions,
            at: date(day: 20, hour: 12),
            calendar: calendar
        ), 3)
    }
}
