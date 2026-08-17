import AppKit
import OSLog
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
    /// F-05: 剪切项交付确认编排（长生命周期 —— promise 写入常在拖拽会话
    /// 结束后才完成，会话级的 DragSessionController 活不到那时）。
    private let cutDeliveryCoordinator: CutDeliveryCoordinator

    /// S8: 拖出成功（`operation` 非空）后的回调，由 ShelfWindowController
    /// 在 init 完成后接线以实现 autoHide（init 期无法捕获未完成的 self）。
    /// 为 nil 时不做任何事（Preview/测试）。
    var onSuccessfulDrop: (@MainActor () -> Void)?

    init(store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         bookmarkService: BookmarkService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel = ShelfNoticeModel()) {
        self.store = store
        self.settings = settings
        self.recents = recents
        self.bookmarkService = bookmarkService
        self.cutDeliveryCoordinator = CutDeliveryCoordinator(store: store,
                                                             recents: recents,
                                                             tempFileService: tempFileService,
                                                             noticeCenter: noticeCenter)
    }

    /// 拖拽启动入口：`CardDragSourceAnchorView` 在 mouseDragged 超阈值时经卡片
    /// 回调调用。必须在主线程、且 `event` 为当前手势的 mouseDown/mouseDragged
    /// 事件（`beginDraggingSession` 的硬性要求）。
    func beginDrag(contents: DragOutContents, from sourceView: NSView, event: NSEvent) {
        // F-05: 剪切项的交付确认通道（promise 写队列 → MainActor 编排器）。
        let cutDeliveryCoordinator = cutDeliveryCoordinator
        cutDeliveryCoordinator.noteSessionBegan(contents: contents)
        let sink = CutDeliverySink(
            delivered: { itemID, url in
                Task { @MainActor in cutDeliveryCoordinator.noteDelivered(itemID: itemID, destination: url) }
            },
            failed: { itemID in
                Task { @MainActor in cutDeliveryCoordinator.noteFailed(itemID: itemID) }
            }
        )
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: contents.items,
            frame: sourceView.bounds,
            bookmarkService: bookmarkService,
            cutDelivery: sink
        )
        guard !draggingItems.isEmpty else { return }
        // 每次会话独立的 NSDraggingSource：无复用状态，结果处理只依赖本次 contents。
        let source = DragSessionController(contents: contents,
                                           store: store,
                                           settings: settings,
                                           recents: recents,
                                           cutDelivery: cutDeliveryCoordinator,
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
    /// F-05: 剪切项交付确认编排（nil 时剪切项退化为普通复制语义，测试用）。
    private let cutDelivery: CutDeliveryCoordinator?
    private let onSuccessfulDrop: (@MainActor () -> Void)?

    init(contents: DragOutContents,
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         cutDelivery: CutDeliveryCoordinator? = nil,
         onSuccessfulDrop: (@MainActor () -> Void)? = nil) {
        self.contents = contents
        self.store = store
        self.settings = settings
        self.recents = recents
        self.cutDelivery = cutDelivery
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
    ///
    /// F-05: 剪切（isCut）项不参与上述策略 —— 剪切语义即移走，交付确认
    /// （promise 写入完成）后由 `CutDeliveryCoordinator` 移出 shelf 并删除
    /// 保管副本，不受 dragOutRemovalPolicy 影响。会话取消（operation == []）
    /// 时 cut 项与保管文件原样保留。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        cutDelivery?.noteSessionEnded(contents: contents, succeeded: operation != [])
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

    /// F-05: 剔除剪切项后的顶层 id 集合（策略移除/询问只作用于非剪切项）。
    /// 若不剔除，.remove 会在交付确认到达前就把待交付的 cut 项移架，保管
    /// 文件成孤儿（下次启动被 cleanupOrphans 删除），移动中的数据丢失。
    private var nonCutTopLevelIDs: Set<UUID> {
        contents.topLevelIDs.filter { id in
            contents.items.first(where: { $0.id == id })?.isCut != true
        }
    }

    /// F-05: 剔除剪切项后的展开项目集合（最近历史只记非剪切项；剪切项在
    /// 交付确认时由 CutDeliveryCoordinator 单独记录）。
    private var nonCutFlattenedItems: [ShelfItem] {
        DragPayloadBuilder.flattenedItems(contents.items).filter { !$0.isCut }
    }

    /// 移除顶层项目并记入最近历史（.remove 策略与 .ask 确认移除共用）。
    /// 浮层子项拖出 topLevelIDs 为空、不从 shelf 移除，但同样记入历史。
    private func removeDraggedItems() {
        let ids = nonCutTopLevelIDs
        if !ids.isEmpty {
            store.remove(ids: ids)
        }
        recents.record(nonCutFlattenedItems)
    }

    /// S8: .ask 策略 —— 成功拖出后询问是否从 shelf 移除；勾选
    /// 「Don't ask again」则把本次选择写回为 keep/remove 策略。
    /// F-05: 只问非剪切项（剪切项交付后自动离架，无需询问）。
    ///
    /// LSUIElement 注意点：应用无 Dock 且平时处于非活跃状态，弹 NSAlert
    /// 前必须 `NSApp.activate(ignoringOtherApps:)` 把应用提到前台，否则
    /// 对话框会落在其他应用窗口之后、看起来「什么都没发生」。
    /// runModal 是应用级模态：拖出会话此时已结束，阻塞主线程等待回答是
    /// 可接受的，也是「每次询问」语义本身所需。
    private func askWhetherToRemove() {
        let itemCount = nonCutTopLevelIDs.isEmpty
            ? nonCutFlattenedItems.count
            : nonCutTopLevelIDs.count
        guard itemCount > 0 else { return }
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

// MARK: - Cut delivery coordination (F-05)

/// 剪切项拖出的交付确认编排（MainActor，由 DragOutController 持有，
/// 生命周期跨越拖拽会话）。
///
/// 为什么需要它：file promise 的写入（`FilePromiseDelegate.writePromiseTo`）
/// 发生在后台队列、通常在 `draggingSession(endedAt:)` 之后；会话级的
/// DragSessionController 等不到交付确认。本编排器跟踪「会话结果 × 交付
/// 确认」两个事件的到达顺序（任一先到都可以）：
///
/// - 会话成功（operation != []）+ 交付确认 → **交付**：删保管副本、
///   把该项移出 shelf（顶层或 stack 子项）、记 RecentItemsService。
///   这是剪切的移动语义，不受 dragOutRemovalPolicy 影响。
/// - 会话取消（operation == []）→ 保留 shelf 项与保管文件，丢弃等待状态。
/// - 交付失败 → 保留 shelf 项与保管文件（可重试），发 notice。
///
/// 交付确认以 item 快照为准（不依赖 store 里此刻的状态）：用户若在交付
/// 到达前手动移除了该项，保管文件仍会被正确删除（store 移除为 no-op）。
@MainActor
final class CutDeliveryCoordinator {
    /// 等待交付闭环的剪切项状态。
    private struct PendingCut {
        /// 会话结束时的项目快照（path/displayName/bookmark 据此定稿）。
        var item: ShelfItem
        /// 会话已成功结束（operation 非空）。
        var sessionEndedSuccessfully = false
        /// promise 写入完成后的目标 URL（交付确认）。
        var destinationURL: URL?
    }

    private var pendingCuts: [UUID: PendingCut] = [:]
    /// 先于会话结束到达的写入失败（见 noteFailed）。
    private var earlyFailures: Set<UUID> = []

    private let store: ShelfStore
    private let recents: RecentItemsService
    private let tempFileService: TempFileService
    private let noticeCenter: ShelfNoticeModel
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "CutDelivery")

    init(store: ShelfStore,
         recents: RecentItemsService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel) {
        self.store = store
        self.recents = recents
        self.tempFileService = tempFileService
        self.noticeCenter = noticeCenter
    }

    /// DragSessionController 会话结束回调。`succeeded == false`（取消/目标
    /// 拒绝）时保留一切并清除等待状态。
    func noteSessionEnded(contents: DragOutContents, succeeded: Bool) {
        for item in DragPayloadBuilder.flattenedItems(contents.items) where item.isCut {
            guard succeeded else {
                pendingCuts.removeValue(forKey: item.id)
                earlyFailures.remove(item.id)
                continue
            }
            if earlyFailures.remove(item.id) != nil {
                // 写入失败先于会话结束到达：drop 已成功但交付失败——保留可重试。
                noticeCenter.show(String(localized: "Couldn't deliver \(item.displayName) — the item stays on the shelf."))
                continue
            }
            var pending = pendingCuts[item.id] ?? PendingCut(item: item)
            pending.item = item
            pending.sessionEndedSuccessfully = true
            pendingCuts[item.id] = pending
            if pending.destinationURL != nil {
                finalize(itemID: item.id)
            }
        }
    }

    /// promise 写入完成（经 CutDeliverySink 从写队列桥回）。
    func noteDelivered(itemID: UUID, destination: URL) {
        if var pending = pendingCuts[itemID] {
            pending.destinationURL = destination
            pendingCuts[itemID] = pending
            if pending.sessionEndedSuccessfully {
                finalize(itemID: itemID)
            }
        } else if let item = lookupCutItem(itemID) {
            // 逆时序：交付先于会话结束到达（快速小文件）。此刻 item 还在架上，
            // 以 store 中的当前快照建账，等 noteSessionEnded 到来后定稿。
            var pending = PendingCut(item: item)
            pending.destinationURL = destination
            pendingCuts[itemID] = pending
        }
    }

    /// promise 写入失败：item 与保管文件保留（用户可重试拖出），发 notice。
    func noteFailed(itemID: UUID) {
        if let pending = pendingCuts.removeValue(forKey: itemID) {
            noticeCenter.show(String(localized: "Couldn't deliver \(pending.item.displayName) — the item stays on the shelf."))
        } else {
            // 失败先于会话结束到达：交由 noteSessionEnded 裁决（会话取消则静默）。
            earlyFailures.insert(itemID)
        }
    }

    /// 新拖出会话开始（DragOutController.beginDrag 调用）：清除相关剪切项
    /// 的上一轮残留状态（如取消会话后迟到的交付确认），防止陈旧交付在新
    /// 会话上误触发定稿。
    func noteSessionBegan(contents: DragOutContents) {
        for item in DragPayloadBuilder.flattenedItems(contents.items) where item.isCut {
            pendingCuts.removeValue(forKey: item.id)
            earlyFailures.remove(item.id)
        }
    }

    /// store 中查找剪切项（顶层或 stack 子项），供逆时序交付建账。
    private func lookupCutItem(_ itemID: UUID) -> ShelfItem? {
        if let item = store.item(withID: itemID) {
            return item.isCut ? item : nil
        }
        for stack in store.items where stack.kind == .stack {
            if let child = stack.children?.first(where: { $0.id == itemID }) {
                return child.isCut ? child : nil
            }
        }
        return nil
    }

    /// 交付闭环：删保管副本 → 移出 shelf → 记最近历史。
    private func finalize(itemID: UUID) {
        guard let pending = pendingCuts.removeValue(forKey: itemID) else { return }
        let item = pending.item
        // 删除保管副本（removeMaterializedFile 只接受保管目录内 URL，
        // 理论上永远删不到保管目录之外的东西）。
        if let path = item.path {
            do {
                try tempFileService.removeMaterializedFile(at: URL(fileURLWithPath: path))
            } catch {
                logger.error("Failed to delete managed cut file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // 从 shelf 移除（顶层项或 stack 子项；用户已手动移除时为 no-op）。
        if store.item(withID: itemID) != nil {
            store.remove(ids: [itemID])
        } else if let stack = store.items.first(where: { $0.children?.contains(where: { $0.id == itemID }) == true }) {
            store.removeChild(itemID, fromStack: stack.id)
        }
        // 记最近拖出；path 改写为交付目标（保管副本随即删除，目标路径才对
        // 「在 Finder 显示」/重新入架有意义）。
        var entry = item
        if let destination = pending.destinationURL {
            entry.path = destination.path
        }
        recents.record([entry])
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
