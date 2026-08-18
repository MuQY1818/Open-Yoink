import SwiftUI

/// Compact, non-blocking status for the newest transfer batch. It participates
/// in layout rather than overlaying the grid, so cards remain fully draggable.
struct ShelfActivityStrip: View {
    @Environment(TransferStore.self) private var transferStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let task = transferStore.currentTask {
            HStack(spacing: 8) {
                statusIcon(for: task)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: task))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let detail = detail(for: task) {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if canDismiss(task) {
                    Button {
                        transferStore.dismiss(taskID: task.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Dismiss transfer status"))
                    .help(Text("Dismiss"))
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, canDismiss(task) ? 5 : 9)
            .padding(.vertical, 6)
            .frame(minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.thinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor(for: task), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(accessibilitySummary(for: task)))
        }
    }

    @ViewBuilder
    private func statusIcon(for task: TransferTask) -> some View {
        switch task.phase {
        case .preparing, .receiving, .finalizing:
            if reduceMotion {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .targetAccepted:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .partiallySucceeded:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func title(for task: TransferTask) -> String {
        switch task.phase {
        case .preparing:
            if task.direction == .exportFromShelf {
                return String(localized: "Preparing items to deliver…")
            }
            return String(localized: "Preparing content…")
        case .receiving(let receivedCount, let expectedCount):
            if task.direction == .exportFromShelf {
                if let expectedCount, expectedCount > 1 {
                    return String(
                        format: String(localized: "Delivering items… %lld of %lld finished"),
                        Int64(receivedCount), Int64(expectedCount)
                    )
                }
                return String(localized: "Delivering item…")
            }
            if let expectedCount, expectedCount > 1 {
                return String(
                    format: String(localized: "Receiving content… %lld of %lld"),
                    Int64(receivedCount), Int64(expectedCount)
                )
            }
            if receivedCount > 0 {
                return String(
                    format: String(localized: "Receiving content… %lld received"),
                    Int64(receivedCount)
                )
            }
            return String(localized: "Receiving content…")
        case .finalizing:
            return String(localized: "Preparing received content…")
        case .targetAccepted:
            return String(
                format: String(localized: "Destination accepted %lld items"),
                Int64(task.itemIDs.count)
            )
        case .delivered:
            if task.direction == .exportFromShelf {
                return String(format: String(localized: "%lld items delivered"),
                              Int64(task.itemIDs.count))
            }
            return String(format: String(localized: "%lld items added"),
                          Int64(task.itemIDs.count))
        case .partiallySucceeded(let successCount, let failures):
            if task.direction == .exportFromShelf {
                return String(
                    format: String(localized: "%lld items delivered, %lld not delivered"),
                    Int64(successCount), Int64(failures.count)
                )
            }
            if failures.allSatisfy({ $0.reason == .managedMoveFellBackToReference }) {
                return String(
                    format: String(localized: "%lld items added, %lld added as references"),
                    Int64(successCount), Int64(failures.count)
                )
            }
            if failures.allSatisfy({ $0.impact == .itemAddedWithWarning }) {
                return String(
                    format: String(localized: "%lld items added with warnings"),
                    Int64(successCount)
                )
            }
            return String(
                format: String(localized: "%lld items added, %lld not added"),
                Int64(successCount), Int64(failures.count)
            )
        case .failed:
            if task.direction == .exportFromShelf {
                return String(localized: "Couldn't deliver this content")
            }
            return String(localized: "Couldn't add this content")
        case .cancelled:
            return String(localized: "Transfer cancelled")
        }
    }

    private func detail(for task: TransferTask) -> String? {
        switch task.phase {
        case .preparing, .receiving, .finalizing:
            return task.safetyMessage
        case .partiallySucceeded(_, let failures):
            return recoveryDetail(for: failures.first)
        case .failed(let failure):
            return recoveryDetail(for: failure)
        case .targetAccepted:
            return task.direction == .exportFromShelf
                ? String(localized: "The destination may still be copying the items.")
                : nil
        case .delivered, .cancelled:
            return nil
        }
    }

    private func recoveryDetail(for failure: TransferFailure?) -> String {
        let prefix = failure?.itemName.map { "\($0): " } ?? ""
        switch failure?.recoveryAction {
        case .openStorageRecovery:
            return prefix + String(localized: "Open Storage settings to review recovery data.")
        case .locateExternalFile:
            return prefix + String(localized: "Locate the original file to reconnect it.")
        case .retryByDraggingOut:
            return prefix + String(localized: "The item is still on the shelf. Drag it out again to retry.")
        case .dragAgainFromSource, .dismiss, nil:
            if failure?.reason == .managedMoveFellBackToReference {
                return prefix + String(localized: "The original file remains unchanged.")
            }
            return prefix + String(localized: "Drag the failed item from its source again.")
        }
    }

    private func canDismiss(_ task: TransferTask) -> Bool {
        switch task.phase {
        case .partiallySucceeded, .failed: true
        default: false
        }
    }

    private func borderColor(for task: TransferTask) -> Color {
        switch task.phase {
        case .partiallySucceeded: .orange.opacity(0.45)
        case .failed: .red.opacity(0.45)
        default: .primary.opacity(0.10)
        }
    }

    private func accessibilitySummary(for task: TransferTask) -> String {
        if let detail = detail(for: task) {
            return "\(title(for: task)). \(detail)"
        }
        return title(for: task)
    }
}
