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
    private(set) var materializedBytes: Int64 = 0
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let persistence: PersistenceController
    private let tempFileService: TempFileService
    private let shelfStore: ShelfStore
    private let managedMoveJournal: ManagedMoveJournal?
    private let additionalProtectedPaths: @MainActor () -> Set<String>
    private let prepareRestoredItems: @MainActor ([ShelfItem]) -> [ShelfItem]

    init(persistence: PersistenceController,
         tempFileService: TempFileService,
         shelfStore: ShelfStore,
         managedMoveJournal: ManagedMoveJournal? = nil,
         additionalProtectedPaths: @escaping @MainActor () -> Set<String> = { [] },
         prepareRestoredItems: @escaping @MainActor ([ShelfItem]) -> [ShelfItem] = { $0 }) {
        self.persistence = persistence
        self.tempFileService = tempFileService
        self.shelfStore = shelfStore
        self.managedMoveJournal = managedMoveJournal
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
        !hasQuarantinedData && (managedMoveJournal?.permitsManagedOrphanCleanup ?? true)
    }

    func refresh() {
        snapshots = persistence.recoverySnapshots()
        materializedBytes = tempFileService.storageUsage()
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
        guard persistence.canSafelyCleanupMaterializedOrphans(after: .loaded(shelfStore.items)) else {
            errorMessage = String(localized: "Resolve or delete quarantined recovery data before cleaning files.")
            refresh()
            return
        }

        let protectedItems = shelfStore.items + persistence.recoverableSnapshotItems()
        var protectedPaths = materializedPaths(in: protectedItems)
        protectedPaths.formUnion(managedMoveJournal?.protectedManagedPaths() ?? [])
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
}
