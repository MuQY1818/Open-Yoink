import CoreGraphics
import XCTest
@testable import OpenYoink

/// ShelfLayoutEngine（S9）纯逻辑单测：边缘吸附、隐藏滑出方向、frame 夹取、
/// 目标屏回退（鼠标所在屏被拔 → 主屏）、custom frame 校验与回退、Space 在位校正。
///
/// 测试几何：主屏 frame (0,0 1920×1080)、Dock 占底部 60 → visibleFrame
/// (0,60 1920×1020)；副屏在右侧 frame (1920,0 2560×1440)、menu bar 占顶部
/// 25 → visibleFrame (1920,25 2560×1415)。
final class ShelfLayoutEngineTests: XCTestCase {
    private let mainScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 1020)
    )
    private let secondaryScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1920, y: 25, width: 2560, height: 1415)
    )

    // MARK: - Edge attachment（UX5: 紧凑高度 + 垂直居中）

    func testEdgeAttachedFrame_leftAnchorsToVisibleMinX_andCentersVertically() {
        // y = 60 + (1020-144)/2 = 498。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 498, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_rightAnchorsToVisibleMaxX_andCentersVertically() {
        // x = 4480-320 = 4160；y = 25 + (1415-144)/2 = 660.5。
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: secondaryScreen.visibleFrame),
            CGRect(x: 4160, y: 660.5, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_customHasNoEdge() {
        XCTAssertNil(
            ShelfLayoutEngine.edgeAttachedFrame(position: .custom, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame)
        )
    }

    // MARK: - Hidden frame

    func testHiddenFrame_offsetsAwayFromAttachmentEdge() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .right),
                       CGRect(x: 1920, y: 60, width: 320, height: 1020))
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .left),
                       CGRect(x: 1280, y: 60, width: 320, height: 1020))
    }

    func testHiddenFrame_customStaysInPlace() {
        // custom 无滑向：隐藏只剩透明度动画。
        let frame = CGRect(x: 500, y: 300, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .custom), frame)
    }

    // MARK: - Clamping

    func testClamped_frameInsideReturnsSelf() {
        let frame = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame), frame)
    }

    func testClamped_movesOriginMinimallyIntoBounds() {
        // 越过右缘与上缘：x 收到 maxX-width，y 收到 maxY-height。
        let frame = CGRect(x: 1700, y: 1000, width: 320, height: 300)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 1600, y: 780, width: 320, height: 300))
    }

    func testClamped_shrinksOversizedFrame() {
        let frame = CGRect(x: -100, y: -100, width: 3000, height: 2000)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 0, y: 60, width: 1920, height: 1020))
    }

    // MARK: - Target screen

    func testTargetScreen_prefersScreenContainingMouse() {
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 500, y: 500),
                                                      screens: screens), mainScreen)
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 2000, y: 100),
                                                      screens: screens), secondaryScreen)
    }

    func testTargetScreen_mouseOffAllScreensFallsBackToMain() {
        // 鼠标所在屏刚被拔掉、坐标悬空 → 回退首屏（主屏）。
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: -50, y: 3000),
                                                      screens: screens), mainScreen)
    }

    func testTargetScreen_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.targetScreen(mouseLocation: .zero, screens: []))
    }

    // MARK: - Custom frame validation

    func testValidatedCustomFrame_insideScreenKeepsPosition() {
        let persisted = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            persisted
        )
    }

    func testValidatedCustomFrame_appliesCurrentWidthSetting() {
        // 宽度以设置为准：持久化宽度 300、当前设置 400 → 400，原点不动。
        let persisted = CGRect(x: 100, y: 200, width: 300, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 400, screens: [mainScreen]),
            CGRect(x: 100, y: 200, width: 400, height: 600)
        )
    }

    func testValidatedCustomFrame_partiallyOutsideClampsIntoVisibleFrame() {
        // 分辨率变小后持久化 frame 越出右缘与上缘 → 夹回可见区域。
        let persisted = CGRect(x: 1800, y: 500, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            CGRect(x: 1600, y: 480, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_straddlingScreensPicksLargestIntersection() {
        // 横跨双屏：与副屏交集更大 → 夹取进副屏。
        let persisted = CGRect(x: 1800, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen]),
            CGRect(x: 1920, y: 200, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_offAllScreensReturnsNil() {
        // 持久化 frame 所在屏已拔掉 → nil，由调用方回退默认位置。
        let persisted = CGRect(x: 5000, y: 5000, width: 320, height: 600)
        XCTAssertNil(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen])
        )
    }

    // MARK: - Full target-frame decision

    func testTargetFrame_edgePositionsFollowMouseScreen() {
        let screens = [mainScreen, secondaryScreen]
        // 鼠标在副屏 → 贴副屏右缘；含语义状态行的卡片 1 项 1 行 = 192，垂直居中。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 2000, y: 100),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 4160, y: 636.5, width: 320, height: 192)
        )
        // 鼠标在主屏 → 贴主屏左缘。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 300, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 0, y: 474, width: 300, height: 192)
        )
    }

    func testTargetFrame_emptyShelfUsesCompactEmptyHeight() {
        // 空架：紧凑空态高度 200，在主屏垂直居中 → y = 60 + (1020-200)/2 = 470。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 0,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 470, width: 320, height: 200)
        )
    }

    func testTargetFrame_customWithoutPersistedStartsAtRightEdge() {
        // 首次选 custom（无持久化 frame）→ 鼠标屏右缘默认 frame 起步（UX5 不动
        // custom 路径：默认 frame 仍为全高）。
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 5,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_customWithValidPersistedStaysWhereUserPlacedIt() {
        // custom 不跟随鼠标：持久化在副屏，鼠标在主屏，仍出现副屏原处。
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 3,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen, secondaryScreen],
                                          persistedCustomFrame: persisted),
            persisted
        )
    }

    func testTargetFrame_customWithUnpluggedPersistedScreenFallsBackToRightEdge() {
        // 持久化 frame 所在屏已拔掉 → 回退鼠标屏（被拔则主屏）右缘默认。
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 2,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen],
                                          persistedCustomFrame: persisted),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_emptyScreensReturnsFallback() {
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 4,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: nil),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 0,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: CGRect(x: 100, y: 100, width: 320, height: 600)),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
    }

    // MARK: - UX5 紧凑高度：列数推算（与 SwiftUI adaptive 网格一致）

    func testColumnCount_matchesAdaptiveGridMath() {
        // 88pt 最小列 + 12 间距；面板内边距合计 32。
        // 320 → 网格 288 → 3 列（3×88+2×12=288 恰好放下）。
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 320), 3)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 240), 2)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 420), 4)
        // 窄于单列最小宽度也至少 1 列。
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 100), 1)
    }

    // MARK: - UX5 紧凑高度：行数 / 上限 / 空架

    func testContentHeight_singleRowForUpToFullRowOfItems() {
        // 3 列：1~3 项同为 1 行 → 28 + 132 + 32 = 192。
        for count in 1...3 {
            XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: count, panelWidth: 320,
                                                           visibleHeight: 1020), 192)
        }
    }

    func testContentHeight_growsByRow() {
        // 4 项 2 行 → 28 + (132×2 + 12) + 32 = 336；7 项 3 行 → 480。
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 4, panelWidth: 320,
                                                       visibleHeight: 1020), 336)
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 7, panelWidth: 320,
                                                       visibleHeight: 1020), 480)
    }

    func testContentHeight_narrowerPanelFitsFewerColumnsHenceMoreRows() {
        // 宽 240 → 2 列：3 项即 2 行 → 336。
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 240,
                                                       visibleHeight: 1020), 336)
    }

    func testContentHeight_capsAtEightyPercentOfVisibleHeight() {
        // 可见高 300 → 上限 240；10 项 4 行超过上限 → 夹到 240（超出部分滚动）。
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 10, panelWidth: 320,
                                                       visibleHeight: 300), 240)
    }

    func testContentHeight_emptyShelfUsesCompactPlaceholderCappedOnTinyScreens() {
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 1020), 200)
        // 极小屏幕：空态同样受 80% 上限约束。
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 200), 160)
    }

    func testContentHeight_activityStripReservesSpaceWithoutExceedingCap() {
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000, hasActivity: true),
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000)
                + ShelfLayoutEngine.activityStripHeight
        )
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 20, panelWidth: 240,
                                            visibleHeight: 300, hasActivity: true),
            240
        )
    }

    // MARK: - Space-change correction

    func testOnscreenCorrection_validFrameUnchanged() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            frame
        )
    }

    func testOnscreenCorrection_partiallyOffscreenClampsBack() {
        let frame = CGRect(x: 100, y: -200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            CGRect(x: 100, y: 60, width: 320, height: 600)
        )
    }

    func testOnscreenCorrection_fullyOffscreenReturnsNil() {
        let frame = CGRect(x: 9000, y: 9000, width: 320, height: 600)
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]))
    }

    func testOnscreenCorrection_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: .zero, screens: []))
    }
}
