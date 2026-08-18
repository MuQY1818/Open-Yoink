import Foundation
import Observation

enum TransferDirection: Equatable, Sendable {
    case importIntoShelf
    case exportFromShelf
}

enum TransferFailureReason: Equatable, Sendable {
    case unsupportedFormat
    case sourceUnavailable
    case promiseReceiveFailed
    case materializationFailed
    case bookmarkFailed
    case persistenceFailed
    case deliveryFailed
    case externalFileOffline
    case managedCopyMissing
    /// A destructive managed move was not attempted/completed, but a normal
    /// reference item was safely added instead.
    case managedMoveFellBackToReference
}

enum RecoveryAction: Equatable, Sendable {
    case dragAgainFromSource
    case locateExternalFile(itemID: UUID)
    case retryByDraggingOut(itemID: UUID)
    case openStorageRecovery
    case dismiss
}

enum TransferFailureImpact: Equatable, Sendable {
    case itemNotAdded
    case itemAddedWithWarning
}

struct TransferFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let reason: TransferFailureReason
    let itemName: String?
    let recoveryAction: RecoveryAction
    let impact: TransferFailureImpact

    init(id: UUID = UUID(),
         reason: TransferFailureReason,
         itemName: String? = nil,
         recoveryAction: RecoveryAction,
         impact: TransferFailureImpact = .itemNotAdded) {
        self.id = id
        self.reason = reason
        self.itemName = itemName
        self.recoveryAction = recoveryAction
        self.impact = impact
    }
}

enum TransferPhase: Equatable, Sendable {
    case preparing
    case receiving(receivedCount: Int, expectedCount: Int?)
    case finalizing
    case targetAccepted
    case delivered
    case partiallySucceeded(successCount: Int, failures: [TransferFailure])
    case failed(TransferFailure)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .delivered, .partiallySucceeded, .failed, .cancelled:
            true
        case .preparing, .receiving, .finalizing, .targetAccepted:
            false
        }
    }
}

struct TransferTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: TransferDirection
    let startedAt: Date
    var itemIDs: [UUID]
    var phase: TransferPhase
    var safetyMessage: String
    var expectedCount: Int?
}

/// Runtime status appended to a card's VoiceOver label. It intentionally stays
/// outside ShelfItem so transient transfer state never enters shelf.json.
enum TransferItemAccessibilityStatus: Equatable, Sendable {
    case receiving
    case delivering
    case destinationAccepted
    case added
    case delivered
    case deliveryFailed

    var localizedDescription: String {
        switch self {
        case .receiving: String(localized: "Received; batch still in progress")
        case .delivering: String(localized: "Delivery in progress")
        case .destinationAccepted: String(localized: "Destination accepted")
        case .added: String(localized: "Added to the shelf")
        case .delivered: String(localized: "Delivered")
        case .deliveryFailed: String(localized: "Delivery failed; item remains on the shelf")
        }
    }
}

/// Runtime-only source of truth for import/export activity. ShelfItem remains a
/// stable persisted content model; transient progress and failures never enter
/// shelf.json.
@MainActor
@Observable
final class TransferStore {
    private struct ExportProgress {
        let expectedItemIDs: [UUID]
        var acceptedItemIDs: Set<UUID> = []
        var deliveredItemIDs: Set<UUID> = []
        var failuresByItemID: [UUID: TransferFailure] = [:]
        var sessionAccepted = false
    }

    private(set) var tasks: [TransferTask] = []
    private(set) var visibleTaskIDs: Set<UUID> = []

    /// ShelfWindowController uses this only to recalculate compact height when
    /// the strip appears or disappears. SwiftUI observes the task values.
    @ObservationIgnored var onVisibilityDidChange: (@MainActor () -> Void)?

    @ObservationIgnored private var failuresByTaskID: [UUID: [TransferFailure]] = [:]
    @ObservationIgnored private var exportProgressByTaskID: [UUID: ExportProgress] = [:]
    @ObservationIgnored private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let successDisplayDuration: Duration

    init(successDisplayDuration: Duration = .milliseconds(1500)) {
        self.successDisplayDuration = successDisplayDuration
    }

    var visibleTasks: [TransferTask] {
        tasks.filter { visibleTaskIDs.contains($0.id) }
    }

    var currentTask: TransferTask? {
        visibleTasks.max { $0.startedAt < $1.startedAt }
    }

    var hasVisibleActivity: Bool { currentTask != nil }

