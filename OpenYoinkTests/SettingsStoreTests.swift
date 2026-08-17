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
