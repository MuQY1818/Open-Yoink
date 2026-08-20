import XCTest
@testable import OpenYoink

final class SystemStatusMetricTests: XCTestCase {
    func testCPUUsageUsesTickDifferences() {
        let usage = SystemMetricMath.cpuUsage(
            previous: .init(user: 100, system: 50, idle: 350, nice: 0),
            current: .init(user: 140, system: 70, idle: 420, nice: 10)
        )
        XCTAssertEqual(usage ?? -1, 0.5, accuracy: 0.0001)
    }

    func testCounterRolloverIsHandled() {
        XCTAssertEqual(
            SystemMetricMath.wrappingDelta(previous: UInt64.max - 4, current: 3),
            8
        )
        let rates = SystemMetricMath.networkRates(
            previous: .init(received: UInt64.max - 9, sent: 100),
            current: .init(received: 10, sent: 300),
            elapsed: 2
        )
        XCTAssertEqual(rates?.download, 10)
        XCTAssertEqual(rates?.upload, 100)
    }

    func testCPUTickRolloverUsesMachThirtyTwoBitCounterWidth() {
        let maximum = UInt64(UInt32.max)
        let usage = SystemMetricMath.cpuUsage(
            previous: .init(user: maximum - 4, system: 10, idle: maximum - 9, nice: 0),
            current: .init(user: 5, system: 20, idle: 10, nice: 0)
        )
        XCTAssertEqual(usage ?? -1, 20.0 / 40.0, accuracy: 0.0001)
    }

    func testMemoryUsedExcludesPurgeableActivePages() {
        XCTAssertEqual(SystemMetricMath.memoryUsedPages(
            active: 100,
            wired: 30,
            compressor: 20,
            purgeable: 10
        ), 140)
        XCTAssertEqual(SystemMetricMath.memoryUsedPages(
            active: 5,
            wired: 3,
            compressor: 2,
            purgeable: 20
        ), 5)
    }

    func testAdaptiveRefreshIntervals() {
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: false,
            thermalStatus: .nominal
        ), .seconds(1))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: false,
            isLowPowerModeEnabled: false,
            thermalStatus: .nominal
        ), .seconds(5))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: true,
            thermalStatus: .nominal
        ), .seconds(15))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: false,
            thermalStatus: .critical
        ), .seconds(15))
    }

    @MainActor
    func testMemoryPressureEventOverridesUnavailableSample() async {
        let provider = FixedSystemProvider(snapshot: .unavailable())
        let store = SystemStatusModuleStore(
            provider: provider,
            isSelectedAndExpanded: { false }
        )
        store.start()
        await store.refresh()
        store.processMemoryPressureEvent(.critical)
        XCTAssertEqual(store.snapshot.memoryPressure, .critical)
        XCTAssertEqual(store.alerts.first?.id, "system.memory-pressure")
        store.stop()
    }

    func testApplicationCPURequiresSixtySecondsAndThenCoolsDown() {
        var evaluator = SystemApplicationAlertEvaluator()
        let start = Date(timeIntervalSince1970: 1_000)
        var snapshot = snapshotWithApplication(cpu: 0.9, memory: 100)
        XCTAssertTrue(evaluator.alerts(for: snapshot, at: start).isEmpty)
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: start.addingTimeInterval(60)).count, 1)
        XCTAssertTrue(evaluator.alerts(for: snapshot,
                                       at: start.addingTimeInterval(120)).isEmpty)

        snapshot = snapshotWithApplication(cpu: 0.1, memory: 3_000_000_000)
        XCTAssertTrue(evaluator.alerts(for: snapshot,
                                       at: start.addingTimeInterval(959)).isEmpty)
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: start.addingTimeInterval(961)).count, 1)
    }

    func testApplicationMemoryThresholdIsMaxOfTwoGBAndFifteenPercent() {
        var evaluator = SystemApplicationAlertEvaluator()
        let date = Date(timeIntervalSince1970: 2_000)
        var snapshot = snapshotWithApplication(cpu: 0, memory: 2_100_000_000)
        snapshot.memoryTotalBytes = 64_000_000_000
        XCTAssertTrue(evaluator.alerts(for: snapshot, at: date).isEmpty)

        snapshot = snapshotWithApplication(cpu: 0, memory: 10_000_000_000)
        snapshot.memoryTotalBytes = 64_000_000_000
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: date.addingTimeInterval(1)).count, 1)
    }

    private func snapshotWithApplication(cpu: Double, memory: UInt64) -> SystemSnapshot {
        var snapshot = SystemSnapshot.unavailable(at: Date(timeIntervalSince1970: 0))
        snapshot.memoryTotalBytes = 8_000_000_000
        snapshot.topApplications = [
            .init(id: "com.example.app", processIdentifier: 42, name: "Example",
                  bundleIdentifier: "com.example.app", cpuUsage: cpu,
                  memoryBytes: memory),
        ]
        return snapshot
    }
}

private actor FixedSystemProvider: SystemStatusProviding {
    let fixedSnapshot: SystemSnapshot

    init(snapshot: SystemSnapshot) {
        fixedSnapshot = snapshot
    }

    func sample() async -> SystemSnapshot { fixedSnapshot }
}
