import AppKit
import Carbon
import OSLog

/// Global hot key monitor (S7): toggles the shelf from any app.
///
/// Backend choice (deviates deliberately from plan §2.3's "NSEvent first"):
/// - **Carbon `RegisterEventHotKey` — primary.** Needs no Accessibility
///   permission, the registration result is programmatically detectable
///   (`eventHotKeyExistsErr` on conflict), and the hot key is consumed by the
///   system so the foreground app never sees it.
/// - **`NSEvent` global monitor — best-effort fallback.** Registration always
///   "succeeds"; whether events actually arrive cannot be probed, and the
///   event cannot be consumed, so ⌘⇧Space would also reach the foreground
///   app. Used only when Carbon registration fails.
///
/// Registration state (`isActive` / `activeBackend` / `registrationError`) is
/// observable so the S8 settings page can surface conflicts.
@MainActor
@Observable
final class HotKeyMonitor {
    /// Event backend currently delivering the hot key.
    enum Backend: String, Sendable {
        case carbon, nsEvent
    }

    /// Whether a backend is actively listening.
    private(set) var isActive = false
    /// Backend in use while `isActive` is true.
    private(set) var activeBackend: Backend?
    /// Human-readable registration failure (e.g. shortcut conflict), for the
    /// settings page. Nil when Carbon registration succeeded or the monitor
    /// is disabled.
    private(set) var registrationError: String?

    private var shortcut: SettingsStore.HotKeyShortcut?
    private let actionBox: HotKeyActionBox
    private var enabled = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerUserData: UnsafeMutableRawPointer?
    private var nsEventMonitor: Any?

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "HotKey")

    /// Four-character signature for our hot key IDs ('OYHK').
    private nonisolated static let hotKeySignature = OSType(0x4F59_484B)

    init(shortcut: SettingsStore.HotKeyShortcut? = .default,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.actionBox = HotKeyActionBox(action)
    }

    // MARK: - Lifecycle

    /// Enables/disables the monitor. No-op when the state doesn't change.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            register()
        } else {
            unregister()
            registrationError = nil
        }
    }

    /// Hot-updates the shortcut; re-registers immediately when enabled.
    /// A nil shortcut (cleared in the S8 recorder) unregisters and stays
    /// inactive until a new shortcut is recorded.
    func updateShortcut(_ shortcut: SettingsStore.HotKeyShortcut?) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        if enabled {
            register()
        }
    }

    // MARK: - Registration

    private func register() {
        unregister()
        guard let shortcut else {
            // Cleared shortcut: no registration, but no error either — the
            // settings page shows "Not Set" instead of a conflict banner.
            registrationError = nil
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         Self.carbonModifiers(for: shortcut),
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            logger.warning("RegisterEventHotKey failed with OSStatus \(status); falling back to NSEvent global monitor")
            registrationError = "Hot key registration failed (OSStatus \(status)); another app may already hold this shortcut."
            installNSEventFallback()
            return
        }
        hotKeyRef = ref
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(actionBox).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(),
                                         Self.carbonEventHandler,
                                         1,
                                         &eventType,
                                         userData,
                                         &ref)
        guard status == noErr, let ref else {
            Unmanaged<HotKeyActionBox>.fromOpaque(userData).release()
            logger.error("InstallEventHandler failed with OSStatus \(status)")
            registrationError = "Hot key event handler installation failed (OSStatus \(status))."
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                self.hotKeyRef = nil
            }
            installNSEventFallback()
            return
        }
        handlerRef = ref
        handlerUserData = userData
        isActive = true
        activeBackend = .carbon
        registrationError = nil
    }

    /// Best-effort fallback when Carbon registration fails. Note: an NSEvent
    /// global monitor cannot be probed for actual delivery and cannot consume
    /// the event — the foreground app still receives the key combination.
    private func installNSEventFallback() {
        guard let shortcut else { return }
        let actionBox = self.actionBox
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard HotKeyMonitor.matches(event, shortcut: shortcut) else { return }
            Task { @MainActor in
                actionBox.action()
            }
        }
        if nsEventMonitor != nil {
            isActive = true
            activeBackend = .nsEvent
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let handlerUserData {
            Unmanaged<HotKeyActionBox>.fromOpaque(handlerUserData).release()
            self.handlerUserData = nil
        }
        if let nsEventMonitor {
            NSEvent.removeMonitor(nsEventMonitor)
            self.nsEventMonitor = nil
        }
        isActive = false
        activeBackend = nil
    }

    // MARK: - Matching & modifier mapping (pure, unit-testable)

    /// Carbon event callback. Only our own hot key is ever registered with
    /// this handler, so any delivery is ours. The callback is a plain C
    /// function without actor isolation; the action hops to the MainActor
    /// explicitly instead of assuming a thread.
    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let box = Unmanaged<HotKeyActionBox>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            box.action()
        }
        return noErr
    }

    /// Maps the persisted shortcut to Carbon modifier bits (`cmdKey` etc.).
    nonisolated static func carbonModifiers(for shortcut: SettingsStore.HotKeyShortcut) -> UInt32 {
        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// Exact match on key code + device-independent modifiers (NSEvent
    /// fallback path only; the Carbon path matches by registration).
    nonisolated static func matches(_ event: NSEvent,
                                    shortcut: SettingsStore.HotKeyShortcut) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var expected: NSEvent.ModifierFlags = []
        if shortcut.command { expected.insert(.command) }
        if shortcut.shift { expected.insert(.shift) }
        if shortcut.option { expected.insert(.option) }
        if shortcut.control { expected.insert(.control) }
        return flags == expected && UInt32(event.keyCode) == shortcut.keyCode
    }
}

/// `Sendable` box around the trigger action so the Carbon C callback (no
/// actor isolation) can reach the MainActor without capturing the monitor.
/// Immutable after creation; reference lifetime is managed explicitly via
/// `Unmanaged` across install/remove of the event handler.
private final class HotKeyActionBox: @unchecked Sendable {
    let action: @MainActor @Sendable () -> Void

    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }
}
