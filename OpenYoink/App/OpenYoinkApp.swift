import SwiftUI

@main
struct OpenYoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // LSUIElement 后台 agent 不需要任何常驻窗口 scene；设置窗口由
        // SettingsWindowController 自管理（SwiftUI Settings scene 的
        // showSettingsWindow: 在本形态下静默失败）。保留此 inert scene
        // 仅为满足 App body 的 Scene 要求。
        Settings {
            EmptyView()
        }
    }
}
