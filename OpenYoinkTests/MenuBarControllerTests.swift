import XCTest
@testable import OpenYoink

/// S10/C8: 菜单栏「最近项目」重新入架可行性裁决（MenuBarController.canReadd）。
final class MenuBarControllerTests: XCTestCase {
    private var temporaryFileURL: URL!

    override func setUpWithError() throws {
        temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: temporaryFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }

    private func entry(kind: ItemKind, path: String? = nil, urlString: String? = nil) -> RecentEntry {
        RecentEntry(item: ShelfItem(kind: kind,
                                    path: path,
                                    displayName: "Entry",
                                    urlString: urlString),
                    draggedOutAt: Date())
    }

    /// 文件仍存在且可读 → 可重新入架。
    func testFileEntryReaddsWhenReadable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .file, path: temporaryFileURL.path)))
    }

    /// 文件已删除/不可访问 → 置灰。
    func testFileEntryDisabledWhenUnreachable() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .file, path: "/nonexistent/gone-\(UUID().uuidString)")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .image, path: nil)))
    }

    /// URL 条目可解析即可重新入架。
    func testURLEntryReaddsWhenParseable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .url, urlString: "https://example.com")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .url, urlString: nil)))
    }

    /// text 仅存 100 字符摘要、stack 拖出时已展开为子项 —— 均无法忠实恢复，置灰。
    func testTextAndStackEntriesAreDisabled() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .text)))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .stack)))
    }
}
