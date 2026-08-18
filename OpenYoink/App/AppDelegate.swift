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
                                                                   recents: recentItemsService,
                                                                   dragStartMonitor: dragStartMonitor)
    private lazy var settingsWindowController = SettingsWindowController(settings: settingsStore,
                                                                         hotKeyMonitor: hotKeyMonitor)
    private lazy var menuBarController = MenuBarController(
        appState: appState,
        recents: recentItemsService,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onReaddRecent: { [weak self] entry in
            self?.readdRecent(entry)
        },
        onShowSettings: { [weak self] in
            self?.settingsWindowController.show()
        }
    )

    /// S7: 全局快捷键监听（Carbon RegisterEventHotKey 为主、NSEvent 全局监听
    /// 为备；注册失败状态供 S8 设置页提示）。internal：Settings scene 注入
    /// 环境（registrationError 展示）用。
    /// UX3: 单击 = toggle；双击 = 保存剪贴板到 shelf（识别窗 ~0.3s，设置可关）。
    lazy var hotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.hotKeyShortcut,
        onPress: { [weak self] in
            self?.toggleShelf()
        },
        onDoublePress: { [weak self] in
            self?.saveClipboardToShelf()
        }
    )
    /// S7: 鼠标摇动触发（识别核心 ShakeDetector 为纯类型，见 Triggers/）。
    private lazy var mouseShakeMonitor = MouseShakeMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        self?.toggleShelf()
    })
    /// UX2: 屏幕边缘触发（拖拽版）。仅「唤出」不「隐藏」：贴边的意图是取用
    /// shelf（通常紧接着要向该侧投放），再次贴边反而隐藏会产生往复开关的
    /// 挫败感；隐藏仍由快捷键/菜单与 UX1 拖空无落入自动收回承担。
    /// UX2 设计变更（用户确认）：纯悬停不再触发，仅拖拽中（按住左键）贴边
    /// 短停留唤出；custom 位置无贴附缘时暂停（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身（isEdgeTabBeingDragged）也是 leftMouseDragged，
    /// 会路过贴缘带 —— 抑制，避免重定位拉环时误唤出。
    private lazy var edgeTriggerMonitor = EdgeTriggerMonitor(shouldSuppress: { [weak self] in
        guard let self else { return true }
        return self.appState.isShelfVisible
            || self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        guard let self, !self.appState.isShelfVisible else { return }
        // UX2: 拖拽贴边唤出也记入自动唤出会话（拖空无落入自动收回）。
        self.dragAutoShowSession.markShownAutomatically()
        self.shelfWindowController.showShelf(animated: true)
    })
    /// UX1: 拖拽开始监听（按下 → 位移超阈值判定拖拽 → 抬起结束）。
    /// 同时承担 UX2 贴边唤出的会话记帐：只要任一拖拽驱动唤出路径可能
    /// 生效（immediate 或边缘触发可用）就保持注册。EdgeTab 起还供给
    /// `isDragInProgress` 可观察状态（拉环投放暗示），因此拉环启用时
    /// 同样保持注册（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身被识别为拖拽是正常的，但不应唤出 shelf ——
    /// 经 isEdgeTabBeingDragged 抑制（拉环此时独占该手势）。
    private lazy var dragStartMonitor = DragStartMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onDragStart: { [weak self] in
        self?.handleDragStart()
    }, onDragEnd: { [weak self] in
        self?.handleDragEnd()
    })
    /// UX1/2: 拖拽自动唤出会话裁决（纯逻辑状态机，见 Triggers/DragStartMonitor）。
    private var dragAutoShowSession = DragAutoShowSession()

    /// EdgeTab: 贴屏幕边缘的常驻拉环（单击展开 / 拖入接收 / 沿边拖动换位）。
    /// 拉环与 shelf 互斥（shelf 展开时拉环隐藏；shelf 的外缘隐形热区承担
    /// 同点位收起）。
    private lazy var edgeTabController = EdgeTabController(
        appState: appState,
        settings: settingsStore,
        store: shelfStore,
        importCoordinator: dropImportCoordinator,
        dragStartMonitor: dragStartMonitor,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onShowShelf: { [weak self] in
            self?.shelfWindowController.showShelf(animated: true)
        }
    )

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
        // EdgeTab: 拉环随启动就位（shelf 初始隐藏，拉环立即在边缘就位）。
        _ = edgeTabController
        // UX1: 成功导入（拖入/剪贴板保存）→ 标记拖拽自动唤出会话「本轮
        // 已有内容落入」，拖结束时不再自动收回。
        dropImportCoordinator.onImportHandled = { [weak self] in
            self?.dragAutoShowSession.noteImport()
        }
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
        dragStartMonitor.stop()
    }

    func toggleShelf() {
        shelfWindowController.toggleShelf(animated: true)
    }

    // MARK: - UX1/UX2 drag-driven appearance

    /// UX1: 拖拽确认（位移超阈值）。开启新会话记帐；`.immediate` 模式下
    /// shelf 不可见时立即唤出并打自动唤出标记（拖拽前已可见 = 用户手动
    /// 唤出，不标记、不动它）。`.edgeOnly` 只做记帐，唤出交给边缘触发。
    private func handleDragStart() {
        dragAutoShowSession.dragBegan()
        guard settingsStore.dragAutoAppearMode == .immediate else { return }
        guard !appState.isShelfVisible else { return }
        dragAutoShowSession.markShownAutomatically()
        shelfWindowController.showShelf(animated: true)
    }

    /// UX1: 拖拽结束。本轮为自动唤出且没有内容落入 → 动画收回；
    /// 其余情况（手动唤出、已有导入、用户拖拽中已手动隐藏）不动。
    ///
    /// 任务二审查结论（拖拽中可见性不变式）：本路径不会「拖拽中误隐」——
    /// DragStartMonitor 在派发 onDragEnd 前已把 isDragInProgress 复位，
    /// 收回只发生在抬起之后；且成功落入（含已派发的异步物化）经
    /// onImportHandled → noteImport 置位，dragEnded 必返回 false。
    /// 空架自动隐藏（拖拽中唯一可能误隐的路径）已在 EmptyShelfAutoHideRule
    /// 内按 isDragInProgress 门控。
    private func handleDragEnd() {
        guard dragAutoShowSession.dragEnded(), appState.isShelfVisible else { return }
        shelfWindowController.hideShelf(animated: true)
    }

    // MARK: - UX3 clipboard save

    /// 双击快捷键保存剪贴板：复用 `DropImportCoordinator` 的拖入分派（文件 /
    /// 图片 / URL / 文本）。成功导入即唤出 shelf 给出反馈；空剪贴板或无
    /// 可导入内容时不动作（shelf 可见时走既有 notice 提示）。
    private func saveClipboardToShelf() {
        let result = dropImportCoordinator.importItems(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        guard result.handled else {
            if appState.isShelfVisible {
                shelfNotice.show(String(localized: "Clipboard is empty or has nothing the shelf can hold."))
            }
            return
        }
        shelfStore.add(contentsOf: result.items)
        shelfWindowController.showShelf(animated: true)
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

    /// S7: 按当前设置启停触发监听（启动时与设置变更时调用）。各 monitor
    /// 内部对「配置未变」做了幂等保护，因此可响应任意 UserDefaults 变更
    /// 直接重应用，不会重复注册事件监听。
    ///
    /// UX1/2: 拖拽自动出现由 `dragAutoAppearMode` 单控 —— `.immediate`
    /// 由 DragStartMonitor 在拖拽确认时直接唤出；`.edgeOnly` 由
    /// EdgeTriggerMonitor（拖拽贴边短停留）唤出；`.off` 两者皆停。
    /// 边缘机制在 custom 位置无贴附缘时暂停。DragStartMonitor 还承担
    /// 自动唤出会话记帐（拖空无落入自动收回），因此任一唤出路径可用
    /// 时都要保持注册；EdgeTab 起还供给拉环投放暗示的 `isDragInProgress`
    /// 状态，拉环可用（edgeTabEnabled 且非 custom）时同样保持注册。
    private func applyTriggerSettings() {
        hotKeyMonitor.updateShortcut(settingsStore.hotKeyShortcut)
        hotKeyMonitor.setDoublePressEnabled(settingsStore.hotKeyDoublePressSavesClipboard)
        hotKeyMonitor.setEnabled(settingsStore.hotKeyEnabled)

        if settingsStore.shakeTriggerEnabled {
            mouseShakeMonitor.start(parameters: settingsStore.shakeSensitivity.shakeParameters)
        } else {
            mouseShakeMonitor.stop()
        }

        let edgeActive = settingsStore.dragAutoAppearMode == .edgeOnly
            && settingsStore.shelfPosition != .custom
        if edgeActive {
            edgeTriggerMonitor.start(
                side: settingsStore.shelfPosition,
                dwellTime: settingsStore.edgeTriggerSensitivity.edgeDwellTime,
                bandWidth: settingsStore.edgeTriggerSensitivity.edgeBandWidth
            )
        } else {
            edgeTriggerMonitor.stop()
        }

        // EdgeTab 拉环常驻（开启 && 非 custom 即在位，不再随 shelf 显隐），
        // monitor 注册与拉环在位同一判定 —— 拉环一在位就需要拖拽状态。
        let edgeTabActive = settingsStore.edgeTabEnabled
            && settingsStore.shelfPosition != .custom
        if settingsStore.dragAutoAppearMode == .immediate || edgeActive || edgeTabActive {
            dragStartMonitor.start()
        } else {
            dragStartMonitor.stop()
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
