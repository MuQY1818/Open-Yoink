import Foundation
import OpenYoinkModuleCore

/// UserDefaults-backed app settings, observable by SwiftUI.
///
/// All keys are prefixed with `OpenYoink.` to avoid collisions. Defaults are
/// registered on init, so reads always return meaningful values. Trigger
/// settings are consumed by `HotKeyMonitor` / `MouseShakeMonitor` /
/// `EdgeTriggerMonitor` (S7); the settings UI lives in `SettingsView` (S8).
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Value types

    /// Screen edge the shelf attaches to, or free placement (custom).
    enum ShelfPosition: String, CaseIterable, Sendable {
        case left, right
        /// Free placement (S9): the panel is dragged by its title-bar area and
        /// the frame persists in `customShelfFrame`.
        case custom
    }

    /// Which surface presents the same shelf data. Classic retains the
    /// existing left/right/custom panel; Island anchors a compact surface to
    /// the camera housing (or a floating top pill on displays without one).
    enum ShelfPresentationMode: String, CaseIterable, Sendable {
        case classic, island
    }

    /// Which shelf surface the global shelf command controls when both are
    /// available. Availability is still governed by the independent surface
    /// toggles below; this value is only a preference and never disables a
    /// surface by itself.
    enum PreferredShelfSurface: String, CaseIterable, Sendable {
        case classic, island
    }

    /// Stable Island placement across multiple displays. `.main` follows the
    /// display designated as main in System Settings, `.automatic` preserves
    /// the legacy pointer/drag-following behavior, and `.display` pins one
    /// physical display using its ColorSync UUID.
    enum IslandDisplayTarget: Hashable, Sendable {
        case main
        case automatic
        case display(String)

        fileprivate var persistedValue: String {
            switch self {
            case .main: "main"
            case .automatic: "automatic"
            case let .display(id): "display:\(id)"
            }
        }

        fileprivate init(persistedValue: String?) {
            guard let persistedValue else {
                self = .main
                return
            }
            if persistedValue == "automatic" {
                self = .automatic
            } else if persistedValue == "main" {
                self = .main
            } else if persistedValue.hasPrefix("display:") {
                let id = String(persistedValue.dropFirst("display:".count))
                self = id.isEmpty ? .main : .display(id)
            } else {
                self = .main
            }
        }
    }

    /// User-facing placement picker. Keeping this separate from
    /// `ShelfPosition` prevents Island from leaking into edge-only layout and
    /// trigger switches while still presenting one simple control in Settings.
    enum ShelfPlacement: String, CaseIterable, Sendable {
        case left, right, island, custom
    }

    /// What happens to an item after it is dragged out of the shelf.
    enum DragOutRemovalPolicy: String, CaseIterable, Sendable {
        case keep   // keep the item on the shelf
        case remove // remove it after a successful drop
        case ask    // ask every time (NSAlert in DragSessionController, S8)
    }

    /// UI language override.
    enum LanguagePreference: String, CaseIterable, Sendable {
        case system, chinese, english
    }

    /// What happens when the user starts dragging with the left mouse button
    /// held (UX batch, task 1/2; Yoink's signature "shelf appears on drag").
    enum DragAutoAppearMode: String, CaseIterable, Sendable {
        /// Show the shelf at its configured position as soon as a drag starts.
        case immediate
        /// Stay hidden on drag start; reveal when the drag rests at the
        /// shelf's screen edge (drag version of the edge trigger).
        case edgeOnly
        /// No drag-triggered appearance.
        case off
    }

    /// Codable description of the global toggle hot key. Consumed by
    /// `HotKeyMonitor` (S7), which maps it to Carbon modifiers; the S8
    /// `ShortcutRecorderView` writes new values (and clears to nil).
    struct HotKeyShortcut: Codable, Equatable, Sendable {
        /// Hardware-independent virtual key code (kVK_*; 49 = Space).
        var keyCode: UInt32
        var command: Bool
        var shift: Bool
        var option: Bool
        var control: Bool

        /// ⌘⇧Space
        static let `default` = HotKeyShortcut(
            keyCode: 49, command: true, shift: true, option: false, control: false
        )
    }

    // MARK: - General

    /// Edge the shelf attaches to. Default: right.
    var shelfPosition: ShelfPosition {
        didSet { defaults.set(shelfPosition.rawValue, forKey: Keys.shelfPosition) }
    }

    /// The side shelf and Island are independent surfaces over one ShelfStore.
    /// New installs enable both surfaces and start with Island as the preferred
    /// entry point. Migration below keeps existing users' explicit choices.
    var classicShelfEnabled: Bool {
        didSet { defaults.set(classicShelfEnabled, forKey: Keys.classicShelfEnabled) }
    }

    var islandEnabled: Bool {
        didSet { defaults.set(islandEnabled, forKey: Keys.islandEnabled) }
    }

    var islandDisplayTarget: IslandDisplayTarget {
        didSet {
            defaults.set(islandDisplayTarget.persistedValue,
                         forKey: Keys.islandDisplayTarget)
        }
    }

    /// Shelf is an optional Island module. Turning it off never deletes shelf
    /// contents and doesn't affect the side shelf.
    var islandShelfEnabled: Bool {
        didSet {
            defaults.set(islandShelfEnabled, forKey: Keys.islandShelfEnabled)
            syncModuleConfigurationFromLegacy(.shelf, enabled: islandShelfEnabled)
        }
    }

    var preferredShelfSurface: PreferredShelfSurface {
        didSet {
            defaults.set(preferredShelfSurface.rawValue,
                         forKey: Keys.preferredShelfSurface)
        }
    }

    /// Resolves the user's preferred shelf against currently enabled
    /// surfaces. The stored preference is intentionally retained while its
    /// surface is disabled, so re-enabling it restores the previous choice.
    var effectivePreferredShelfSurface: PreferredShelfSurface? {
        let islandShelfAvailable = islandEnabled && islandShelfEnabled
        // The established global "Shelf" command belongs to the side shelf
        // whenever that surface is enabled. Island remains independently
        // clickable and drag-addressable; it is only the shortcut fallback
        // when the side shelf is disabled.
        if classicShelfEnabled { return .classic }
        if islandShelfAvailable { return .island }
        return nil
    }

    /// Compatibility façade for pre-dual-surface call sites and stored
    /// preferences. New code must use the independent booleans above.
    var shelfPresentationMode: ShelfPresentationMode {
        get {
            effectivePreferredShelfSurface == .island ? .island : .classic
        }
        set {
            switch newValue {
            case .classic:
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .island:
                classicShelfEnabled = false
                islandEnabled = true
                islandShelfEnabled = true
                preferredShelfSurface = .island
            }
        }
    }

    /// Combined Settings binding. Selecting Island preserves the last classic
    /// position so switching back restores the user's previous layout.
    var shelfPlacement: ShelfPlacement {
        get {
            if shelfPresentationMode == .island { return .island }
            switch shelfPosition {
            case .left: return .left
            case .right: return .right
            case .custom: return .custom
            }
        }
        set {
            switch newValue {
            case .island:
                classicShelfEnabled = false
                islandEnabled = true
                islandShelfEnabled = true
                preferredShelfSurface = .island
            case .left:
                shelfPosition = .left
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .right:
                shelfPosition = .right
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .custom:
                shelfPosition = .custom
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            }
        }
    }

    /// Optional hover reveal. Click, drag approach and the global shortcut are
    /// always available, so disabling hover never makes Island unreachable.
    var islandHoverRevealEnabled: Bool {
        didSet { defaults.set(islandHoverRevealEnabled, forKey: Keys.islandHoverRevealEnabled) }
    }

    var islandTimerEnabled: Bool {
        didSet {
            defaults.set(islandTimerEnabled, forKey: Keys.islandTimerEnabled)
            syncModuleConfigurationFromLegacy(.timer, enabled: islandTimerEnabled)
        }
    }

    var islandBatteryEnabled: Bool {
        didSet {
            defaults.set(islandBatteryEnabled, forKey: Keys.islandBatteryEnabled)
            syncModuleConfigurationFromLegacy(.battery, enabled: islandBatteryEnabled)
        }
    }

    var islandFullChargeAlertEnabled: Bool {
        didSet {
            defaults.set(islandFullChargeAlertEnabled,
                         forKey: Keys.islandFullChargeAlertEnabled)
        }
    }

    /// Optional local Now Playing module. It remains opt-in so a fallback
    /// player never requests Automation access until the user asks for media
    /// controls, while the UI itself is a first-class Island module.
    var islandMediaEnabled: Bool {
        didSet {
            defaults.set(islandMediaEnabled, forKey: Keys.islandMediaEnabled)
            syncModuleConfigurationFromLegacy(.media, enabled: islandMediaEnabled)
        }
    }

    /// Versioned primary configuration for Island module enablement and the
    /// five user-controlled pinned positions. The v1.5 booleans remain shadow
    /// keys for one release so downgrading does not discard user choices.
    var islandModuleConfiguration: IslandModuleConfiguration {
        didSet {
            persistIslandModuleConfiguration()
            applyConfigurationToLegacyProperties()
        }
    }

    /// Hovering the classic edge tab briefly previews the side shelf. The
    /// feature is on by default so the shelf stays out of the way until the
    /// pointer approaches its edge tab; an explicitly saved choice still wins.
    var classicShelfHoverRevealEnabled: Bool {
        didSet {
            defaults.set(classicShelfHoverRevealEnabled,
                         forKey: Keys.classicShelfHoverRevealEnabled)
        }
    }

    func isIslandModuleEnabled(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isEnabled(id)
    }

    func isIslandModulePinned(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isPinned(id)
    }

    func setIslandModuleEnabled(_ enabled: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setEnabled(enabled, for: id)
        islandModuleConfiguration = configuration
    }

    func setIslandModulePinned(_ pinned: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setPinned(pinned, for: id)
        islandModuleConfiguration = configuration
    }

    func movePinnedIslandModules(fromOffsets: IndexSet, toOffset: Int) {
        var configuration = islandModuleConfiguration
        configuration.movePinned(fromOffsets: fromOffsets, toOffset: toOffset)
        islandModuleConfiguration = configuration
    }

    /// Shelf width in points. Default: 320.
    var shelfWidth: Double {
        didSet { defaults.set(shelfWidth, forKey: Keys.shelfWidth) }
    }

    /// Hide the shelf automatically after a drag-out. Default: false.
    var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: Keys.autoHide) }
    }

    /// UX6: hide the shelf automatically when its items go from non-empty to
    /// empty (removal / drag-out). A shelf explicitly summoned while empty
    /// stays put — the rule only fires on the non-empty → empty transition.
    /// Default: true.
    var autoHideWhenEmpty: Bool {
        didSet { defaults.set(autoHideWhenEmpty, forKey: Keys.autoHideWhenEmpty) }
    }

    /// What happens after an item is dragged out. Default: keep.
    var dragOutRemovalPolicy: DragOutRemovalPolicy {
        didSet { defaults.set(dragOutRemovalPolicy.rawValue, forKey: Keys.dragOutRemovalPolicy) }
    }

    /// UI language override. Default: system.
    var language: LanguagePreference {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    /// Sparkle 自动检查更新（唯一联网行为）。Default: true。
    /// 由 UpdateController 应用到 SPUUpdater.automaticallyChecksForUpdates
    /// （启动时一次性 + UserDefaults 变更时同步）。
    var autoUpdateCheckEnabled: Bool {
        didSet { defaults.set(autoUpdateCheckEnabled, forKey: Keys.autoUpdateCheckEnabled) }
    }

    /// 已完成/跳过的快速上手版本。0 表示尚未完成；新增流程时递增该值，
    /// 不需要修改 shelf 持久化 schema。
    var onboardingVersion: Int {
        didSet { defaults.set(onboardingVersion, forKey: Keys.onboardingVersion) }
    }

    /// 启动时该键是否真实存在于持久化偏好中。它刻意不进入
    /// `register(defaults:)`，从而能区分「全新安装」与「已经明确处理过引导」。
    let hadPersistedOnboardingVersion: Bool

    /// EdgeTab: vertical placement of the shelf (and its edge tab) along the
    /// attached edge — 0 pins to the bottom of the visible area, 1 to the top.
    /// Default: 0.5 (vertically centered, matching the pre-EdgeTab look).
    /// No "unset" state needs distinguishing, so it lives in register(defaults:).
    var shelfEdgeOffset: Double {
        didSet { defaults.set(shelfEdgeOffset, forKey: Keys.shelfEdgeOffset) }
    }

    /// EdgeTab: show the edge tab on the shelf's screen edge while the shelf
    /// is hidden (mutually exclusive model — the tab disappears once the shelf
    /// opens; collapsing is done via the shelf's own outer-edge hot zone or
    /// inner chevron handle). Only meaningful for left/right positions —
    /// custom placement has no attachment edge, so no tab is shown.
    /// Default: true.
    var edgeTabEnabled: Bool {
        didSet { defaults.set(edgeTabEnabled, forKey: Keys.edgeTabEnabled) }
    }

    /// Persisted panel frame for the `custom` shelf position (S9), in global
    /// screen coordinates. nil = no custom placement yet — the first switch to
    /// custom starts from the right-edge default frame (see
    /// `ShelfLayoutEngine.targetFrame`). Readers must re-validate against the
    /// current screens (`ShelfLayoutEngine.validatedCustomFrame`): the screen
    /// the frame lived on may have been unplugged.
    var customShelfFrame: CGRect? {
        didSet {
            if let customShelfFrame, let data = try? JSONEncoder().encode(customShelfFrame) {
                defaults.set(data, forKey: Keys.customShelfFrame)
            } else if customShelfFrame == nil {
                defaults.removeObject(forKey: Keys.customShelfFrame)
            }
        }
    }

    // MARK: - Triggers (wired in S7; settings UI in S8)

    /// Global hot key (⌘⇧Space) toggles the shelf. Default: true.
    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }

    /// Mouse-shake gesture shows the shelf. Default: false (off until the
    /// heuristic proves reliable, see plan §6).
    var shakeTriggerEnabled: Bool {
        didSet { defaults.set(shakeTriggerEnabled, forKey: Keys.shakeTriggerEnabled) }
    }

    /// Resting the cursor on a screen edge shows the shelf. Default: false.
    ///
    /// UX2: legacy pre-UX-batch semantic (hover dwell). The UX batch replaced
    /// the user-facing control with `dragAutoAppearMode`; this flag is kept
    /// for persistence compatibility and only feeds the one-time migration in
    /// `init` (legacy ON → `.edgeOnly`).
    var edgeTriggerEnabled: Bool {
        didSet { defaults.set(edgeTriggerEnabled, forKey: Keys.edgeTriggerEnabled) }
    }

    /// UX1: drag-triggered shelf appearance. Default: `.edgeOnly`, so starting
    /// a drag does not cover content before the pointer approaches the shelf.
    /// `.edgeOnly` requires a non-custom shelf position (no attachment edge
    /// otherwise); `custom` position pauses the edge mechanism while active.
    var dragAutoAppearMode: DragAutoAppearMode {
        didSet { defaults.set(dragAutoAppearMode.rawValue, forKey: Keys.dragAutoAppearMode) }
    }

    /// UX3: double-pressing the global hot key saves the general pasteboard
    /// to the shelf. While enabled, a single press toggles the shelf after a
    /// short (~0.3 s) discrimination delay; disabling it restores zero-latency
    /// single presses. Default: true.
    var hotKeyDoublePressSavesClipboard: Bool {
        didSet { defaults.set(hotKeyDoublePressSavesClipboard, forKey: Keys.hotKeyDoublePressSavesClipboard) }
    }

    /// Shake sensitivity (three tiers; higher = triggers more easily).
    /// Default: medium. Mapped to heuristic parameters by
    /// `TriggerSensitivity.shakeParameters`.
    var shakeSensitivity: TriggerSensitivity {
        didSet { defaults.set(shakeSensitivity.rawValue, forKey: Keys.shakeSensitivity) }
    }

    /// Edge-trigger sensitivity (three tiers; higher = shorter dwell time and
    /// wider band). Default: medium. Mapped by `TriggerSensitivity.edgeDwellTime`
    /// / `.edgeBandWidth`.
    var edgeTriggerSensitivity: TriggerSensitivity {
        didSet { defaults.set(edgeTriggerSensitivity.rawValue, forKey: Keys.edgeTriggerSensitivity) }
    }

    /// The toggle hot key, or nil when the user cleared it in the recorder
    /// (no shortcut assigned; `hotKeyEnabled` stays untouched so re-recording
    /// a shortcut re-arms the monitor without a separate toggle).
    ///
    /// Persisted as JSON. Three persisted states: key absent → `.default`
    /// (fresh install); JSON `null` → explicitly cleared; object → shortcut.
    var hotKeyShortcut: HotKeyShortcut? {
        didSet {
            // Encoding the Optional itself: a cleared shortcut persists as
            // top-level `null`, distinguishing it from "never customized".
            if let data = try? JSONEncoder().encode(hotKeyShortcut) {
                defaults.set(data, forKey: Keys.hotKeyShortcut)
            }
        }
    }

    // MARK: - Ignore list

    /// Bundle identifiers of apps in which shake/edge triggers stay silent.
    var ignoredAppBundleIDs: [String] {
        didSet { defaults.set(ignoredAppBundleIDs, forKey: Keys.ignoredAppBundleIDs) }
    }

    /// Adds a bundle ID to the ignore list (settings page, S8). Trims
    /// whitespace and dedupes case-insensitively, mirroring the matching
    /// rules of `IgnoreListService.isIgnored`.
    func addIgnoredApp(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = ignoredAppBundleIDs.contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !isDuplicate else { return }
        ignoredAppBundleIDs.append(trimmed)
    }

    /// Removes entries from the ignore list (settings page, S8).
    func removeIgnoredApps(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        ignoredAppBundleIDs.removeAll { bundleIDs.contains($0) }
    }

    // MARK: - Init

    private let defaults: UserDefaults
    @ObservationIgnored private var isApplyingModuleConfiguration = false

    /// Shared persistence domain for feature stores that must follow the
    /// isolated UI-test/defaults suite instead of silently using `.standard`.
    var defaultsStore: UserDefaults { defaults }

    private enum Keys {
        private static let prefix = "OpenYoink."
        static let shelfPosition = prefix + "shelfPosition"
        static let shelfPresentationMode = prefix + "shelfPresentationMode"
        static let shelfSurfaceSettingsVersion = prefix + "shelfSurfaceSettingsVersion"
        static let classicShelfEnabled = prefix + "classicShelfEnabled"
        static let islandEnabled = prefix + "islandEnabled"
        static let islandDisplayTarget = prefix + "islandDisplayTarget"
        static let islandShelfEnabled = prefix + "islandShelfEnabled"
        static let preferredShelfSurface = prefix + "preferredShelfSurface"
        static let islandHoverRevealEnabled = prefix + "islandHoverRevealEnabled"
        static let islandTimerEnabled = prefix + "islandTimerEnabled"
        static let islandBatteryEnabled = prefix + "islandBatteryEnabled"
        static let islandFullChargeAlertEnabled = prefix + "islandFullChargeAlertEnabled"
        static let islandMediaEnabled = prefix + "islandMediaEnabled"
        static let islandModuleConfiguration = prefix + "islandModuleConfiguration"
        static let islandModuleConfigurationCorruptBackup =
            prefix + "islandModuleConfigurationCorruptBackup"
        static let classicShelfHoverRevealEnabled = prefix + "classicShelfHoverRevealEnabled"
        static let shelfWidth = prefix + "shelfWidth"
        static let shelfEdgeOffset = prefix + "shelfEdgeOffset"
        static let edgeTabEnabled = prefix + "edgeTabEnabled"
        static let autoHide = prefix + "autoHide"
        static let autoHideWhenEmpty = prefix + "autoHideWhenEmpty"
        static let dragOutRemovalPolicy = prefix + "dragOutRemovalPolicy"
        static let language = prefix + "language"
        static let autoUpdateCheckEnabled = prefix + "autoUpdateCheckEnabled"
        static let onboardingVersion = prefix + "onboardingVersion"
        static let customShelfFrame = prefix + "customShelfFrame"
        static let hotKeyEnabled = prefix + "hotKeyEnabled"
        static let hotKeyDoublePressSavesClipboard = prefix + "hotKeyDoublePressSavesClipboard"
        static let shakeTriggerEnabled = prefix + "shakeTriggerEnabled"
        static let edgeTriggerEnabled = prefix + "edgeTriggerEnabled"
        static let dragAutoAppearMode = prefix + "dragAutoAppearMode"
        static let shakeSensitivity = prefix + "shakeSensitivity"
        static let edgeTriggerSensitivity = prefix + "edgeTriggerSensitivity"
        static let hotKeyShortcut = prefix + "hotKeyShortcut"
        static let ignoredAppBundleIDs = prefix + "ignoredAppBundleIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hadPersistedOnboardingVersion = defaults.object(forKey: Keys.onboardingVersion) != nil
        let persistedModuleConfigurationData = defaults.data(
            forKey: Keys.islandModuleConfiguration
        )
        // Registration defaults are process-wide and leak into isolated test
        // suites. Only durable migration evidence may classify an install as
        // existing; v1.5 has onboardingVersion, while pre-release modular
        // builds may only have the versioned configuration blob.
        let hadPersistedAppSettings = hadPersistedOnboardingVersion
            || persistedModuleConfigurationData != nil
        // UX1 迁移必须在注册默认值之前读取：注册域会让「从未设置」与
        // 「显式存过 immediate」无法区分（且 NSRegistrationDomain 进程内
        // 共享，跨 UserDefaults 实例可见）。旧版布尔 edgeTriggerEnabled（悬停
        // 触发开关）为开且从未持久化过 dragAutoAppearMode → 迁移为
        // .edgeOnly（最接近旧意图的贴边唤出），并立即落盘让 UI 反映。
        // 注意：dragAutoAppearMode 因此刻意不进 register(defaults:) ——
        // 一旦注册，nil 判定即失效，迁移会永远不会发生。
        let legacyEdgeTriggerEnabled = defaults.bool(forKey: Keys.edgeTriggerEnabled)
        let persistedDragMode = defaults.string(forKey: Keys.dragAutoAppearMode)
        // Preserve settings written by an earlier development build of the
        // dual-surface feature, which predates the explicit migration version.
        // Only inspect the app's real persistent domain for `.standard`;
        // isolated test/UI suites must not inherit the host app's preferences.
        let standardPersistentDomain: [String: Any]? = if defaults === UserDefaults.standard,
                                                          let domain = Bundle.main.bundleIdentifier {
            defaults.persistentDomain(forName: domain)
        } else {
            nil
        }
        let persistedClassicShelfEnabled = standardPersistentDomain?[Keys.classicShelfEnabled]
            as? Bool ?? defaults.object(forKey: Keys.classicShelfEnabled) as? Bool
        let persistedIslandEnabled = standardPersistentDomain?[Keys.islandEnabled]
            as? Bool ?? defaults.object(forKey: Keys.islandEnabled) as? Bool
        let persistedIslandShelfEnabled = standardPersistentDomain?[Keys.islandShelfEnabled]
            as? Bool ?? defaults.object(forKey: Keys.islandShelfEnabled) as? Bool
        let persistedPreferredSurface = standardPersistentDomain?[Keys.preferredShelfSurface]
            as? String ?? defaults.string(forKey: Keys.preferredShelfSurface)
        let persistedLegacyPresentationMode = defaults.string(
            forKey: Keys.shelfPresentationMode
        ).flatMap(ShelfPresentationMode.init(rawValue:))
        let legacyPresentationMode = persistedLegacyPresentationMode ?? .classic
        let persistedSurfaceSettingsVersion = defaults.integer(
            forKey: Keys.shelfSurfaceSettingsVersion
        )
        defaults.register(defaults: [
            Keys.shelfPosition: ShelfPosition.right.rawValue,
            Keys.shelfPresentationMode: ShelfPresentationMode.classic.rawValue,
            Keys.classicShelfEnabled: true,
            Keys.islandEnabled: true,
            Keys.islandDisplayTarget: IslandDisplayTarget.main.persistedValue,
            Keys.islandShelfEnabled: true,
            Keys.preferredShelfSurface: PreferredShelfSurface.island.rawValue,
            Keys.islandHoverRevealEnabled: false,
            Keys.islandTimerEnabled: true,
            Keys.islandBatteryEnabled: true,
            Keys.islandFullChargeAlertEnabled: false,
            Keys.islandMediaEnabled: false,
            Keys.shelfWidth: 320.0,
            Keys.shelfEdgeOffset: 0.5,
            Keys.edgeTabEnabled: true,
            Keys.autoHide: false,
            Keys.autoHideWhenEmpty: true,
            Keys.dragOutRemovalPolicy: DragOutRemovalPolicy.keep.rawValue,
            Keys.language: LanguagePreference.system.rawValue,
            Keys.autoUpdateCheckEnabled: true,
            Keys.hotKeyEnabled: true,
            Keys.hotKeyDoublePressSavesClipboard: true,
            Keys.shakeTriggerEnabled: false,
            Keys.edgeTriggerEnabled: false,
            Keys.shakeSensitivity: TriggerSensitivity.medium.rawValue,
            Keys.edgeTriggerSensitivity: TriggerSensitivity.medium.rawValue,
            Keys.ignoredAppBundleIDs: [String](),
        ])

        shelfPosition = ShelfPosition(rawValue: defaults.string(forKey: Keys.shelfPosition) ?? "")
            ?? .right
        let hasPreversionedSurfaceSettings = standardPersistentDomain?[Keys.classicShelfEnabled] != nil
            || standardPersistentDomain?[Keys.islandEnabled] != nil
            || standardPersistentDomain?[Keys.islandShelfEnabled] != nil
            || standardPersistentDomain?[Keys.preferredShelfSurface] != nil
        let needsSurfaceMigration = persistedSurfaceSettingsVersion < 1
            && !hasPreversionedSurfaceSettings
        let resolvedClassicShelfEnabled: Bool
        let resolvedIslandEnabled: Bool
        let resolvedIslandShelfEnabled: Bool
        let resolvedPreferredSurface: PreferredShelfSurface
        if needsSurfaceMigration {
            // Registration-domain defaults are process-wide, so a pristine
            // isolated UserDefaults suite can still appear to contain the
            // legacy `.classic` value after another SettingsStore is created.
            // An actual legacy Island choice still overrides that value, while
            // onboarding persistence identifies an established classic user.
            let isFreshInstall = !hadPersistedOnboardingVersion
                && legacyPresentationMode != .island
            if isFreshInstall {
                resolvedClassicShelfEnabled = true
                resolvedIslandEnabled = true
                resolvedIslandShelfEnabled = true
                resolvedPreferredSurface = .island
            } else {
                resolvedClassicShelfEnabled = legacyPresentationMode == .classic
                resolvedIslandEnabled = legacyPresentationMode == .island
                resolvedIslandShelfEnabled = true
                resolvedPreferredSurface = legacyPresentationMode == .island
                    ? .island : .classic
            }
        } else {
            resolvedClassicShelfEnabled = persistedClassicShelfEnabled
                ?? defaults.bool(forKey: Keys.classicShelfEnabled)
            resolvedIslandEnabled = persistedIslandEnabled
                ?? defaults.bool(forKey: Keys.islandEnabled)
            resolvedIslandShelfEnabled = persistedIslandShelfEnabled
                ?? defaults.bool(forKey: Keys.islandShelfEnabled)
            resolvedPreferredSurface = PreferredShelfSurface(
                rawValue: persistedPreferredSurface
                    ?? defaults.string(forKey: Keys.preferredShelfSurface)
                    ?? ""
            ) ?? .classic
        }
        classicShelfEnabled = resolvedClassicShelfEnabled
        islandEnabled = resolvedIslandEnabled
        islandDisplayTarget = IslandDisplayTarget(
            persistedValue: defaults.string(forKey: Keys.islandDisplayTarget)
        )
        islandShelfEnabled = resolvedIslandShelfEnabled
        preferredShelfSurface = resolvedPreferredSurface
        if needsSurfaceMigration {
            defaults.set(resolvedClassicShelfEnabled, forKey: Keys.classicShelfEnabled)
            defaults.set(resolvedIslandEnabled, forKey: Keys.islandEnabled)
            defaults.set(resolvedIslandShelfEnabled, forKey: Keys.islandShelfEnabled)
            defaults.set(resolvedPreferredSurface.rawValue,
                         forKey: Keys.preferredShelfSurface)
        }
        if persistedSurfaceSettingsVersion < 1 {
            defaults.set(1, forKey: Keys.shelfSurfaceSettingsVersion)
        }
        let resolvedIslandHoverRevealEnabled = defaults.bool(
            forKey: Keys.islandHoverRevealEnabled
        )
        let resolvedIslandTimerEnabled = defaults.bool(forKey: Keys.islandTimerEnabled)
        let resolvedIslandBatteryEnabled = defaults.bool(forKey: Keys.islandBatteryEnabled)
        let resolvedIslandFullChargeAlertEnabled = defaults.bool(
            forKey: Keys.islandFullChargeAlertEnabled
        )
        let resolvedIslandMediaEnabled = defaults.bool(forKey: Keys.islandMediaEnabled)
        islandHoverRevealEnabled = resolvedIslandHoverRevealEnabled
        islandTimerEnabled = resolvedIslandTimerEnabled
        islandBatteryEnabled = resolvedIslandBatteryEnabled
        islandFullChargeAlertEnabled = resolvedIslandFullChargeAlertEnabled
        islandMediaEnabled = resolvedIslandMediaEnabled
        let migratedModuleConfiguration = Self.migratedModuleConfiguration(
            existingInstallation: hadPersistedAppSettings,
            shelfEnabled: resolvedIslandShelfEnabled,
            timerEnabled: resolvedIslandTimerEnabled,
            batteryEnabled: resolvedIslandBatteryEnabled,
            mediaEnabled: resolvedIslandMediaEnabled
        )
        if let persistedModuleConfigurationData {
            do {
                var decoded = try JSONDecoder().decode(
                    IslandModuleConfiguration.self,
                    from: persistedModuleConfigurationData
                )
                decoded.normalize()
                islandModuleConfiguration = decoded
            } catch {
                islandModuleConfiguration = migratedModuleConfiguration
                if defaults.data(forKey: Keys.islandModuleConfigurationCorruptBackup) == nil {
                    defaults.set(persistedModuleConfigurationData,
                                 forKey: Keys.islandModuleConfigurationCorruptBackup)
                }
            }
        } else {
            islandModuleConfiguration = migratedModuleConfiguration
            if let encoded = try? JSONEncoder().encode(migratedModuleConfiguration) {
                defaults.set(encoded, forKey: Keys.islandModuleConfiguration)
            }
        }
        let resolvedClassicShelfHoverRevealEnabled =
            defaults.object(forKey: Keys.classicShelfHoverRevealEnabled) as? Bool
            ?? true
        classicShelfHoverRevealEnabled = resolvedClassicShelfHoverRevealEnabled
        if defaults.object(forKey: Keys.classicShelfHoverRevealEnabled) == nil {
            defaults.set(resolvedClassicShelfHoverRevealEnabled,
                         forKey: Keys.classicShelfHoverRevealEnabled)
        }
        shelfWidth = defaults.double(forKey: Keys.shelfWidth)
        shelfEdgeOffset = defaults.double(forKey: Keys.shelfEdgeOffset)
        edgeTabEnabled = defaults.bool(forKey: Keys.edgeTabEnabled)
        autoHide = defaults.bool(forKey: Keys.autoHide)
        autoHideWhenEmpty = defaults.bool(forKey: Keys.autoHideWhenEmpty)
        dragOutRemovalPolicy = DragOutRemovalPolicy(
            rawValue: defaults.string(forKey: Keys.dragOutRemovalPolicy) ?? ""
        ) ?? .keep
        language = LanguagePreference(rawValue: defaults.string(forKey: Keys.language) ?? "")
            ?? .system
        autoUpdateCheckEnabled = defaults.bool(forKey: Keys.autoUpdateCheckEnabled)
        onboardingVersion = defaults.object(forKey: Keys.onboardingVersion) as? Int ?? 0
        if let data = defaults.data(forKey: Keys.customShelfFrame) {
            // 解码失败视为无自定义位置（下次选 custom 从右缘默认起步）。
            customShelfFrame = try? JSONDecoder().decode(CGRect.self, from: data)
        } else {
            customShelfFrame = nil
        }
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyDoublePressSavesClipboard = defaults.bool(forKey: Keys.hotKeyDoublePressSavesClipboard)
        shakeTriggerEnabled = defaults.bool(forKey: Keys.shakeTriggerEnabled)
        edgeTriggerEnabled = defaults.bool(forKey: Keys.edgeTriggerEnabled)
        if let persistedDragMode {
            dragAutoAppearMode = DragAutoAppearMode(rawValue: persistedDragMode) ?? .edgeOnly
        } else if legacyEdgeTriggerEnabled {
            // 迁移：旧版悬停边缘触发开启 → 拖拽贴边唤出。
            dragAutoAppearMode = .edgeOnly
            defaults.set(DragAutoAppearMode.edgeOnly.rawValue, forKey: Keys.dragAutoAppearMode)
        } else {
            dragAutoAppearMode = .edgeOnly
        }
        shakeSensitivity = TriggerSensitivity(
            rawValue: defaults.string(forKey: Keys.shakeSensitivity) ?? ""
        ) ?? .medium
        edgeTriggerSensitivity = TriggerSensitivity(
            rawValue: defaults.string(forKey: Keys.edgeTriggerSensitivity) ?? ""
        ) ?? .medium
        if let data = defaults.data(forKey: Keys.hotKeyShortcut) {
            // 显式 do/catch 而非 `try? … ?? .default`：try? 会把
            // 「解码成功为 nil」（JSON null = 明确清除）与「解码失败」
            // 扁平化成同一个 nil（SE-0230），清除态会被吞掉。
            do {
                hotKeyShortcut = try JSONDecoder().decode(HotKeyShortcut?.self, from: data)
            } catch {
                hotKeyShortcut = .default
            }
        } else {
            hotKeyShortcut = .default
        }
        ignoredAppBundleIDs = defaults.stringArray(forKey: Keys.ignoredAppBundleIDs) ?? []
        // A valid primary configuration wins on every launch. Refresh the
        // one-release v1.5 shadow keys immediately, not only after the user
        // changes a module in this process.
        applyConfigurationToLegacyProperties()
    }

    private static func migratedModuleConfiguration(
        existingInstallation: Bool,
        shelfEnabled: Bool,
        timerEnabled: Bool,
        batteryEnabled: Bool,
        mediaEnabled: Bool
    ) -> IslandModuleConfiguration {
        if !existingInstallation {
            return IslandModuleConfiguration(
                enabledModuleIDs: [.shelf, .transfers, .timer, .battery, .system],
                pinnedModuleIDs: [.shelf, .timer, .system]
            )
        }

        var enabled: [IslandModuleID] = []
        if shelfEnabled { enabled.append(.shelf) }
        if mediaEnabled { enabled.append(.media) }
        enabled.append(.transfers)
        if timerEnabled { enabled.append(.timer) }
        if batteryEnabled { enabled.append(.battery) }
        return IslandModuleConfiguration(
            enabledModuleIDs: enabled,
            pinnedModuleIDs: Array(enabled.prefix(
                IslandModuleConfiguration.maximumPinnedModules
            ))
        )
    }

    private func syncModuleConfigurationFromLegacy(_ id: IslandModuleID,
                                                    enabled: Bool) {
        guard !isApplyingModuleConfiguration else { return }
        var configuration = islandModuleConfiguration
        configuration.setEnabled(enabled, for: id)
        islandModuleConfiguration = configuration
    }

    private func persistIslandModuleConfiguration() {
        guard let data = try? JSONEncoder().encode(islandModuleConfiguration) else { return }
        defaults.set(data, forKey: Keys.islandModuleConfiguration)
    }

    private func applyConfigurationToLegacyProperties() {
        guard !isApplyingModuleConfiguration else { return }
        isApplyingModuleConfiguration = true
        defer { isApplyingModuleConfiguration = false }
        islandShelfEnabled = islandModuleConfiguration.isEnabled(.shelf)
        islandTimerEnabled = islandModuleConfiguration.isEnabled(.timer)
        islandBatteryEnabled = islandModuleConfiguration.isEnabled(.battery)
        islandMediaEnabled = islandModuleConfiguration.isEnabled(.media)
    }
}
