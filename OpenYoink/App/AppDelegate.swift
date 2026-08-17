import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    /// JSON 持久化（原子写 + 500ms 防抖）；store 的一切变更经它落盘。
    private let persistence = PersistenceController()
    /// 安全书签服务（拖入创建 / 启动解析 / 缩略图与打开操作的访问权管理）。
    private let bookmarkService = BookmarkService()
    /// 物化临时文件目录（file promise 与图片数据落盘处）。
    private let tempFileService = TempFileService()
    /// Shelf 数据（S3 起由 AppDelegate 持有并注入 ShelfView）。
    private lazy var shelfStore = ShelfStore(persistence: persistence)
    /// S4: 拖入分派器（pasteboard → ShelfItem）。
    private lazy var dropImportCoordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                                   tempFileService: tempFileService)
    /// 用户设置（S5 起拖出后移除策略被 DragSessionController 读取；S8 出设置 UI）。
    private let settingsStore = SettingsStore()
    /// S5: 最近拖出历史（内存 + recents.json；S10 接菜单栏「最近项目」）。
    private let recentItemsService = RecentItemsService()

    private lazy var shelfWindowController = ShelfWindowController(appState: appState,
                                                                   store: shelfStore,
                                                                   importCoordinator: dropImportCoordinator,
                                                                   settings: settingsStore,
                                                                   recents: recentItemsService)
    private lazy var menuBarController = MenuBarController(appState: appState) { [weak self] in
        self?.toggleShelf()
    }

    /// NSEvent local monitor 句柄（⌘⇧Space）。
    private var localHotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = menuBarController
        installLocalHotKeyMonitor()
        // S4: 批量解析持久化项目的 bookmark（失败标记 stale，过期书签重建并更新
        // 路径），再按最新路径清理物化目录里的孤儿文件。
        resolvePersistedBookmarks()
        cleanupMaterializedOrphans()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistence.flushPendingSave()
        bookmarkService.stopAccessingAll()
        removeLocalHotKeyMonitor()
    }

    func toggleShelf() {
        shelfWindowController.toggleShelf(animated: true)
    }

    // MARK: - Bookmark resolution at launch (S4)

    /// 启动时批量解析已持久化项目的 bookmark：
    /// - 解析失败 → `isStale = true`（卡片显示「不可用」，不静默删除，计划 §6）；
    /// - 解析成功但 bookmark 过期（文件移动过）→ 重建 bookmark 并更新 path；
    /// - Stack 子项递归处理。
    private func resolvePersistedBookmarks() {
        for item in shelfStore.items {
            if let refreshed = refreshedByResolvingBookmark(item) {
                shelfStore.update(refreshed)
            }
        }
    }

    /// 返回需要更新的项目副本；无需更新返回 nil。递归处理 Stack 子项。
    private func refreshedByResolvingBookmark(_ item: ShelfItem) -> ShelfItem? {
        var updated = item
        var changed = false

        if let bookmark = item.bookmark {
            do {
                let resolved = try bookmarkService.resolve(bookmark)
                if resolved.isStale {
                    // bookmark 过期但可解析（文件移动后经 file id 找到）：重建。
                    updated.bookmark = (try? bookmarkService.createBookmark(for: resolved.url)) ?? bookmark
                    updated.path = resolved.url.path
                    changed = true
                } else if item.path != resolved.url.path {
                    updated.path = resolved.url.path
                    changed = true
                }
            } catch {
                updated.isStale = true
                changed = true
            }
        }

        if var children = updated.children {
            var childrenChanged = false
            for index in children.indices {
                if let refreshedChild = refreshedByResolvingBookmark(children[index]) {
                    children[index] = refreshedChild
                    childrenChanged = true
                }
            }
            if childrenChanged {
                updated.children = children
                changed = true
            }
        }

        return changed ? updated : nil
    }

    // MARK: - Materialized file cleanup (S4)

    /// 清理物化目录中的孤儿文件：保留仍被 shelf 项目（含 Stack 子项）引用的
    /// 物化文件，其余视为上次会话中断的残留删除。
    private func cleanupMaterializedOrphans() {
        let managedPrefix = tempFileService.directoryURL.standardizedFileURL.path + "/"
        tempFileService.cleanupOrphans(keepingPaths: materializedPaths(in: shelfStore.items, managedPrefix: managedPrefix))
    }

    private func materializedPaths(in items: [ShelfItem], managedPrefix: String) -> Set<String> {
        var paths = Set<String>()
        for item in items {
            if let path = item.path, path.hasPrefix(managedPrefix) {
                paths.insert(path)
            }
            if let children = item.children {
                paths.formUnion(materializedPaths(in: children, managedPrefix: managedPrefix))
            }
        }
        return paths
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