    /// Card-level status for the newest visible batch. Import failures have no
    /// card to annotate; export status can be mapped through the private
    /// expected-item progress without exposing delivery internals to the UI.
    func accessibilityStatus(for itemID: UUID) -> TransferItemAccessibilityStatus? {
        guard let task = currentTask else { return nil }
        if task.direction == .exportFromShelf,
           let progress = exportProgressByTaskID[task.id],
           progress.expectedItemIDs.contains(itemID) {
            if progress.failuresByItemID[itemID] != nil { return .deliveryFailed }
            if progress.deliveredItemIDs.contains(itemID) { return .delivered }
            if progress.acceptedItemIDs.contains(itemID) { return .destinationAccepted }
            switch task.phase {
            case .failed: return .deliveryFailed
            case .cancelled: return nil
            default: return .delivering
            }
        }

        guard task.direction == .importIntoShelf,
              task.itemIDs.contains(itemID) else { return nil }
        switch task.phase {
        case .preparing, .receiving, .finalizing: return .receiving
        case .delivered, .partiallySucceeded: return .added
        case .targetAccepted, .failed, .cancelled: return nil
        }
    }

    /// Creates an import batch only when the caller has actually dispatched
    /// asynchronous work. Supplying a stable id lets fallback materializers
    /// merge multiple pasteboard items into the same batch.
    @discardableResult
    func beginImport(id: UUID = UUID(),
                     expectedCount: Int? = nil,
                     safetyMessage: String = String(localized: "Original files remain unchanged.")) -> UUID {
        guard taskIndex(id: id) == nil else {
            if let expectedCount {
                setExpectedCount(expectedCount, for: id)
            }
            return id
        }
        let wasVisible = hasVisibleActivity
        tasks.append(TransferTask(
            id: id,
            direction: .importIntoShelf,
            startedAt: Date(),
            itemIDs: [],
            phase: .receiving(receivedCount: 0, expectedCount: expectedCount),
            safetyMessage: safetyMessage,
            expectedCount: expectedCount
        ))
        visibleTaskIDs.insert(id)
        failuresByTaskID[id] = []
        trimHistory()
        notifyVisibilityChange(ifPreviously: wasVisible)
        completeIfReady(id: id)
        return id
    }

    /// Starts one drag-out session. The task does not claim success until the
    /// destination accepts the drag, and it distinguishes direct
    /// representations from file promises whose write completion is known.
    @discardableResult
    func beginExport(id: UUID = UUID(),
                     itemIDs: [UUID],
                     safetyMessage: String = String(localized: "Items stay on the shelf if delivery fails.")) -> UUID {
        guard taskIndex(id: id) == nil else { return id }
        let uniqueItemIDs = itemIDs.reduce(into: [UUID]()) { result, itemID in
            if !result.contains(itemID) {
                result.append(itemID)
            }
        }
        guard !uniqueItemIDs.isEmpty else { return id }

        let wasVisible = hasVisibleActivity
        tasks.append(TransferTask(
            id: id,
            direction: .exportFromShelf,
            startedAt: Date(),
            itemIDs: [],
            phase: .preparing,
            safetyMessage: safetyMessage,
            expectedCount: uniqueItemIDs.count
        ))
        visibleTaskIDs.insert(id)
        failuresByTaskID[id] = []
        exportProgressByTaskID[id] = ExportProgress(expectedItemIDs: uniqueItemIDs)
        trimHistory()
        notifyVisibilityChange(ifPreviously: wasVisible)
        return id
    }

    /// A destination asked the provider to materialize a promised file. A
    /// late request revokes an earlier direct-representation assumption until
    /// the provider reports delivered or failed.
    func recordExportPromiseRequested(taskID: UUID, itemID: UUID) {
        guard var progress = exportProgressByTaskID[taskID],
              progress.expectedItemIDs.contains(itemID) else { return }
        dismissalTasks[taskID]?.cancel()
        dismissalTasks[taskID] = nil
        makeVisible(taskID)
        progress.acceptedItemIDs.remove(itemID)
        exportProgressByTaskID[taskID] = progress
        refreshExportTask(taskID: taskID)
    }

    func recordExportDelivered(taskID: UUID, itemID: UUID) {
        guard var progress = exportProgressByTaskID[taskID],
              progress.expectedItemIDs.contains(itemID) else { return }
        dismissalTasks[taskID]?.cancel()
        dismissalTasks[taskID] = nil
        makeVisible(taskID)
        progress.acceptedItemIDs.remove(itemID)
        progress.failuresByItemID.removeValue(forKey: itemID)
        progress.deliveredItemIDs.insert(itemID)
        exportProgressByTaskID[taskID] = progress
        refreshExportTask(taskID: taskID)
    }

