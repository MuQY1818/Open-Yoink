import XCTest
@testable import OpenYoink

@MainActor
final class IslandTimerStoreTests: XCTestCase {
    private func suite() throws -> (UserDefaults, String) {
        let name = "IslandTimerTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testPauseResumeUsesRemainingDuration() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 600)
        now = now.addingTimeInterval(125)
        timer.pause()
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        now = now.addingTimeInterval(500)
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        timer.resume()
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        timer.stop()
    }

    func testRunningTimerRestoresAcrossLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 2_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 300)
        first.stop()
        now = now.addingTimeInterval(40)
        let restored = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restored.remaining(), 260, accuracy: 0.001)
        restored.stop()
    }

    func testElapsedTimerRestoresAsFinished() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 3_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 10)
        first.stop()
        now = now.addingTimeInterval(11)
        let restored = IslandTimerStore(defaults: defaults, now: { now })
        guard case .finished = restored.state else {
            return XCTFail("Expected finished timer after elapsed end date")
        }
    }

    func testSystemTimeJumpFinishesWithoutPollingLoop() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 4_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 60)
        timer.stop()
        now = now.addingTimeInterval(120)
        timer.updateForCurrentTime()
        guard case .finished = timer.state else {
            return XCTFail("Expected clock jump to finish timer")
        }
    }

    func testTickRefreshesFormattedTimeAndProgress() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 5_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 60)
        let initialTick = timer.tick

        now = now.addingTimeInterval(1)
        timer.updateForCurrentTime()

        XCTAssertGreaterThan(timer.tick, initialTick)
        XCTAssertEqual(timer.formattedRemaining, "00:59")
        XCTAssertEqual(timer.progress, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(timer.remainingFraction, 59.0 / 60.0, accuracy: 0.000_001)
        timer.stop()
    }

    func testFlowModeAndGoalPersistAcrossLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(first.mode, .focus)
        first.selectMode(.longBreak)
        first.setGoal("Read the architecture notes")

        let restored = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .longBreak)
        XCTAssertEqual(restored.mode.defaultMinutes, 15)
        XCTAssertEqual(restored.goal, "Read the architecture notes")
    }

    func testRunningTimerKeepsItsSelectedMode() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let timer = IslandTimerStore(defaults: defaults)
        timer.selectMode(.shortBreak)
        timer.start(duration: 300)
        timer.selectMode(.focus)

        XCTAssertEqual(timer.mode, .shortBreak)
        timer.stop()
    }

    func testFocusGoalIsUsedForCompactActivity() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let timer = IslandTimerStore(defaults: defaults)
        var publishedActivity: IslandActivity?
        timer.onActivity = { publishedActivity = $0 }
        timer.setGoal("Finish the timer redesign")
        timer.start(duration: 60)

        XCTAssertEqual(publishedActivity?.title, "Finish the timer redesign")
        XCTAssertEqual(publishedActivity?.systemImage, "scope")
        timer.stop()
    }

    func testGoalLengthIsBoundedBeforePersistence() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let timer = IslandTimerStore(defaults: defaults)
        timer.setGoal(String(repeating: "x", count: 120))

        XCTAssertEqual(timer.goal.count, 80)
        let restored = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(restored.goal.count, 80)
    }

    func testCompletedFocusSessionPersistsHistoryAndGoal() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 10_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.setGoal("Write the release notes")
        timer.start(duration: 60)

        now = now.addingTimeInterval(60)
        timer.updateForCurrentTime()

        let session = try XCTUnwrap(timer.sessions.first)
        XCTAssertEqual(timer.sessions.count, 1)
        XCTAssertEqual(session.duration, 60, accuracy: 0.001)
        XCTAssertEqual(session.completedAt, Date(timeIntervalSince1970: 10_060))
        XCTAssertEqual(session.goal, "Write the release notes")

        let restored = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restored.sessions, timer.sessions)
    }

    func testBreakAndResetDoNotCreateFocusHistory() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 20_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })

        timer.selectMode(.shortBreak)
        timer.start(duration: 1)
        now = now.addingTimeInterval(1)
        timer.updateForCurrentTime()
        XCTAssertTrue(timer.sessions.isEmpty)

        timer.acknowledgeFinished()
        timer.selectMode(.focus)
        timer.start(duration: 60)
        timer.reset()
        XCTAssertTrue(timer.sessions.isEmpty)
    }

    func testElapsedRestoreRecordsFocusSessionExactlyOnce() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 30_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 60)
        first.stop()

        now = now.addingTimeInterval(61)
        let restoredOnce = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restoredOnce.sessions.count, 1)
        let restoredAgain = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restoredAgain.sessions.count, 1)
        XCTAssertEqual(restoredAgain.sessions.first?.id,
                       restoredOnce.sessions.first?.id)
    }
}
