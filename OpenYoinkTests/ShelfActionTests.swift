import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfActionTests: XCTestCase {
    private let bookmarks = BookmarkService()

    override func tearDown() {
        bookmarks.stopAccessingAll()
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("OpenYoinkShelfActionTests.\(UUID().uuidString)"))
    }

    private func makeFile(named name: String = "item.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkShelfActionTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "content".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExplicitSelectionPrefersExpandedStackChildren() {
        let childA = ShelfItem(kind: .text, displayName: "A", text: "a")
        let childB = ShelfItem(kind: .text, displayName: "B", text: "b")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [childA, childB])
        let other = ShelfItem(kind: .text, displayName: "Other", text: "other")

        XCTAssertEqual(
            ShelfActionSelectionResolver.explicitItems(
                topLevelItems: [stack, other],
                topLevelSelection: [stack.id, other.id],
                expandedStackID: stack.id,
                childSelection: [childB.id]
            ),
            [childB]
        )
        XCTAssertTrue(
            ShelfActionSelectionResolver.explicitItems(
                topLevelItems: [stack, other],
                topLevelSelection: [stack.id],
                expandedStackID: stack.id,
                childSelection: []
            ).isEmpty
        )
    }

    func testContextualSelectionUsesWholeSelectionOnlyWhenAnchorIsSelected() {
        let first = ShelfItem(kind: .text, displayName: "First", text: "1")
        let second = ShelfItem(kind: .text, displayName: "Second", text: "2")
        let third = ShelfItem(kind: .text, displayName: "Third", text: "3")
        let visible = [first, second, third]

        XCTAssertEqual(
            ShelfActionSelectionResolver.contextualItems(
                anchor: second, visibleItems: visible, selectedIDs: [first.id, second.id]
            ),
            [first, second]
        )
        XCTAssertEqual(
            ShelfActionSelectionResolver.contextualItems(
                anchor: third, visibleItems: visible, selectedIDs: [first.id, second.id]
            ),
            [third]
        )
    }

    func testCatalogFlattensStacksAndKeepsTruthfulPerActionAvailability() {
        let file = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        let text = ShelfItem(kind: .text, displayName: "Text", text: "hello")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [text, file])

        XCTAssertTrue(ShelfActionCatalog.canPerform(.share, on: [stack]))
        XCTAssertTrue(ShelfActionCatalog.canPerform(.copyPath, on: [stack]))
        XCTAssertTrue(ShelfActionCatalog.canPerform(.revealInFinder, on: [stack]))
        XCTAssertTrue(ShelfActionCatalog.canPerform(.share, on: [text]))
        XCTAssertFalse(ShelfActionCatalog.canPerform(.copyPath, on: [text]))
        XCTAssertFalse(ShelfActionCatalog.canPerform(.revealInFinder, on: [text]))

        var offlineFile = file
        offlineFile.availability = .externalFileOffline
        XCTAssertFalse(ShelfActionCatalog.hasAnyAction(for: [offlineFile]))
    }

    func testCopyPathWritesOrderedNewlineSeparatedPathsAndReportsSkippedItems() throws {
        let firstURL = try makeFile(named: "first.txt")
        let secondURL = try makeFile(named: "second.txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let pasteboard = makePasteboard()
        let notices = ShelfNoticeModel()
        let runner = ShelfActionRunner(bookmarkService: bookmarks,
                                       notices: notices,
                                       pasteboard: pasteboard)
        let stack = ShelfItem(
            kind: .stack,
            displayName: "Stack",
            children: [
                ShelfItem(kind: .file, path: firstURL.path, displayName: "first.txt"),
                ShelfItem(kind: .text, displayName: "Text", text: "skip"),
                ShelfItem(kind: .file, path: secondURL.path, displayName: "second.txt")
            ]
        )

        let result = runner.perform(.copyPath, on: [stack])

        XCTAssertEqual(result, .init(state: .completed, succeededCount: 2, skippedCount: 1))
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.plainText),
                       "\(firstURL.path)\n\(secondURL.path)")
        XCTAssertNotNil(notices.message)
    }

    func testCopyPathFailurePreservesExistingClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: PasteboardTypes.plainText)
        let runner = ShelfActionRunner(bookmarkService: bookmarks,
                                       notices: ShelfNoticeModel(),
                                       pasteboard: pasteboard)
        let missing = ShelfItem(kind: .file, path: "/definitely/missing/file",
                                displayName: "missing")

        let result = runner.perform(.copyPath, on: [missing])

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.plainText), "keep")
    }

    func testRevealResolvesAllFilesAndInvokesWorkspaceOnce() throws {
        let firstURL = try makeFile(named: "first.txt")
        let secondURL = try makeFile(named: "second.txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        var revealCalls: [[URL]] = []
        let runner = ShelfActionRunner(
            bookmarkService: bookmarks,
            notices: ShelfNoticeModel(),
            revealFiles: { revealCalls.append($0) }
        )
        let items = [
            ShelfItem(kind: .file, path: firstURL.path, displayName: "first.txt"),
            ShelfItem(kind: .text, displayName: "Text", text: "skip"),
            ShelfItem(kind: .file, path: secondURL.path, displayName: "second.txt")
        ]

        let result = runner.perform(.revealInFinder, on: items)

        XCTAssertEqual(result, .init(state: .completed, succeededCount: 2, skippedCount: 1))
        XCTAssertEqual(revealCalls, [[firstURL, secondURL]])
    }

    func testInvalidBookmarkNeverFallsBackToStoredPath() throws {
        let realFile = try makeFile()
        defer { try? FileManager.default.removeItem(at: realFile.deletingLastPathComponent()) }
        let item = ShelfItem(kind: .file,
                             path: realFile.path,
                             bookmark: Data("not-a-bookmark".utf8),
                             displayName: "item.txt")

        XCTAssertNil(ItemActions.resolveFileURL(for: item, bookmarkService: bookmarks))
    }

    func testSelectionCallbacksOnlyFireForRealVisibilityChanges() {
        let item = ShelfItem(kind: .text, displayName: "Text", text: "hello")
        let store = ShelfStore(items: [item])
        var storeChanges = 0
        store.onSelectionDidChange = { storeChanges += 1 }

        store.select(item.id)
        store.select(item.id)
        store.clearSelection()
        XCTAssertEqual(storeChanges, 2)

        let interaction = ShelfInteractionState()
        var childChanges = 0
        interaction.onActionSelectionDidChange = { childChanges += 1 }
        interaction.childSelection = [item.id]
        interaction.childSelection = [item.id]
        interaction.expandedStackID = UUID()
        XCTAssertEqual(childChanges, 2)
    }

    func testUserCancelledShareIsSilent() {
        let notices = ShelfNoticeModel()
        let runner = ShelfActionRunner(bookmarkService: bookmarks, notices: notices)
        let service = NSSharingService(
            title: "Test",
            image: NSImage(),
            alternateImage: NSImage(),
            handler: {}
        )

        runner.sharingService(
            service,
            didFailToShareItems: [],
            error: NSError(domain: NSCocoaErrorDomain,
                           code: CocoaError.Code.userCancelled.rawValue)
        )

        XCTAssertNil(notices.message)
    }

    func testRealShareFailureShowsNonDestructiveNotice() {
        let notices = ShelfNoticeModel()
        let runner = ShelfActionRunner(bookmarkService: bookmarks, notices: notices)
        let service = NSSharingService(
            title: "Test",
            image: NSImage(),
            alternateImage: NSImage(),
            handler: {}
        )

        runner.sharingService(
            service,
            didFailToShareItems: [],
            error: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadUnknown.rawValue)
        )

        XCTAssertEqual(
            notices.message,
            String(localized: "Sharing failed. The selected items remain on the shelf.")
        )
    }
}