    func recordExportFailure(taskID: UUID,
                             itemID: UUID,
                             failure: TransferFailure) {
        guard var progress = exportProgressByTaskID[taskID],
              progress.expectedItemIDs.contains(itemID) else { return }
        dismissalTasks[taskID]?.cancel()
        dismissalTasks[taskID] = nil
        makeVisible(taskID)
        progress.acceptedItemIDs.remove(itemID)
        progress.deliveredItemIDs.remove(itemID)
        progress.failuresByItemID[itemID] = failure
        exportProgressByTaskID[taskID] = progress
        refreshExportTask(taskID: taskID)
    }

    /// Closes the AppKit drag session. A non-empty drag operation means only
    /// that the destination accepted it; direct representations therefore end
    /// at `.targetAccepted`, while promised files still wait for their writer
    /// callbacks.
    func finishExportSession(taskID: UUID,
                             accepted: Bool,
                             directlyAcceptedItemIDs: Set<UUID> = []) {
        guard var progress = exportProgressByTaskID[taskID] else { return }
        guard accepted else {
            cancel(taskID: taskID)
            return
        }
        progress.sessionAccepted = true
        for itemID in directlyAcceptedItemIDs
        where progress.expectedItemIDs.contains(itemID)
            && !progress.deliveredItemIDs.contains(itemID)
            && progress.failuresByItemID[itemID] == nil {
            progress.acceptedItemIDs.insert(itemID)
        }
        exportProgressByTaskID[taskID] = progress
        refreshExportTask(taskID: taskID)
    }

    /// Adds work discovered while traversing a heterogeneous fallback batch.
    func extendImport(id: UUID,
                      by additionalCount: Int,
                      safetyMessage: String = String(localized: "Original files remain unchanged.")) {
        guard additionalCount > 0 else { return }
        if taskIndex(id: id) == nil {
            beginImport(id: id, expectedCount: additionalCount, safetyMessage: safetyMessage)
            return
        }
        let current = tasks[taskIndex(id: id)!].expectedCount ?? 0
        setExpectedCount(current + additionalCount, for: id)
    }

    /// File promises learn their actual filenames only after receiving has been
    /// requested. Until then expectedCount is nil and no premature terminal
    /// state is emitted.
    func setExpectedCount(_ expectedCount: Int, for id: UUID) {
        guard expectedCount > 0, let index = taskIndex(id: id) else { return }
        // A heterogeneous batch may discover more work after an earlier fast
        // item already reached `.delivered`. Reopen it and cancel the stale
        // success timer before increasing the total.
        dismissalTasks[id]?.cancel()
        dismissalTasks[id] = nil
        makeVisible(id)
        tasks[index].expectedCount = expectedCount
        updateReceivingPhase(at: index)
        completeIfReady(id: id)
    }

    func recordSuccess(taskID: UUID, itemID: UUID) {
        guard let index = taskIndex(id: taskID) else { return }
        dismissalTasks[taskID]?.cancel()
        makeVisible(taskID)
        if !tasks[index].itemIDs.contains(itemID) {
            tasks[index].itemIDs.append(itemID)
        }
        updateReceivingPhase(at: index)
        completeIfReady(id: taskID)
    }

    func recordFailure(taskID: UUID, failure: TransferFailure) {
        guard let index = taskIndex(id: taskID) else { return }
        dismissalTasks[taskID]?.cancel()
        makeVisible(taskID)
        var failures = failuresByTaskID[taskID] ?? []
        failures.append(failure)
        failuresByTaskID[taskID] = failures
        updateReceivingPhase(at: index)
        completeIfReady(id: taskID)
    }

    /// Records a completed item that also carries a non-destructive warning,
    /// such as a requested managed move safely falling back to a reference.
    func recordWarning(taskID: UUID, itemID: UUID, warning: TransferFailure) {
        guard let index = taskIndex(id: taskID) else { return }
        dismissalTasks[taskID]?.cancel()
        makeVisible(taskID)
        if !tasks[index].itemIDs.contains(itemID) {
            tasks[index].itemIDs.append(itemID)
        }
        var failures = failuresByTaskID[taskID] ?? []
        failures.append(warning)
        failuresByTaskID[taskID] = failures
        updateReceivingPhase(at: index)
        completeIfReady(id: taskID)
    }

    /// Explicitly closes a batch whose producer cannot provide an expected
    /// count. Known-count imports finish automatically as outcomes arrive.
    func finish(taskID: UUID) {
        guard let index = taskIndex(id: taskID) else { return }
        tasks[index].expectedCount = outcomeCount(for: taskID)
        completeIfReady(id: taskID)
    }

