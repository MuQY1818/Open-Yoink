import XCTest
@testable import OpenYoink

/// 触发设置的默认值与持久化（SettingsStore 的 S7 字段），以及
/// TriggerSensitivity → 识别参数的档位映射。
@MainActor
final class TriggerSettingsTests: XCTestCase {
    // MARK: - Helpers

    /// 独立 UserDefaults suite，避免污染应用自身的设置。
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "OpenYoinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - Sensitivity mappings

    func testShakeParameters_tiersGetStricterFromHighToLow() {
        let low = TriggerSensitivity.low.shakeParameters
        let medium = TriggerSensitivity.medium.shakeParameters
        let high = TriggerSensitivity.high.shakeParameters
        // 越不敏感：窗口越短、要求反转越多、段长阈值越高。
        XCTAssertLessThan(low.window, medium.window)
        XCTAssertLessThan(medium.window, high.window)
        XCTAssertGreaterThan(low.requiredReversals, medium.requiredReversals)
        XCTAssertGreaterThan(medium.requiredReversals, high.requiredReversals)
        XCTAssertGreaterThan(low.minSegmentDistance, medium.minSegmentDistance)
        XCTAssertGreaterThan(medium.minSegmentDistance, high.minSegmentDistance)
    }

    func testEdgeMappings_higherSensitivityMeansEasierTrigger() {
        XCTAssertGreaterThan(TriggerSensitivity.low.edgeDwellTime,
                             TriggerSensitivity.medium.edgeDwellTime)
        XCTAssertGreaterThan(TriggerSensitivity.medium.edgeDwellTime,
                             TriggerSensitivity.high.edgeDwellTime)
        XCTAssertLessThan(TriggerSensitivity.low.edgeBandWidth,
                          TriggerSensitivity.medium.edgeBandWidth)
        XCTAssertLessThan(TriggerSensitivity.medium.edgeBandWidth,
                          TriggerSensitivity.high.edgeBandWidth)
    }

    // MARK: - SettingsStore defaults & persistence

    func testDefaults_matchPlanRiskTable() throws {
        // 计划 §6：快捷键默认开，摇动/边缘默认关，灵敏度默认中档。
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.hotKeyEnabled)
        XCTAssertFalse(store.shakeTriggerEnabled)
        XCTAssertFalse(store.edgeTriggerEnabled)
        XCTAssertEqual(store.shakeSensitivity, .medium)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
        XCTAssertEqual(store.hotKeyShortcut, .default)
        XCTAssertEqual(store.ignoredAppBundleIDs, [])
    }

    func testTriggerSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyEnabled = false
        store.shakeTriggerEnabled = true
        store.edgeTriggerEnabled = true
        store.shakeSensitivity = .high
        store.edgeTriggerSensitivity = .low
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 3, command: true, shift: false, option: true, control: false
        )
        store.ignoredAppBundleIDs = ["com.apple.safari"]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hotKeyEnabled)
        XCTAssertTrue(reloaded.shakeTriggerEnabled)
        XCTAssertTrue(reloaded.edgeTriggerEnabled)
        XCTAssertEqual(reloaded.shakeSensitivity, .high)
        XCTAssertEqual(reloaded.edgeTriggerSensitivity, .low)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 3, command: true,
                                                    shift: false, option: true, control: false))
        XCTAssertEqual(reloaded.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testLegacyDoubleSensitivity_fallsBackToMedium() throws {
        // S7 之前占位实现存的是 Double；读到旧值/脏值时回退中档，不崩溃。
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(0.5, forKey: "OpenYoink.shakeSensitivity")
        defaults.set("garbage", forKey: "OpenYoink.edgeTriggerSensitivity")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.shakeSensitivity, .medium)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
    }
}
