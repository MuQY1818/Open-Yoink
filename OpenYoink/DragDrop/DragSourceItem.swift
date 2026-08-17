import AppKit
import SwiftUI

/// 一次拖出的内容集合，由卡片事件层（ShelfView / Stack 浮层）计算。
struct DragOutContents: Equatable, Sendable {
    /// 实际拖出的项目（顶层选择集合或浮层子项集合；stack 由
    /// `DragPayloadBuilder.flattenedItems` 展开为子项）。
    var items: [ShelfItem]
    /// 涉及的顶层项目 id：drop 成功且策略为移除时从 store 删除。
    /// Stack 浮层子项拖出传空集 —— 子项的移除语义（unstack 局部移除）
    /// 随 S6 的 stack 批量操作一起设计，本步不移除子项。
    var topLevelIDs: Set<UUID>
}

/// 拖出总控（MainActor）：把卡片 mouseDragged 转成 AppKit 拖拽会话。
///
/// 经 SwiftUI 环境（`\.dragOutController`）注入卡片；Preview/测试中环境缺省
/// 为 nil，卡片拖拽静默关闭、点击不受影响。
@MainActor
final class DragOutController {
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let bookmarkService: BookmarkService

    init(store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         bookmarkService: BookmarkService) {
        self.store = store
        self.settings = settings
        self.recents = recents
        self.bookmarkService = bookmarkService
    }

    /// 拖拽启动入口：`CardDragSourceAnchorView` 在 mouseDragged 超阈值时经卡片
    /// 回调调用。必须在主线程、且 `event` 为当前手势的 mouseDown/mouseDragged
    /// 事件（`beginDraggingSession` 的硬性要求）。
    func beginDrag(contents: DragOutContents, from sourceView: NSView, event: NSEvent) {
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: contents.items,
            frame: sourceView.bounds,
            bookmarkService: bookmarkService
        )
        guard !draggingItems.isEmpty else { return }
        // 每次会话独立的 NSDraggingSource：无复用状态，结果处理只依赖本次 contents。
        let source = DragSessionController(contents: contents,
                                           store: store,
                                           settings: settings,
                                           recents: recents)
        sourceView.beginDraggingSession(with: draggingItems, event: event, source: source)
    }
}

/// 单次拖出会话的 `NSDraggingSource`（每会话一个实例，无跨会话状态）。
@MainActor
final class DragSessionController: NSObject, NSDraggingSource {
    private let contents: DragOutContents
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService

    init(contents: DragOutContents,
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService) {
        self.contents = contents
        self.store = store
        self.settings = settings
        self.recents = recents
        super.init()
    }

    /// 操作掩码：只声明 `.copy`，永不声明 `.move`。
    ///
    /// 若声明 .move，Finder 目标在默认或修饰键组合下会执行「移动」—— 复制到
    /// 目标后删除原位置文件，违背「任何情况下都不删除用户原文件」（计划 §1.2；
    /// 调研报告 7.2 风险 C：最终语义由源掩码、目标返回值与修饰键共同决定，
    /// 源侧收窄是最可靠的边界）。只给 .copy 后拖到 Finder 永远是复制，
    /// ⌥/⌘ 不能把它升级为移动。
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// 会话结束处理：仅当实际 drop 发生（`operation` 非空；取消/目标拒绝为空）
    /// 才按设置策略处理 —— 移除顶层项目并记入最近历史，或原样保留。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard operation != [] else { return }
        switch settings.dragOutRemovalPolicy {
        case .keep, .ask:
            // .ask 的确认 UI 在 S8 接入；v1 按非破坏性的 keep 处理。
            break
        case .remove:
            if !contents.topLevelIDs.isEmpty {
                store.remove(ids: contents.topLevelIDs)
            }
            // 记录实际拖出的项目（stack 已展开）。浮层子项拖出 topLevelIDs
            // 为空、不从 shelf 移除，但同样记入历史。
            recents.record(DragPayloadBuilder.flattenedItems(contents.items))
        }
    }
}

// MARK: - SwiftUI environment

private struct DragOutControllerEnvironmentKey: EnvironmentKey {
    // nil 缺省：Preview 与单测中拖拽关闭（点击仍工作）。
    static var defaultValue: DragOutController? { nil }
}

extension EnvironmentValues {
    /// 拖出总控；由 ShelfWindowController 在面板内容根上注入。
    var dragOutController: DragOutController? {
        get { self[DragOutControllerEnvironmentKey.self] }
        set { self[DragOutControllerEnvironmentKey.self] = newValue }
    }
}