    func cancel(taskID: UUID) {
        guard let index = taskIndex(id: taskID) else { return }
        tasks[index].phase = .cancelled
        dismiss(taskID: taskID)
    }

    func dismiss(taskID: UUID) {
        dismissalTasks[taskID]?.cancel()
        dismissalTasks[taskID] = nil
        let wasVisible = hasVisibleActivity
        visibleTaskIDs.remove(taskID)
        notifyVisibilityChange(ifPreviously: wasVisible)
    }

    // MARK: - State reduction

    private func completeIfReady(id: UUID) {
        guard let index = taskIndex(id: id),
              let expectedCount = tasks[index].expectedCount,
              outcomeCount(for: id) >= expectedCount else { return }

        let failures = failuresByTaskID[id] ?? []
        let successCount = tasks[index].itemIDs.count
        if failures.isEmpty {
            tasks[index].phase = .delivered
            scheduleSuccessDismissal(taskID: id)
        } else if successCount > 0 {
            tasks[index].phase = .partiallySucceeded(successCount: successCount,
                                                      failures: failures)
        } else {
            tasks[index].phase = .failed(failures[0])
        }
    }

    private func refreshExportTask(taskID: UUID) {
        guard let index = taskIndex(id: taskID),
              let progress = exportProgressByTaskID[taskID] else { return }

        let successfulIDs = progress.acceptedItemIDs.union(progress.deliveredItemIDs)
        tasks[index].itemIDs = progress.expectedItemIDs.filter(successfulIDs.contains)
        let failures = progress.expectedItemIDs.compactMap { progress.failuresByItemID[$0] }
        failuresByTaskID[taskID] = failures

        let outcomeCount = successfulIDs.count + failures.count
        guard progress.sessionAccepted,
              outcomeCount >= progress.expectedItemIDs.count else {
            if progress.sessionAccepted {
                tasks[index].phase = .receiving(
                    receivedCount: outcomeCount,
                    expectedCount: progress.expectedItemIDs.count
                )
            } else {
                tasks[index].phase = .preparing
            }
            return
        }

        if failures.isEmpty {
            if progress.deliveredItemIDs.count == progress.expectedItemIDs.count {
                tasks[index].phase = .delivered
            } else {
                tasks[index].phase = .targetAccepted
            }
            scheduleSuccessDismissal(taskID: taskID)
        } else if !successfulIDs.isEmpty {
            tasks[index].phase = .partiallySucceeded(
                successCount: successfulIDs.count,
                failures: failures
            )
        } else {
            tasks[index].phase = .failed(failures[0])
        }
    }

    private func updateReceivingPhase(at index: Int) {
        let task = tasks[index]
        tasks[index].phase = .receiving(
            receivedCount: task.itemIDs.count,
            expectedCount: task.expectedCount
        )
    }

    private func outcomeCount(for id: UUID) -> Int {
        guard let index = taskIndex(id: id) else { return 0 }
        let hardFailureCount = failuresByTaskID[id]?.count {
            $0.impact == .itemNotAdded
        } ?? 0
        return tasks[index].itemIDs.count + hardFailureCount
    }

    private func taskIndex(id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    private func makeVisible(_ id: UUID) {
        let wasVisible = hasVisibleActivity
        visibleTaskIDs.insert(id)
        notifyVisibilityChange(ifPreviously: wasVisible)
    }

    private func scheduleSuccessDismissal(taskID: UUID) {
        dismissalTasks[taskID]?.cancel()
        dismissalTasks[taskID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.successDisplayDuration ?? .milliseconds(1500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss(taskID: taskID)
        }
    }

    private func notifyVisibilityChange(ifPreviously wasVisible: Bool) {
        if wasVisible != hasVisibleActivity {
            onVisibilityDidChange?()
        }
    }

    private func trimHistory() {
        guard tasks.count > 64 else { return }
        let removableIDs = tasks
            .filter { !visibleTaskIDs.contains($0.id) }
            .prefix(tasks.count - 64)
            .map(\.id)
        guard !removableIDs.isEmpty else { return }
        let ids = Set(removableIDs)
        tasks.removeAll { ids.contains($0.id) }
        for id in ids {
            failuresByTaskID.removeValue(forKey: id)
            exportProgressByTaskID.removeValue(forKey: id)
            dismissalTasks[id]?.cancel()
            dismissalTasks.removeValue(forKey: id)
        }
    }
}
