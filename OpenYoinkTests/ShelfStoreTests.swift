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
