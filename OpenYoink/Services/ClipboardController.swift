import AppKit

/// One-shot clipboard export used as a keyboard-accessible alternative to
/// precise dragging. It does not retain history and never applies drag-out
/// removal policy.
@MainActor
enum ClipboardController {
    struct Result: Equatable, Sendable {
        var copiedCount: Int
        var skippedCount: Int
        var didWrite: Bool
    }

    static func statusMessage(for result: Result) -> String {
        guard result.didWrite else {
            return String(localized: "The selected items could not be copied.")
        }
        if result.skippedCount > 0 {
            return String(
                format: String(localized: "%lld items copied; %lld unavailable items skipped."),
                Int64(result.copiedCount),
                Int64(result.skippedCount)
            )
        }
        return String(
            format: String(localized: "%lld items copied to the Clipboard."),
            Int64(result.copiedCount)
        )
    }

    static func copy(_ items: [ShelfItem],
                     to pasteboard: NSPasteboard = .general,
                     bookmarkService: BookmarkService) -> Result {
        let flattened = DragPayloadBuilder.flattenedItems(items)
        var writers: [NSPasteboardWriting] = []
        var accessedURLs: [URL] = []
        defer {
            for url in accessedURLs {
                bookmarkService.stopAccessing(url)
            }
        }

        for item in flattened where item.availability == .available {
            if let writer = writer(for: item,
                                   bookmarkService: bookmarkService,
                                   accessedURLs: &accessedURLs) {
                writers.append(writer)
            }
        }

        guard !writers.isEmpty else {
            return Result(copiedCount: 0,
                          skippedCount: flattened.count,
                          didWrite: false)
        }
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(writers)
        return Result(
            copiedCount: didWrite ? writers.count : 0,
            skippedCount: flattened.count - writers.count,
            didWrite: didWrite
        )
    }

    private static func writer(for item: ShelfItem,
                               bookmarkService: BookmarkService,
                               accessedURLs: inout [URL]) -> NSPasteboardWriting? {
        switch item.kind {
        case .file, .folder, .image:
            let url: URL
            if let bookmark = item.bookmark {
                guard let resolved = try? bookmarkService.resolve(bookmark) else { return nil }
                url = resolved.url
                if bookmarkService.startAccessing(url) {
                    accessedURLs.append(url)
                }
            } else if let fileURL = item.fileURL {
                url = fileURL
            } else {
                return nil
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            // NSURL's native NSPasteboardWriting conformance carries file URL
            // semantics (including the sandbox transfer performed by AppKit).
            return url as NSURL
        case .text:
            guard let text = item.text, !text.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(text, forType: PasteboardTypes.plainText)
            return pasteboardItem
        case .url:
            guard let string = item.urlString, URL(string: string) != nil else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(string, forType: PasteboardTypes.url)
            pasteboardItem.setString(string, forType: PasteboardTypes.plainText)
            return pasteboardItem
        case .stack:
            return nil
        }
    }
}
