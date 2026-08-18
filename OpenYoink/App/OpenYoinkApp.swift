import SwiftUI

@main
struct OpenYoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏入口仍由 SettingsWindowController 自管理（LSUIElement 下
        // showSettingsWindow: 响应链不可靠）；这里也提供同一份真实内容，
        // 避免应用被激活后从系统“OpenYoink → 设置…”打开一个空白窗口。
        Settings {
            SettingsView()
                .environment(appDelegate.settingsStore)
                .environment(appDelegate.hotKeyMonitor)
                .environment(appDelegate.launchAtLoginController)
                .environment(appDelegate.updateController)
                .environment(appDelegate.storageManagementController)
                .environment(appDelegate.settingsNavigation)
                .environment(appDelegate.supportController)
        }
    }
}
