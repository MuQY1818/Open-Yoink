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

    func testEdgeMappings_dragTunedValues() {
        // UX2: 拖拽场景（按住左键移动中贴边）比悬停场景的停留更短、带宽更宽。
        XCTAssertEqual(TriggerSensitivity.low.edgeDwellTime, 0.4)
        XCTAssertEqual(TriggerSensitivity.medium.edgeDwellTime, 0.2)
        XCTAssertEqual(TriggerSensitivity.high.edgeDwellTime, 0.1)
        XCTAssertEqual(TriggerSensitivity.low.edgeBandWidth, 6)
        XCTAssertEqual(TriggerSensitivity.medium.edgeBandWidth, 10)
        XCTAssertEqual(TriggerSensitivity.high.edgeBandWidth, 16)
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
        // UX 批次新增项的默认值：拖到边缘再出现、双击存剪贴板、空架自动隐藏。
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
        XCTAssertTrue(store.hotKeyDoublePressSavesClipboard)
        XCTAssertTrue(store.autoHideWhenEmpty)
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

    // MARK: - UX 批次：新设置持久化与迁移

    func testUXSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.dragAutoAppearMode = .edgeOnly
        store.hotKeyDoublePressSavesClipboard = false
        store.autoHideWhenEmpty = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
        XCTAssertFalse(reloaded.hotKeyDoublePressSavesClipboard)
        XCTAssertFalse(reloaded.autoHideWhenEmpty)
    }

    func testDragAutoAppearMode_invalidPersistedValue_fallsBackToEdgeOnly() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("garbage", forKey: "OpenYoink.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_legacyEdgeTriggerEnabled_migratesToEdgeOnly() throws {
        // UX1 迁移：旧版布尔边缘触发开关为开、且从未持久化过新模式 → .edgeOnly。
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "OpenYoink.edgeTriggerEnabled")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)

        // 迁移立即落盘：后续实例仍读到 edgeOnly。
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_explicitModeWinsOverLegacyFlag() throws {
        // 显式持久化过新模式 → 旧布尔开关不再参与（迁移只发生一次）。
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "OpenYoink.edgeTriggerEnabled")
        defaults.set("off", forKey: "OpenYoink.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .off)
    }
}
