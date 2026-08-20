import XCTest
@testable import OpenYoink

final class ClassicShelfHoverPreviewStateMachineTests: XCTestCase {
    func testDwellShowsPreviewAfterPointerRemainsInTab() {
        var machine = ClassicShelfHoverPreviewStateMachine()
        XCTAssertEqual(machine.handle(.tabEntered), [.scheduleDwell])
        XCTAssertEqual(machine.handle(.dwellElapsed), [.showPreview])
        XCTAssertTrue(machine.isPreview)
    }

    func testLeavingBeforeDwellCancelsPreview() {
        var machine = ClassicShelfHoverPreviewStateMachine()
        _ = machine.handle(.tabEntered)
        XCTAssertEqual(machine.handle(.tabExited), [.cancelDwell])
        XCTAssertTrue(machine.handle(.dwellElapsed).isEmpty)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testMovingFromTabIntoShelfKeepsPreviewOpen() {
        var machine = previewMachine()
        XCTAssertEqual(machine.handle(.tabExited), [.scheduleExit])
        XCTAssertEqual(machine.handle(.shelfEntered), [.cancelExit])
        XCTAssertTrue(machine.handle(.exitElapsed).isEmpty)
        XCTAssertTrue(machine.isPreview)
    }

    func testLeavingBothSurfacesHidesAfterExitDelay() {
        var machine = previewMachine()
        _ = machine.handle(.tabExited)
        XCTAssertEqual(machine.handle(.exitElapsed), [.hidePreview])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testClickPromotesPreviewToPersistent() {
        var machine = previewMachine()
        XCTAssertEqual(machine.handle(.persistentInteraction),
                       [.cancelExit, .promoteToPersistent])
        XCTAssertEqual(machine.phase, .persistent)
        XCTAssertTrue(machine.handle(.shelfExited).isEmpty)
        XCTAssertTrue(machine.handle(.exitElapsed).isEmpty)
    }

    func testDragSuppressionCancelsPendingAndVisiblePreview() {
        var pending = ClassicShelfHoverPreviewStateMachine()
        _ = pending.handle(.tabEntered)
        XCTAssertEqual(pending.handle(.suppress), [.cancelDwell])

        var preview = previewMachine()
        XCTAssertEqual(preview.handle(.suppress), [.cancelExit, .hidePreview])
        XCTAssertEqual(preview.phase, .idle)
    }

    private func previewMachine() -> ClassicShelfHoverPreviewStateMachine {
        var machine = ClassicShelfHoverPreviewStateMachine()
        _ = machine.handle(.tabEntered)
        _ = machine.handle(.dwellElapsed)
        return machine
    }
}
