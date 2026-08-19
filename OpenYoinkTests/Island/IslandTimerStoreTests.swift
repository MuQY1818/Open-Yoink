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
}
