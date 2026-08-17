import AppKit

/// 菜单栏入口：NSStatusItem + NSMenu。
///
/// 菜单含「Show/Hide Shelf」（勾选项跟随 `AppState.isShelfVisible`）、
/// 「Recent Items」最近拖出子菜单（S10，读 `RecentItemsService`）、
/// 「Settings…」（S8 起打开 SwiftUI Settings scene）、「Quit OpenYoink」。
/// 用户可见字符串经 `String(localized:)` 走 Localizable.xcstrings（S10）。
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let recents: RecentItemsService
    private let onToggleShelf: () -> Void
    /// S10: 最近项目重新入架（条目构造在 AppDelegate，那里持有 shelfStore）。
    private let onReaddRecent: (RecentEntry) -> Void

    private let statusItem: NSStatusItem
    private let toggleItem = NSMenuItem()
    /// 「Recent Items」父项；子菜单每次打开菜单时重建（entries 随拖出变化）。
    private let recentParentItem = NSMenuItem()

    init(appState: AppState,
         recents: RecentItemsService,
         onToggleShelf: @escaping () -> Void,
         onReaddRecent: @escaping (RecentEntry) -> Void) {
        self.appState = appState
        self.recents = recents
        self.onToggleShelf = onToggleShelf
        self.onReaddRecent = onReaddRecent
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // SF Symbol template 渲染：isTemplate 让系统按菜单栏状态自动反色，
        // 深浅色菜单栏与选中高亮下均正确（S10 确认保持符号方案）。
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

        // S10: 最近拖出历史子菜单（每次打开重建，见 rebuildRecentSubmenu）。
        recentParentItem.title = String(localized: "Recent Items")
        recentParentItem.submenu = NSMenu()
        menu.addItem(recentParentItem)

        menu.addItem(.separator())

        // S8: 打开 SwiftUI Settings scene（见 showSettings(_:)）。
        let settingsItem = NSMenuItem(title: String(localized: "Settings…"),
                                      action: #selector(showSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit OpenYoink"),
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
        // Selector(("..."))：括号抑制「未声明的 Objective-C selector」编译警告
        //（该 action 由 SwiftUI Settings scene 在响应链上提供，静态不可见）。
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recent Items submenu (S10)

    /// 重建最近项目子菜单：最新在前（上限 20 由 RecentItemsService 保证），
    /// 条目带种类图标；文件不可访问/无法忠实恢复（text 摘要）的条目置灰；
    /// 尾部「Clear Recent」清空历史。
    private func rebuildRecentSubmenu() {
        guard let submenu = recentParentItem.submenu else { return }
        submenu.removeAllItems()
        let entries = recents.entries
        guard !entries.isEmpty else {
            let emptyItem = NSMenuItem(title: String(localized: "No Recent Items"),
                                       action: nil,
                                       keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.displayName,
                                  action: #selector(readdRecent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.image = Self.menuIcon(for: entry)
            item.isEnabled = Self.canReadd(entry)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clearItem = NSMenuItem(title: String(localized: "Clear Recent"),
                                   action: #selector(clearRecent(_:)),
                                   keyEquivalent: "")
        clearItem.target = self
        submenu.addItem(clearItem)
    }

    /// 重新入架可行性：文件类要求路径仍可读（沙箱下无访问权即置灰）；
    /// URL 要求可解析；text 仅存 100 字符摘要、stack 拖出时已展开为子项，
    /// 二者无法忠实恢复，置灰。
    nonisolated static func canReadd(_ entry: RecentEntry) -> Bool {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return false }
            return FileManager.default.isReadableFile(atPath: path)
        case .url:
            return entry.urlString.flatMap(URL.init(string:)) != nil
        case .text, .stack:
            return false
        }
    }

    /// 子菜单条目 16pt 图标：文件类用 NSWorkspace 图标，其余用 SF Symbol。
    private static func menuIcon(for entry: RecentEntry) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let image: NSImage?
        if let path = entry.path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let symbolName = switch entry.kind {
            case .file: "doc"
            case .folder: "folder"
            case .image: "photo"
            case .text: "doc.text"
            case .url: "link"
            case .stack: "square.stack.3d.up"
            }
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        image?.size = size
        return image
    }

    @objc private func readdRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentEntry,
              Self.canReadd(entry) else { return }
        onReaddRecent(entry)
    }

    @objc private func clearRecent(_ sender: NSMenuItem) {
        recents.clear()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// 每次打开菜单时刷新勾选项与标题（跟随 shelf 实际可见性），并重建
    /// 最近项目子菜单（entries 随拖出/Clear 变化）。
    func menuWillOpen(_ menu: NSMenu) {
        let isVisible = appState.isShelfVisible
        toggleItem.title = isVisible
            ? String(localized: "Hide Shelf")
            : String(localized: "Show Shelf")
        toggleItem.state = isVisible ? .on : .off
        rebuildRecentSubmenu()
    }
}
