import Foundation
import XCTest
@testable import OpenYoink

/// F-05: CutDeliveryCoordinator 的交付确认状态机 —— 「会话结果 × 交付确认」
/// 两个事件任一先到的组合、取消保留、失败保留 + notice、stack 子项移除。
@MainActor
final class CutDeliveryCoordinatorTests: XCTestCase {
    @MainActor
    private struct Context {
        let store: ShelfStore
        let recents: RecentItemsService
        let tempFileService: TempFileService
        let noticeCenter = ShelfNoticeModel()
        let coordinator: CutDeliveryCoordinator
        var temporaryURLs: [URL] = []

        init(items: [ShelfItem] = []) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-CutDelivery-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            recents = RecentItemsService(directoryURL: root)
            store = ShelfStore(items: items)
            coordinator = CutDeliveryCoordinator(store: store,
                                                 recents: recents,
                                                 tempFileService: tempFileService,
                                                 noticeCenter: noticeCenter)
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

    // MARK: - 交付闭环

    /// 常规时序：会话成功结束 → promise 写入完成 → 移出 shelf + 删保管文件 + 记历史。
    func testDeliveryAfterSuccessfulSession_finalizesItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")

        context.coordinator.noteSessionEnded(contents: contents(for: [item]), succeeded: true)
        XCTAssertNotNil(context.store.item(withID: item.id), "交付确认前不移除")
        context.coordinator.noteDelivered(itemID: item.id, destination: destination)

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

        context.coordinator.noteDelivered(itemID: item.id, destination: destination)
        XCTAssertNotNil(context.store.item(withID: item.id), "会话未成功结束前不移除")
        context.coordinator.noteSessionEnded(contents: contents(for: [item]), succeeded: true)

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

        context.coordinator.noteSessionEnded(contents: contents(for: [item]), succeeded: false)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertTrue(context.recents.entries.isEmpty)
        // 防御：取消后来路不明的迟到交付不改变任何状态。
        context.coordinator.noteDelivered(itemID: item.id, destination: URL(fileURLWithPath: "/tmp/x.txt"))
        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
    }

    /// 交付失败：item 与保管文件保留（可重试），发 notice。
    func testDeliveryFailure_keepsItemAndShowsNotice() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)

        context.coordinator.noteSessionEnded(contents: contents(for: [item]), succeeded: true)
        context.coordinator.noteFailed(itemID: item.id)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertNotNil(context.noticeCenter.message)
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

        context.coordinator.noteSessionEnded(contents: childContents, succeeded: true)
        context.coordinator.noteDelivered(itemID: cutChild.id, destination: URL(fileURLWithPath: "/tmp/out-child.txt"))

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

        context.coordinator.noteSessionEnded(contents: contents(for: [item]), succeeded: true)
        context.store.remove(ids: [item.id]) // 用户手动移除
        context.coordinator.noteDelivered(itemID: item.id, destination: URL(fileURLWithPath: "/tmp/out.txt"))

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "item 快照驱动定稿：store 里没有也要删掉保管副本")
        XCTAssertEqual(context.recents.entries.first?.displayName, item.displayName)
    }

    /// 混合拖出：同批非剪切项的策略移除与剪切项互不影响（.remove 策略下
    /// 非剪切项照常由 DragSessionController 处理 —— 此处验证编排器只认
    /// isCut 项，普通项的会话结束通报是 no-op）。
    func testNonCutItems_areIgnoredByCoordinator() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let normal = ShelfItem(kind: .file, path: "/tmp/normal.txt", displayName: "normal.txt")
        context.store.add(normal)

        context.coordinator.noteSessionEnded(contents: contents(for: [normal]), succeeded: true)
        context.coordinator.noteDelivered(itemID: normal.id, destination: URL(fileURLWithPath: "/tmp/out.txt"))

        XCTAssertNotNil(context.store.item(withID: normal.id), "普通项不受交付编排影响")
        XCTAssertTrue(context.recents.entries.isEmpty, "普通项的历史由 DragSessionController 策略路径记录")
    }
}
