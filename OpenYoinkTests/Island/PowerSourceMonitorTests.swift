import IOKit.ps
import XCTest
@testable import OpenYoink

@MainActor
final class PowerSourceMonitorTests: XCTestCase {
    func testSnapshotParsesCapacityAndPowerState() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 45,
            kIOPSMaxCapacityKey: 90,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
        ])
        XCTAssertEqual(snapshot.percentage, 50)
        XCTAssertTrue(snapshot.hasBattery)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isConnectedToPower)
    }

    func testMissingMaximumIsUnavailable() {
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: [:]), .unavailable)
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: nil), .unavailable)
    }

    func testThresholdNotificationIsDeduplicatedWithinBand() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 21))
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 18))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 1)
        monitor.process(snapshot(percentage: 10))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 2)
    }

    func testPowerChangeExpiresAfterTwoPointFiveSeconds() {
        let now = Date(timeIntervalSince1970: 5_000)
        let monitor = PowerSourceMonitor(now: { now })
        var latest: IslandActivity?
        monitor.onActivity = { latest = $0 }
        monitor.process(snapshot(percentage: 80, power: false))
        monitor.process(snapshot(percentage: 80, power: true))
        XCTAssertEqual(latest?.id, "battery.power-change")
        XCTAssertEqual(latest?.expiresAt, now.addingTimeInterval(2.5))
    }

    func testRecoveringAboveLowBatteryThresholdClearsActivity() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 21))
        XCTAssertEqual(activities.first.flatMap { $0 }?.id, "battery.low")
        XCTAssertNil(activities.last ?? nil)
    }

    private func snapshot(percentage: Int, power: Bool = false) -> PowerSourceMonitor.Snapshot {
        .init(hasBattery: true, percentage: percentage,
              isCharging: power, isConnectedToPower: power)
    }
}
