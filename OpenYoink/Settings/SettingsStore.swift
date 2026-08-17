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

    /// Screen edge the shelf attaches to.
    enum ShelfPosition: String, CaseIterable, Sendable {
        case left, right
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

    /// What happens after an item is dragged out. Default: keep.
    var dragOutRemovalPolicy: DragOutRemovalPolicy {
        didSet { defaults.set(dragOutRemovalPolicy.rawValue, forKey: Keys.dragOutRemovalPolicy) }
    }

    /// UI language override. Default: system.
    var language: LanguagePreference {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
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
    var edgeTriggerEnabled: Bool {
        didSet { defaults.set(edgeTriggerEnabled, forKey: Keys.edgeTriggerEnabled) }
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
        static let autoHide = prefix + "autoHide"
        static let dragOutRemovalPolicy = prefix + "dragOutRemovalPolicy"
        static let language = prefix + "language"
        static let hotKeyEnabled = prefix + "hotKeyEnabled"
        static let shakeTriggerEnabled = prefix + "shakeTriggerEnabled"
        static let edgeTriggerEnabled = prefix + "edgeTriggerEnabled"
        static let shakeSensitivity = prefix + "shakeSensitivity"
        static let edgeTriggerSensitivity = prefix + "edgeTriggerSensitivity"
        static let hotKeyShortcut = prefix + "hotKeyShortcut"
        static let ignoredAppBundleIDs = prefix + "ignoredAppBundleIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.shelfPosition: ShelfPosition.right.rawValue,
            Keys.shelfWidth: 320.0,
            Keys.autoHide: false,
            Keys.dragOutRemovalPolicy: DragOutRemovalPolicy.keep.rawValue,
            Keys.language: LanguagePreference.system.rawValue,
            Keys.hotKeyEnabled: true,
            Keys.shakeTriggerEnabled: false,
            Keys.edgeTriggerEnabled: false,
            Keys.shakeSensitivity: TriggerSensitivity.medium.rawValue,
            Keys.edgeTriggerSensitivity: TriggerSensitivity.medium.rawValue,
            Keys.ignoredAppBundleIDs: [String](),
        ])

        shelfPosition = ShelfPosition(rawValue: defaults.string(forKey: Keys.shelfPosition) ?? "")
            ?? .right
        shelfWidth = defaults.double(forKey: Keys.shelfWidth)
        autoHide = defaults.bool(forKey: Keys.autoHide)
        dragOutRemovalPolicy = DragOutRemovalPolicy(
            rawValue: defaults.string(forKey: Keys.dragOutRemovalPolicy) ?? ""
        ) ?? .keep
        language = LanguagePreference(rawValue: defaults.string(forKey: Keys.language) ?? "")
            ?? .system
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        shakeTriggerEnabled = defaults.bool(forKey: Keys.shakeTriggerEnabled)
        edgeTriggerEnabled = defaults.bool(forKey: Keys.edgeTriggerEnabled)
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
