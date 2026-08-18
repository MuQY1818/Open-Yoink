import XCTest
@testable import OpenYoink

final class ItemAvailabilityTests: XCTestCase {
    private let bookmarks = BookmarkService()

    override func tearDown() {
        bookmarks.stopAccessingAll()
    }

    func testMissingExternalReferenceAllowsRelocation() {
        let item = ShelfItem(kind: .file,
                             path: "/Volumes/Offline/report.pdf",
                             displayName: "report.pdf")

        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarks,
            fileExists: { _ in false }
        )

        XCTAssertEqual(result.item.availability, .externalFileOffline)
        XCTAssertFalse(result.requiresPersistence)
    }

    func testMissingManagedCopyUsesRecoveryInsteadOfRelocation() {
        let item = ShelfItem(kind: .file,
                             path: "/managed/archive.zip",
                             displayName: "archive.zip",
                             isCut: true)

        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarks,
            fileExists: { _ in false }
        )

        XCTAssertEqual(result.item.availability, .managedCopyMissing)
        XCTAssertNil(ItemRelocationPlanner.relocatedItem(
            from: result.item,
            to: URL(fileURLWithPath: "/tmp/replacement.zip"),
            bookmark: Data([1])
        ))
    }

    func testExistingFileClearsPreviousUnavailableState() {
        var item = ShelfItem(kind: .file,
                             path: "/Volumes/Drive/report.pdf",
                             displayName: "report.pdf")
        item.availability = .externalFileOffline

        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarks,
            fileExists: { $0 == "/Volumes/Drive/report.pdf" }
        )

        XCTAssertEqual(result.item.availability, .available)
    }

    func testInvalidBookmarkDoesNotFallBackToUntrustedPath() {
        let item = ShelfItem(kind: .file,
                             path: "/tmp/a-path-that-must-not-be-used",
                             bookmark: Data("invalid bookmark".utf8),
                             displayName: "file")

        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarks,
            fileExists: { _ in true }
        )

        XCTAssertEqual(result.item.availability, .externalFileOffline)
    }

    func testStackSurfacesStrongestChildIssue() {
        var external = ShelfItem(kind: .file, path: "/missing/a", displayName: "a")
        external.availability = .externalFileOffline
        let managed = ShelfItem(kind: .file,
                                path: "/missing/b",
                                displayName: "b",
                                isCut: true)
        let stack = ShelfItem(kind: .stack,
                              displayName: "Files",
                              children: [external, managed])

        let result = ItemAvailabilityResolver.refresh(
            stack,
            bookmarkService: bookmarks,
            fileExists: { _ in false }
        )

        XCTAssertEqual(result.item.availability, .managedCopyMissing)
        XCTAssertEqual(result.item.children?[0].availability, .externalFileOffline)
        XCTAssertEqual(result.item.children?[1].availability, .managedCopyMissing)
    }

    func testRelocationReplacesOnlyExternalReferenceFields() throws {
        var item = ShelfItem(kind: .file,
                             path: "/old/report.pdf",
                             bookmark: Data([0]),
                             displayName: "report.pdf")
        item.availability = .externalFileOffline
        let newURL = URL(fileURLWithPath: "/new/renamed.pdf")

        let relocated = try XCTUnwrap(ItemRelocationPlanner.relocatedItem(
            from: item,
            to: newURL,
            bookmark: Data([1, 2, 3])
        ))

        XCTAssertEqual(relocated.id, item.id)
        XCTAssertEqual(relocated.path, newURL.path)
        XCTAssertEqual(relocated.bookmark, Data([1, 2, 3]))
        XCTAssertEqual(relocated.displayName, "renamed.pdf")
        XCTAssertEqual(relocated.availability, .available)
    }

    func testAvailabilityIsRuntimeOnly() throws {
        var item = ShelfItem(kind: .file, path: "/missing", displayName: "missing")
        item.availability = .managedCopyMissing

        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)

        XCTAssertNil(object["availability"])
        XCTAssertEqual(decoded.availability, .available)
    }
}
