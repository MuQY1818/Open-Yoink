import XCTest
@testable import OpenYoink

@MainActor
final class ShelfStoreTests: XCTestCase {
    // MARK: - Helpers

    private func makeItem(_ name: String, kind: ItemKind = .file) -> ShelfItem {
        ShelfItem(kind: kind, path: "/tmp/\(name)", displayName: name)
    }

    private func makeStore(names: [String]) -> ShelfStore {
        ShelfStore(items: names.map { makeItem($0) })
    }

    /// Creates a fresh, empty directory in the container temp directory.
    /// Cleaned up with `defer` at each call site (XCTestCase teardown overrides
    /// are nonisolated and cannot touch MainActor state).
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(_ store: ShelfStore) -> [String] {
        store.items.map(\.displayName)
    }

    // MARK: - Adding

    func testAdd_appendsAndInsertsAtClampedIndex() {
        let store = ShelfStore()
        store.add(makeItem("a"))
        store.add(makeItem("b"), at: 0)
        store.add(makeItem("c"), at: 99)
        store.add(makeItem("d"), at: -5)
        XCTAssertEqual(names(store), ["d", "b", "a", "c"])
    }

    func testAddContentsOf_appendsInOrder() {
        let store = makeStore(names: ["a"])
        store.add(contentsOf: [makeItem("b"), makeItem("c")])
        store.add(contentsOf: [])
        XCTAssertEqual(names(store), ["a", "b", "c"])
    }

    /// C6: 拖入插入位置 —— 批量插入到指定下标（夹取边界），nil 追加。
    func testAddContentsOfAt_insertsAtClampedIndex() {
        let store = makeStore(names: ["a", "b"])
        store.add(contentsOf: [makeItem("c"), makeItem("d")], at: 1)
        store.add(contentsOf: [makeItem("e")], at: 99)
        store.add(contentsOf: [makeItem("f")], at: -3)
        store.add(contentsOf: [makeItem("g")], at: nil)
        XCTAssertEqual(names(store), ["f", "a", "c", "d", "b", "e", "g"])
    }

    // MARK: - Removing

