import Foundation
import XCTest
@testable import OpenYoink

@MainActor
final class StorageManagementControllerTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-Storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ name: String, path: String? = nil) -> ShelfItem {
        ShelfItem(kind: .file, path: path ?? "/tmp/\(name)", displayName: name)
    }

    func testRestoreReplacesMemoryAndDiskWhilePreservingUndoBackup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let old = [item("old")]
        let current = [item("current")]
        try persistence.saveNow(old)
        try persistence.saveNow(current)
        let store = ShelfStore(items: current, persistence: persistence)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: store
        )
        let backup = try XCTUnwrap(controller.latestRecoverableSnapshot)

        controller.restore(backup)

        XCTAssertEqual(store.items.map(\.displayName), ["old"])
        XCTAssertEqual(persistence.load().map(\.displayName), ["old"])
        XCTAssertNil(controller.errorMessage)
        // 恢复前的 current 被 saveNow 反向保存在同一个 backup，可再次撤回。
        let undo = try XCTUnwrap(controller.latestRecoverableSnapshot)
        XCTAssertEqual(try persistence.loadRecoverySnapshot(undo).map(\.displayName), ["current"])
    }

    func testCleanupProtectsFilesReferencedOnlyByRecoverableBackup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let protectedURL = try temp.uniqueFileURL(suggestedName: "backup.dat")
        let orphanURL = try temp.uniqueFileURL(suggestedName: "orphan.dat")
        try Data([1]).write(to: protectedURL)
        try Data([2]).write(to: orphanURL)
        try persistence.saveNow([item("backup", path: protectedURL.path)])
        try persistence.saveNow([])
        let store = ShelfStore(items: [], persistence: persistence)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: store
        )

        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertNil(controller.errorMessage)
    }

    func testCleanupProtectsManagedMoveJournalFiles() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = ManagedMoveJournal(directoryURL: root)
        let protectedURL = try temp.uniqueFileURL(suggestedName: "moving.dat")
        let orphanURL = try temp.uniqueFileURL(suggestedName: "orphan.dat")
        try Data([1]).write(to: protectedURL)
        try Data([2]).write(to: orphanURL)
        let reference = item("source", path: root.appendingPathComponent("source.dat").path)
        let managed = ShelfItem(kind: .file,
                                path: protectedURL.path,
                                displayName: "moving.dat",
                                isCut: true)
        try journal.createPrepared(referenceItem: reference, managedItem: managed)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            managedMoveJournal: journal
        )

        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertNil(controller.errorMessage)
    }

    func testCleanupProtectsRuntimeDeliveryLease() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let leasedURL = try temp.uniqueFileURL(suggestedName: "delivering.dat")
        let orphanURL = try temp.uniqueFileURL(suggestedName: "orphan.dat")
        try Data([1]).write(to: leasedURL)
        try Data([2]).write(to: orphanURL)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            additionalProtectedPaths: { [leasedURL.path] }
        )

        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: leasedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testDamagedManagedMoveJournalDisablesCleanup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let orphanURL = try temp.uniqueFileURL(suggestedName: "keep.dat")
        try Data([1]).write(to: orphanURL)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("managed-moves.json"))
        let journal = ManagedMoveJournal(directoryURL: root)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            managedMoveJournal: journal
        )

        XCTAssertFalse(controller.canCleanUnusedFiles)
        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertNotNil(controller.errorMessage)
    }

    func testCleanupProtectsPendingImportCrashLocations() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let stagingDirectory = try temp.createPromiseStagingDirectory()
        let stagingURL = stagingDirectory.appendingPathComponent("received.txt")
        let destinationURL = try temp.uniqueFileURL(suggestedName: "received.txt")
        let orphanURL = try temp.uniqueFileURL(suggestedName: "orphan.txt")
        try Data("received".utf8).write(to: stagingURL)
        try Data("orphan".utf8).write(to: orphanURL)
        _ = try journal.create(stagingURL: stagingURL,
                               destinationURL: destinationURL,
                               displayName: "received.txt",
                               promisedTypeIdentifiers: ["public.text"])
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertNil(controller.errorMessage)
    }

    func testDamagedPendingImportJournalDisablesCleanup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let orphanURL = try temp.uniqueFileURL(suggestedName: "keep.dat")
        try Data([1]).write(to: orphanURL)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("pending-imports.json"))
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        XCTAssertFalse(controller.canCleanUnusedFiles)
        XCTAssertTrue(controller.isPendingImportRecoveryDamaged)
        controller.cleanUnusedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRetryPendingImportMovesPersistsAndClearsJournal() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let stagingDirectory = try temp.createPromiseStagingDirectory()
        let stagingURL = stagingDirectory.appendingPathComponent("received.txt")
        try Data("safe payload".utf8).write(to: stagingURL)
        let destinationURL = try temp.uniqueFileURL(suggestedName: "received.txt")
        let record = try journal.create(stagingURL: stagingURL,
                                        destinationURL: destinationURL,
                                        displayName: "received.txt",
                                        promisedTypeIdentifiers: ["public.text"])
        let store = ShelfStore(items: [], persistence: persistence)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: store,
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        controller.retryPendingImport(record)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].id, record.id)
        XCTAssertEqual(store.items[0].displayName, "received.txt")
        XCTAssertEqual(store.items[0].path, destinationURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(persistence.load().map(\.id), [record.id])
        XCTAssertEqual(journal.loadResult(), .missing)
        XCTAssertNil(controller.errorMessage)
    }

    func testRetryPendingImportIsIdempotentAfterShelfCommit() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let staging = materialized.appendingPathComponent("PromiseStaging-old/received.txt")
        let destination = try temp.uniqueFileURL(suggestedName: "received.txt")
        try Data("safe payload".utf8).write(to: destination)
        let record = try journal.create(stagingURL: staging,
                                        destinationURL: destination,
                                        displayName: "received.txt",
                                        promisedTypeIdentifiers: [])
        let existing = ShelfItem(id: record.id,
                                 kind: .file,
                                 path: destination.path,
                                 displayName: "received.txt")
        try persistence.saveNow([existing])
        let store = ShelfStore(items: [existing], persistence: persistence)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: store,
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        controller.retryPendingImport(record)

        XCTAssertEqual(store.items, [existing])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(journal.loadResult(), .missing)
        XCTAssertNil(controller.errorMessage)
    }

    func testRetryPrefersCompletedStagingPayloadWhenBothCrashPathsExist() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let stagingDirectory = try temp.createPromiseStagingDirectory()
        let staging = stagingDirectory.appendingPathComponent("received.txt")
        let interruptedDestination = try temp.uniqueFileURL(suggestedName: "received.txt")
        try Data("complete payload".utf8).write(to: staging)
        try Data("partial".utf8).write(to: interruptedDestination)
        let record = try journal.create(stagingURL: staging,
                                        destinationURL: interruptedDestination,
                                        displayName: "received.txt",
                                        promisedTypeIdentifiers: ["public.text"])
        let store = ShelfStore(items: [], persistence: persistence)
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: store,
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        controller.retryPendingImport(record)

        let importedPath = try XCTUnwrap(store.items.first?.path)
        XCTAssertNotEqual(importedPath, interruptedDestination.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)),
                       Data("complete payload".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptedDestination.path))
        XCTAssertEqual(journal.loadResult(), .missing)
        XCTAssertNil(controller.errorMessage)
    }

    func testDiscardPendingImportDeletesOnlyManagedRetainedCopies() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceController(directoryURL: root)
        let materialized = root.appendingPathComponent("Materialized", isDirectory: true)
        let temp = TempFileService(directoryURL: materialized)
        let journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: materialized)
        let stagingDirectory = try temp.createPromiseStagingDirectory()
        let staging = stagingDirectory.appendingPathComponent("received.txt")
        let destination = try temp.uniqueFileURL(suggestedName: "received.txt")
        try Data("staging".utf8).write(to: staging)
        try Data("destination".utf8).write(to: destination)
        let record = try journal.create(stagingURL: staging,
                                        destinationURL: destination,
                                        displayName: "received.txt",
                                        promisedTypeIdentifiers: [])
        let controller = StorageManagementController(
            persistence: persistence,
            tempFileService: temp,
            shelfStore: ShelfStore(items: [], persistence: persistence),
            pendingImportJournal: journal,
            bookmarkService: BookmarkService()
        )

        controller.discardPendingImport(record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(journal.loadResult(), .missing)
        XCTAssertNil(controller.errorMessage)
    }
}
