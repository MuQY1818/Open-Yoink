import CoreGraphics
import XCTest
@testable import OpenYoink

/// EdgeTab 布局纯逻辑单测：拉环 frame（贴缘/offset 映射/夹取）、offset 反解、
/// 换边判定、强调态放大 frame、shelf 展开时的驻点 frame（dockedTabFrame），
/// 以及 shelf 本体的 edgeOffset 垂直定位。
///
/// 测试几何与 ShelfLayoutEngineTests 相同：主屏 frame (0,0 1920×1080)、
/// Dock 占底部 60 → visibleFrame (0,60 1920×1020)。
final class EdgeTabLayoutTests: XCTestCase {
    private let mainScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 1020)
    )

    // MARK: - edgeTabFrame：贴缘与 offset 映射

    func testEdgeTabFrame_rightEdgeOffsetHalfIsVerticallyCentered() {
        // 行程 = 1020-84 = 936；中心 y = 60 + 42 + 936×0.5 = 570 → y = 528。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 528, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_leftEdgeAnchorsToVisibleMinX() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .left, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 528, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_offsetExtremesPinToBottomAndTop() {
        // offset 0：拉环底缘贴可见区底缘；offset 1：顶缘贴顶缘。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 60, width: 14, height: 84)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 996, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_outOfRangeOffsetClamps() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: -0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0,
                                           visibleFrame: mainScreen.visibleFrame)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1.5,
                                           visibleFrame: mainScreen.visibleFrame),
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1,
                                           visibleFrame: mainScreen.visibleFrame)
        )
    }

    func testEdgeTabFrame_customReturnsNil() {
        XCTAssertNil(
            ShelfLayoutEngine.edgeTabFrame(position: .custom, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame)
        )
    }

    func testEdgeTabFrame_tinyVisibleHeightShrinksTab() {
        // 可见高度小于拉环高度：收缩到可见高度、无垂直行程（不越界）。
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 60)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0.7, visibleFrame: tiny),
            CGRect(x: 786, y: 0, width: 14, height: 60)
        )
    }

    // MARK: - edgeTabOffset：中心 y 反解与夹取

    func testEdgeTabOffset_mapsBottomCenterAndTop() {
        // 底缘贴底（中心 60+42=102）→ 0；中心居中（60+510=570）→ 0.5；
        // 顶缘贴顶（中心 60+1020-42=1038）→ 1。
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 102,
                                                       visibleFrame: mainScreen.visibleFrame), 0)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 570,
                                                       visibleFrame: mainScreen.visibleFrame), 0.5)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 1038,
                                                       visibleFrame: mainScreen.visibleFrame), 1)
    }

    func testEdgeTabOffset_clampsBeyondVisibleArea() {
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: -100,
                                                       visibleFrame: mainScreen.visibleFrame), 0)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 5000,
                                                       visibleFrame: mainScreen.visibleFrame), 1)
    }

    func testEdgeTabOffset_noVerticalTravelFallsBackToHalf() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 60)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 30, visibleFrame: tiny), 0.5)
    }

    func testEdgeTabOffset_isExactInverseOfEdgeTabFrame() {
        // 拖动结束按中心 y 持久化 offset 后，重建 frame 必须逐点一致（不跳位）。
        for offset in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let frame = ShelfLayoutEngine.edgeTabFrame(position: .right, offset: offset,
                                                       visibleFrame: mainScreen.visibleFrame)
            let roundTripped = ShelfLayoutEngine.edgeTabOffset(forCenterY: frame?.midY ?? 0,
                                                               visibleFrame: mainScreen.visibleFrame)
            XCTAssertEqual(roundTripped, offset, accuracy: 1e-9,
                           "offset \(offset) round-trip mismatch")
        }
    }

    // MARK: - shouldFlipSide：换边判定

    func testShouldFlipSide_rightTabFlipsNearLeftEdgePastMidline() {
        // 主屏 frame 宽 1920，中线 960：光标 x=100 已过中线且距左缘 100 < 120 → 换边。
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 100, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_rightTabStaysWhenFarFromOppositeEdge() {
        // 过中线但距左缘 150 > 120 → 不换。
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 150, y: 500),
                                             screenFrame: mainScreen.frame)
        )
        // 仍在右半边 → 不换。
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 1500, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_requiresCrossingMidlineOnNarrowScreens() {
        // 窄屏（宽 200）：翻转带（120）越过中线（100）。光标 x=110 距左缘
        // 110 < 120 但未过中线 → 不换边。
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 600)
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 110, y: 300),
                                             screenFrame: narrow)
        )
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 90, y: 300),
                                             screenFrame: narrow)
        )
    }

    func testShouldFlipSide_leftTabFlipsNearRightEdgePastMidline() {
        // 光标 x=1820：过中线（> 960）且距右缘 100 < 120 → 换边。
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .left,
                                             cursorLocation: CGPoint(x: 1820, y: 500),
                                             screenFrame: mainScreen.frame)
        )
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .left,
                                             cursorLocation: CGPoint(x: 1770, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_customNeverFlips() {
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .custom,
                                             cursorLocation: CGPoint(x: 100, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_flipDistanceIsAdjustable() {
        // 距对缘 130：默认 120 不换；flipDistance 150 → 换。
        let cursor = CGPoint(x: 130, y: 500)
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right, cursorLocation: cursor,
                                             screenFrame: mainScreen.frame)
        )
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right, cursorLocation: cursor,
                                             screenFrame: mainScreen.frame, flipDistance: 150)
        )
    }

    // MARK: - edgeTabEmphasisFrame：强调态轻微放大

    func testEdgeTabEmphasisFrame_growsInwardKeepingCenterY() {
        let base = CGRect(x: 1906, y: 528, width: 14, height: 84)
        // 右缘：右缘仍贴 1920（宽 18 → x=1902）；中心 y 570 不变（高 92 → y=524）。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .right,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1902, y: 524, width: 18, height: 92)
        )
        // 左缘：x=0 不变，向右加宽。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: CGRect(x: 0, y: 528, width: 14, height: 84),
                                                   position: .left,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 524, width: 18, height: 92)
        )
    }

    func testEdgeTabEmphasisFrame_clampsIntoVisibleFrameAtExtremes() {
        // 拉环贴底（midY=102）：加高后 y=56 越出底缘 → 夹回 60。
        let base = CGRect(x: 1906, y: 60, width: 14, height: 84)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .right,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1902, y: 60, width: 18, height: 92)
        )
    }

    func testEdgeTabEmphasisFrame_customReturnsBaseUnchanged() {
        let base = CGRect(x: 100, y: 200, width: 14, height: 84)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .custom,
                                                   visibleFrame: mainScreen.visibleFrame),
            base
        )
    }

    // MARK: - dockedTabFrame：shelf 展开时的驻点布局

    func testDockedTabFrame_docksBelowPanelWhenSpaceAllows() {
        // 右锚 shelf（1600,498 320×144）：下方空间 498-60=438 ≥ 90 →
        // 驻点面板下缘外侧：x 对齐面板右缘（1600+320-14=1906），
        // y = 面板底 498 − 间隙 6 − 拉环高 84 = 408。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 498, width: 320, height: 144),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 408, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_leftSideMirrorsX() {
        // 左锚 shelf（0,498 320×144）：x 对齐面板左缘（=0），y 与右锚一致。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 0, y: 498, width: 320, height: 144),
                                             position: .left,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 408, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_alignsToPanelEdgeSideEvenWhenPanelNotFlush() {
        // 面板未贴缘（x=1500，防护性情形）：拉环仍对齐面板贴缘侧而非屏幕缘
        // → x = 1500+320−14 = 1806（而非 1906）。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1500, y: 498, width: 320, height: 144),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1806, y: 408, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_belowSpaceExactlySufficientStillDocksBelow() {
        // 下方空间恰为 拉环高 84 + 间隙 6 = 90（面板底 60+90=150）→ 仍驻下方，
        // 拉环底缘恰好贴可见区底缘：y = 150−90 = 60。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 150, width: 320, height: 144),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 60, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_fallsBackAboveWhenBelowTooTight() {
        // 面板贴底（下方 0）：回退上缘外侧 —— y = 面板顶 560 + 间隙 6 = 566。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 60, width: 320, height: 500),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 566, width: 14, height: 84)
        )
        // 下方差 1pt 不足（89 < 90）：同样回退上方 —— y = 293+6 = 299。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 149, width: 320, height: 144),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 299, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_straddlesPanelBottomEdgeWhenPanelNearlyFullHeight() {
        // 面板几乎全高（下 85 < 90、上 85 < 90）：挂在面板下缘上，顶缘与面板
        // 重叠 2pt —— y = 面板底 145 + 2 − 84 = 63（≥ 60，无需夹取）。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 145, width: 320, height: 850),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 63, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_clampsIntoVisibleFrameWhenEvenStraddleOverflows() {
        // 更极端（面板底距可见区底仅 5pt）：挂钩位 y=−17 越界 → 夹回可见区
        // 底缘 60，拉环完整可点（与面板重叠大于 2pt，属设计内兜底）。
        XCTAssertEqual(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 65, width: 320, height: 1000),
                                             position: .right,
                                             visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 60, width: 14, height: 84)
        )
    }

    func testDockedTabFrame_customReturnsNil() {
        XCTAssertNil(
            ShelfLayoutEngine.dockedTabFrame(shelfFrame: CGRect(x: 1600, y: 498, width: 320, height: 144),
                                             position: .custom,
                                             visibleFrame: mainScreen.visibleFrame)
        )
    }

    // MARK: - shelf 本体的 edgeOffset 垂直定位

    func testEdgeAttachedFrame_edgeOffsetPositionsAlongEdge() {
        // offset 0 → 底缘贴底；offset 1 → 顶缘贴顶；行程 = 1020-144 = 876。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 0),
            CGRect(x: 1600, y: 60, width: 320, height: 144)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 1),
            CGRect(x: 1600, y: 936, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_defaultOffsetKeepsLegacyCentering() {
        // 不传 edgeOffset = 0.5：与旧的固定垂直居中公式一致（y = 60+876/2 = 498）。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 498, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_outOfRangeOffsetClamps() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 2),
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 1)
        )
    }

    func testTargetFrame_edgeOffsetFlowsThrough() {
        // 1 项 → 紧凑高 144；offset 0 → 主屏右缘贴底。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil,
                                          edgeOffset: 0),
            CGRect(x: 1600, y: 60, width: 320, height: 144)
        )
        // offset 1 → 贴顶：y = 60 + 876 = 936。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil,
                                          edgeOffset: 1),
            CGRect(x: 0, y: 936, width: 320, height: 144)
        )
    }

    func testTargetFrame_defaultOffsetKeepsLegacyCentering() {
        // 不传 edgeOffset：与既有断言一致（垂直居中 y = 498）。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 300, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 0, y: 498, width: 300, height: 144)
        )
    }
}
