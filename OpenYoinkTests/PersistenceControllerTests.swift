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

    /// 启动链路必须复用第一次读取的结果：损坏文件在首次读取时会被隔离，
    /// 第二次读取已经变成 missing；若用第二次结果判断清理，就会误删全部
    /// Materialized 文件。
    func testLoadResult_failedSnapshotNeverPermitsOrphanCleanup_afterQuarantine() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json {{{".write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )
        let controller = PersistenceController(directoryURL: directory)

        let initialResult = controller.loadResult()

        XCTAssertEqual(initialResult, .failed)
        XCTAssertEqual(initialResult.items, [])
        XCTAssertFalse(initialResult.permitsMaterializedOrphanCleanup)
        XCTAssertFalse(controller.canSafelyCleanupMaterializedOrphans(after: initialResult))
        XCTAssertEqual(controller.loadResult(), .missing,
                       "隔离后的再次读取会变成 missing，启动代码不能依赖它")
        XCTAssertFalse(initialResult.permitsMaterializedOrphanCleanup,
                       "首次失败结果必须持续阻止本轮孤儿清理")
        XCTAssertFalse(
            controller.canSafelyCleanupMaterializedOrphans(after: .missing),
            "隔离快照存在时，后续启动即使读到 missing 也必须保留恢复材料"
        )
    }

    func testLoadResult_trustedSnapshotsPermitOrphanCleanup() throws {
        XCTAssertTrue(PersistenceController.LoadResult.missing.permitsMaterializedOrphanCleanup)
        XCTAssertTrue(PersistenceController.LoadResult.loaded([]).permitsMaterializedOrphanCleanup)

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertTrue(controller.canSafelyCleanupMaterializedOrphans(after: .missing))
        XCTAssertTrue(controller.canSafelyCleanupMaterializedOrphans(after: .loaded([])))
    }

    func testOrphanCleanup_staysBlockedWhenValidShelfCoexistsWithRecoverySnapshot() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("new")])
        try "recoverable".write(
            to: directory.appendingPathComponent("shelf.json.corrupt-old"),
            atomically: true,
            encoding: .utf8
        )

        let result = controller.loadResult()

        guard case .loaded = result else { return XCTFail("expected valid current snapshot") }
        XCTAssertFalse(controller.canSafelyCleanupMaterializedOrphans(after: result),
                       "新快照不能隐式表示用户已放弃旧快照的数据恢复")
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

    // MARK: - Recovery snapshots

    func testSaveOverExistingSnapshot_preservesLastKnownGoodBackup() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)

        try controller.saveNow([makeItem("old")])
        try controller.saveNow([makeItem("new")])

        let backup = try XCTUnwrap(
            controller.recoverySnapshots().first { $0.kind == .lastKnownGood }
        )
        XCTAssertTrue(backup.isRecoverable)
        XCTAssertEqual(try controller.loadRecoverySnapshot(backup).map(\.displayName), ["old"])
        XCTAssertEqual(controller.load().map(\.displayName), ["new"])
    }

    func testRecoverySnapshots_marksDamagedQuarantineAsUnreadable() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedURL = directory.appendingPathComponent("shelf.json.corrupt-test")
        try "broken".write(to: damagedURL, atomically: true, encoding: .utf8)
        let controller = PersistenceController(directoryURL: directory)

        let snapshot = try XCTUnwrap(controller.recoverySnapshots().first)

        XCTAssertEqual(snapshot.kind, .quarantined)
        XCTAssertFalse(snapshot.isRecoverable)
        XCTAssertThrowsError(try controller.loadRecoverySnapshot(snapshot)) { error in
            XCTAssertEqual(error as? PersistenceController.RecoveryError, .snapshotIsUnreadable)
        }
    }

    func testRecoverySnapshot_refusesURLOutsideManagedDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        let outside = PersistenceController.RecoverySnapshot(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("shelf.json.backup"),
            kind: .lastKnownGood,
            modifiedAt: nil,
            byteCount: 0,
            isRecoverable: true
        )

        XCTAssertThrowsError(try controller.loadRecoverySnapshot(outside)) { error in
            XCTAssertEqual(error as? PersistenceController.RecoveryError, .invalidSnapshot)
        }
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
