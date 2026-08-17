import XCTest
@testable import OpenYoink

final class BookmarkServiceTests: XCTestCase {
    private var service: BookmarkService!
    private var temporaryURLs: [URL] = []

    override func setUp() {
        service = BookmarkService()
    }

    override func tearDown() {
        service.stopAccessingAll()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
        service = nil
    }

    // MARK: - Helpers

    /// TestFixtures/sample-files is empty, and the sandboxed test host cannot
    /// read files from the repo directory without user selection — so bookmark
    /// tests run against real files created in the container temp directory,
    /// which exercises the same security-scoped code path.
    private func makeTempFile(named name: String = "sample.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-\(name)")
        try "sample content".write(to: url, atomically: true, encoding: .utf8)
        temporaryURLs.append(url)
        return url
    }

    private func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Create / resolve

    func testCreateAndResolveBookmark_returnsCorrectURL_notStale() throws {
        let fileURL = try makeTempFile()

        let bookmark = try service.createBookmark(for: fileURL)
        XCTAssertFalse(bookmark.isEmpty)

        let resolved = try service.resolve(bookmark)
        XCTAssertEqual(normalizedPath(resolved.url), normalizedPath(fileURL))
        XCTAssertFalse(resolved.isStale)
    }

    func testCreateBookmark_forNonexistentFile_throwsCreationFailed() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString).txt")

        XCTAssertThrowsError(try service.createBookmark(for: url)) { error in
            guard case .creationFailed(let failingURL, _) = error as? BookmarkError else {
                return XCTFail("expected BookmarkError.creationFailed, got \(error)")
            }
            XCTAssertEqual(normalizedPath(failingURL), normalizedPath(url))
        }
    }

    func testResolve_garbageData_throwsResolutionFailed() {
        XCTAssertThrowsError(try service.resolve(Data("not a bookmark".utf8))) { error in
            guard case .resolutionFailed = error as? BookmarkError else {
                return XCTFail("expected BookmarkError.resolutionFailed, got \(error)")
            }
        }
    }

    /// A renamed file still resolves via file id. Whether the stale flag is set
    /// in this scenario is platform-dependent, so only the URL is asserted.
    func testResolve_afterFileMove_stillFindsFile() throws {
        let fileURL = try makeTempFile(named: "before.txt")
        let bookmark = try service.createBookmark(for: fileURL)

        let movedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: fileURL, to: movedURL)
        temporaryURLs.append(movedURL)

        let resolved = try service.resolve(bookmark)
        XCTAssertEqual(resolved.url.lastPathComponent, "after.txt")
    }

    // MARK: - Access lifecycle

    func testAccessLifecycle_balancedStartStop() throws {
        let fileURL = try makeTempFile()

        // Reference-counted: two starts need two stops; no crash, no leak.
        _ = service.startAccessing(fileURL)
        _ = service.startAccessing(fileURL)
        service.stopAccessing(fileURL)
        service.stopAccessing(fileURL)
        service.stopAccessingAll() // no-op now, must be safe
    }

    func testWithSecurityScopedAccess_executesBodyAndReturnsValue() throws {
        let fileURL = try makeTempFile()

        let content = try service.withSecurityScopedAccess(to: fileURL) {
            try String(contentsOf: fileURL, encoding: .utf8)
        }

        XCTAssertEqual(content, "sample content")
    }
}
