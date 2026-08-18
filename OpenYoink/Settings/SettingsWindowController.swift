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
    private let launchAtLoginController: LaunchAtLoginController
    private let updateController: UpdateController
    private let storageManagementController: StorageManagementController
    private let navigation: SettingsNavigationModel
    private var window: NSWindow?

    init(settings: SettingsStore,
         hotKeyMonitor: HotKeyMonitor,
         launchAtLoginController: LaunchAtLoginController,
         updateController: UpdateController,
         storageManagementController: StorageManagementController,
         navigation: SettingsNavigationModel) {
        self.settings = settings
        self.hotKeyMonitor = hotKeyMonitor
        self.launchAtLoginController = launchAtLoginController
        self.updateController = updateController
        self.storageManagementController = storageManagementController
        self.navigation = navigation
    }

    /// 显示设置窗口并激活应用（LSUIElement：窗口前置与键盘焦点都依赖显式
    /// activate；重复调用幂等——窗口已存在则只做前置）。
    func show(pane: SettingsPane? = nil) {
        if let pane {
            navigation.selectedPane = pane
        }
        if window == nil {
            let rootView = SettingsView()
                .environment(settings)
                .environment(hotKeyMonitor)
                .environment(launchAtLoginController)
                .environment(updateController)
                .environment(storageManagementController)
                .environment(navigation)
            let hostingController = NSHostingController(rootView: rootView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "OpenYoink Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // 侧边栏需要稳定的最小宽度；允许继续放大，长文案和辅助功能字号
            // 会自然获得更多空间，而不是和顶部导航挤在一起。
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OpenYoinkSettings")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
