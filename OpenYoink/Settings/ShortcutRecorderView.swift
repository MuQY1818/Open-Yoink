import AppKit
import SwiftUI

/// Pure capture/format logic behind `ShortcutRecorderView`, split out for
/// headless unit tests (the view/controller layer needs a key window and a
/// running event loop).
enum ShortcutRecorderLogic {
    /// Virtual key codes with special recorder semantics.
    nonisolated static let escapeKeyCode: UInt32 = 53
    nonisolated static let deleteKeyCode: UInt32 = 51
    nonisolated static let forwardDeleteKeyCode: UInt32 = 117

    /// Builds a shortcut from a captured keyDown, or returns nil when the
    /// combination is not usable as a global hot key (see `isValid`).
    nonisolated static func shortcut(keyCode: UInt32,
                                     command: Bool,
                                     shift: Bool,
                                     option: Bool,
                                     control: Bool) -> SettingsStore.HotKeyShortcut? {
        let shortcut = SettingsStore.HotKeyShortcut(keyCode: keyCode,
                                                    command: command,
                                                    shift: shift,
                                                    option: option,
                                                    control: control)
        return isValid(shortcut) ? shortcut : nil
    }

    /// A global hot key needs at least one "strong" modifier (⌘/⌥/⌃). A bare
    /// key would fire on every keystroke in every app; ⇧+letter is plain
    /// typing, not a shortcut.
    nonisolated static func isValid(_ shortcut: SettingsStore.HotKeyShortcut) -> Bool {
        shortcut.command || shortcut.option || shortcut.control
    }

    /// Symbol string with the conventional modifier order ⌃⌥⇧⌘ + key name
    /// (e.g. "⇧⌘Space").
    nonisolated static func displayString(for shortcut: SettingsStore.HotKeyShortcut) -> String {
        var result = ""
        if shortcut.control { result += "⌃" }
        if shortcut.option { result += "⌥" }
        if shortcut.shift { result += "⇧" }
        if shortcut.command { result += "⌘" }
        result += keyName(forKeyCode: shortcut.keyCode)
        return result
    }

    /// Human-readable name for a hardware-independent virtual key code
    /// (kVK_* table + symbolic names for non-printing keys).
    nonisolated static func keyName(forKeyCode keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private nonisolated static let keyNames: [UInt32: String] = [
        // ANSI letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        // ANSI digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
        // Whitespace / editing
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        // Arrows & navigation
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]
}

/// Recording state machine for `ShortcutRecorderView`. While recording, a
/// local keyDown monitor captures the next combination: Esc cancels (keeps
/// the previous shortcut), Delete/Forward Delete clears (nil), any other
/// valid combination is saved. All keyDowns are consumed while recording so
/// nothing leaks into the settings window's other controls.
///
/// 本地监听足够且必须：录制时设置窗口是 key window，keyDown 必达本应用；
/// 全局监听无法消费事件，按键会漏到其他应用。
@MainActor
@Observable
final class ShortcutRecorderController {
    private(set) var isRecording = false

    /// Receives the captured shortcut, or nil when cleared. Set by the view.
    var onCapture: ((SettingsStore.HotKeyShortcut?) -> Void)?

    private var monitor: Any?

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording, monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Consume every keyDown while recording; dispatch async so the
            // monitor handler stays a pure, non-isolated passthrough.
            Task { @MainActor in
                self.handleKeyDown(keyCode: keyCode, flags: flags)
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func handleKeyDown(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        switch keyCode {
        case ShortcutRecorderLogic.escapeKeyCode:
            stopRecording()
        case ShortcutRecorderLogic.deleteKeyCode, ShortcutRecorderLogic.forwardDeleteKeyCode:
            onCapture?(nil)
            stopRecording()
        default:
            guard let shortcut = ShortcutRecorderLogic.shortcut(
                keyCode: keyCode,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.option),
                control: flags.contains(.control)
            ) else {
                // Bare key / ⇧-only: not a usable global hot key, keep recording.
                return
            }
            onCapture?(shortcut)
            stopRecording()
        }
    }
}

/// Lightweight shortcut recorder (S8): shows the current combination with
/// modifier symbols; click to re-record. Visual states: idle capsule,
/// accent-tinted pulsing capsule while recording.
struct ShortcutRecorderView: View {
    @Binding var shortcut: SettingsStore.HotKeyShortcut?

    @State private var controller = ShortcutRecorderController()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { controller.toggleRecording() }) {
                Text(buttonTitle)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(controller.isRecording
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.primary.opacity(0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(controller.isRecording
                                          ? Color.accentColor
                                          : Color.primary.opacity(0.15),
                                          lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Global hot key recorder")

            if controller.isRecording {
                Text("Type a shortcut · Esc cancels · ⌫ clears")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            controller.onCapture = { shortcut = $0 }
        }
        .onDisappear {
            controller.stopRecording()
        }
    }

    private var buttonTitle: String {
        if controller.isRecording { return "Press shortcut…" }
        if let shortcut { return ShortcutRecorderLogic.displayString(for: shortcut) }
        return "Not Set — Click to Record"
    }
}
