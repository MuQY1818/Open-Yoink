import CoreGraphics
import XCTest
@testable import OpenYoink

/// UX1 拖拽开始状态机（DragGestureTracker）与自动唤出会话裁决
/// （DragAutoShowSession）的纯逻辑单测。
final class DragStartMonitorTests: XCTestCase {
    // MARK: - DragGestureTracker

    func testClickWithoutMovement_neverStartsDrag() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 103, y: 102))) // 位移 ~3.6 < 8
        XCTAssertEqual(tracker.phase, .pressing)
        // 普通点击抬起：不报告拖拽结束。
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDrag_firesExactlyOnceWhenThresholdCrossed() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 105, y: 100))) // 5pt < 8
        // 恰好到达阈值（>= 判定）即确认。
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 108, y: 100)))
        XCTAssertEqual(tracker.phase, .dragging)
        // 确认后继续移动不重复回调。
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 200, y: 200)))
        // 抬起报告拖拽结束，随后复位。
        XCTAssertTrue(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDisplacementIsMeasuredFromOrigin_notPathLength() {
        // 绕小圈抖动：路径长度早已超过阈值，但与起点位移从未达到 → 不触发。
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 104, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 104)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 96, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 96)))
        XCTAssertEqual(tracker.phase, .pressing)
    }

    func testDiagonalDisplacement_usesEuclideanDistance() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 4, y: 4))) // ~5.66 < 8
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 6, y: 6)))  // ~8.49 ≥ 8
    }

    func testNewMouseDown_rearmsAfterMissedMouseUp() {
        // 上一轮抬起事件丢失（防御）：新按下重置会话，可再次触发。
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 20, y: 0)))
        tracker.mouseDown(at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(tracker.phase, .pressing)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 508, y: 500)))
        XCTAssertTrue(tracker.mouseUp())
    }

    func testMouseUpWithoutPress_isNoOp() {
        var tracker = DragGestureTracker(threshold: 8)
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    // MARK: - DragAutoShowSession

    func testAutoShow_dragEndedWithoutImport_requestsHide() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
        // 结束后会话复位：再次抬起不重复请求。
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_importDuringDrag_keepsShelf() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_markedOutsideDrag_isIgnored() {
        // 非拖拽会话中的唤出（快捷键/剪贴板保存）是显式意图，不参与自动收回。
        var session = DragAutoShowSession()
        session.markShownAutomatically()
        XCTAssertFalse(session.shownAutomatically)
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_shelfVisibleBeforeDrag_staysUntouched() {
        // 拖拽前 shelf 已可见（手动唤出）：调用方不打标记，拖结束不收回。
        var session = DragAutoShowSession()
        session.dragBegan()
        // （无 markShownAutomatically —— 对应 AppDelegate 的可见性守卫）
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_newDragResetsPreviousSession() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        // 新一轮拖拽重置全部标记：本轮无导入的自动唤出仍会收回。
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
    }
}
