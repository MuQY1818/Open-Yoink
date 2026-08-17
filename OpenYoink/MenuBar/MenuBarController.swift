import AppKit

/// 菜单栏入口：NSStatusItem + NSMenu。
///
/// 菜单含「Show/Hide Shelf」（勾选项跟随 `AppState.isShelfVisible`）、
/// 「Settings…」（S8 起打开 SwiftUI Settings scene）、「Quit OpenYoink」。
/// 菜单文本暂为英文原文，S10 统一提取到 Localizable.xcstrings。
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let onToggleShelf: () -> Void

    private let statusItem: NSStatusItem
    private let toggleItem = NSMenuItem()

    init(appState: AppState, onToggleShelf: @escaping () -> Void) {
        self.appState = appState
        self.onToggleShelf = onToggleShelf
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                            accessibilityDescription: "OpenYoink")
        image?.isTemplate = true
        button.image = image
    }

    private func configureMenu() {
        let menu = NSMenu()

        toggleItem.action = #selector(toggleShelf(_:))
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // S8: 打开 SwiftUI Settings scene（见 showSettings(_:)）。
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit OpenYoink",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleShelf(_ sender: NSMenuItem) {
        onToggleShelf()
    }

    /// S8: 打开 SwiftUI Settings scene 的窗口。
    ///
    /// LSUIElement 下的焦点处理：后台 agent 平时处于非活跃状态，
    /// `showSettingsWindow:` 只负责创建并前置窗口，不会把应用激活——
    /// 必须随后 `NSApp.activate(ignoringOtherApps:)`，否则设置窗口可能
    /// 停在原前台应用窗口之后、拿不到键盘焦点（录制快捷键等交互失效）。
    @objc private func showSettings(_ sender: Any?) {
        NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// 每次打开菜单时刷新勾选项与标题，使其跟随 shelf 实际可见性。
    func menuWillOpen(_ menu: NSMenu) {
        let isVisible = appState.isShelfVisible
        toggleItem.title = isVisible ? "Hide Shelf" : "Show Shelf"
        toggleItem.state = isVisible ? .on : .off
    }
}
