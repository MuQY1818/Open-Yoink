import XCTest
@testable import OpenYoink

@MainActor
final class ShelfRecoveryPresentationTests: XCTestCase {
    func testCardShowsActiveTransferAndFailureStates() {
        let item = ShelfItem(kind: .file, displayName: "report.pdf")

        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: item, transferStatus: .receiving),
                       .receiving)
        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: item, transferStatus: .delivering),
                       .delivering)
        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: item,
                                                      transferStatus: .destinationAccepted),
                       .destinationAccepted)
        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: item,
                                                      transferStatus: .deliveryFailed),
                       .deliveryFailed)
    }

    func testReadyCardStaysQuietButManagedCopyKeepsPersistentMeaning() {
        let ordinary = ShelfItem(kind: .file, displayName: "report.pdf")
        let managed = ShelfItem(kind: .file, displayName: "archive.zip", isCut: true)

        XCTAssertNil(ShelfCardVisualStatus.resolve(item: ordinary, transferStatus: nil))
        XCTAssertNil(ShelfCardVisualStatus.resolve(item: ordinary, transferStatus: .delivered))
        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: managed, transferStatus: nil),
                       .managedCopy)
        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: managed, transferStatus: .delivered),
                       .managedCopy)
    }

    func testFailureOverridesManagedCopyWhileItNeedsAttention() {
        let item = ShelfItem(kind: .file, displayName: "archive.zip", isCut: true)

        XCTAssertEqual(ShelfCardVisualStatus.resolve(item: item,
                                                      transferStatus: .deliveryFailed),
                       .deliveryFailed)
    }

    func testActivityOffersOnlyExecutableRecoveryActions() {
        let itemID = UUID()
        let sourceFailure = task(with: TransferFailure(
            reason: .promiseReceiveFailed,
            recoveryAction: .dragAgainFromSource
        ))
        let retainedFailure = task(with: TransferFailure(
            reason: .deliveryFailed,
            recoveryAction: .retryByDraggingOut(itemID: itemID)
        ))

        XCTAssertNil(ShelfActivityStrip.primaryRecovery(for: sourceFailure))
        XCTAssertEqual(ShelfActivityStrip.primaryRecovery(for: retainedFailure)?.action,
                       .retryByDraggingOut(itemID: itemID))
    }

    func testPartialBatchSkipsDismissOnlyFailureAndFindsRealRecovery() {
        let itemID = UUID()
        let task = TransferTask(
            id: UUID(),
            direction: .importIntoShelf,
            startedAt: Date(),
            itemIDs: [],
            phase: .partiallySucceeded(successCount: 1, failures: [
                TransferFailure(reason: .promiseReceiveFailed,
                                recoveryAction: .dragAgainFromSource),
                TransferFailure(reason: .externalFileOffline,
                                recoveryAction: .locateExternalFile(itemID: itemID))
            ]),
            safetyMessage: "",
            expectedCount: 2
        )

        XCTAssertEqual(ShelfActivityStrip.primaryRecovery(for: task)?.action,
                       .locateExternalFile(itemID: itemID))
    }

    private func task(with failure: TransferFailure) -> TransferTask {
        TransferTask(
            id: UUID(),
            direction: .exportFromShelf,
            startedAt: Date(),
            itemIDs: [],
            phase: .failed(failure),
            safetyMessage: "",
            expectedCount: 1
        )
    }
}
