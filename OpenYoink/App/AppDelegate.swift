import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    /// JSON 持久化（原子写 + 500ms 防抖）；store 的一切变更经它落盘。
    private let persistence = PersistenceController()
    /// 安全书签服务（拖入创建 / 启动解析 / 缩略图与打开操作的访问权管理）。
    private let bookmarkService = BookmarkService()
    /// 物化临时文件目录（file promise 与图片数据落盘处）。
    private let tempFileService = TempFileService()
    /// S10: 拖入/物化失败的内联提示（shelf 标题栏下方短暂胶囊，自动消失）。
    private let shelfNotice = ShelfNoticeModel()
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "App")
    /// Shelf 数据（S3 起由 AppDelegate 持有并注入 ShelfView）。
    private lazy var shelfStore = ShelfStore(persistence: persistence)
    /// S4: 拖入分派器（pasteboard → ShelfItem）。S10: 失败路径经 shelfNotice 反馈。
    private lazy var dropImportCoordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                                   tempFileService: tempFileService,
                                                                   noticeCenter: shelfNotice)
    /// 用户设置（S5 起拖出后移除策略被 DragSessionController 读取；S8 由
    /// SettingsView 编辑）。internal：OpenYoinkApp 的 Settings scene 注入环境用。
    let settingsStore = SettingsStore()
    /// S5: 最近拖出历史（内存 + recents.json；S10 已接入菜单栏「最近项目」）。
    private let recentItemsService = RecentItemsService()

    private lazy var shelfWindowController = ShelfWindowController(appState: appState,
                                                                   store: shelfStore,
                                                                   importCoordinator: dropImportCoordinator,
                                                                   tempFileService: tempFileService,
                                                                   settings: settingsStore,
                                                                   recents: recentItemsService)
    private lazy var menuBarController = MenuBarController(
        appState: appState,
        recents: recentItemsService,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onReaddRecent: { [weak self] entry in
            self?.readdRecent(entry)
        }
    )

    /// S7: 全局快捷键监听（Carbon RegisterEventHotKey 为主、NSEvent 全局监听
    /// 为备；注册失败状态供 S8 设置页提示）。internal：Settings scene 注入
    /// 环境（registrationError 展示）用。
    lazy var hotKeyMonitor = HotKeyMonitor(shortcut: settingsStore.hotKeyShortcut) { [weak self] in
        self?.toggleShelf()
    }
    /// S7: 鼠标摇动触发（识别核心 ShakeDetector 为纯类型，见 Triggers/）。
    private lazy var mouseShakeMonitor = MouseShakeMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        self?.toggleShelf()
    })
    /// S7: 屏幕边缘停留触发。仅「唤出」不「隐藏」：停留在边缘的意图是取用
    /// shelf（通常紧接着要向该侧拖拽），若再次停留反而隐藏会产生往复开关的
    /// 挫败感；隐藏仍由快捷键/菜单承担（调研报告 §7.2：快捷键是无歧义主入口）。
    private lazy var edgeTriggerMonitor = EdgeTriggerMonitor(shouldSuppress: { [weak self] in
        guard let self else { return true }
        return self.appState.isShelfVisible
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        self?.shelfWindowController.showShelf(animated: true)
    })

    /// S10: 语言覆盖必须在最早阶段生效——`AppleLanguages` 决定进程后续加载的
    /// 本地化资源（Bundle 主语言在首个本地化查询时锁定），故放在
    /// willFinishLaunching（SwiftUI scene 与任何 UI 构建之前）。
    /// 设置页注明「重启后生效」：运行期切换只写偏好，下次启动由此应用。
    func applicationWillFinishLaunching(_ notification: Notification) {
        applyLanguageOverride()
    }

    /// 按 `SettingsStore.language` 覆盖 `AppleLanguages`；`.system` 时移除覆盖，
    /// 完全交还系统语言列表。
    private func applyLanguageOverride() {
        switch settingsStore.language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .chinese:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = menuBarController
        applyTriggerSettings()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(userDefaultsDidChange(_:)),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
        // S4: 批量解析持久化项目的 bookmark（失败标记 stale，过期书签重建并更新
        // 路径），再按最新路径清理物化目录里的孤儿文件。
        resolvePersistedBookmarks()
        cleanupMaterializedOrphans()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistence.flushPendingSave()
        bookmarkService.stopAccessingAll()
        hotKeyMonitor.setEnabled(false)
        mouseShakeMonitor.stop()
        edgeTriggerMonitor.stop()
    }

    func toggleShelf() {
        shelfWindowController.toggleShelf(animated: true)
    }

    // MARK: - Recent items re-add (S10)

    /// 菜单栏「最近项目」点击重新入架：文件类按路径重建 ShelfItem（含新的
    /// 安全书签；`canReadd` 已在菜单侧确认可访问），URL 直接复原。text/stack
    /// 条目在菜单侧已置灰，不会到达这里。入架后唤出 shelf 给出明确反馈。
    private func readdRecent(_ entry: RecentEntry) {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return }
            let item = DropImportCoordinator.makeFileBackedItem(
                for: URL(fileURLWithPath: path),
                displayName: entry.displayName,
                bookmarkService: bookmarkService,
                logger: logger
            )
            shelfStore.add(item)
        case .url:
            guard let urlString = entry.urlString else { return }
            shelfStore.add(ShelfItem(kind: .url,
                                     displayName: entry.displayName,
                                     urlString: urlString))
        case .text, .stack:
            return
        }
        shelfWindowController.showShelf(animated: true)
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

    // MARK: - Trigger wiring (S7)

    /// S7: 按当前设置启停三个触发监听（启动时与设置变更时调用）。各 monitor
    /// 内部对「配置未变」做了幂等保护，因此可响应任意 UserDefaults 变更
    /// 直接重应用，不会重复注册事件监听。
    private func applyTriggerSettings() {
        hotKeyMonitor.updateShortcut(settingsStore.hotKeyShortcut)
        hotKeyMonitor.setEnabled(settingsStore.hotKeyEnabled)

        if settingsStore.shakeTriggerEnabled {
            mouseShakeMonitor.start(parameters: settingsStore.shakeSensitivity.shakeParameters)
        } else {
            mouseShakeMonitor.stop()
        }

        // S9: custom 位置无贴附缘，边缘触发失去目标缘，暂停（切回 left/right
        // 即恢复；开关状态本身不动）。
        if settingsStore.edgeTriggerEnabled, settingsStore.shelfPosition != .custom {
            edgeTriggerMonitor.start(
                side: settingsStore.shelfPosition,
                dwellTime: settingsStore.edgeTriggerSensitivity.edgeDwellTime,
                bandWidth: settingsStore.edgeTriggerSensitivity.edgeBandWidth
            )
        } else {
            edgeTriggerMonitor.stop()
        }
    }

    /// S7: 设置变更 → 重应用触发配置。
    ///
    /// 为什么用 UserDefaults.didChangeNotification 而不是 withObservationTracking：
    /// 后者的 onChange 是 @Sendable 非隔离闭包，Swift 6 严格并发下无法捕获
    /// MainActor 隔离的 self；选择器式 NotificationCenter 观察不涉闭包捕获，
    /// 是本项目已验证的等价机制（同 ShelfWindowController 的屏幕参数监听）。
    /// applyTriggerSettings 幂等，无关设置项的变更不会导致重复注册。
    ///
    /// 必须 nonisolated：该通知按投递线程同步回调，而投递方可能是任意线程
    /// （XCTest 引导阶段就在后台线程 registerDefaults:）；若选择器方法保留
    /// MainActor 隔离，运行期隔离断言会在投递线程上直接 SIGTRAP。
    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyTriggerSettings()
        }
    }
}
