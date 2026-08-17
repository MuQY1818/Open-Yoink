import SwiftUI

@main
struct OpenYoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 本 LSUIElement 后台 agent 的唯一 scene：设置窗口（S8）。
        // SettingsStore / HotKeyMonitor 由 AppDelegate 持有并注入环境；
        // 打开入口在 MenuBarController（showSettingsWindow: + NSApp.activate）。
        Settings {
            SettingsView()
                .environment(appDelegate.settingsStore)
                .environment(appDelegate.hotKeyMonitor)
        }
    }
}
