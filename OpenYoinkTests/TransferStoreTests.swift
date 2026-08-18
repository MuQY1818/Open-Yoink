import XCTest
@testable import OpenYoink

@MainActor
final class TransferStoreTests: XCTestCase {
    func testKnownCountBatchMovesFromReceivingToDelivered() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: 2)

        XCTAssertEqual(store.currentTask?.phase,
                       .receiving(receivedCount: 0, expectedCount: 2))

        let first = UUID()
        store.recordSuccess(taskID: taskID, itemID: first)
        XCTAssertEqual(store.currentTask?.phase,
                       .receiving(receivedCount: 1, expectedCount: 2))

        store.recordSuccess(taskID: taskID, itemID: UUID())
        XCTAssertEqual(store.currentTask?.phase, .delivered)
        XCTAssertEqual(store.currentTask?.itemIDs.first, first)
    }

    func testPartialSuccessRetainsActionableFailureUntilDismissed() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: 2)
        let failure = TransferFailure(reason: .materializationFailed,
                                      itemName: "broken.dat",
                                      recoveryAction: .dragAgainFromSource)

        store.recordSuccess(taskID: taskID, itemID: UUID())
        store.recordFailure(taskID: taskID, failure: failure)

        XCTAssertEqual(store.currentTask?.phase,
                       .partiallySucceeded(successCount: 1, failures: [failure]))
        XCTAssertTrue(store.hasVisibleActivity)
        store.dismiss(taskID: taskID)
        XCTAssertFalse(store.hasVisibleActivity)
    }

    func testAllFailuresProduceFailedState() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: 1)
        let failure = TransferFailure(reason: .promiseReceiveFailed,
                                      recoveryAction: .dragAgainFromSource)

        store.recordFailure(taskID: taskID, failure: failure)

        XCTAssertEqual(store.currentTask?.phase, .failed(failure))
    }

    func testSafeFallbackCountsAsAddedItemAndProducesWarning() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: 1)
        let itemID = UUID()
        let warning = TransferFailure(reason: .managedMoveFellBackToReference,
                                      itemName: "readonly.txt",
                                      recoveryAction: .dismiss,
                                      impact: .itemAddedWithWarning)

        store.recordWarning(taskID: taskID, itemID: itemID, warning: warning)

        XCTAssertEqual(store.currentTask?.phase,
                       .partiallySucceeded(successCount: 1, failures: [warning]))
        XCTAssertEqual(store.currentTask?.itemIDs, [itemID])
    }

    func testUnknownCountDoesNotFinishBeforeExpectedCountArrives() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: nil)
        store.recordSuccess(taskID: taskID, itemID: UUID())

        XCTAssertEqual(store.currentTask?.phase,
                       .receiving(receivedCount: 1, expectedCount: nil))

        store.setExpectedCount(1, for: taskID)
        XCTAssertEqual(store.currentTask?.phase, .delivered)
    }

    func testFallbackWorkExtendsOneStableBatch() {
        let store = TransferStore()
        let taskID = UUID()

        store.extendImport(id: taskID, by: 1)
        store.extendImport(id: taskID, by: 2)

        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.currentTask?.expectedCount, 3)
        XCTAssertEqual(store.currentTask?.id, taskID)
    }

    func testExtendingDeliveredBatchCancelsStaleAutoDismissal() async throws {
        let store = TransferStore(successDisplayDuration: .milliseconds(10))
        let taskID = store.beginImport(expectedCount: 1)
        store.recordSuccess(taskID: taskID, itemID: UUID())

        store.extendImport(id: taskID, by: 1)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(store.hasVisibleActivity)
        XCTAssertEqual(store.currentTask?.phase,
                       .receiving(receivedCount: 1, expectedCount: 2))
    }

    func testDeliveredTaskAutoHidesButRemainsInHistory() async throws {
        let store = TransferStore(successDisplayDuration: .milliseconds(10))
        let taskID = store.beginImport(expectedCount: 1)
        store.recordSuccess(taskID: taskID, itemID: UUID())

        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(store.hasVisibleActivity)
        XCTAssertEqual(store.tasks.first?.phase, .delivered)
    }

    func testLatePromiseCallbackCanMakeHiddenTaskVisibleAgain() {
        let store = TransferStore()
        let taskID = store.beginImport(expectedCount: 1)
        store.recordSuccess(taskID: taskID, itemID: UUID())
        store.dismiss(taskID: taskID)

        store.recordSuccess(taskID: taskID, itemID: UUID())

        XCTAssertTrue(store.hasVisibleActivity)
        XCTAssertEqual(store.currentTask?.phase, .delivered)
        XCTAssertEqual(store.currentTask?.itemIDs.count, 2)
    }

    func testDirectExportEndsAsTargetAcceptedNotDelivered() {
        let store = TransferStore()
        let itemID = UUID()
        let taskID = store.beginExport(itemIDs: [itemID])

        store.finishExportSession(taskID: taskID,
                                  accepted: true,
                                  directlyAcceptedItemIDs: [itemID])

        XCTAssertEqual(store.currentTask?.direction, .exportFromShelf)
        XCTAssertEqual(store.currentTask?.phase, .targetAccepted)
        XCTAssertEqual(store.currentTask?.itemIDs, [itemID])
    }

    func testPromisedExportWaitsForSessionAcceptanceThenBecomesDelivered() {
        let store = TransferStore()
        let itemID = UUID()
        let taskID = store.beginExport(itemIDs: [itemID])

        store.recordExportPromiseRequested(taskID: taskID, itemID: itemID)
        store.recordExportDelivered(taskID: taskID, itemID: itemID)
        XCTAssertEqual(store.currentTask?.phase, .preparing)

        store.finishExportSession(taskID: taskID, accepted: true)
        XCTAssertEqual(store.currentTask?.phase, .delivered)
    }

    func testPromisedExportFailureBeforeSessionEndBecomesFailureOnlyAfterAcceptedDrop() {
        let store = TransferStore()
        let itemID = UUID()
        let taskID = store.beginExport(itemIDs: [itemID])
        let failure = TransferFailure(reason: .deliveryFailed,
                                      itemName: "report.pdf",
                                      recoveryAction: .retryByDraggingOut(itemID: itemID))

        store.recordExportFailure(taskID: taskID, itemID: itemID, failure: failure)
        XCTAssertEqual(store.currentTask?.phase, .preparing)

        store.finishExportSession(taskID: taskID, accepted: true)
        XCTAssertEqual(store.currentTask?.phase, .failed(failure))
    }

    func testLatePromiseRequestRevokesDirectAcceptanceAndCancelsAutoDismissal() async throws {
        let store = TransferStore(successDisplayDuration: .milliseconds(10))
        let itemID = UUID()
        let taskID = store.beginExport(itemIDs: [itemID])
        store.finishExportSession(taskID: taskID,
                                  accepted: true,
                                  directlyAcceptedItemIDs: [itemID])

        store.recordExportPromiseRequested(taskID: taskID, itemID: itemID)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(store.hasVisibleActivity)
        XCTAssertEqual(store.currentTask?.phase,
                       .receiving(receivedCount: 0, expectedCount: 1))
    }

    func testMixedExportReportsDeliveredAndFailedCounts() {
        let store = TransferStore()
        let deliveredID = UUID()
        let failedID = UUID()
        let taskID = store.beginExport(itemIDs: [deliveredID, failedID])
        let failure = TransferFailure(reason: .deliveryFailed,
                                      itemName: "broken.zip",
                                      recoveryAction: .retryByDraggingOut(itemID: failedID))

        store.recordExportDelivered(taskID: taskID, itemID: deliveredID)
        store.recordExportFailure(taskID: taskID, itemID: failedID, failure: failure)
        store.finishExportSession(taskID: taskID, accepted: true)

        XCTAssertEqual(store.currentTask?.phase,
                       .partiallySucceeded(successCount: 1, failures: [failure]))
        XCTAssertEqual(store.currentTask?.itemIDs, [deliveredID])
    }

    func testCancelledExportDoesNotShowAnError() {
        let store = TransferStore()
        let taskID = store.beginExport(itemIDs: [UUID()])

        store.finishExportSession(taskID: taskID, accepted: false)

        XCTAssertFalse(store.hasVisibleActivity)
        XCTAssertEqual(store.tasks.first?.phase, .cancelled)
    }
}
