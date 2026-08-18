import AppKit
import Foundation

/// 设置页中的数据恢复与托管存储管理。
///
/// 所有删除都被限制在 OpenYoink 的 Application Support 目录；“清理未使用
/// 文件”还会同时保护当前 shelf 和可恢复快照引用的物化文件。存在无法解码的
/// 隔离快照时清理被禁用，因为无法可靠计算它引用了哪些文件。
@MainActor
@Observable
final class StorageManagementController {
    private(set) var snapshots: [PersistenceController.RecoverySnapshot] = []
    private(set) var pendingImports: [PendingImportJournal.Record] = []
    private(set) var isPendingImportRecoveryDamaged = false
    private(set) var materializedBytes: Int64 = 0
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let persistence: PersistenceController
    private let tempFileService: TempFileService
    private let shelfStore: ShelfStore
    private let managedMoveJournal: ManagedMoveJournal?
    private let pendingImportJournal: PendingImportJournal?
    private let bookmarkService: BookmarkService?
    private let additionalProtectedPaths: @MainActor () -> Set<String>
    private let prepareRestoredItems: @MainActor ([ShelfItem]) -> [ShelfItem]

    init(persistence: PersistenceController,
         tempFileService: TempFileService,
         shelfStore: ShelfStore,
         managedMoveJournal: ManagedMoveJournal? = nil,
         pendingImportJournal: PendingImportJournal? = nil,
         bookmarkService: BookmarkService? = nil,
         additionalProtectedPaths: @escaping @MainActor () -> Set<String> = { [] },
         prepareRestoredItems: @escaping @MainActor ([ShelfItem]) -> [ShelfItem] = { $0 }) {
        self.persistence = persistence
        self.tempFileService = tempFileService
        self.shelfStore = shelfStore
        self.managedMoveJournal = managedMoveJournal
        self.pendingImportJournal = pendingImportJournal
        self.bookmarkService = bookmarkService
        self.additionalProtectedPaths = additionalProtectedPaths
        self.prepareRestoredItems = prepareRestoredItems
        refresh()
    }

    var latestRecoverableSnapshot: PersistenceController.RecoverySnapshot? {
        snapshots.first { $0.isRecoverable }
    }

    var hasQuarantinedData: Bool {
        snapshots.contains { $0.kind == .quarantined }
    }

    var canCleanUnusedFiles: Bool {
        !hasQuarantinedData
            && (managedMoveJournal?.permitsManagedOrphanCleanup ?? true)
            && (pendingImportJournal?.permitsOrphanCleanup ?? true)
    }

    func refresh() {
        snapshots = persistence.recoverySnapshots()
        switch pendingImportJournal?.loadResult() {
        case .loaded(let records):
            pendingImports = records.sorted { $0.createdAt > $1.createdAt }
            isPendingImportRecoveryDamaged = false
        case .failed:
            pendingImports = []
            isPendingImportRecoveryDamaged = true
        case .missing, nil:
            pendingImports = []
            isPendingImportRecoveryDamaged = false
        }
        materializedBytes = tempFileService.storageUsage()
    }