    func testRemove_dropsItemAndSelection_butNeverDeletesOriginalFile() throws {
        // A real file on disk proves removal only drops the reference.
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("keep-me.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ShelfStore()
        let item = ShelfItem(kind: .file, path: fileURL.path, displayName: "keep-me.txt")
        store.add(item)
        store.select(item.id)

        let removed = store.remove(ids: [item.id])

        XCTAssertEqual(removed.map(\.id), [item.id])
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRemoveSelection_andRemoveAll() {
        let store = makeStore(names: ["a", "b", "c"])
        let target = store.items[1]
        store.select(target.id)
        store.removeSelection()
        XCTAssertEqual(names(store), ["a", "c"])
        store.removeAll()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.selection.isEmpty)
    }

    // MARK: - Reordering

    func testMove_matchesSwiftUIOnMoveSemantics() {
        let store = makeStore(names: ["a", "b", "c", "d"])

        store.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(names(store), ["b", "c", "a", "d"])

        store.move(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(names(store), ["d", "b", "c", "a"])

        store.move(fromOffsets: [1, 2], toOffset: 0)
        XCTAssertEqual(names(store), ["b", "c", "d", "a"])
    }

    func testMove_boundariesAndNoOps() {
        let store = makeStore(names: ["a", "b", "c"])

        store.move(fromOffsets: [0], toOffset: 3) // to the very end
        XCTAssertEqual(names(store), ["b", "c", "a"])

        store.move(fromOffsets: [], toOffset: 1) // empty offsets: no-op
        XCTAssertEqual(names(store), ["b", "c", "a"])

        store.move(fromOffsets: [42], toOffset: 0) // out-of-range: no-op
        XCTAssertEqual(names(store), ["b", "c", "a"])

        store.move(fromOffsets: [2], toOffset: 99) // clamped destination
        XCTAssertEqual(names(store), ["b", "c", "a"])
    }

    // MARK: - Selection

    func testSelection_exclusiveAdditiveToggle() {
        let store = makeStore(names: ["a", "b", "c"])
        let (a, b, c) = (store.items[0].id, store.items[1].id, store.items[2].id)

        store.select(a)
        XCTAssertEqual(store.selection, [a])

        store.select(b) // exclusive by default
        XCTAssertEqual(store.selection, [b])

        store.select(a, additive: true)
        store.select(c, additive: true)
        XCTAssertEqual(store.selection, [a, b, c])

        store.toggleSelection(b)
        XCTAssertEqual(store.selection, [a, c])
        store.toggleSelection(b)
        XCTAssertEqual(store.selection, [a, b, c])

        store.clearSelection()
        XCTAssertTrue(store.selection.isEmpty)

        store.selectAll()
        XCTAssertEqual(store.selection.count, 3)
    }

    func testSetSelection_filtersUnknownIDs_andSelectedItemsFollowDisplayOrder() {
        let store = makeStore(names: ["a", "b", "c"])
        store.setSelection([store.items[2].id, store.items[0].id, UUID()])
        XCTAssertEqual(store.selection.count, 2)
        XCTAssertEqual(store.selectedItems.map(\.displayName), ["a", "c"])
    }

    // MARK: - Stacks

    func testMakeStack_mergesSelectionPreservingDisplayOrder() throws {
        let store = makeStore(names: ["a", "b", "c", "d"])
        let b = store.items[1]
        let c = store.items[2]

        let stackID = try XCTUnwrap(store.makeStack(from: [c.id, b.id])) // selection order ≠ display order

        let stack = try XCTUnwrap(store.item(withID: stackID))
        XCTAssertEqual(names(store), ["a", "b", "d"]) // stack named after first member
        XCTAssertEqual(stack.kind, .stack)
        XCTAssertEqual(stack.children?.map(\.id), [b.id, c.id])
        XCTAssertEqual(store.selection, [stackID])
    }

    func testMakeStack_requiresAtLeastTwoExistingItems() {
        let store = makeStore(names: ["a", "b"])

        XCTAssertNil(store.makeStack(from: [store.items[0].id])) // single item
        XCTAssertNil(store.makeStack(from: [store.items[0].id, UUID()])) // one unknown id
        XCTAssertNil(store.makeStack(from: []))
        XCTAssertEqual(names(store), ["a", "b"]) // untouched
    }

    func testUnstack_restoresMembersAtOriginalPosition() throws {
        let store = makeStore(names: ["a", "b", "c", "d"])
        let a = store.items[0]
        let b = store.items[1]
        let c = store.items[2]
        let d = store.items[3]
        let stackID = try XCTUnwrap(store.makeStack(from: [b.id, c.id]))

        XCTAssertTrue(store.unstack(stackID))

        XCTAssertEqual(store.items.map(\.id), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(store.selection, [b.id, c.id])
    }

    func testUnstack_rejectsNonStackItems() {
        let store = makeStore(names: ["a", "b"])
        XCTAssertFalse(store.unstack(store.items[0].id))
        XCTAssertFalse(store.unstack(UUID()))
        XCTAssertEqual(names(store), ["a", "b"])
    }

    // MARK: - UX4 removeChild（stack 子项 ✕ 移除）

    private func makeThreeItemStack() throws -> (store: ShelfStore, stackID: UUID, childIDs: [UUID]) {
        let store = makeStore(names: ["a", "b", "c", "d"])
        let ids = [store.items[0].id, store.items[1].id, store.items[2].id]
        let stackID = try XCTUnwrap(store.makeStack(from: Set(ids)))
        return (store, stackID, ids)
    }

    func testRemoveChild_fromLargerStack_keepsStackWithRemainingChildren() throws {
        let (store, stackID, childIDs) = try makeThreeItemStack()

        XCTAssertTrue(store.removeChild(childIDs[1], fromStack: stackID))

        let stack = try XCTUnwrap(store.item(withID: stackID))
        XCTAssertEqual(stack.kind, .stack)
        XCTAssertEqual(stack.children?.map(\.id), [childIDs[0], childIDs[2]])
        XCTAssertEqual(names(store), ["a", "d"]) // stack 沿用首个子项名
        // stack 选中态保持（makeStack 选中 stack 本身）。
        XCTAssertEqual(store.selection, [stackID])
    }

    func testRemoveChild_leavingOneChild_dissolvesStackIntoPlainItem() throws {
        let store = makeStore(names: ["x", "a", "b", "y"])
        let a = store.items[1]
        let b = store.items[2]
        let stackID = try XCTUnwrap(store.makeStack(from: [a.id, b.id]))

        XCTAssertTrue(store.removeChild(a.id, fromStack: stackID))

        // stack 原位解散为存活子项（普通项），选中跟随。
        XCTAssertEqual(store.items.map(\.id), [store.items[0].id, b.id, store.items[2].id])
        XCTAssertEqual(store.item(withID: b.id)?.kind, .file)
        XCTAssertNil(store.item(withID: stackID))
        XCTAssertEqual(store.selection, [b.id])
    }

    func testRemoveChild_lastRemainingChild_removesStack() throws {
        // 防御性构造：children 为 1 的 stack（makeStack 不会产出，直接构造）。
        let child = ShelfItem(kind: .file, path: "/tmp/solo", displayName: "solo")
        let store = ShelfStore(items: [
            ShelfItem(kind: .stack, displayName: "solo", children: [child])
        ])
        let stackID = store.items[0].id

        XCTAssertTrue(store.removeChild(child.id, fromStack: stackID))

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testRemoveChild_unknownIDs_areNoOps() throws {
        let (store, stackID, childIDs) = try makeThreeItemStack()

        XCTAssertFalse(store.removeChild(UUID(), fromStack: stackID)) // 子项不在 stack 中
        XCTAssertFalse(store.removeChild(childIDs[0], fromStack: UUID())) // stack 不存在
        // 非 stack 顶层项同样拒绝。
        let plainID = try XCTUnwrap(store.items.last?.id)
        XCTAssertFalse(store.removeChild(childIDs[0], fromStack: plainID))

        let stack = try XCTUnwrap(store.item(withID: stackID))
        XCTAssertEqual(stack.children?.count, 3)
    }

    func testRemoveChild_triggersPersistence() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceController(directoryURL: directory)
        let a = makeItem("a")
        let b = makeItem("b")
        let store = ShelfStore(items: [a, b], persistence: persistence)
        let stackID = try XCTUnwrap(store.makeStack(from: [a.id, b.id]))

        XCTAssertTrue(store.removeChild(a.id, fromStack: stackID))
        persistence.flushPendingSave()

        // 解散后的存活子项被持久化（stack 已不存在）。
        XCTAssertEqual(persistence.load().map(\.id), [b.id])
    }

    // MARK: - Item updates

    func testUpdate_replacesItemWithSameID() {
        let store = makeStore(names: ["a", "b"])
        var updated = store.items[0]
        updated.displayName = "a2"
        store.update(updated)
        XCTAssertEqual(names(store), ["a2", "b"])
    }

    func testMarkStale_setsRuntimeFlag() {
        let store = makeStore(names: ["a"])
        let id = store.items[0].id
        store.markStale(id, true)
        XCTAssertTrue(store.items[0].isStale)
        store.markStale(id, false)
        XCTAssertFalse(store.items[0].isStale)
    }

    // MARK: - Persistence integration

    func testMutations_triggerDebouncedPersistence() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceController(directoryURL: directory)
        let store = ShelfStore(persistence: persistence)

        store.add(makeItem("a"))
        store.add(makeItem("b"))
        persistence.flushPendingSave()
        XCTAssertEqual(persistence.load().map(\.displayName), ["a", "b"])

        // A second store over the same controller sees the saved contents.
        let reloaded = ShelfStore(persistence: persistence)
        XCTAssertEqual(names(reloaded), ["a", "b"])

        store.removeAll()
        persistence.flushPendingSave()
        XCTAssertEqual(persistence.load(), [])
    }
}
