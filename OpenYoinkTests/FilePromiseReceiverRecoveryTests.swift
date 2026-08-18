import Foundation
import OSLog
import XCTest
@testable import OpenYoink

final class FilePromiseReceiverRecoveryTests: XCTestCase {
    private struct Context {
        let root: URL
        let materialized: URL
        let temp: TempFileService
        let journal: PendingImportJournal
        let bookmarks = BookmarkService()
        let logger = Logger(subsystem: "com.weijue.OpenYoinkTests", category: "FilePromise")

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-PromiseRecovery-\(UUID().uuidString)",
                                        isDirectory: true)
            materialized = root.appendingPathComponent("Materialized", isDirectory: true)
            temp = TempFileService(directoryURL: materialized)
            journal = PendingImportJournal(directoryURL: root,
                                           managedDirectoryURL: materialized)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testFinalizationJournalsBeforeProducingStableItem() throws {
        let context = Context()
        defer { context.cleanup() }
        let stagingDirectory = try context.temp.createPromiseStagingDirectory()
        let staging = stagingDirectory.appendingPathComponent("photo.png")
        try Data("payload".utf8).write(to: staging)
        var completedItem: ShelfItem?
        var completedRecoveryID: UUID?
        var failure: RecoveryAction?

        FilePromiseReceiver.handleMaterializedPromise(
            fileURL: staging,
            error: nil,
            promisedTypes: ["public.png"],
            tempFileService: context.temp,
            bookmarkService: context.bookmarks,
            pendingImportJournal: context.journal,
            logger: context.logger,
            completion: { item, recoveryID in
                completedItem = item
                completedRecoveryID = recoveryID
            },
            failure: { failure = $0 }
        )

        let item = try XCTUnwrap(completedItem)
        let recoveryID = try XCTUnwrap(completedRecoveryID)
        XCTAssertEqual(item.id, recoveryID)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, "photo.png")
        XCTAssertNotNil(item.bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.path)))
        XCTAssertEqual(context.journal.loadResult().records.first?.id, recoveryID)
        XCTAssertNil(failure)
    }

    func testFailureAfterJournalCreationOffersStorageRecovery() throws {
        let context = Context()
        defer { context.cleanup() }
        let stagingDirectory = try context.temp.createPromiseStagingDirectory()
        let missingPayload = stagingDirectory.appendingPathComponent("missing.txt")
        var failure: RecoveryAction?

        FilePromiseReceiver.handleMaterializedPromise(
            fileURL: missingPayload,
            error: nil,
            promisedTypes: ["public.text"],
            tempFileService: context.temp,
            bookmarkService: context.bookmarks,
            pendingImportJournal: context.journal,
            logger: context.logger,
            completion: { _, _ in XCTFail("Missing payload must not complete") },
            failure: { failure = $0 }
        )

        XCTAssertEqual(failure, .openStorageRecovery)
        XCTAssertEqual(context.journal.loadResult().records.count, 1)
    }

    func testSourceErrorBeforeJournalRequiresNewSourceDrag() {
        struct SourceError: Error {}
        let context = Context()
        defer { context.cleanup() }
        var failure: RecoveryAction?

        FilePromiseReceiver.handleMaterializedPromise(
            fileURL: nil,
            error: SourceError(),
            promisedTypes: [],
            tempFileService: context.temp,
            bookmarkService: context.bookmarks,
            pendingImportJournal: context.journal,
            logger: context.logger,
            completion: { _, _ in XCTFail("Source error must not complete") },
            failure: { failure = $0 }
        )

        XCTAssertEqual(failure, .dragAgainFromSource)
        XCTAssertEqual(context.journal.loadResult(), .missing)
    }
}
