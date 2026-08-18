import XCTest
@testable import OpenYoink

@MainActor
final class AccessibilityAnnouncementTests: XCTestCase {
    func testReceivingProgressProducesOneDeduplicatedStartAnnouncement() {
        var messages: [AccessibilityAnnouncement] = []
        let center = AccessibilityAnnouncementCenter { messages.append($0) }
        let id = UUID()
        var task = TransferTask(
            id: id,
            direction: .importIntoShelf,
            startedAt: Date(),
            itemIDs: [],
            phase: .receiving(receivedCount: 0, expectedCount: 3),
            safetyMessage: "safe",
            expectedCount: 3
        )

        center.announce(task: task)
        task.phase = .receiving(receivedCount: 2, expectedCount: 3)
        center.announce(task: task)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].priority, .low)
    }

    func testPartialOutcomeIncludesCountsAndCanAnnounceARevisedOutcome() {
        var messages: [AccessibilityAnnouncement] = []
        let center = AccessibilityAnnouncementCenter { messages.append($0) }
        let failure = TransferFailure(reason: .deliveryFailed,
                                      recoveryAction: .retryByDraggingOut(itemID: UUID()))
        var task = TransferTask(
            id: UUID(),
            direction: .exportFromShelf,
            startedAt: Date(),
            itemIDs: [UUID(), UUID()],
            phase: .partiallySucceeded(successCount: 2, failures: [failure]),
            safetyMessage: "safe",
            expectedCount: 3
        )

        center.announce(task: task)
        center.announce(task: task)
        task.phase = .partiallySucceeded(successCount: 2, failures: [failure, failure])
        center.announce(task: task)

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].message.contains("2"))
        XCTAssertTrue(messages[0].message.contains("1"))
        XCTAssertEqual(messages[0].priority, .high)
    }

    func testSuccessAndCancellationStaySilent() {
        let base = TransferTask(
            id: UUID(),
            direction: .importIntoShelf,
            startedAt: Date(),
            itemIDs: [UUID()],
            phase: .delivered,
            safetyMessage: "safe",
            expectedCount: 1
        )

        XCTAssertNil(AccessibilityAnnouncementPlanner.announcement(for: base))
        var cancelled = base
        cancelled.phase = .cancelled
        XCTAssertNil(AccessibilityAnnouncementPlanner.announcement(for: cancelled))
    }
}
