import Foundation

/// UserDefaults-backed app settings, observable by SwiftUI.
///
/// All keys are prefixed with `OpenYoink.` to avoid collisions. Defaults are
/// registered on init, so reads always return meaningful values. Settings UI is
/// built in S8; trigger settings are placeholders wired up in S7.
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
        case ask    // placeholder: ask every time (UI wired in S8)
    }

    /// UI language override.
    enum LanguagePreference: String, CaseIterable, Sendable {
        case system, chinese, english
    }

    /// Codable description of the global toggle hot key. Placeholder
    /// representation for S7/S8: `ShortcutRecorderView` writes new values,
    /// `HotKeyMonitor` maps them to `NSEvent`/Carbon modifiers.
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

    // MARK: - Triggers (placeholders, wired in S7/S8)

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

    /// Shake sensitivity, 0...1; higher = triggers more easily. Default: 0.5.
    var shakeSensitivity: Double {
        didSet { defaults.set(shakeSensitivity, forKey: Keys.shakeSensitivity) }
    }

    /// Edge-trigger sensitivity, 0...1; higher = shorter dwell time. Default: 0.5.
    var edgeTriggerSensitivity: Double {
        didSet { defaults.set(edgeTriggerSensitivity, forKey: Keys.edgeTriggerSensitivity) }
    }

    /// The toggle hot key. Persisted as JSON.
    var hotKeyShortcut: HotKeyShortcut {
        didSet {
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
            Keys.shakeSensitivity: 0.5,
            Keys.edgeTriggerSensitivity: 0.5,
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
        shakeSensitivity = defaults.double(forKey: Keys.shakeSensitivity)
        edgeTriggerSensitivity = defaults.double(forKey: Keys.edgeTriggerSensitivity)
        hotKeyShortcut = defaults.data(forKey: Keys.hotKeyShortcut)
            .flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) }
            ?? .default
        ignoredAppBundleIDs = defaults.stringArray(forKey: Keys.ignoredAppBundleIDs) ?? []
    }
}
