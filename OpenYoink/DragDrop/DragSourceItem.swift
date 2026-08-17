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

    /// S8: 拖出成功（`operation` 非空）后的回调，由 ShelfWindowController
    /// 在 init 完成后接线以实现 autoHide（init 期无法捕获未完成的 self）。
    /// 为 nil 时不做任何事（Preview/测试）。
    var onSuccessfulDrop: (@MainActor () -> Void)?

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
                                           recents: recents,
                                           onSuccessfulDrop: onSuccessfulDrop)
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
    private let onSuccessfulDrop: (@MainActor () -> Void)?

    init(contents: DragOutContents,
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         onSuccessfulDrop: (@MainActor () -> Void)? = nil) {
        self.contents = contents
        self.store = store
        self.settings = settings
        self.recents = recents
        self.onSuccessfulDrop = onSuccessfulDrop
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
    /// 才按设置策略处理 —— 移除顶层项目并记入最近历史、原样保留，或（.ask）
    /// 弹确认框。成功 drop 后先回调 onSuccessfulDrop（autoHide 接线处）。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard operation != [] else { return }
        onSuccessfulDrop?()
        switch settings.dragOutRemovalPolicy {
        case .keep:
            break
        case .remove:
            removeDraggedItems()
        case .ask:
            askWhetherToRemove()
        }
    }

    /// 移除顶层项目并记入最近历史（.remove 策略与 .ask 确认移除共用）。
    /// 浮层子项拖出 topLevelIDs 为空、不从 shelf 移除，但同样记入历史。
    private func removeDraggedItems() {
        if !contents.topLevelIDs.isEmpty {
            store.remove(ids: contents.topLevelIDs)
        }
        recents.record(DragPayloadBuilder.flattenedItems(contents.items))
    }

    /// S8: .ask 策略 —— 成功拖出后询问是否从 shelf 移除；勾选
    /// 「Don't ask again」则把本次选择写回为 keep/remove 策略。
    ///
    /// LSUIElement 注意点：应用无 Dock 且平时处于非活跃状态，弹 NSAlert
    /// 前必须 `NSApp.activate(ignoringOtherApps:)` 把应用提到前台，否则
    /// 对话框会落在其他应用窗口之后、看起来「什么都没发生」。
    /// runModal 是应用级模态：拖出会话此时已结束，阻塞主线程等待回答是
    /// 可接受的，也是「每次询问」语义本身所需。
    private func askWhetherToRemove() {
        let itemCount = contents.topLevelIDs.isEmpty
            ? contents.items.count
            : contents.topLevelIDs.count
        let alert = NSAlert()
        alert.messageText = itemCount == 1
            ? String(localized: "Remove the dragged item from the shelf?")
            : String(localized: "Remove the \(itemCount) dragged items from the shelf?")
        alert.informativeText = String(localized: "The original files are never deleted.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let verdict = DragOutRemovalDecision.verdict(
            removeChosen: response == .alertFirstButtonReturn,
            dontAskAgain: alert.suppressionButton?.state == .on
        )
        if let policy = verdict.policyToPersist {
            settings.dragOutRemovalPolicy = policy
        }
        if verdict.shouldRemove {
            removeDraggedItems()
        }
    }
}

/// S8: .ask 策略确认框的裁决（纯逻辑，单测覆盖；NSAlert 交互本身无法
/// 无头测试）。「不再询问」勾选时把本次选择固化为后续策略。
enum DragOutRemovalDecision {
    struct Verdict: Equatable, Sendable {
        /// 本次是否从 shelf 移除。
        var shouldRemove: Bool
        /// 需要写回 SettingsStore 的固化策略；未勾选「不再询问」为 nil。
        var policyToPersist: SettingsStore.DragOutRemovalPolicy?
    }

    nonisolated static func verdict(removeChosen: Bool, dontAskAgain: Bool) -> Verdict {
        Verdict(shouldRemove: removeChosen,
                policyToPersist: dontAskAgain ? (removeChosen ? .remove : .keep) : nil)
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
