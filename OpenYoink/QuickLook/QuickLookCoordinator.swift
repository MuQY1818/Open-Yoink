import AppKit
import OSLog
import QuickLookUI
import SwiftUI

/// Quick Look 预览集合的解析规则（纯逻辑，无窗口/QL 依赖，供单测）。
///
/// 规则（实施计划 §2.3「Quick Look」+ F-05）：
/// 1. `contextItem` 命中当前选中集合 → 预览整个选中集合（展示序），
///    并把 `contextItem` 作为起始项（右键已选中卡片 = 预览全部选中并定位到它）；
/// 2. `contextItem` 未命中选中集合（如未选中的卡片、Stack 浮层子项）→ 只预览它自身；
/// 3. `contextItem` 为 nil（空格键路径）→ 预览当前选中集合；选中为空则无预览。
/// 产出前把 stack 递归展开为其 children，并剔除 stale 项（bookmark 失效，
/// QL 打不开——右键菜单此时显示「File Unavailable」，见 ShelfItemCard）。
enum QuickLookPreviewPlanner {
    /// 解析预览集合（展平 + 剔除 stale 后的最终结果）。
    static func previewItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        flatten(baseItems(selection: selection, contextItem: contextItem))
            .filter { !$0.isStale }
    }

    /// 起始项下标：`contextItem` 在展平集合中的位置；未提供或未命中时为 0。
    static func currentIndex(in previewItems: [ShelfItem], contextItem: ShelfItem?) -> Int {
        guard let contextItem,
              let index = previewItems.firstIndex(where: { $0.id == contextItem.id }) else {
            return 0
        }
        return index
    }

    /// 规则 1–3 的原始集合（未展平、未剔除 stale）。
    static func baseItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        if let contextItem, !selection.contains(where: { $0.id == contextItem.id }) {
            return [contextItem]
        }
        if !selection.isEmpty {
            return selection
        }
        return contextItem.map { [$0] } ?? []
    }

    /// stack 递归展开为 children；其余项目原样保留。
    static func flatten(_ items: [ShelfItem]) -> [ShelfItem] {
        items.flatMap { item -> [ShelfItem] in
            if item.kind == .stack, let children = item.children {
                return flatten(children)
            }
            return [item]
        }
    }
}

// MARK: - Item actions (Open / Show in Finder)

/// 项目操作（§1.1「项目操作」）：打开、在 Finder 显示，以及各操作的可用性判断。
///
/// 全部是无状态静态方法，由卡片右键菜单调用；`canX` 同时供菜单 disabled 态与
/// 单测使用。所有操作对 stale 项一律不可用（菜单此时改显示「File Unavailable」）。
/// 任何操作都不删除用户原文件（§1.2）。
@MainActor
enum ItemActions {
    // MARK: Availability

