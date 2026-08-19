import AppKit
import Carbon
import OSLog

/// UX3 热键单击/双击判别（纯逻辑，与 AppKit 解耦供单测）：
/// 首次按下进入「待确认单击」；识别窗内第二次按下成立双击（单击作废）；
/// 窗外第二次按下视为新一轮首次。超时由调用方（HotKeyMonitor 的延迟任务）
/// 经 `confirmPending()` 确认单击成立。
struct DoublePressDiscriminator: Sendable, Equatable {
    /// 一次按下的判定结果。
    enum PressResult: Sendable, Equatable {
        /// 首次按下：等待窗内第二次按下（调用方启动 window 时长的计时）。
        case firstPressPending
        /// 窗内第二次按下：双击成立。
        case doublePress
    }

    /// 双击识别窗（秒）。约 0.3s —— 与系统双击间隔同量级。
    let window: TimeInterval
    /// 是否有待确认的单击（延迟任务到期时据此决定单击是否成立）。
    private(set) var hasPending = false
    private var lastPressTime: TimeInterval?

    init(window: TimeInterval) {
        self.window = window
    }

    /// 记录一次按下（`time` 为单调时钟，如 ProcessInfo.systemUptime）。
    mutating func press(at time: TimeInterval) -> PressResult {
        if hasPending, let lastPressTime, time - lastPressTime <= window {
            hasPending = false
            self.lastPressTime = nil
            return .doublePress
        }
        hasPending = true
        lastPressTime = time
        return .firstPressPending
    }

    /// 延迟任务到期确认单击；复位待确认状态。
    mutating func confirmPending() {
        hasPending = false
        lastPressTime = nil
    }

    /// 丢弃待确认单击（停用/重注册时调用，作废未到期的延迟任务语义）。
    mutating func reset() {
        hasPending = false
        lastPressTime = nil
    }
}

/// Global hot key monitor (S7): toggles the shelf from any app.
/// UX3: 单击 = toggle；双击（识别窗内第二次按下）= 保存剪贴板到 shelf，
/// 判别核心 `DoublePressDiscriminator` 为纯类型（见本文件顶部）。
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
    /// 首次注册时才构造（`requireActionBox()`）——闭包需弱引用 self 经实例
    /// 方法 handlePress 仲裁单击/双击，无法在 init 中捕获（self 未完全
    /// 初始化），而 @Observable 宏又不允许 lazy 属性，故改为按需构造。
    private var actionBox: HotKeyActionBox?
    private var enabled = false

    /// UX3: 单击动作（toggle shelf）。
    private let onPress: @MainActor @Sendable () -> Void
    /// UX3: 双击动作（保存剪贴板到 shelf）。
    private let onDoublePress: @MainActor @Sendable () -> Void
    /// UX3: 双击识别开关（设置 `hotKeyDoublePressSavesClipboard` 同步）。
    /// 关闭时单击零延迟直发。
    private var doublePressEnabled = false
    private var discriminator: DoublePressDiscriminator
    /// 延迟单击任务的代际戳：每次按下/作废自增，到期任务据此识别自己是否
    /// 已被更新的按下取代（避免已成立的双击之后又补发一次单击）。
    private var pressGeneration: UInt64 = 0

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerUserData: UnsafeMutableRawPointer?
    private var nsEventMonitor: Any?

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "HotKey")

    /// Four-character signature for our hot key IDs ('OYHK').
    private nonisolated static let hotKeySignature = OSType(0x4F59_484B)

    init(shortcut: SettingsStore.HotKeyShortcut? = .default,
         doublePressWindow: TimeInterval = 0.3,
         onPress: @escaping @MainActor @Sendable () -> Void,
         onDoublePress: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.onPress = onPress
        self.onDoublePress = onDoublePress
        self.discriminator = DoublePressDiscriminator(window: doublePressWindow)
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

    /// UX3: 同步双击识别开关（`SettingsStore.hotKeyDoublePressSavesClipboard`）。
    func setDoublePressEnabled(_ enabled: Bool) {
        guard enabled != doublePressEnabled else { return }
        doublePressEnabled = enabled
        // 设置切换时作废旧模式留下的延迟单击。否则在识别窗内关闭双击后，
        // 下一次按键会立即触发，旧任务随后又补发一次，造成 shelf 连续切换。
        pressGeneration &+= 1
        discriminator.reset()
    }

    /// UX3: 按下统一入口（Carbon 处理器与 NSEvent 兜底都经 actionBox 路由到
    /// 这里）。双击识别开启时单击延迟一个识别窗发出；关闭时零延迟直发。
    private func handlePress() {
        guard doublePressEnabled else {
            onPress()
            return
        }
        switch discriminator.press(at: ProcessInfo.processInfo.systemUptime) {
        case .doublePress:
            // 作废弃用的单击延迟任务（代际戳失效），直发双击。
            pressGeneration &+= 1
            onDoublePress()
        case .firstPressPending:
            pressGeneration &+= 1
            let generation = pressGeneration
            let window = discriminator.window
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(window * 1000)))
                guard let self, !Task.isCancelled else { return }
                // 窗内已有第二次按下（双击成立，代际戳已失效）或状态被
                // reset → 不补发单击。
                guard self.discriminator.hasPending, self.pressGeneration == generation else { return }
                self.discriminator.confirmPending()
                self.onPress()
            }
        }
    }

    // MARK: - Registration

    /// 返回共享的动作 box（不存在则构造）。Carbon 处理器经 `Unmanaged`
    /// passRetained/balanced-release 持有它；重复注册复用同一实例，
    /// retain/release 逐次平衡。
    private func requireActionBox() -> HotKeyActionBox {
        if let actionBox { return actionBox }
        let box = HotKeyActionBox { [weak self] in
            self?.handlePress()
        }
        actionBox = box
        return box
    }

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
            registrationError = String(localized: "Hot key registration failed (OSStatus \(status)); another app may already hold this shortcut.")
            installNSEventFallback()
            return
        }
        hotKeyRef = ref
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(requireActionBox()).toOpaque()
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
            registrationError = String(localized: "Hot key event handler installation failed (OSStatus \(status)).")
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
        let actionBox = requireActionBox()
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
        // UX3: 作废待确认单击与未到期延迟任务（停用/重注册时识别状态清零）。
        pressGeneration &+= 1
        discriminator.reset()
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
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flags.subtract([.capsLock, .function, .numericPad])
        var expected: NSEvent.ModifierFlags = []
        if shortcut.command { expected.insert(.command) }
        if shortcut.shift { expected.insert(.shift) }
        if shortcut.option { expected.insert(.option) }
        if shortcut.control { expected.insert(.control) }
        return flags == expected && UInt32(event.keyCode) == shortcut.keyCode
    }
}

/// `Sendable` box around the press route so the Carbon C callback (no actor
/// isolation) can reach the MainActor without strongly capturing the monitor
/// （UX3 起路由闭包经 `weak self` 调用 `handlePress` 仲裁单击/双击）.
/// Immutable after creation; reference lifetime is managed explicitly via
/// `Unmanaged` across install/remove of the event handler.
private final class HotKeyActionBox: @unchecked Sendable {
    let action: @MainActor @Sendable () -> Void

    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }
}
