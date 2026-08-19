import AppKit
import XCTest
@testable import OpenYoink

final class IslandGeometryResolverTests: XCTestCase {
    func testPhysicalNotchUsesAuxiliaryGapAndWings() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 645, height: 38),
            auxiliaryTopRightArea: CGRect(x: 867, y: 944, width: 645, height: 38)
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertTrue(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.cameraHousingFrame,
                       CGRect(x: 645, y: 944, width: 222, height: 38))
        XCTAssertEqual(layout.compactFrame.width,
                       222 + IslandGeometryResolver.compactWingWidth * 2)
        XCTAssertEqual(layout.compactFrame.height,
                       38 + IslandGeometryResolver.physicalNotchClickExtension)
        XCTAssertEqual(layout.compactFrame.midX, screen.frame.midX)
        XCTAssertEqual(layout.compactFrame.maxY, screen.frame.maxY)
        XCTAssertEqual(layout.expandedFrame.maxY, screen.frame.maxY)
    }

    func testNoNotchUsesFloatingPillBelowVisibleTop() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertFalse(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.compactFrame.size,
                       IslandGeometryResolver.floatingCompactSize)
        XCTAssertEqual(layout.compactFrame.maxY, screen.visibleFrame.maxY - 8)
        XCTAssertEqual(layout.expandedFrame.maxY, layout.compactFrame.maxY)
    }

    func testNotchHousingUsesAuxiliaryWidthsAcrossCoordinateSpaces() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 949),
            safeAreaTop: 32,
            // Some screen snapshots expose these rects in screen-local coordinates.
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )

        let layout = IslandGeometryResolver.resolve(screen: screen)

        XCTAssertTrue(layout.hasPhysicalNotch)
        XCTAssertEqual(layout.cameraHousingFrame,
                       CGRect(x: -849, y: 950, width: 185, height: 32))
        XCTAssertEqual(layout.compactFrame.midX, layout.cameraHousingFrame.midX)
        XCTAssertEqual(layout.expandedFrame.midX, layout.cameraHousingFrame.midX)
        XCTAssertEqual(layout.compactFrame.height,
                       32 + IslandGeometryResolver.physicalNotchClickExtension)
        XCTAssertEqual(layout.compactFrame.maxY, screen.frame.maxY)
    }

    func testNegativeCoordinateExternalScreenStaysOnThatScreen() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: -2560, y: -200, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -2560, y: -200, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertEqual(layout.compactFrame.midX, screen.visibleFrame.midX)
        XCTAssertTrue(screen.frame.contains(layout.activationFrame.center))
        XCTAssertLessThanOrEqual(layout.expandedFrame.height,
                                 screen.visibleFrame.height * 0.6)
    }

    func testNarrowDisplayClampsExpandedWidthToAvailableSpace() {
        let screen = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 340, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 340, height: 775),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )
        let layout = IslandGeometryResolver.resolve(screen: screen)
        XCTAssertEqual(layout.expandedFrame.width, 360)
        XCTAssertEqual(layout.expandedFrame.midX, screen.visibleFrame.midX)
    }

    func testDisplayRemovalFallsBackToRemainingScreen() throws {
        let main = geometry(x: 0, width: 1512, height: 982)
        let removed = geometry(x: 1512, width: 1920, height: 1080)
        let point = CGPoint(x: removed.frame.midX, y: removed.frame.midY)
        XCTAssertEqual(try XCTUnwrap(IslandGeometryResolver.resolve(
            at: point, screens: [main, removed]
        )).compactFrame.midX, removed.visibleFrame.midX)
        XCTAssertEqual(try XCTUnwrap(IslandGeometryResolver.resolve(
            at: point, screens: [main]
        )).compactFrame.midX, main.visibleFrame.midX)
    }

    func testResolutionChangeRecomputesFrames() throws {
        let before = geometry(x: 0, width: 1512, height: 982)
        let after = geometry(x: 0, width: 1280, height: 800)
        let point = CGPoint(x: 600, y: 700)
        let first = try XCTUnwrap(IslandGeometryResolver.resolve(at: point,
                                                                  screens: [before]))
        let second = try XCTUnwrap(IslandGeometryResolver.resolve(at: point,
                                                                   screens: [after]))
        XCTAssertNotEqual(first.compactFrame, second.compactFrame)
        XCTAssertLessThanOrEqual(second.expandedFrame.height,
                                 after.visibleFrame.height * 0.6)
    }

    private func geometry(x: CGFloat, width: CGFloat,
                          height: CGFloat) -> IslandGeometryResolver.ScreenGeometry {
        .init(frame: CGRect(x: x, y: 0, width: width, height: height),
              visibleFrame: CGRect(x: x, y: 0, width: width, height: height - 25),
              safeAreaTop: 0,
              auxiliaryTopLeftArea: .zero,
              auxiliaryTopRightArea: .zero)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
