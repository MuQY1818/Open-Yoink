import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfKeyboardNavigationTests: XCTestCase {
    func testNavigatorMovesAcrossRowsAndClampsAtEdges() {
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .left), 3)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .right), 5)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .up), 1)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .down), 7)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 0, itemCount: 8, columnCount: 3, direction: .left), 0)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 7, itemCount: 8, columnCount: 3, direction: .down), 7)
    }

    func testFocusAndSelectionAreIndependentWhenEnteringAndLeavingStack() {
        let children = [
            ShelfItem(kind: .text, displayName: "a", text: "a"),
            ShelfItem(kind: .text, displayName: "b", text: "b")
        ]
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: children)
        let interaction = ShelfInteractionState()
        interaction.focusedItemID = stack.id
        interaction.childSelection = [children[1].id]

        interaction.enterStack(stack)

        XCTAssertEqual(interaction.expandedStackID, stack.id)
        XCTAssertEqual(interaction.focusedItemID, children[0].id)
        XCTAssertTrue(interaction.childSelection.isEmpty)

        interaction.childSelection = [children[1].id]
        interaction.exitStack()
        XCTAssertEqual(interaction.focusedItemID, stack.id)
        XCTAssertNil(interaction.expandedStackID)
        XCTAssertTrue(interaction.childSelection.isEmpty)
    }

    func testNormalizeDropsOnlyInvalidFocusAndChildSelection() {
        let child = ShelfItem(kind: .text, displayName: "a", text: "a")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [child])
        let interaction = ShelfInteractionState()
        interaction.enterStack(stack)
        interaction.childSelection = [child.id, UUID()]

        interaction.normalize(for: [stack])

        XCTAssertEqual(interaction.focusedItemID, child.id)
        XCTAssertEqual(interaction.childSelection, [child.id])

        interaction.normalize(for: [])
        XCTAssertNil(interaction.expandedStackID)
        XCTAssertNil(interaction.focusedItemID)
        XCTAssertTrue(interaction.childSelection.isEmpty)
    }
}

@MainActor
final class ClipboardControllerTests: XCTestCase {
    private let bookmarks = BookmarkService()

    override func tearDown() {
        bookmarks.stopAccessingAll()
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests.\(UUID().uuidString)"))
    }

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkClipboard-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCopyTextAndURLWritesOnePasteboardItemPerShelfItem() throws {
        let pasteboard = makePasteboard()
        let items = [
            ShelfItem(kind: .text, displayName: "Text", text: "hello"),
            ShelfItem(kind: .url, displayName: "Example", urlString: "https://example.com")
        ]

        let result = ClipboardController.copy(items,
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 2, skippedCount: 0, didWrite: true))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].string(forType: PasteboardTypes.plainText),
                       "hello")
        XCTAssertEqual(pasteboard.pasteboardItems?[1].string(forType: PasteboardTypes.url),
                       "https://example.com")
    }

    func testCopyFileUsesNativeFileURLRepresentation() throws {
        let pasteboard = makePasteboard()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ShelfItem(kind: .file, path: url.path, displayName: url.lastPathComponent)

        let result = ClipboardController.copy([item],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertTrue(result.didWrite)
        XCTAssertEqual(result.copiedCount, 1)
        let copied = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
        XCTAssertEqual(copied?.standardizedFileURL, url.standardizedFileURL)
    }

    func testUnavailableOnlySelectionDoesNotDestroyExistingClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: PasteboardTypes.plainText)
        var item = ShelfItem(kind: .file, path: "/missing", displayName: "missing")
        item.availability = .externalFileOffline

        let result = ClipboardController.copy([item],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 0, skippedCount: 1, didWrite: false))
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.plainText), "keep")
    }

    func testCopyFlattensStackAndSkipsMalformedChildren() {
        let pasteboard = makePasteboard()
        let good = ShelfItem(kind: .text, displayName: "Good", text: "content")
        let bad = ShelfItem(kind: .text, displayName: "Bad", text: "")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [good, bad])

        let result = ClipboardController.copy([stack],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 1, skippedCount: 1, didWrite: true))
    }
}
