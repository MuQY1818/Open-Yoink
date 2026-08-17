import Foundation

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

    /// EdgeTab: vertical placement of the shelf (and its edge tab) along the
    /// attached edge — 0 pins to the bottom of the visible area, 1 to the top.
    /// Default: 0.5 (vertically centered, matching the pre-EdgeTab look).
    /// No "unset" state needs distinguishing, so it lives in register(defaults:).
    var shelfEdgeOffset: Double {
        didSet { defaults.set(shelfEdgeOffset, forKey: Keys.shelfEdgeOffset) }
    }

    /// EdgeTab: show the edge tab on the shelf's screen edge while the shelf
    /// is hidden. Default: true. Only meaningful for left/right positions —
    /// custom placement has no attachment edge, so no tab is shown.
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

    /// UX1: drag-triggered shelf appearance. Default: `.immediate`.
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

    private enum Keys {
        private static let prefix = "OpenYoink."
        static let shelfPosition = prefix + "shelfPosition"
        static let shelfWidth = prefix + "shelfWidth"
        static let shelfEdgeOffset = prefix + "shelfEdgeOffset"
        static let edgeTabEnabled = prefix + "edgeTabEnabled"
        static let autoHide = prefix + "autoHide"
        static let autoHideWhenEmpty = prefix + "autoHideWhenEmpty"
        static let dragOutRemovalPolicy = prefix + "dragOutRemovalPolicy"
        static let language = prefix + "language"
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
        // UX1 迁移必须在注册默认值之前读取：注册域会让「从未设置」与
        // 「显式存过 immediate」无法区分（且 NSRegistrationDomain 进程内
        // 共享，跨 UserDefaults 实例可见）。旧版布尔 edgeTriggerEnabled（悬停
        // 触发开关）为开且从未持久化过 dragAutoAppearMode → 迁移为
        // .edgeOnly（最接近旧意图的贴边唤出），并立即落盘让 UI 反映。
        // 注意：dragAutoAppearMode 因此刻意不进 register(defaults:) ——
        // 一旦注册，nil 判定即失效，迁移会永远不会发生。
        let legacyEdgeTriggerEnabled = defaults.bool(forKey: Keys.edgeTriggerEnabled)
        let persistedDragMode = defaults.string(forKey: Keys.dragAutoAppearMode)
        defaults.register(defaults: [
            Keys.shelfPosition: ShelfPosition.right.rawValue,
            Keys.shelfWidth: 320.0,
            Keys.shelfEdgeOffset: 0.5,
            Keys.edgeTabEnabled: true,
            Keys.autoHide: false,
            Keys.autoHideWhenEmpty: true,
            Keys.dragOutRemovalPolicy: DragOutRemovalPolicy.keep.rawValue,
            Keys.language: LanguagePreference.system.rawValue,
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
            dragAutoAppearMode = DragAutoAppearMode(rawValue: persistedDragMode) ?? .immediate
        } else if legacyEdgeTriggerEnabled {
            // 迁移：旧版悬停边缘触发开启 → 拖拽贴边唤出。
            dragAutoAppearMode = .edgeOnly
            defaults.set(DragAutoAppearMode.edgeOnly.rawValue, forKey: Keys.dragAutoAppearMode)
        } else {
            dragAutoAppearMode = .immediate
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
    }
}
