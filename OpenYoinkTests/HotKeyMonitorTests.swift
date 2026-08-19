import AppKit
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

    func testMatchesIgnoresIncidentalKeyboardFlagsButRequiresExactShortcutModifiers() throws {
        let expected = shortcut(keyCode: 8, command: true, option: true)
        let matching = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .capsLock, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let missingOption = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertTrue(HotKeyMonitor.matches(matching, shortcut: expected))
        XCTAssertFalse(HotKeyMonitor.matches(missingOption, shortcut: expected))
    }

    // MARK: - UX3 DoublePressDiscriminator

    func testDoublePress_secondPressInsideWindow_isDouble() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 10.0), .firstPressPending)
        XCTAssertTrue(discriminator.hasPending)
        XCTAssertEqual(discriminator.press(at: 10.25), .doublePress)
        XCTAssertFalse(discriminator.hasPending)
    }

    func testDoublePress_secondPressOutsideWindow_startsNewPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 10.0), .firstPressPending)
        // 窗外第二次按下 → 不是双击，而是新一轮待确认单击。
        XCTAssertEqual(discriminator.press(at: 10.5), .firstPressPending)
        XCTAssertTrue(discriminator.hasPending)
    }

    func testDoublePress_exactWindowBoundary_countsAsDouble() {
        // 边界值取可精确表示的二进制小数（0.5/1.5），避免 0.3 这类浮点
        // 误差淹没「恰好等于窗口」的判定（判别器用 <= window）。
        var discriminator = DoublePressDiscriminator(window: 0.5)
        XCTAssertEqual(discriminator.press(at: 1.0), .firstPressPending)
        XCTAssertEqual(discriminator.press(at: 1.5), .doublePress)
    }

    func testDoublePress_confirmedSingle_rearmsForNextPress() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 1.0), .firstPressPending)
        discriminator.confirmPending() // 延迟任务到期：单击成立
        XCTAssertFalse(discriminator.hasPending)
        // 下一次按下是新的首次（与上次单击无关）。
        XCTAssertEqual(discriminator.press(at: 1.2), .firstPressPending)
    }

    func testDoublePress_triplePressIsDoublePlusPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 0.0), .firstPressPending)
        XCTAssertEqual(discriminator.press(at: 0.2), .doublePress)
        // 三连击的第三下：重新进入待确认（等待可能的第四下）。
        XCTAssertEqual(discriminator.press(at: 0.4), .firstPressPending)
    }

    func testDoublePress_resetDiscardsPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 0.0), .firstPressPending)
        discriminator.reset()
        XCTAssertFalse(discriminator.hasPending)
        XCTAssertEqual(discriminator.press(at: 0.1), .firstPressPending)
    }
}
