import XCTest
@testable import OpenYoink

/// 任务三：shelf 内缘收起把手的侧判定纯逻辑（`ShelfLayoutEngine.innerEdgeHandleSide`）。
/// 把手总在 shelf 朝向屏幕中心的内缘；custom 自由位置无贴附缘，不显示把手。
final class ShelfCollapseHandleTests: XCTestCase {
    func testHandleSide_rightAnchoredShelf_placesHandleOnLeadingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .right), .leading)
    }

    func testHandleSide_leftAnchoredShelf_placesHandleOnTrailingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .left), .trailing)
    }

    func testHandleSide_customPosition_hasNoHandle() {
        XCTAssertNil(ShelfLayoutEngine.innerEdgeHandleSide(for: .custom))
    }

    /// 把手宽度必须 ≤ 面板边距带（外层 8pt + 内容 8pt padding）——它以覆盖层
    /// 形式放在边距带内，不挤占网格宽度（列数推算与卡片坐标系不受污染的约束）。
    func testHandleWidth_fitsInsidePanelMarginBand() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 10)
        XCTAssertLessThanOrEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 16)
    }
}
