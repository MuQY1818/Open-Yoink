import Carbon
import XCTest
@testable import OpenYoink

/// HotKeyMonitor 的纯逻辑：快捷键 → Carbon 修饰键位映射。
/// （Carbon RegisterEventHotKey 注册与 NSEvent 全局事件分发依赖运行中的
/// WindowServer / 应用事件循环，无法无头单测；见 HotKeyMonitor 文档注释。）
final class HotKeyMonitorTests: XCTestCase {
    private func shortcut(keyCode: UInt32 = 49,
                          command: Bool = false,
                          shift: Bool = false,
                          option: Bool = false,
                          control: Bool = false) -> SettingsStore.HotKeyShortcut {
        SettingsStore.HotKeyShortcut(keyCode: keyCode, command: command,
                                     shift: shift, option: option, control: control)
    }

    func testDefaultShortcut_mapsToCommandShift() {
        let modifiers = HotKeyMonitor.carbonModifiers(for: .default)
        XCTAssertEqual(modifiers, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testNoModifiers_mapsToZero() {
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut()), 0)
    }

    func testEachModifierMapsToItsOwnBit() {
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(command: true)), UInt32(cmdKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(shift: true)), UInt32(shiftKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(option: true)), UInt32(optionKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(control: true)), UInt32(controlKey))
    }

    func testAllModifiersCombine() {
        let modifiers = HotKeyMonitor.carbonModifiers(
            for: shortcut(command: true, shift: true, option: true, control: true)
        )
        XCTAssertEqual(modifiers,
                       UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey))
    }
}
