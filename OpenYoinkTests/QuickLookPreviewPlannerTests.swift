import XCTest
@testable import OpenYoink

/// S6: Quick Look 预览集合解析规则（`QuickLookPreviewPlanner`，纯逻辑）。
final class QuickLookPreviewPlannerTests: XCTestCase {
    // MARK: - Helpers

    private func file(_ name: String, stale: Bool = false) -> ShelfItem {
        var item = ShelfItem(kind: .file, path: "/tmp/\(name)", displayName: name)
        item.isStale = stale
        return item
    }

    private func stack(_ name: String, children: [ShelfItem]) -> ShelfItem {
        ShelfItem(kind: .stack, displayName: name, children: children)
    }

    private func ids(_ items: [ShelfItem]) -> [UUID] {
        items.map(\.id)
    }

    // MARK: - Base set rules (§2.3 Quick Look)

    /// 右键已选中的卡片：预览整个选中集合，顺序即展示序。
    func testContextItemInSelection_previewsWholeSelectionInDisplayOrder() {
        let a = file("a"), b = file("b"), c = file("c")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b, c], contextItem: b)
        XCTAssertEqual(ids(result), ids([a, b, c]))
    }

    /// 右键未选中的卡片（或 Stack 浮层子项）：只预览它自身，忽略当前选中。
    func testContextItemOutsideSelection_previewsContextItemOnly() {
        let a = file("a"), b = file("b")
        let context = file("x")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: context)
        XCTAssertEqual(ids(result), [context.id])
    }

    /// 空格路径（无上下文项）：预览当前选中集合；选中为空则无预览。
    func testNilContextItem_usesSelectionOrNothing() {
        let a = file("a"), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       ids([a, b]))
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [], contextItem: nil).isEmpty)
    }

    // MARK: - Stack flattening

    /// stack 递归展开为 children（含子项中的嵌套 stack），保持顺序。
    func testStacksAreFlattenedRecursively() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3"), f4 = file("f4")
        let inner = stack("inner", children: [f2, f3])
        let outer = stack("outer", children: [f1, inner])
        let result = QuickLookPreviewPlanner.previewItems(selection: [outer, f4], contextItem: nil)
        XCTAssertEqual(ids(result), ids([f1, f2, f3, f4]))
    }

    /// 选中单个 stack 卡片作为上下文：展开其 children 而非预览 stack 本身。
    func testContextStackExpandsToChildren() {
        let f1 = file("f1"), f2 = file("f2")
        let s = stack("s", children: [f1, f2])
        let result = QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: s)
        XCTAssertEqual(ids(result), ids([f1, f2]))
    }

    // MARK: - Stale filtering

    /// stale 项（bookmark 失效，QL 打不开）从预览集合中剔除，含 stack 子项；
    /// 全部 stale 时集合为空（调用方不打开面板）。
    func testStaleItemsAreFilteredIncludingStackChildren() {
        let a = file("a", stale: true), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       [b.id])

        let staleChild = file("c", stale: true), liveChild = file("d")
        let s = stack("s", children: [staleChild, liveChild])
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: nil)),
                       [liveChild.id])

        let allStale = stack("t", children: [file("e", stale: true)])
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [a, allStale], contextItem: nil).isEmpty)
    }

    // MARK: - Current index

    /// 起始项 = 上下文项在展平集合中的位置；未提供/未命中时为 0。
    func testCurrentIndex() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3")
        let flattened = [f1, f2, f3]
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: f3), 2)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: file("other")), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: nil), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: [], contextItem: f1), 0)
    }
}
