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
    /// Long-lived delivery state survives the AppKit drag session because file
    /// promise callbacks may arrive before or after `endedAt`.
    private let deliveryCoordinator: DeliveryCoordinator

    /// S8: 拖出成功（`operation` 非空）后的回调，由 ShelfWindowController
    /// 在 init 完成后接线以实现 autoHide（init 期无法捕获未完成的 self）。
    /// 为 nil 时不做任何事（Preview/测试）。
    var onSuccessfulDrop: (@MainActor () -> Void)?

    init(store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         bookmarkService: BookmarkService,
         deliveryCoordinator: DeliveryCoordinator) {
        self.store = store
        self.settings = settings
        self.recents = recents
        self.bookmarkService = bookmarkService
        self.deliveryCoordinator = deliveryCoordinator
    }

    /// 拖拽启动入口：`CardDragSourceAnchorView` 在 mouseDragged 超阈值时经卡片
    /// 回调调用。必须在主线程、且 `event` 为当前手势的 mouseDown/mouseDragged
    /// 事件（`beginDraggingSession` 的硬性要求）。
    func beginDrag(contents: DragOutContents, from sourceView: NSView, event: NSEvent) {
        let sessionID = UUID()
        let deliveryCoordinator = deliveryCoordinator
        deliveryCoordinator.noteSessionBegan(id: sessionID, contents: contents)
        let sink = DeliverySink(
            promiseRequested: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.notePromiseRequested(sessionID: sessionID,
                                                             itemID: itemID)
                }
            },
            delivered: { itemID, url in
                Task { @MainActor in
                    deliveryCoordinator.noteDelivered(sessionID: sessionID,
                                                      itemID: itemID,
                                                      destination: url)
                }
            },
            failed: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.noteFailed(sessionID: sessionID, itemID: itemID)
                }
            }
        )
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: contents.items,
            frame: sourceView.bounds,
            bookmarkService: bookmarkService,
            delivery: sink
        )
        guard !draggingItems.isEmpty else {
            deliveryCoordinator.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        // 每次会话独立的 NSDraggingSource：无复用状态，结果处理只依赖本次 contents。
        let source = DragSessionController(contents: contents,
                                           sessionID: sessionID,
                                           store: store,
                                           settings: settings,
                                           recents: recents,
                                           delivery: deliveryCoordinator,
                                           onSuccessfulDrop: onSuccessfulDrop)
        sourceView.beginDraggingSession(with: draggingItems, event: event, source: source)
    }
}

/// 单次拖出会话的 `NSDraggingSource`（每会话一个实例，无跨会话状态）。
@MainActor
final class DragSessionController: NSObject, NSDraggingSource {
    private let contents: DragOutContents
    private let sessionID: UUID
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let delivery: DeliveryCoordinator?
    private let onSuccessfulDrop: (@MainActor () -> Void)?

