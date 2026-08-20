import XCTest
@testable import OpenYoink

final class IslandScreenSelectionPolicyTests: XCTestCase {
    private let main = IslandScreenSelectionCandidate(
        id: "main",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        isMain: true
    )
    private let external = IslandScreenSelectionCandidate(
        id: "external",
        frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        isMain: false
    )

    func testMainTargetIgnoresPointerOnExternalDisplay() {
        XCTAssertEqual(IslandScreenSelectionPolicy.selectedID(
            for: .main,
            pointerPoint: CGPoint(x: 2_000, y: 500),
            screens: [main, external]
        ), "main")
    }

    func testAutomaticTargetFollowsPointer() {
        XCTAssertEqual(IslandScreenSelectionPolicy.selectedID(
            for: .automatic,
            pointerPoint: CGPoint(x: 2_000, y: 500),
            screens: [main, external]
        ), "external")
    }

    func testPhysicalDisplayTargetIgnoresPointer() {
        XCTAssertEqual(IslandScreenSelectionPolicy.selectedID(
            for: .display("external"),
            pointerPoint: CGPoint(x: 300, y: 500),
            screens: [main, external]
        ), "external")
    }

    func testDisconnectedDisplayFallsBackWithoutChangingPreference() {
        XCTAssertEqual(IslandScreenSelectionPolicy.selectedID(
            for: .display("external"),
            pointerPoint: CGPoint(x: 300, y: 500),
            screens: [main]
        ), "main")
        XCTAssertEqual(IslandScreenSelectionPolicy.selectedID(
            for: .display("external"),
            pointerPoint: CGPoint(x: 300, y: 500),
            screens: [main, external]
        ), "external")
    }
}
