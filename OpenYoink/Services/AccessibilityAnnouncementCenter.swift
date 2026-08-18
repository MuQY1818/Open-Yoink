import AppKit
import SwiftUI

/// A batch-level VoiceOver announcement. The token represents the semantic
/// event, so progress-count churn cannot repeat the same spoken message.
struct AccessibilityAnnouncement: Equatable, Sendable {
    enum Priority: Int, Equatable, Sendable {
        case low = 10
        case medium = 50
        case high = 90
    }

    let token: String
    let message: String
    let priority: Priority
}

/// Pure reduction from transfer state to the few events worth interrupting a
/// VoiceOver user for. Per-file progress deliberately produces no speech.
enum AccessibilityAnnouncementPlanner {
    static func announcement(for task: TransferTask) -> AccessibilityAnnouncement? {
        switch task.phase {
        case .preparing, .receiving, .finalizing:
            let message = task.direction == .importIntoShelf
                ? String(localized: "Started receiving content.")
                : String(localized: "Started delivering content.")
            return AccessibilityAnnouncement(
                token: "\(task.id.uuidString).started",
                message: message,
                priority: .low
            )
        case .partiallySucceeded(let successCount, let failures):
            let failureCount = failures.count
            let message: String
            if task.direction == .exportFromShelf {
                message = String(
                    format: String(localized: "%lld items delivered; %lld not delivered. Undelivered items remain on the shelf."),
                    Int64(successCount), Int64(failureCount)
                )
            } else {
                message = String(
                    format: String(localized: "%lld items added; %lld not added."),
                    Int64(successCount), Int64(failureCount)
                )
            }
            return AccessibilityAnnouncement(
                token: "\(task.id.uuidString).partial.\(successCount).\(failureCount)",
                message: message,
                priority: .high
            )
        case .failed:
            let message = task.direction == .exportFromShelf
                ? String(localized: "Delivery failed. The items remain on the shelf.")
                : String(localized: "The content could not be added.")
            return AccessibilityAnnouncement(
                token: "\(task.id.uuidString).failed",
                message: message,
                priority: .high
            )
        case .targetAccepted, .delivered, .cancelled:
            return nil
        }
    }
}

/// Long-lived deduplication and AppKit delivery boundary. Apple requires an
/// announcement string and a priority, posted for the application element.
@MainActor
final class AccessibilityAnnouncementCenter {
    typealias PostHandler = @MainActor (AccessibilityAnnouncement) -> Void

    private var postedTokens: Set<String> = []
    private let postHandler: PostHandler

    init(postHandler: @escaping PostHandler = AccessibilityAnnouncementCenter.postToSystem) {
        self.postHandler = postHandler
    }

    func announce(task: TransferTask?) {
        guard let task,
              let announcement = AccessibilityAnnouncementPlanner.announcement(for: task),
              postedTokens.insert(announcement.token).inserted else { return }
        postHandler(announcement)
    }

    static func postToSystem(_ announcement: AccessibilityAnnouncement) {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: NSNumber(value: announcement.priority.rawValue)
            ]
        )
    }
}

private struct AccessibilityAnnouncementCenterEnvironmentKey: EnvironmentKey {
    static var defaultValue: AccessibilityAnnouncementCenter? { nil }
}

extension EnvironmentValues {
    var accessibilityAnnouncementCenter: AccessibilityAnnouncementCenter? {
        get { self[AccessibilityAnnouncementCenterEnvironmentKey.self] }
        set { self[AccessibilityAnnouncementCenterEnvironmentKey.self] = newValue }
    }
}