    /// Finishes one interrupted promised-file import. The payload can be at
    /// either recorded path; moving, bookmark creation and shelf persistence
    /// are all idempotent across retries.
    func retryPendingImport(_ pending: PendingImportJournal.Record) {
        statusMessage = nil
        errorMessage = nil
        guard let journal = pendingImportJournal,
              let bookmarkService else {
            errorMessage = String(localized: "Pending import recovery is unavailable.")
            return
        }

        do {
            if containsItem(id: pending.id, in: shelfStore.items) {
                try journal.remove(id: pending.id)
                statusMessage = String(localized: "This file was already imported. Its recovery record was cleared.")
                refresh()
                return
            }

            let fileManager = FileManager.default
            var record = pending
            let stagingURL = URL(fileURLWithPath: record.stagingPath)
            let recordedDestinationURL = URL(fileURLWithPath: record.destinationPath)
            let stagingExists = fileManager.fileExists(atPath: stagingURL.path)
            let destinationExists = fileManager.fileExists(atPath: recordedDestinationURL.path)
            guard stagingExists || destinationExists else {
                throw PendingImportRecoveryError.payloadMissing
            }

            let payloadURL: URL
            if stagingExists {
                // If both candidates exist, the destination may be an
                // interrupted/partial copy. The source application's completed
                // staging payload is authoritative; reserve a fresh path and
                // update the journal before moving it.
                let destinationURL: URL
                if destinationExists {
                    destinationURL = try tempFileService.uniqueFileURL(
                        suggestedName: record.displayName
                    )
                    record = try journal.updateDestination(id: record.id, to: destinationURL)
                } else {
                    destinationURL = recordedDestinationURL
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                payloadURL = destinationURL
            } else {
                payloadURL = recordedDestinationURL
            }

            let bookmark = try bookmarkService.createBookmark(for: payloadURL)
            let item = ShelfItem(
                id: record.id,
                kind: DropImportCoordinator.inferFileKind(
                    for: payloadURL,
                    promisedTypeIdentifiers: record.promisedTypeIdentifiers
                ),
                path: payloadURL.path,
                bookmark: bookmark,
                displayName: record.displayName,
                addedAt: record.createdAt
            )
            try shelfStore.addAndPersistNow(item)

            // A cross-volume move interrupted after copying may leave the
            // staging source too. It is app-owned and now redundant.
            if stagingURL.standardizedFileURL != payloadURL.standardizedFileURL {
                try? tempFileService.removeMaterializedFile(at: stagingURL)
            }
            do {
                try journal.remove(id: record.id)
                statusMessage = String(localized: "The received file was imported successfully.")
            } catch {
                // The item is already durable and startup reconciliation will
                // safely remove the stale record.
                statusMessage = String(localized: "The file was imported. Recovery cleanup will finish automatically later.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Deletes only app-owned copies after explicit user confirmation.
    func discardPendingImport(_ pending: PendingImportJournal.Record) {
        statusMessage = nil
        errorMessage = nil
        guard let journal = pendingImportJournal else { return }
        do {
            // A stale record may survive a crash immediately after shelf save.
            // Never delete the payload of an already-persisted item.
            if containsItem(id: pending.id, in: shelfStore.items) {
                try journal.remove(id: pending.id)
            } else {
                try journal.remove(id: pending.id)
                for path in Set([pending.stagingPath, pending.destinationPath]) {
                    try tempFileService.removeMaterializedFile(at: URL(fileURLWithPath: path))
                }
            }
            statusMessage = String(localized: "The pending import was deleted.")
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func restore(_ snapshot: PersistenceController.RecoverySnapshot) {
        statusMessage = nil
        errorMessage = nil
        do {
            // 先完整解码，再同步保存；只有保存成功才替换内存，避免 UI 与磁盘
            // 分叉。saveNow 会把恢复前的当前状态写成新的 last-known-good，故可撤回。
            let decodedItems = try persistence.loadRecoverySnapshot(snapshot)
            let restoredItems = prepareRestoredItems(decodedItems)
            try persistence.saveNow(restoredItems)
            shelfStore.replaceWithPersistedItems(restoredItems)
            if snapshot.kind == .quarantined {
                try persistence.discardRecoverySnapshot(snapshot)
            }
            statusMessage = String(localized: "Shelf data was restored successfully.")
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func discardAllRecoveryData() {
        statusMessage = nil
        errorMessage = nil
        do {
            for snapshot in snapshots {
                try persistence.discardRecoverySnapshot(snapshot)
            }
            statusMessage = String(localized: "Recovery data was deleted.")
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func cleanUnusedFiles() {
        statusMessage = nil
        errorMessage = nil
        guard managedMoveJournal?.permitsManagedOrphanCleanup ?? true else {
            errorMessage = String(localized: "Resolve managed move recovery data before cleaning files.")
            refresh()
            return
        }
        guard pendingImportJournal?.permitsOrphanCleanup ?? true else {
            errorMessage = String(localized: "Resolve pending import recovery data before cleaning files.")
            refresh()
            return
        }
        guard persistence.canSafelyCleanupMaterializedOrphans(after: .loaded(shelfStore.items)) else {
            errorMessage = String(localized: "Resolve or delete quarantined recovery data before cleaning files.")
            refresh()
            return
        }

        let protectedItems = shelfStore.items + persistence.recoverableSnapshotItems()
        var protectedPaths = materializedPaths(in: protectedItems)
        protectedPaths.formUnion(managedMoveJournal?.protectedManagedPaths() ?? [])
        protectedPaths.formUnion(pendingImportJournal?.protectedPaths() ?? [])
        protectedPaths.formUnion(additionalProtectedPaths())
        let result = tempFileService.cleanupOrphans(keepingPaths: protectedPaths)
        if result.removedItemCount == 0 {
            statusMessage = String(localized: "No unused files were found.")
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: result.reclaimedBytes,
                                                  countStyle: .file)
            statusMessage = String(
                format: String(localized: "Removed %lld unused items and reclaimed %@."),
                Int64(result.removedItemCount),
                bytes
            )
        }
        refresh()
    }

    func revealDataFolder() {
        do {
            try FileManager.default.createDirectory(
                at: persistence.directoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([persistence.directoryURL])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func materializedPaths(in items: [ShelfItem]) -> Set<String> {
        let root = tempFileService.directoryURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var result = Set<String>()
        for item in items {
            if let path = item.path {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                if standardized.hasPrefix(prefix) {
                    result.insert(standardized)
                }
            }
            if let children = item.children {
                result.formUnion(materializedPaths(in: children))
            }
        }
        return result
    }

    private func containsItem(id: UUID, in items: [ShelfItem]) -> Bool {
        items.contains { item in
            item.id == id || containsItem(id: id, in: item.children ?? [])
        }
    }
}

private enum PendingImportRecoveryError: LocalizedError {
    case payloadMissing

    var errorDescription: String? {
        switch self {
        case .payloadMissing:
            String(localized: "The retained file is missing. It cannot be imported automatically.")
        }
    }
}
