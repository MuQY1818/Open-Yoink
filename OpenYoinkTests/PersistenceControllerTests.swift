import XCTest
@testable import OpenYoink

@MainActor
final class PersistenceControllerTests: XCTestCase {
    // MARK: - Helpers

    /// Creates a fresh, empty directory in the container temp directory.
    /// Cleaned up with `defer` at each call site (XCTestCase teardown overrides
    /// are nonisolated and cannot touch MainActor state).
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dates use exactly representable fractional seconds so the ISO8601
    /// (millisecond) encoding round-trips losslessly.
    private func makeItem(_ name: String) -> ShelfItem {
        ShelfItem(
            kind: .file,
            path: "/tmp/\(name)",
            displayName: name,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
    }

    // MARK: - Round trip

    func testSaveThenLoad_roundTripsItems() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        let items = [makeItem("a"), makeItem("b")]

        try controller.saveNow(items)

        XCTAssertEqual(controller.load(), items)
        XCTAssertEqual(controller.saveCount, 1)
    }

    func testLoad_missingFile_returnsEmptyArray() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.load(), [])
    }

    func testSave_createsSchemaVersionEnvelope() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("a")])

        let data = try Data(contentsOf: directory.appendingPathComponent("shelf.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(envelope["schemaVersion"] as? Int, PersistenceController.currentSchemaVersion)
        XCTAssertNotNil(envelope["items"])
    }

    /// A file written by a newer app version must not crash; unknown fields are
    /// ignored by the decoder (best-effort forward compatibility).
    func testLoad_newerSchemaVersion_decodesBestEffort() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
            "schemaVersion": 99,
            "futureField": {"anything": true},
            "items": []
        }
        """
        try json.write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.load(), [])
    }

    // MARK: - Corrupted data

    func testLoad_corruptedJSON_returnsEmptyArray_andRecovers() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json {{{".write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.load(), [])

        // The controller stays usable after a corrupted read.
        try controller.saveNow([makeItem("recovered")])
        XCTAssertEqual(controller.load().map(\.displayName), ["recovered"])
    }

    // MARK: - Debounce

    func testScheduledSaves_coalesceIntoSingleDiskWrite() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(
            directoryURL: directory,
            debounceInterval: .milliseconds(50)
        )

        controller.scheduleSave([makeItem("a")])
        controller.scheduleSave([makeItem("a"), makeItem("b")])
        controller.scheduleSave([makeItem("a"), makeItem("b"), makeItem("c")])

        // Generous margin over the 50ms debounce; suspending (not blocking)
        // keeps the main actor free to run the debounced write.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.saveCount, 1)
        XCTAssertEqual(controller.load().map(\.displayName), ["a", "b", "c"])
    }

    func testFlushPendingSave_writesImmediatelyAndCancelsDebounce() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(
            directoryURL: directory,
            debounceInterval: .milliseconds(50)
        )

        controller.scheduleSave([makeItem("a")])
        controller.flushPendingSave()

        XCTAssertEqual(controller.saveCount, 1)
        XCTAssertEqual(controller.load().map(\.displayName), ["a"])

        // The cancelled debounce task must not write again.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.saveCount, 1)
    }

    func testFlushPendingSave_withoutPendingSave_isNoOp() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        controller.flushPendingSave()
        XCTAssertEqual(controller.saveCount, 0)
    }
}