    /// Quick Look 可用性：file/folder/image 需有路径且非 stale；text 需有内容；
    /// url 需有 URL 字符串（回退为临时 .txt 预览，见 QuickLookCoordinator）；
    /// stack 有任一可预览子项即可。
    static func canQuickLook(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .file, .folder, .image:
            return !item.isStale && item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return !(item.urlString?.isEmpty ?? true)
        case .stack:
            return (item.children ?? []).contains(where: canQuickLook)
        }
    }

    /// 打开：file/folder/image 经 NSWorkspace.open 打开解析后的 URL；text 写入
    /// 临时 .txt 打开；url 直接 NSWorkspace.open。stack 不提供「打开」。
    static func canOpen(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return item.urlString.flatMap(URL.init(string:)) != nil
        case .stack:
            return false
        }
    }

    /// 在 Finder 显示：file/folder/image 定位解析后的 URL；text 定位其临时 .txt
    /// （物化/临时文件同样可定位）。url 无本地文件、stack 无单一对应文件，不可用。
    static func canRevealInFinder(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url, .stack:
            return false
        }
    }

    // MARK: Actions

    /// 「打开」。不可用（canOpen == false）时为 no-op。
    static func open(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canOpen(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            // 沙箱下先取得安全范围访问权再交给 LaunchServices 打开。
            bookmarkService.withSecurityScopedAccess(to: url) {
                _ = NSWorkspace.shared.open(url)
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.open(url)
        case .url:
            guard let urlString = item.urlString, let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        case .stack:
            break
        }
    }

    /// 「在 Finder 显示」。不可用（canRevealInFinder == false）时为 no-op。
    static func revealInFinder(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canRevealInFinder(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            bookmarkService.withSecurityScopedAccess(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .url, .stack:
            break
        }
    }

    // MARK: Shared helpers（QuickLookCoordinator 复用）

    /// 解析 file/folder/image 的落地 URL：有 bookmark 时只信任 bookmark
    /// 解析结果。安全书签无效时绝不回退旧 path；旧路径只是一条展示/重连
    /// 提示，不能绕过用户已授予的安全范围访问边界。没有 bookmark 的旧数据
    /// 才使用其原始 fileURL。
    static func resolveFileURL(for item: ShelfItem, bookmarkService: BookmarkService) -> URL? {
        if let bookmark = item.bookmark {
            return try? bookmarkService.resolve(bookmark).url
        }
        return item.fileURL
    }

    /// text 项预览/打开/定位共用的临时 .txt 写入。文件落在 TempFileService
    /// 管理的物化目录（沙箱容器内，无需安全范围）；会话级清理由调用方负责，
    /// 漏网文件由 TempFileService 的启动孤儿清理兜底回收。
    static func writeTextToTemporaryFile(_ text: String, suggestedName: String, tempFileService: TempFileService) throws -> URL {
        // uniqueFileURL 内部会对名字做 lastPathComponent 清洗并加 UUID 前缀。
        let url = try tempFileService.uniqueFileURL(suggestedName: suggestedName + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - QuickLookCoordinator

/// QLPreviewPanel 的数据源/代理与 Quick Look 会话管理（实施计划 §2.3「Quick Look」、S6）。
///
/// 接入方式与焦点处理（围绕 ShelfPanel 的 `.nonactivatingPanel` + LSUIElement 形态）：
/// - QLPreviewPanel 是进程内共享单例面板，`makeKeyAndOrderFront` 可让它在不激活
///   本应用的情况下成为 key window 并接管键盘（空格关闭、方向键翻页、Esc 关闭），
///   前台应用保持 active —— 即「不抢主应用焦点」的标准用法，无需 NSApp.activate。
/// - 面板打开期间本协调器是其 dataSource/delegate；用户再次按空格（面板为 key 时
///   由 QL 自己处理）或在 shelf 上按空格/Esc（ShelfWindowController 键盘链路）均可关闭。
/// - 文件类项目在会话期间持有安全范围访问权（bookmark 解析 + startAccessing），
///   会话结束（面板关闭/会话替换/shelf 隐藏/应用退出）统一 stopAccessing。
///
/// 内容策略：
/// - file/folder/image：bookmark 解析 URL 后直接作为 QL preview item；
/// - text：内容写入临时 .txt（TempFileService 目录）预览；
/// - url：回退为「显示 URL 字符串的临时 .txt」。不下载远端内容：沙箱未申请
///   network entitlement（见 OpenYoink.entitlements），且下载的延迟/失败处理
///   与「按下空格即刻预览」的体验冲突；调研报告 F-05 允许回退文本预览。
/// - stack：由 QuickLookPreviewPlanner 展开为 children，多选天然支持翻页。
///
/// 生命周期：由 ShelfWindowController 长期持有（进而被 AppDelegate 间接持有），
/// 经 SwiftUI 环境（`\.quickLookCoordinator`）注入卡片；Preview/单测中缺省为 nil，
/// 相关入口自动禁用。
///
/// 并发说明：QLPreviewPanelDataSource/Delegate 是 QuickLookUI 的旧式 @objc 可选
/// 协议，SDK 未标注 @MainActor（与 AppKit 的 NSDraggingSource 不同）——此处用
/// isolated conformance（`@MainActor P`）把一致性隔离到主 actor；QL 始终在主线程
/// 调用数据源，与类本身的 @MainActor 隔离一致。
@MainActor
final class QuickLookCoordinator: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    /// 一条预览会话记录：源项目 + 其 QL 项（含会话资源）。
    private struct PreviewEntry {
        let source: ShelfItem
        let previewItem: ShelfPreviewItem
    }

    private let store: ShelfStore
    private let bookmarkService: BookmarkService
    private let tempFileService: TempFileService
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "QuickLook")

    /// QLPreviewPanel 进程内共享单例。SDK 声明返回可选值（实践中恒非 nil），
    /// 统一经此访问以避免散落解包。
    private var sharedPanel: QLPreviewPanel? { QLPreviewPanel.shared() }

    /// 当前会话（展平、剔除不可预览项之后）。`session.map(\.source)` 用于
    /// 「同一集合再次触发 = 关闭」的 toggle 判断。
    private var session: [PreviewEntry] = []
    /// 关闭观察只安装一次（QLPreviewPanel.shared() 惰性创建，避免启动期无谓实例化）。
    private var didInstallCloseObserver = false

    /// QL 面板（用户侧）关闭后回调 —— ShelfWindowController 借此让 ShelfPanel
    /// 重新成为 key（nonactivating：只接键盘焦点，不激活应用），空格可再次唤出预览。
    var onPanelClosed: (() -> Void)?

    init(store: ShelfStore, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        self.store = store
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// QL 面板当前是否可见。用 session 非空作前置守卫，避免在从未使用时
    /// 提前实例化共享面板。
    var isPreviewing: Bool {
        guard !session.isEmpty else { return false }
        return sharedPanel?.isVisible ?? false
    }

    // MARK: - Session control

    /// 切换 Quick Look：当前选中集合（或 `contextItem`，规则见
    /// QuickLookPreviewPlanner）与当前会话相同则关闭；不同则替换会话内容；
    /// 面板未开则打开。返回值表示事件是否被处理（无可预览内容时为 false）。
    @discardableResult
    func toggle(contextItem: ShelfItem?) -> Bool {
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        let panelVisible = !session.isEmpty && (sharedPanel?.isVisible ?? false)
        if panelVisible, sourceItems == session.map(\.source) {
            dismiss()
            return true
        }
        guard !sourceItems.isEmpty else {
            if panelVisible { dismiss() }
            return false
        }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: true)
        return !session.isEmpty
    }

    /// 选中集合变化时同步已打开的预览（如 QL 打开期间点击/⌘点击其他卡片）。
    /// 面板未打开时为 no-op；新集合为空时保留当前会话（清空选择不应关掉用户
    /// 正在看的预览）。不抢键盘焦点 —— 面板保持可见，key window 留在原处。
    func refreshPreview(contextItem: ShelfItem?) {
        guard !session.isEmpty, sharedPanel?.isVisible == true else { return }
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        guard !sourceItems.isEmpty, sourceItems != session.map(\.source) else { return }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: false)
    }

    /// 用户发起的关闭（空格 toggle-off / Esc）：关闭面板、释放会话资源，
    /// 并回调让 ShelfPanel 重新成为 key。
    func dismiss() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
        onPanelClosed?()
    }

    /// shelf 隐藏时的清理：关闭面板并释放资源，但不恢复键盘焦点
    /// （面板正在滑出，不宜再成为 key）。
    func closeForShelfHide() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
    }

    // MARK: - Session internals

    /// 建立（或替换）会话并刷新面板。`grabKeyFocus` 为 true 或面板尚不可见时
    /// makeKeyAndOrderFront；refreshPreview 路径传 false 以避免焦点乒乓。
    private func present(_ sourceItems: [ShelfItem], contextItem: ShelfItem?, grabKeyFocus: Bool) {
        buildSession(from: sourceItems)
        guard !session.isEmpty, let panel = sharedPanel else { return }
        installCloseObserverIfNeeded()
        // 面板为进程内共享单例；每次会话都重新指定，确保数据源指向本协调器。
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = QuickLookPreviewPlanner.currentIndex(
            in: session.map(\.source), contextItem: contextItem
        )
        if grabKeyFocus || !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 逐项解析预览 URL，建立会话；先释放上一会话的资源。单个项目解析失败
    /// 不影响其余项目（记录日志后跳过）。
    private func buildSession(from sourceItems: [ShelfItem]) {
        endSession()
        var entries: [PreviewEntry] = []
        for item in sourceItems {
            if let previewItem = makePreviewItem(for: item) {
                entries.append(PreviewEntry(source: item, previewItem: previewItem))
            } else {
                logger.error("Skipping Quick Look item '\(item.displayName, privacy: .public)': could not resolve a preview URL")
            }
        }
        session = entries
    }

    /// 释放会话资源：配对 stopAccessing，删除本会话生成的临时 .txt。
    private func endSession() {
        for entry in session {
            if let accessedURL = entry.previewItem.accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
            if let temporaryFileURL = entry.previewItem.temporaryFileURL {
                try? tempFileService.removeMaterializedFile(at: temporaryFileURL)
            }
        }
        session = []
    }

    /// 单个项目 → QL preview item（解析规则见类注释「内容策略」）。
    private func makePreviewItem(for item: ShelfItem) -> ShelfPreviewItem? {
        switch item.kind {
        case .file, .folder, .image:
            guard let url = ItemActions.resolveFileURL(for: item, bookmarkService: bookmarkService) else {
                return nil
            }
            // 会话期间持有安全范围访问权，endSession 配对 stopAccessing。
            // BookmarkService 引用计数在 start 失败时已回滚，无需 stop。
            let accessedURL = bookmarkService.startAccessing(url) ? url : nil
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: accessedURL, temporaryFileURL: nil)
        case .text:
            guard let text = item.text, !text.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .url:
            // 回退（不下载远端内容，原因见类注释）：把 URL 字符串写成临时 .txt 预览。
            guard let urlString = item.urlString, !urlString.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(urlString, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .stack:
            // stack 已被 QuickLookPreviewPlanner 展开；防御性返回。
            return nil
        }
    }

    // MARK: - Panel close observation

    private func installCloseObserverIfNeeded() {
        guard !didInstallCloseObserver else { return }
        didInstallCloseObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: QLPreviewPanel.shared()
        )
    }

    /// 用户直接关闭 QL 面板（面板为 key 时按空格/Esc 由 QL 自行处理）时的兜底
    /// 清理。注：QLPreviewPanel 的隐藏路径在不同系统版本上可能发 close 也可能只
    /// orderOut；若走 orderOut 则不会收到本通知，资源将顺延到下次会话替换/
    /// shelf 隐藏/应用退出（stopAccessingAll + 孤儿清理）时释放，语义安全。
    @objc private func panelWillClose(_ notification: Notification) {
        endSession()
        onPanelClosed?()
    }
}