    init(contents: DragOutContents,
         sessionID: UUID = UUID(),
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         delivery: DeliveryCoordinator? = nil,
         onSuccessfulDrop: (@MainActor () -> Void)? = nil) {
        self.contents = contents
        self.sessionID = sessionID
        self.store = store
        self.settings = settings
        self.recents = recents
        self.delivery = delivery
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
    /// （promise 写入完成）后由 `DeliveryCoordinator` 移出 shelf 并删除
    /// 保管副本，不受 dragOutRemovalPolicy 影响。会话取消（operation == []）
    /// 时 cut 项与保管文件原样保留。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard operation != [] else {
            delivery?.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        onSuccessfulDrop?()
        switch settings.dragOutRemovalPolicy {
        case .keep:
            break
        case .remove:
            removeDraggedItems()
        case .ask:
            askWhetherToRemove()
        }
        // Report acceptance after the removal policy has run. If a promise
        // failure arrived early, the coordinator can now safely reinsert the
        // failed snapshot instead of having this method remove it afterwards.
        delivery?.noteSessionEnded(id: sessionID, accepted: true)
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
    /// 交付确认时由 DeliveryCoordinator 单独记录）。
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

// MARK: - Delivery coordination

/// Reconciles the two independent facts involved in drag-out delivery:
/// AppKit's session result says a destination accepted the drag, while a file
/// promise callback says bytes were actually written. Session snapshots are
/// retained so a late promise failure can restore an item removed by the
/// user's drag-out policy. Managed-move items are finalized only after both
/// acceptance and confirmed promise delivery.
@MainActor
final class DeliveryCoordinator {
    private enum PromiseState {
        case notRequested
        case requested
        case delivered(URL)
        case failed
    }

    private struct PendingItem {
        let item: ShelfItem
        let insertionIndex: Int
        let supportsFilePromise: Bool
        var promiseState: PromiseState
    }

    private struct PendingSession {
        let id: UUID
        let startedAt: Date
        let orderedItemIDs: [UUID]
        var itemsByID: [UUID: PendingItem]
        var accepted: Bool?
    }

    private var sessions: [UUID: PendingSession] = [:]
    private var latestSessionByItemID: [UUID: UUID] = [:]

    private let store: ShelfStore
    private let recents: RecentItemsService
    private let tempFileService: TempFileService
    private let transferStore: TransferStore
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "Delivery")

    init(store: ShelfStore,
         recents: RecentItemsService,
         tempFileService: TempFileService,
         transferStore: TransferStore) {
        self.store = store
        self.recents = recents
        self.tempFileService = tempFileService
        self.transferStore = transferStore
    }

    func noteSessionBegan(id: UUID, contents: DragOutContents) {
        let flattened = DragPayloadBuilder.flattenedItems(contents.items)
            .filter(DragPayloadBuilder.canMakePasteboardWriter)
        var itemsByID: [UUID: PendingItem] = [:]
        var orderedItemIDs: [UUID] = []
        for item in flattened where itemsByID[item.id] == nil {
            let strategy = DragPayloadBuilder.strategy(for: item)
            let supportsPromise = strategy == .fileBacked || strategy == .fileBackedImage
            itemsByID[item.id] = PendingItem(
                item: item,
                insertionIndex: insertionIndex(for: item.id),
                supportsFilePromise: supportsPromise,
                promiseState: .notRequested
            )
            orderedItemIDs.append(item.id)
            latestSessionByItemID[item.id] = id
        }
        guard !orderedItemIDs.isEmpty else { return }
        sessions[id] = PendingSession(id: id,
                                      startedAt: Date(),
                                      orderedItemIDs: orderedItemIDs,
                                      itemsByID: itemsByID,
                                      accepted: nil)
        transferStore.beginExport(id: id, itemIDs: orderedItemIDs)
        trimRetainedSessions()
    }

    func notePromiseRequested(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .notRequested:
            pending.promiseState = .requested
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
            transferStore.recordExportPromiseRequested(taskID: sessionID, itemID: itemID)
        case .requested, .delivered, .failed:
            break
        }
    }

