import CoreGraphics
import XCTest
@testable import OpenYoink

/// 边缘触发纯逻辑：触发带判定（isInsideEdgeBand）与停留跟踪（EdgeDwellTracker）。
final class EdgeTriggerMonitorTests: XCTestCase {
    // MARK: - Edge band

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testBand_rightSide_insideAtAndBeyondBoundary() {
        // 右缘带 [maxX-4, maxX]，边界值本身算在内。
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 996, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 995.9, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
        // 左侧不在右缘带内。
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_leftSide_insideAtAndBeyondBoundary() {
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4.1, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
    }

    func testBand_pointOutsideScreen_neverCounts() {
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1200, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_customPosition_neverInside() {
        // S9: custom 位置无贴附缘，屏幕任何点都不命中。
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
    }

    func testBand_nonZeroOriginScreen() {
        // 副屏（原点非 0）：带判定基于屏幕 frame 而非固定坐标。
        let secondScreen = CGRect(x: 1000, y: 0, width: 1440, height: 900)
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 2438, y: 100),
                                                          screenFrame: secondScreen, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1001, y: 100),
                                                           screenFrame: secondScreen, side: .right, bandWidth: 4))
    }

    // MARK: - Dwell tracker

    func testDwell_firesOnlyAfterThreshold() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0)) // 进入，开始计时
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.2))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.49))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.5))
    }

    func testDwell_exactBoundaryCounts() {
        // 停留时长恰好等于阈值（>= 判定）即触发。
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_leavingBandRearmsTimer() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.3))
        XCTAssertFalse(tracker.addSample(isInside: false, at: 0.4)) // 离开：计时清零
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.5)) // 重新进入
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.9)) // 0.4s < 0.5s
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.0))
    }

    func testDwell_firesOncePerEntry_untilCursorLeaves() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        // 停留在带内不重复触发（防止 shelf 被隐藏后光标未动又立刻唤出）。
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.7))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.0))
        // 离开后重新进入才可再次触发。
        XCTAssertFalse(tracker.addSample(isInside: false, at: 5.1))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.2))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 5.8))
    }

    func testDwell_resetRearms() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        tracker.reset()
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_neverInside_neverFires() {
        var tracker = EdgeDwellTracker(dwellTime: 0.3)
        for index in 0..<20 {
            XCTAssertFalse(tracker.addSample(isInside: false, at: TimeInterval(index) * 0.1))
        }
    }
}
