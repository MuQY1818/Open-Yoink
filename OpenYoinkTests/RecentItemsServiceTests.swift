import XCTest
@testable import OpenYoink

/// RecentItemsService 的追加 / 上限 / 持久化往返。
///
/// @MainActor 测试类不使用 setUp/tearDown（XCTestCase 的这两个 override 是
/// 非隔离的，访问 MainActor 状态会产生告警）——每个用例就地建临时目录并用
/// defer 清理。
@MainActor
final class RecentItemsServiceTests: XCTestCase {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFileItem(_ name: String) -> ShelfItem {
        ShelfItem(kind: .file, path: "/tmp/\(name)", displayName: name)
    }

    // MARK: - Recording

    func testRecord_prependsNewestBatchFirst_preservingInBatchOrder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        service.record([makeFileItem("a.txt")], at: date1)
        service.record([makeFileItem("b.txt"), makeFileItem("c.txt")], at: date2)

        XCTAssertEqual(service.entries.map(\.displayName), ["b.txt", "c.txt", "a.txt"])
        XCTAssertEqual(service.entries[0].draggedOutAt, date2)
        XCTAssertEqual(service.entries[2].draggedOutAt, date1)
        XCTAssertEqual(service.entries[0].kind, .file)
        XCTAssertEqual(service.entries[0].path, "/tmp/b.txt")
    }

    func testRecord_enforcesMaxCount_droppingOldestAcrossBatches() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)

        service.record((1...15).map { makeFileItem("file-\($0).txt") })
        service.record((16...25).map { makeFileItem("file-\($0).txt") })

        // 25 条裁剪到 20：保留最新批次全部 + 旧批次中较新的 10 条。
        XCTAssertEqual(service.entries.count, RecentItemsService.maxEntryCount)
        XCTAssertEqual(service.entries.first?.displayName, "file-16.txt")
        XCTAssertEqual(service.entries.last?.displayName, "file-10.txt")
    }

    func testRecord_ignoresEmptyInput() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)
        service.record([])
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testRecord_entriesHaveUniqueIDs() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)
        let item = makeFileItem("a.txt")
        service.record([item])
        service.record([item])
        XCTAssertEqual(service.entries.count, 2)
        XCTAssertNotEqual(service.entries[0].id, service.entries[1].id)
    }

    // MARK: - Persistence

    func testPersistence_roundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)
        let date = Date()
        let fileItem = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        let urlItem = ShelfItem(kind: .url, displayName: "Apple", urlString: "https://www.apple.com")
        let textItem = ShelfItem(kind: .text, displayName: "note", text: "some text content")

        service.record([fileItem, urlItem, textItem], at: date)

        let reloaded = RecentItemsService(directoryURL: directory)
        XCTAssertEqual(reloaded.entries.map(\.displayName), ["pic.png", "Apple", "note"])
        XCTAssertEqual(reloaded.entries.map(\.kind), [.image, .url, .text])
        XCTAssertEqual(reloaded.entries[0].path, "/tmp/pic.png")
        XCTAssertEqual(reloaded.entries[1].urlString, "https://www.apple.com")
        XCTAssertEqual(reloaded.entries[2].textPreview, "some text content")
        XCTAssertEqual(reloaded.entries[0].draggedOutAt.timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPersistence_missingOrCorruptedFile_returnsEmpty() throws {
        let missingDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: missingDirectory) }
        XCTAssertTrue(RecentItemsService(directoryURL: missingDirectory).entries.isEmpty)

        let corruptedDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: corruptedDirectory) }
        try "not json".write(to: corruptedDirectory.appendingPathComponent("recents.json"),
                             atomically: true, encoding: .utf8)
        XCTAssertTrue(RecentItemsService(directoryURL: corruptedDirectory).entries.isEmpty)
    }

    func testClear_removesEntriesAndPersists() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RecentItemsService(directoryURL: directory)
        service.record([makeFileItem("a.txt")])

        service.clear()

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertTrue(RecentItemsService(directoryURL: directory).entries.isEmpty,
                      "清空必须落盘")
    }
}