    func noteDelivered(sessionID: UUID, itemID: UUID, destination: URL) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID] else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .delivered(destination)
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        transferStore.recordExportDelivered(taskID: sessionID, itemID: itemID)
        if pending.item.isCut {
            finalizeManagedItem(pending.item, destination: destination)
        }
    }

    func noteFailed(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID] else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .failed
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        registerFailure(pending.item,
                        insertionIndex: pending.insertionIndex,
                        sessionID: sessionID)
    }

    func noteSessionEnded(id: UUID, accepted: Bool) {
        guard var session = sessions[id] else { return }
        guard accepted else {
            transferStore.finishExportSession(taskID: id, accepted: false)
            discardSession(id)
            return
        }

        session.accepted = true
        sessions[id] = session
        let directlyAccepted = Set(session.orderedItemIDs.compactMap { itemID -> UUID? in
            guard let pending = session.itemsByID[itemID] else { return nil }
            if !pending.supportsFilePromise { return itemID }
            if !pending.item.isCut, case .notRequested = pending.promiseState {
                return itemID
            }
            return nil
        })
        transferStore.finishExportSession(taskID: id,
                                          accepted: true,
                                          directlyAcceptedItemIDs: directlyAccepted)

        // Promise callbacks may have beaten the AppKit session callback.
        for itemID in session.orderedItemIDs {
            guard let pending = session.itemsByID[itemID] else { continue }
            switch pending.promiseState {
            case .delivered(let destination):
                transferStore.recordExportDelivered(taskID: id, itemID: itemID)
                if pending.item.isCut {
                    finalizeManagedItem(pending.item, destination: destination)
                }
            case .failed:
                registerFailure(pending.item,
                                insertionIndex: pending.insertionIndex,
                                sessionID: id)
            case .notRequested, .requested:
                break
            }
        }
    }

    /// Runtime file leases used by Storage settings. A direct drop can remove
    /// a materialized card before a target makes a late promise request; these
    /// snapshots prevent manual cleanup from deleting the only retained bytes.
    var protectedMaterializedPaths: Set<String> {
        let root = tempFileService.directoryURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var result = Set<String>()
        for session in sessions.values where session.accepted == true {
            for pending in session.itemsByID.values {
                guard case .delivered = pending.promiseState else {
                    if !containsItem(pending.item.id),
                       let path = pending.item.path {
                        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                        if standardized.hasPrefix(prefix) {
                            result.insert(standardized)
                        }
                    }
                    continue
                }
            }
        }
        return result
    }

    private func registerFailure(_ item: ShelfItem,
                                 insertionIndex: Int,
                                 sessionID: UUID) {
        if !containsItem(item.id) {
            store.add(item, at: insertionIndex)
        }
        transferStore.recordExportFailure(
            taskID: sessionID,
            itemID: item.id,
            failure: TransferFailure(
                reason: .deliveryFailed,
                itemName: item.displayName,
                recoveryAction: .retryByDraggingOut(itemID: item.id)
            )
        )
    }

    private func finalizeManagedItem(_ item: ShelfItem, destination: URL) {
        if let path = item.path {
            do {
                try tempFileService.removeMaterializedFile(at: URL(fileURLWithPath: path))
            } catch {
                logger.error("Failed to delete managed cut file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if store.item(withID: item.id) != nil {
            store.remove(ids: [item.id])
        } else if let stack = store.items.first(where: {
            containsItem(item.id, in: $0.children ?? [])
        }) {
            store.removeChild(item.id, fromStack: stack.id)
        }
        var entry = item
        entry.path = destination.path
        recents.record([entry])
    }

    private func insertionIndex(for itemID: UUID) -> Int {
        if let index = store.index(ofItemWithID: itemID) {
            return index
        }
        return store.items.firstIndex { containsItem(itemID, in: $0.children ?? []) }
            ?? store.items.count
    }

    private func containsItem(_ itemID: UUID) -> Bool {
        store.items.contains { item in
            item.id == itemID || containsItem(itemID, in: item.children ?? [])
        }
    }

    private func containsItem(_ itemID: UUID, in items: [ShelfItem]) -> Bool {
        items.contains { item in
            item.id == itemID || containsItem(itemID, in: item.children ?? [])
        }
    }

    private func discardSession(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for itemID in session.orderedItemIDs where latestSessionByItemID[itemID] == id {
            latestSessionByItemID.removeValue(forKey: itemID)
        }
    }

    /// Bound runtime snapshots while keeping current/incomplete sessions. The
    /// oldest completed ordinary sessions are the first candidates; active
    /// managed deliveries are never evicted.
    private func trimRetainedSessions() {
        guard sessions.count > 128 else { return }
        let removable = sessions.values
            .filter { session in
                guard session.accepted != nil else { return false }
                return session.itemsByID.values.allSatisfy { pending in
                    !pending.item.isCut && {
                        switch pending.promiseState {
                        case .requested: false
                        case .notRequested, .delivered, .failed: true
                        }
                    }()
                }
            }
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(sessions.count - 128)
            .map(\.id)
        for id in removable {
            discardSession(id)
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
