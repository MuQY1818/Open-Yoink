import XCTest
@testable import OpenYoink

final class ManagedMoveJournalTests: XCTestCase {
    private struct Context {
        let root: URL
        let journal: ManagedMoveJournal

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-ManagedMoveJournal-\(UUID().uuidString)",
                                        isDirectory: true)
            journal = ManagedMoveJournal(directoryURL: root)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeItems(root: URL) -> (reference: ShelfItem, managed: ShelfItem) {
        let reference = ShelfItem(
            kind: .file,
            path: root.appendingPathComponent("source.txt").path,
            displayName: "source.txt"
        )
        let managed = ShelfItem(
            kind: .file,
            path: root.appendingPathComponent("Materialized/managed-source.txt").path,
            displayName: "source.txt",
            isCut: true
        )
        return (reference, managed)
    }

    func testMissingJournalPermitsCleanup() {
        let context = Context()
        defer { context.cleanup() }

        XCTAssertEqual(context.journal.loadResult(), .missing)
        XCTAssertTrue(context.journal.permitsManagedOrphanCleanup)
        XCTAssertEqual(context.journal.protectedManagedPaths(), [])
    }

    func testPreparedRecordRoundTripsAndProtectsManagedPath() throws {
        let context = Context()
        defer { context.cleanup() }
        let items = makeItems(root: context.root)

        try context.journal.createPrepared(referenceItem: items.reference,
                                           managedItem: items.managed)

        guard case .loaded(let records) = context.journal.loadResult() else {
            return XCTFail("Expected a loaded journal")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .prepared)
        XCTAssertEqual(records[0].referenceItem, items.reference)
        XCTAssertEqual(records[0].managedItem, items.managed)
        XCTAssertEqual(records[0].id, items.managed.id)
        XCTAssertEqual(context.journal.protectedManagedPaths(), [items.managed.path!])
    }

    func testOriginalTrashedTransitionPersistsResultingPath() throws {
        let context = Context()
        defer { context.cleanup() }
        let items = makeItems(root: context.root)
        let trashURL = context.root.appendingPathComponent("Trash/source.txt")
        try context.journal.createPrepared(referenceItem: items.reference,
                                           managedItem: items.managed)

        try context.journal.markOriginalTrashed(id: items.managed.id,
                                                resultingURL: trashURL)

        guard case .loaded(let records) = context.journal.loadResult() else {
            return XCTFail("Expected a loaded journal")
        }
        XCTAssertEqual(records[0].state, .originalTrashed)
        XCTAssertEqual(records[0].resultingTrashPath, trashURL.path)
    }

    func testRemoveLastRecordDeletesJournal() throws {
        let context = Context()
        defer { context.cleanup() }
        let items = makeItems(root: context.root)
        try context.journal.createPrepared(referenceItem: items.reference,
                                           managedItem: items.managed)

        try context.journal.remove(id: items.managed.id)

        XCTAssertEqual(context.journal.loadResult(), .missing)
        XCTAssertTrue(context.journal.permitsManagedOrphanCleanup)
    }

    func testRemovingAllRecordsAlsoDeletesStaleBackup() throws {
        let context = Context()
        defer { context.cleanup() }
        let first = makeItems(root: context.root)
        let second = makeItems(root: context.root)
        try context.journal.createPrepared(referenceItem: first.reference,
                                           managedItem: first.managed)
        try context.journal.createPrepared(referenceItem: second.reference,
                                           managedItem: second.managed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("managed-moves.json.backup").path
        ))

        try context.journal.remove(id: first.managed.id)
        try context.journal.remove(id: second.managed.id)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("managed-moves.json.backup").path
        ))
    }

    func testDamagedJournalBlocksCleanupAndMutation() throws {
        let context = Context()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: context.root.appendingPathComponent("managed-moves.json")
        )
        let items = makeItems(root: context.root)

        XCTAssertEqual(context.journal.loadResult(), .failed)
        XCTAssertFalse(context.journal.permitsManagedOrphanCleanup)
        XCTAssertThrowsError(try context.journal.createPrepared(
            referenceItem: items.reference,
            managedItem: items.managed
        )) { error in
            XCTAssertEqual(error as? ManagedMoveJournal.JournalError, .damaged)
        }
    }

    func testNewerSchemaBlocksCleanup() throws {
        let context = Context()
        defer { context.cleanup() }
        let items = makeItems(root: context.root)
        try context.journal.createPrepared(referenceItem: items.reference,
                                           managedItem: items.managed)
        let journalURL = context.root.appendingPathComponent("managed-moves.json")
        var text = try String(contentsOf: journalURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1",
                                         with: "\"schemaVersion\" : 2")
        try text.write(to: journalURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(context.journal.loadResult(), .failed)
        XCTAssertFalse(context.journal.permitsManagedOrphanCleanup)
    }

    // MARK: - Recovery decision table

    func testRecoveryPlannerCoversEveryCrashWindow() {
        let context = Context()
        defer { context.cleanup() }
        let items = makeItems(root: context.root)
        let prepared = ManagedMoveJournal.Record(
            state: .prepared,
            referenceItem: items.reference,
            managedItem: items.managed,
            resultingTrashPath: nil,
            createdAt: Date()
        )
        var trashed = prepared
        trashed.state = .originalTrashed

        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: prepared,
                sourceExists: true,
                managedExists: true,
                persistedItemIDs: [items.managed.id]
            ),
            .alreadyCommitted
        )
        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: prepared,
                sourceExists: true,
                managedExists: true,
                persistedItemIDs: []
            ),
            .recoverManaged
        )
        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: prepared,
                sourceExists: false,
                managedExists: true,
                persistedItemIDs: []
            ),
            .recoverManaged
        )
        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: trashed,
                sourceExists: true,
                managedExists: true,
                persistedItemIDs: []
            ),
            .recoverManaged
        )
        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: trashed,
                sourceExists: true,
                managedExists: false,
                persistedItemIDs: []
            ),
            .recoverReference
        )
        XCTAssertEqual(
            ManagedMoveRecoveryPlanner.decision(
                for: trashed,
                sourceExists: false,
                managedExists: false,
                persistedItemIDs: []
            ),
            .unresolved
        )
    }
}
