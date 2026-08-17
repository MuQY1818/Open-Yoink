import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    /// JSON 持久化（原子写 + 500ms 防抖）；store 的一切变更经它落盘。
    private let persistence = PersistenceController()
    /// Shelf 数据（S3 起由 AppDelegate 持有并注入 ShelfView）。
    private lazy var shelfStore = ShelfStore(persistence: persistence)

    private lazy var shelfWindowController = ShelfWindowController(appState: appState, store: shelfStore)
    private lazy var menuBarController = MenuBarController(appState: appState) { [weak self] in
        self?.toggleShelf()
    }

    /// NSEvent local monitor 句柄（⌘⇧Space）。
    private var localHotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = menuBarController
        installLocalHotKeyMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistence.flushPendingSave()
        removeLocalHotKeyMonitor()
    }

    func toggleShelf() {
        shelfWindowController.toggleShelf(animated: true)
    }

    // MARK: - Hot key (⌘⇧Space)

    /// S7 替换点：本应用 LSUIElement 不抢焦点，local monitor 仅在 app active 时生效，
    /// 属预期行为；S7 会用全局监听（NSEvent 全局监听 / Carbon RegisterEventHotKey）
    /// 的 HotKeyMonitor 替换这里，对外仍只调用 `toggleShelf()`。
    private func installLocalHotKeyMonitor() {
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // handler 为同步非隔离上下文，且 NSEvent 非 Sendable：
            // 命中判断就地完成，切换动作派发到 MainActor 执行。
            guard let self, Self.isToggleHotKey(event) else { return event }
            Task { @MainActor in
                self.toggleShelf()
            }
            return nil
        }
    }

    private func removeLocalHotKeyMonitor() {
        if let monitor = localHotKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotKeyMonitor = nil
        }
    }

    private nonisolated static func isToggleHotKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .shift] && event.keyCode == 49 // 49 = Space
    }
}
