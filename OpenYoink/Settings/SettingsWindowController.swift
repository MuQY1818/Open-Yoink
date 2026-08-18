import AppKit
import SwiftUI

/// 自管理设置窗口（SettingsView 的承载窗口）。
///
/// 为什么不用 SwiftUI `Settings` scene 的 `showSettingsWindow:`：LSUIElement
/// 后台 agent 下该 action 依赖响应链上由 scene 动态安装的处理者，实测静默
/// 失败（菜单点了没反应）。自管理 NSWindowController 完全可控：创建一次、
/// 重复打开只做前置 + 激活。
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let hotKeyMonitor: HotKeyMonitor
    private var window: NSWindow?

    init(settings: SettingsStore, hotKeyMonitor: HotKeyMonitor) {
        self.settings = settings
        self.hotKeyMonitor = hotKeyMonitor
    }

    /// 显示设置窗口并激活应用（LSUIElement：窗口前置与键盘焦点都依赖显式
    /// activate；重复调用幂等——窗口已存在则只做前置）。
    func show() {
        if window == nil {
            let rootView = SettingsView()
                .environment(settings)
                .environment(hotKeyMonitor)
            let hostingController = NSHostingController(rootView: rootView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "OpenYoink Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            // 设置页内容固定尺寸：TabView 各页自行布局，窗口不可缩放。
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OpenYoinkSettings")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
