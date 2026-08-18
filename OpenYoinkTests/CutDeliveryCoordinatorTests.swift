import Foundation
import XCTest
@testable import OpenYoink

/// DeliveryCoordinator 的交付确认状态机：普通直接拖出由会话结果确认；托管
/// 剪切项需要「目标接受 × promise 交付」。覆盖逆序、取消、失败、stack 与 lease。
@MainActor
final class DeliveryCoordinatorTests: XCTestCase {
    @MainActor
    private struct Context {
        let store: ShelfStore
        let recents: RecentItemsService
        let tempFileService: TempFileService
        let transferStore = TransferStore()
        let coordinator: DeliveryCoordinator
        var temporaryURLs: [URL] = []

        init(items: [ShelfItem] = []) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-CutDelivery-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            recents = RecentItemsService(directoryURL: root)
            store = ShelfStore(items: items)
            coordinator = DeliveryCoordinator(store: store,
                                              recents: recents,
                                              tempFileService: tempFileService,
                                              transferStore: transferStore)
            temporaryURLs.append(root)
        }

        func cleanup() {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext() -> Context { Context() }

    /// 造一个保管目录里的真实文件 + 指向它的 isCut ShelfItem。
    private func makeCutItem(in context: inout Context, name: String = "cut-me.txt") throws -> ShelfItem {
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: name)
        try "managed content".write(to: managedURL, atomically: true, encoding: .utf8)
        return ShelfItem(kind: .file,
                         path: managedURL.path,
                         displayName: name,
                         isCut: true)
    }

    private func contents(for items: [ShelfItem]) -> DragOutContents {
        DragOutContents(items: items, topLevelIDs: Set(items.map(\.id)))
    }

    private func beginSession(_ context: Context, items: [ShelfItem]) -> UUID {
        let id = UUID()
        context.coordinator.noteSessionBegan(id: id, contents: contents(for: items))
        return id
    }

    // MARK: - 交付闭环

    /// 常规时序：会话成功结束 → promise 写入完成 → 移出 shelf + 删保管文件 + 记历史。
    func testDeliveryAfterSuccessfulSession_finalizesItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertNotNil(context.store.item(withID: item.id), "交付确认前不移除")
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)

        XCTAssertNil(context.store.item(withID: item.id), "交付后 item 必须离架")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "交付后保管副本必须删除")
        let entry = try XCTUnwrap(context.recents.entries.first)
        XCTAssertEqual(entry.displayName, item.displayName)
        XCTAssertEqual(entry.path, destination.path, "最近历史记录交付目标路径（保管副本已删）")
    }

    /// 逆时序：promise 写入先于会话结束完成（快速小文件）→ 会话成功结束时定稿。
    func testDeliveryBeforeSessionEnd_finalizesOnSessionEnd() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)
        XCTAssertNotNil(context.store.item(withID: item.id), "会话未成功结束前不移除")
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertEqual(context.recents.entries.first?.path, destination.path)
    }

    /// 取消（operation == []）：item 与保管文件都保留，等待状态清除。
    func testCancelledSession_keepsItemAndManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: false)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertTrue(context.recents.entries.isEmpty)
        // 防御：取消后来路不明的迟到交付不改变任何状态。
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/x.txt"))
        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
    }

    /// 交付失败：item 与保管文件保留（可重试），状态条给出真实失败。
    func testDeliveryFailure_keepsItemAndShowsTransferFailure() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        if case .failed(let failure) = context.transferStore.currentTask?.phase {
            XCTAssertEqual(failure.reason, .deliveryFailed)
            XCTAssertEqual(failure.recoveryAction, .retryByDraggingOut(itemID: item.id))
        } else {
            XCTFail("交付失败必须进入 failed 状态")
        }
        XCTAssertTrue(context.recents.entries.isEmpty)
    }

    /// stack 子项中的剪切项：交付后从 stack 移除（子项拖出 topLevelIDs 为空）。
    func testCutChildInStack_removedFromStackOnDelivery() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let cutChild = try makeCutItem(in: &context, name: "child.txt")
        let sibling = ShelfItem(kind: .file, path: "/tmp/sibling.txt", displayName: "sibling.txt")
        let stack = ShelfItem(kind: .stack, displayName: "child.txt", children: [cutChild, sibling])
        context.store.add(stack)
        // 浮层子项拖出：topLevelIDs 为空（不移除顶层 stack 本身）。
        let childContents = DragOutContents(items: [cutChild], topLevelIDs: [])
        let sessionID = UUID()
        context.coordinator.noteSessionBegan(id: sessionID, contents: childContents)

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: cutChild.id,
                                          destination: URL(fileURLWithPath: "/tmp/out-child.txt"))

        XCTAssertNil(context.store.item(withID: stack.id), "剩 1 子项时 stack 自动解散")
        let survivor = try XCTUnwrap(context.store.items.first)
        XCTAssertEqual(survivor.id, sibling.id, "stack 解散后存活子项原位保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutChild.fileURL!.path))
    }

    /// 交付到达前用户已手动移除该项：保管文件仍被删除，不崩溃，历史照记。
    func testDeliveryAfterManualRemoval_stillDeletesManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.store.remove(ids: [item.id]) // 用户手动移除
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/out.txt"))

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "item 快照驱动定稿：store 里没有也要删掉保管副本")
        XCTAssertEqual(context.recents.entries.first?.displayName, item.displayName)
    }

    /// 普通文件未请求 promise 时，只能表达「目标已接受」。
    func testOrdinaryDirectRepresentationReportsTargetAccepted() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let normal = ShelfItem(kind: .file, path: "/tmp/normal.txt", displayName: "normal.txt")
        context.store.add(normal)
        let sessionID = beginSession(context, items: [normal])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNotNil(context.store.item(withID: normal.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
        XCTAssertTrue(context.recents.entries.isEmpty, "普通项的历史由 DragSessionController 策略路径记录")
    }

    /// `.remove` 策略移除普通物化项后，已接受的直接拖出会话仍保护源文件，
    /// 避免用户在目标完成读取前从“存储”页清理掉唯一副本。
    func testAcceptedDirectMaterializedItemProtectsRuntimeLeaseAfterRemoval() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: "kept.txt")
        try "only copy".write(to: managedURL, atomically: true, encoding: .utf8)
        let item = ShelfItem(kind: .file,
                             path: managedURL.path,
                             displayName: "kept.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertTrue(context.coordinator.protectedMaterializedPaths.contains(managedURL.path))
    }

    /// 普通项不再携带 file promise；即便收到来路不明的迟到回调，也不得把
    /// 已由用户策略移除的项目回插或伪造失败状态。
    func testDirectItemIgnoresSpuriousPromiseCallbacks() {
        let context = makeContext()
        defer { context.cleanup() }
        let item = ShelfItem(kind: .file, path: "/tmp/direct.txt", displayName: "direct.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.notePromiseRequested(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/unexpected.txt"))
        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
    }
}