// MARK: - QLPreviewPanelDataSource / QLPreviewPanelDelegate

/// 数据源方法实现（conformance 声明在类上，见类注释「并发说明」）。
/// 代理方法全部可选，v1 不实现：默认的居中缩放过渡与标准键盘处理已足够。
extension QuickLookCoordinator {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        session.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard session.indices.contains(index) else { return nil }
        return session[index].previewItem
    }
}

// MARK: - ShelfPreviewItem

/// QLPreviewItem 包装：除预览 URL/标题外携带会话资源（安全范围访问权、
/// 会话级临时文件），由 QuickLookCoordinator 在会话结束时统一释放。
private final class ShelfPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    /// 预览期间持有的安全范围访问权（nil 表示无需或未成功 start）。
    let accessedURL: URL?
    /// 会话内生成的临时 .txt（text/url 回退），会话结束后删除。
    let temporaryFileURL: URL?

    init(url: URL, title: String, accessedURL: URL?, temporaryFileURL: URL?) {
        self.previewItemURL = url
        self.previewItemTitle = title
        self.accessedURL = accessedURL
        self.temporaryFileURL = temporaryFileURL
        super.init()
    }
}

// MARK: - SwiftUI environment

private struct QuickLookCoordinatorEnvironmentKey: EnvironmentKey {
    // nil 缺省：Preview 与单测中 Quick Look 入口禁用。
    static var defaultValue: QuickLookCoordinator? { nil }
}

private struct TempFileServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = TempFileService()
}

extension EnvironmentValues {
    /// Quick Look 会话协调器；由 ShelfWindowController 在面板内容根上注入。
    var quickLookCoordinator: QuickLookCoordinator? {
        get { self[QuickLookCoordinatorEnvironmentKey.self] }
        set { self[QuickLookCoordinatorEnvironmentKey.self] = newValue }
    }

    /// 物化临时文件目录（text/url 项的打开/预览/定位需写临时 .txt）。
    var tempFileService: TempFileService {
        get { self[TempFileServiceEnvironmentKey.self] }
        set { self[TempFileServiceEnvironmentKey.self] = newValue }
    }
}
