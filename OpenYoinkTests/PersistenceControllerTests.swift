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

    // MARK: - 评审 P1：失败感知的加载语义

    func testLoadResult_missingFile_returnsMissing() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult(), .missing)
    }

    func testLoadResult_validFile_returnsLoaded() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("a"), makeItem("b")])
        guard case .loaded(let items) = controller.loadResult() else {
            return XCTFail("expected .loaded, got \(controller.loadResult())")
        }
        XCTAssertEqual(items.map(\.displayName), ["a", "b"])
    }

    /// 评审 P1 核心回归：损坏文件必须被判为 .failed 并隔离保留（而不是
    /// 静默视为空架）——这样启动链路才能据此跳过孤儿清理，避免连锁
    /// 删除 Materialized 保管文件。
    func testLoadResult_corruptedJSON_returnsFailed_andQuarantinesFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelfURL = directory.appendingPathComponent("shelf.json")
        try "not json {{{".write(to: shelfURL, atomically: true, encoding: .utf8)

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult(), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfURL.path),
                       "损坏文件应被移出原位")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("shelf.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "损坏文件应被隔离保留供人工恢复")
    }

    /// 原子替换：已有文件时保存不得经「先删后移」（旧实现在移动失败时
    /// 新旧俱损）；正常路径下新内容完整落盘、无临时文件残留。
    func testWrite_existingFile_atomicallyReplaced() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("old")])
        try controller.saveNow([makeItem("new-1"), makeItem("new-2")])
        XCTAssertEqual(controller.load().map(\.displayName), ["new-1", "new-2"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("shelf.json.tmp").path))
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
