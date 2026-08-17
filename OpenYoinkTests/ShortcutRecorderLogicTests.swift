import XCTest
@testable import OpenYoink

/// 快捷键录制控件（S8）的纯逻辑：组合校验（必须含 ⌘/⌥/⌃ 至少一个，
/// 拒绝裸键与仅 ⇧）、修饰键符号显示顺序（⌃⌥⇧⌘）、键名表。
final class ShortcutRecorderLogicTests: XCTestCase {
    // MARK: - Validation

    func testBareKey_isRejected() {
        XCTAssertNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: false,
                                                    shift: false, option: false,
                                                    control: false))
    }

    func testShiftOnly_isRejected() {
        XCTAssertNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: false,
                                                    shift: true, option: false,
                                                    control: false))
    }

    func testStrongModifiers_areAccepted() {
        XCTAssertNotNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: true,
                                                       shift: false, option: false,
                                                       control: false))
        XCTAssertNotNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: false,
                                                       shift: false, option: true,
                                                       control: false))
        XCTAssertNotNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: false,
                                                       shift: false, option: false,
                                                       control: true))
        XCTAssertNotNil(ShortcutRecorderLogic.shortcut(keyCode: 0, command: true,
                                                       shift: true, option: false,
                                                       control: false))
    }

    func testCapturedShortcut_carriesKeyCodeAndFlags() {
        let shortcut = ShortcutRecorderLogic.shortcut(keyCode: 8, command: true,
                                                      shift: false, option: true,
                                                      control: false)
        XCTAssertEqual(shortcut, SettingsStore.HotKeyShortcut(
            keyCode: 8, command: true, shift: false, option: true, control: false
        ))
    }

    // MARK: - Display string

    func testDefaultShortcut_displaysAsShiftCommandSpace() {
        XCTAssertEqual(ShortcutRecorderLogic.displayString(for: .default), "⇧⌘Space")
    }

    func testModifierSymbols_useConventionalOrder() {
        let all = SettingsStore.HotKeyShortcut(keyCode: 0, command: true,
                                               shift: true, option: true, control: true)
        XCTAssertEqual(ShortcutRecorderLogic.displayString(for: all), "⌃⌥⇧⌘A")
    }

    func testDisplayString_omitsUnsetModifiers() {
        let optionOnly = SettingsStore.HotKeyShortcut(keyCode: 49, command: false,
                                                      shift: false, option: true, control: false)
        XCTAssertEqual(ShortcutRecorderLogic.displayString(for: optionOnly), "⌥Space")
    }

    // MARK: - Key names

    func testKeyName_knownCodes() {
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 49), "Space")
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 36), "↩")
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 123), "←")
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 0), "A")
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 122), "F1")
    }

    func testKeyName_unknownCodeFallsBackToNumberedName() {
        XCTAssertEqual(ShortcutRecorderLogic.keyName(forKeyCode: 250), "Key 250")
    }
}
