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

/// Runtime-only source of truth for import/export activity. ShelfItem remains a
/// stable persisted content model; transient progress and failures never enter
/// shelf.json.
@MainActor
@Observable
final class TransferStore {
    private(set) var tasks: [TransferTask] = []
    private(set) var visibleTaskIDs: Set<UUID> = []

    /// ShelfWindowController uses this only to recalculate compact height when
    /// the strip appears or disappears. SwiftUI observes the task values.
    @ObservationIgnored var onVisibilityDidChange: (@MainActor () -> Void)?

    @ObservationIgnored private var failuresByTaskID: [UUID: [TransferFailure]] = [:]
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
            dismissalTasks[id]?.cancel()
            dismissalTasks.removeValue(forKey: id)
        }
    }
}
