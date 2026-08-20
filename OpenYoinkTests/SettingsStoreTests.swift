import XCTest
@testable import OpenYoink

/// SettingsStore 的 S8 面：通用设置持久化往返、可清除的快捷键
/// （Optional：键缺失 → 默认；持久化 null → 明确清除），以及忽略列表
/// 编辑 helper（去重/裁剪/移除）。
@MainActor
final class SettingsStoreTests: XCTestCase {
    /// 独立 UserDefaults suite，避免污染应用自身的设置。
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "OpenYoinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - General settings persistence

    func testGeneralSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .left
        store.shelfWidth = 420
        store.autoHide = true
        store.dragOutRemovalPolicy = .ask
        store.language = .chinese

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shelfPosition, .left)
        XCTAssertEqual(reloaded.shelfWidth, 420)
        XCTAssertTrue(reloaded.autoHide)
        XCTAssertEqual(reloaded.dragOutRemovalPolicy, .ask)
        XCTAssertEqual(reloaded.language, .chinese)
    }

    func testGeneralSettings_defaults() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.shelfPosition, .right)
        XCTAssertEqual(store.shelfWidth, 320)
        XCTAssertFalse(store.autoHide)
        XCTAssertEqual(store.dragOutRemovalPolicy, .keep)
        XCTAssertEqual(store.language, .system)
        XCTAssertEqual(store.onboardingVersion, 0)
        XCTAssertFalse(store.hadPersistedOnboardingVersion)
        XCTAssertEqual(store.shelfPresentationMode, .classic)
        XCTAssertEqual(store.shelfPlacement, .right)
        XCTAssertTrue(store.classicShelfEnabled)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertEqual(store.islandDisplayTarget, .main)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .island)
        XCTAssertEqual(store.effectivePreferredShelfSurface, .classic)
        XCTAssertFalse(store.islandHoverRevealEnabled)
        XCTAssertTrue(store.islandTimerEnabled)
        XCTAssertTrue(store.islandBatteryEnabled)
        XCTAssertFalse(store.islandMediaEnabled)
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs,
                       [.shelf, .transfers, .timer, .battery, .system])
        XCTAssertEqual(store.islandModuleConfiguration.pinnedModuleIDs,
                       [.shelf, .timer, .system])
        XCTAssertTrue(store.classicShelfHoverRevealEnabled)
    }

    func testExistingUserMigratesLegacyModuleOrderWithoutEnablingSystem() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "OpenYoink.onboardingVersion")
        defaults.set(true, forKey: "OpenYoink.islandShelfEnabled")
        defaults.set(true, forKey: "OpenYoink.islandMediaEnabled")
        defaults.set(true, forKey: "OpenYoink.islandTimerEnabled")
        defaults.set(false, forKey: "OpenYoink.islandBatteryEnabled")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.islandModuleConfiguration.enabledModuleIDs,
                       [.shelf, .media, .transfers, .timer])
        XCTAssertEqual(store.islandModuleConfiguration.pinnedModuleIDs,
                       [.shelf, .media, .transfers, .timer])
        XCTAssertFalse(store.isIslandModuleEnabled(.system))
        XCTAssertTrue(store.classicShelfHoverRevealEnabled)
    }

    func testUnknownModuleIDsSurviveReloadAndRuntimeEdits() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let unknown = IslandModuleID(rawValue: "future.weather")
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: [.shelf, unknown],
            pinnedModuleIDs: [unknown, .shelf]
        )
        defaults.set(try JSONEncoder().encode(configuration),
                     forKey: "OpenYoink.islandModuleConfiguration")

        let store = SettingsStore(defaults: defaults)
        store.setIslandModuleEnabled(true, id: .timer)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.isIslandModuleEnabled(unknown))
        XCTAssertTrue(reloaded.isIslandModulePinned(unknown))
    }

    func testPrimaryConfigurationShadowWritesLegacyBooleans() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        store.setIslandModuleEnabled(false, id: .timer)
        store.setIslandModuleEnabled(true, id: .media)

        XCTAssertFalse(defaults.bool(forKey: "OpenYoink.islandTimerEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "OpenYoink.islandMediaEnabled"))
    }

    func testLoadingPrimaryConfigurationRefreshesLegacyShadowKeys() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: [.transfers, .media], pinnedModuleIDs: [.media]
        )
        defaults.set(try JSONEncoder().encode(configuration),
                     forKey: "OpenYoink.islandModuleConfiguration")
        defaults.set(true, forKey: "OpenYoink.islandTimerEnabled")
        defaults.set(false, forKey: "OpenYoink.islandMediaEnabled")

        _ = SettingsStore(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: "OpenYoink.islandTimerEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "OpenYoink.islandMediaEnabled"))
    }

    func testCorruptModuleConfigurationIsBackedUpWithoutBeingOverwritten() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let corrupt = Data([0x00, 0xCA, 0xFE])
        defaults.set(corrupt, forKey: "OpenYoink.islandModuleConfiguration")

        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.islandModuleConfiguration.enabledModuleIDs.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "OpenYoink.islandModuleConfiguration"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "OpenYoink.islandModuleConfigurationCorruptBackup"),
                       corrupt)
    }

    func testIslandPlacementPreservesLastClassicPosition() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .left
        store.shelfPlacement = .island
        XCTAssertEqual(store.shelfPresentationMode, .island)
        XCTAssertEqual(store.shelfPosition, .left)

        store.shelfPlacement = .right
        XCTAssertEqual(store.shelfPresentationMode, .classic)
        XCTAssertEqual(store.shelfPosition, .right)
    }

    func testIslandSettingsPersistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPlacement = .island
        store.islandDisplayTarget = .display("display-uuid")
        store.islandHoverRevealEnabled = true
        store.islandTimerEnabled = false
        store.islandBatteryEnabled = false
        store.islandFullChargeAlertEnabled = true
        store.islandMediaEnabled = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shelfPresentationMode, .island)
        XCTAssertEqual(reloaded.islandDisplayTarget, .display("display-uuid"))
        XCTAssertTrue(reloaded.islandHoverRevealEnabled)
        XCTAssertFalse(reloaded.islandTimerEnabled)
        XCTAssertFalse(reloaded.islandBatteryEnabled)
        XCTAssertTrue(reloaded.islandFullChargeAlertEnabled)
        XCTAssertTrue(reloaded.islandMediaEnabled)
    }

    func testIslandDisplayTargetCanSwitchBackToAutomatic() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.islandDisplayTarget = .display("external-display")
        XCTAssertEqual(SettingsStore(defaults: defaults).islandDisplayTarget,
                       .display("external-display"))

        store.islandDisplayTarget = .automatic
        XCTAssertEqual(SettingsStore(defaults: defaults).islandDisplayTarget,
                       .automatic)
    }

    func testSideShelfAndIslandPersistIndependently() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.classicShelfEnabled = true
        store.islandEnabled = true
        store.islandShelfEnabled = true
        store.preferredShelfSurface = .island

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertTrue(reloaded.islandShelfEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
        XCTAssertEqual(reloaded.effectivePreferredShelfSurface, .classic)

        reloaded.islandShelfEnabled = false
        XCTAssertTrue(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
        XCTAssertEqual(reloaded.effectivePreferredShelfSurface, .classic)
    }

    func testLegacyIslandModeMigratesToIndependentSurfaceSettings() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("island", forKey: "OpenYoink.shelfPresentationMode")

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.classicShelfEnabled)
        XCTAssertTrue(store.islandEnabled)
        XCTAssertTrue(store.islandShelfEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .island)
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.classicShelfEnabled)
        XCTAssertTrue(reloaded.islandEnabled)
        XCTAssertTrue(reloaded.islandShelfEnabled)
        XCTAssertEqual(reloaded.preferredShelfSurface, .island)
    }

    func testExistingClassicUserDoesNotInheritFreshInstallIslandDefault() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "OpenYoink.onboardingVersion")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.classicShelfEnabled)
        XCTAssertFalse(store.islandEnabled)
        XCTAssertEqual(store.preferredShelfSurface, .classic)
    }

    func testEffectivePreferredSurfaceFallsBackWithoutOverwritingPreference() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.classicShelfEnabled = true
        store.islandEnabled = true
        store.islandShelfEnabled = true
        store.preferredShelfSurface = .island
        XCTAssertEqual(store.effectivePreferredShelfSurface, .classic)

        store.islandEnabled = false
        XCTAssertEqual(store.effectivePreferredShelfSurface, .classic)
        XCTAssertEqual(store.preferredShelfSurface, .island)

        store.classicShelfEnabled = false
        XCTAssertNil(store.effectivePreferredShelfSurface)

        store.islandEnabled = true
        XCTAssertEqual(store.effectivePreferredShelfSurface, .island)
    }

    func testOnboardingVersionPersistsAndKeepsExplicitState() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.onboardingVersion = 1

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.onboardingVersion, 1)
        XCTAssertTrue(reloaded.hadPersistedOnboardingVersion)
    }

    // MARK: - Custom shelf frame (S9)

    func testCustomShelfFrame_defaultsToNil() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testCustomShelfFrame_persistsAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        let frame = CGRect(x: 120, y: 240, width: 360, height: 800)
        store.customShelfFrame = frame

        XCTAssertEqual(SettingsStore(defaults: defaults).customShelfFrame, frame)
    }

    func testCustomShelfFrame_clearedRemovesPersistedValue() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.customShelfFrame = CGRect(x: 0, y: 0, width: 320, height: 600)
        store.customShelfFrame = nil

        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testCustomShelfFrame_corruptDataFallsBackToNil() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(Data([0x00, 0x01]), forKey: "OpenYoink.customShelfFrame")
        XCTAssertNil(SettingsStore(defaults: defaults).customShelfFrame)
    }

    func testShelfPosition_customPersistsAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfPosition = .custom

        XCTAssertEqual(SettingsStore(defaults: defaults).shelfPosition, .custom)
    }

    // MARK: - Clearable hot key shortcut

    func testHotKeyShortcut_absentKeyFallsBackToDefault() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(SettingsStore(defaults: defaults).hotKeyShortcut, .default)
    }

    func testHotKeyShortcut_clearedStateSurvivesReload() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyShortcut = nil

        // 「清除」必须作为显式状态持久化（编码为 JSON null），而不是
        // 回退成默认快捷键。
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertNil(reloaded.hotKeyShortcut)
    }

    func testHotKeyShortcut_recordingAfterClearRoundTrips() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyShortcut = nil
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 8, command: true, shift: false, option: true, control: false
        )

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 8, command: true,
                                                    shift: false, option: true, control: false))
    }

    // MARK: - EdgeTab settings

    func testEdgeTabSettings_defaults() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        // 默认垂直居中（保持旧版视觉）、拉环默认开。
        XCTAssertEqual(store.shelfEdgeOffset, 0.5)
        XCTAssertTrue(store.edgeTabEnabled)
    }

    func testEdgeTabSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.shelfEdgeOffset = 0.2
        store.edgeTabEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shelfEdgeOffset, 0.2)
        XCTAssertFalse(reloaded.edgeTabEnabled)
    }

    // MARK: - Ignore list editing

    func testAddIgnoredApp_appendsNewBundleID() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "com.google.Chrome")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.google.Chrome"])
    }

    func testAddIgnoredApp_dedupesCaseInsensitively() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "COM.APPLE.SAFARI")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testAddIgnoredApp_trimsWhitespaceAndRejectsEmpty() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "  com.apple.safari  ")
        store.addIgnoredApp(bundleID: "   ")
        store.addIgnoredApp(bundleID: "")

        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testRemoveIgnoredApps_removesExactlyTheGivenIDs() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.ignoredAppBundleIDs = ["com.apple.safari", "com.google.Chrome", "com.apple.mail"]
        store.removeIgnoredApps(bundleIDs: ["com.google.Chrome"])
        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.apple.mail"])

        store.removeIgnoredApps(bundleIDs: [])
        XCTAssertEqual(store.ignoredAppBundleIDs, ["com.apple.safari", "com.apple.mail"])
    }

    func testIgnoreListEdits_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addIgnoredApp(bundleID: "com.apple.safari")
        store.addIgnoredApp(bundleID: "com.apple.mail")
        store.removeIgnoredApps(bundleIDs: ["com.apple.safari"])

        XCTAssertEqual(SettingsStore(defaults: defaults).ignoredAppBundleIDs, ["com.apple.mail"])
    }
}
