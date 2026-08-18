import XCTest
@testable import OpenYoink

final class PendingImportJournalTests: XCTestCase {
    private struct Context {
        let root: URL
        let managed: URL
        let journal: PendingImportJournal

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-PendingImport-\(UUID().uuidString)",
                                        isDirectory: true)
            managed = root.appendingPathComponent("Materialized", isDirectory: true)
            journal = PendingImportJournal(directoryURL: root, managedDirectoryURL: managed)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRecord(in context: Context) throws -> PendingImportJournal.Record {
        let staging = context.managed
            .appendingPathComponent("PromiseStaging-1", isDirectory: true)
            .appendingPathComponent("photo.png")
        let destination = context.managed.appendingPathComponent("final-photo.png")
        return try context.journal.create(
            stagingURL: staging,
            destinationURL: destination,
            displayName: "photo.png",
            promisedTypeIdentifiers: ["public.png"]
        )
    }

    func testMissingJournalPermitsCleanup() {
        let context = Context()
        defer { context.cleanup() }

        XCTAssertEqual(context.journal.loadResult(), .missing)
        XCTAssertTrue(context.journal.permitsOrphanCleanup)
        XCTAssertEqual(context.journal.protectedPaths(), [])
    }

    func testRecordRoundTripsAndProtectsBothCrashLocations() throws {
        let context = Context()
        defer { context.cleanup() }
        let created = try makeRecord(in: context)

        guard case .loaded(let records) = context.journal.loadResult() else {
            return XCTFail("Expected loaded pending import journal")
        }
        XCTAssertEqual(records, [created])
        XCTAssertEqual(created.displayName, "photo.png")
        XCTAssertEqual(created.promisedTypeIdentifiers, ["public.png"])
        XCTAssertEqual(context.journal.protectedPaths(), [
            created.stagingPath,
            created.destinationPath,
        ])
    }

    func testUpdateDestinationIsDurableBeforeRetryMove() throws {
        let context = Context()
        defer { context.cleanup() }
        let created = try makeRecord(in: context)
        let replacement = context.managed.appendingPathComponent("replacement.png")

        let updated = try context.journal.updateDestination(id: created.id, to: replacement)

        XCTAssertEqual(updated.destinationPath, replacement.path)
        XCTAssertEqual(context.journal.loadResult().records.first?.destinationPath,
                       replacement.path)
    }

    func testOutsideManagedPathsAreRejected() throws {
        let context = Context()
        defer { context.cleanup() }
        let staging = context.managed.appendingPathComponent("inside.txt")
        let outside = context.root.appendingPathComponent("outside.txt")

        XCTAssertThrowsError(try context.journal.create(
            stagingURL: staging,
            destinationURL: outside,
            displayName: "outside.txt",
            promisedTypeIdentifiers: []
        )) { error in
            XCTAssertEqual(error as? PendingImportJournal.JournalError,
                           .pathOutsideManagedDirectory)
        }
    }

    func testRemoveLastRecordDeletesJournalAndBackup() throws {
        let context = Context()
        defer { context.cleanup() }
        _ = try makeRecord(in: context)
        _ = try context.journal.create(
            stagingURL: context.managed.appendingPathComponent("PromiseStaging-2/second.txt"),
            destinationURL: context.managed.appendingPathComponent("second.txt"),
            displayName: "second.txt",
            promisedTypeIdentifiers: ["public.text"]
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("pending-imports.json.backup").path
        ))

        guard case .loaded(let records) = context.journal.loadResult() else {
            return XCTFail("Expected records")
        }
        for record in records {
            try context.journal.remove(id: record.id)
        }

        XCTAssertEqual(context.journal.loadResult(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("pending-imports.json.backup").path
        ))
    }

    func testDamagedJournalBlocksCleanupAndMutation() throws {
        let context = Context()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: context.root.appendingPathComponent("pending-imports.json")
        )

        XCTAssertEqual(context.journal.loadResult(), .failed)
        XCTAssertFalse(context.journal.permitsOrphanCleanup)
        XCTAssertThrowsError(try makeRecord(in: context)) { error in
            XCTAssertEqual(error as? PendingImportJournal.JournalError, .damaged)
        }
    }

    func testNewerSchemaBlocksCleanup() throws {
        let context = Context()
        defer { context.cleanup() }
        _ = try makeRecord(in: context)
        let url = context.root.appendingPathComponent("pending-imports.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1",
                                         with: "\"schemaVersion\" : 2")
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(context.journal.loadResult(), .failed)
        XCTAssertFalse(context.journal.permitsOrphanCleanup)
    }

    func testTamperedOutsidePathBlocksCleanup() throws {
        let context = Context()
        defer { context.cleanup() }
        _ = try makeRecord(in: context)
        let url = context.root.appendingPathComponent("pending-imports.json")
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0]["destinationPath"] = "/tmp/not-owned.txt"
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object)
            .write(to: url, options: .atomic)

        XCTAssertEqual(context.journal.loadResult(), .failed)
        XCTAssertFalse(context.journal.permitsOrphanCleanup)
    }
}
