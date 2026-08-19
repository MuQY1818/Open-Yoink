import XCTest
@testable import OpenYoink

@MainActor
final class IslandActivityCoordinatorTests: XCTestCase {
    func testPriorityPicksDragBeforeTransferAndTimer() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer, priority: .timerFinished))
        coordinator.publish(activity(id: "transfer", module: .transfers, priority: .transfer))
        coordinator.publish(activity(id: "drag", module: .shelf, priority: .userDrag))
        XCTAssertEqual(coordinator.primaryActivity()?.id, "drag")
        coordinator.removeActivity(id: "drag")
        XCTAssertEqual(coordinator.primaryActivity()?.id, "transfer")
    }

    func testSelectedModuleSummaryDoesNotOverrideAnotherModule() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer,
                                     priority: .selectedModule))
        XCTAssertNil(coordinator.primaryActivity())
        coordinator.selectedModule = .timer
        XCTAssertEqual(coordinator.primaryActivity()?.id, "timer")
    }

    func testExpiredActivityIsIgnoredAndPruned() {
        let coordinator = IslandActivityCoordinator()
        let now = Date(timeIntervalSince1970: 100)
        coordinator.publish(.init(id: "expired", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt", expiresAt: now.addingTimeInterval(-1)))
        XCTAssertNil(coordinator.primaryActivity(at: now))
        coordinator.pruneExpired(at: now)
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testExpiringActivityPrunesItselfWithoutPolling() async throws {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(.init(id: "brief", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt",
                                  expiresAt: Date().addingTimeInterval(0.02)))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testCancelledDragRestoresPreviousModuleAndState() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer, pinned: true)
        coordinator.beginDrag()
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
        coordinator.endDrag(imported: false)
        XCTAssertEqual(coordinator.selectedModule, .timer)
        XCTAssertEqual(coordinator.surfaceState, .pinned)
    }

    func testSuccessfulDropStaysExpandedOnShelf() {
        let coordinator = IslandActivityCoordinator()
        coordinator.collapse()
        coordinator.beginDrag()
        coordinator.endDrag(imported: true)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    private func activity(id: String, module: IslandModuleID,
                          priority: IslandActivityPriority) -> IslandActivity {
        .init(id: id, moduleID: module, priority: priority,
              title: id, detail: nil, systemImage: "circle", expiresAt: nil)
    }
}
