import XCTest
@testable import OpenYoink

/// S6: 项目操作的可用性规则（`ItemActions.canX`，纯逻辑）——
/// 右键菜单 disabled 态与 stale「File Unavailable」分支的依据。
@MainActor
final class ItemActionsTests: XCTestCase {
    // MARK: - Helpers

    private func item(_ kind: ItemKind,
                      path: String? = nil,
                      text: String? = nil,
                      urlString: String? = nil,
                      children: [ShelfItem]? = nil,
                      stale: Bool = false) -> ShelfItem {
        var result = ShelfItem(kind: kind, path: path, displayName: "item",
                               text: text, urlString: urlString, children: children)
        result.isStale = stale
        return result
    }

    // MARK: - Open

    func testCanOpen() {
        // file/folder/image：需有路径；folder 可打开（Finder 中打开该目录）。
        XCTAssertTrue(ItemActions.canOpen(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canOpen(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canOpen(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canOpen(item(.file)))
        // text：写入临时 .txt 打开，需有内容。
        XCTAssertTrue(ItemActions.canOpen(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canOpen(item(.text, text: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.text)))
        // url：NSWorkspace.open URL，需能解析出 URL。
        XCTAssertTrue(ItemActions.canOpen(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canOpen(item(.url, urlString: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.url)))
        // stack 不提供「打开」。
        XCTAssertFalse(ItemActions.canOpen(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // stale 一律不可用。
        XCTAssertFalse(ItemActions.canOpen(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Show in Finder

    func testCanRevealInFinder() {
        // file/folder/image：定位解析后的 URL。
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file)))
        // text：定位其临时 .txt（物化/临时文件同样可定位）。
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.text)))
        // url 无本地文件、stack 无单一对应文件：不可用。
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // stale 一律不可用。
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Quick Look

    func testCanQuickLook() {
        // file/folder/image：需有路径且非 stale（macOS QL 支持文件夹，不禁用）。
        XCTAssertTrue(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.file)))
        // text：临时 .txt 预览，需有内容。
        XCTAssertTrue(ItemActions.canQuickLook(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.text, text: "")))
        // url：回退为 URL 字符串的临时 .txt，需有 URL 字符串。
        XCTAssertTrue(ItemActions.canQuickLook(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.url)))
        // stack：任一子项可预览即可（嵌套递归）。
        let liveStack = item(.stack, children: [item(.file, path: "/tmp/a", stale: true),
                                                item(.stack, children: [item(.text, text: "hi")])])
        XCTAssertTrue(ItemActions.canQuickLook(liveStack))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [item(.file, path: "/tmp/a", stale: true)])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack)))
        // stale 一律不可用。
        XCTAssertFalse(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt", stale: true)))
    }
}
