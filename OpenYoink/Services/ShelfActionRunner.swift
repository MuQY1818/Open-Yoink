import AppKit
import SwiftUI

/// Non-destructive actions exposed by the selection action bar.
///
/// Metadata and availability remain separate from execution so the toolbar,
/// keyboard path and future context menus can share one source of truth.
enum ShelfAction: String, CaseIterable, Identifiable, Sendable {
    case share
    case copyPath
    case revealInFinder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .share: String(localized: "Share")
        case .copyPath: String(localized: "Copy Path")
        case .revealInFinder: String(localized: "Show in Finder")
        }
    }

    var compactTitle: String {
        switch self {
        case .share: String(localized: "Share")
        case .copyPath: String(localized: "Path")
        case .revealInFinder: String(localized: "Finder")
        }
    }

    var systemImage: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .copyPath: "link"
        case .revealInFinder: "folder"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .share: String(localized: "Share the selected items")
        case .copyPath: String(localized: "Copy the selected file paths")
        case .revealInFinder: String(localized: "Show the selected files in Finder")
        }
    }

    var accessibilityIdentifier: String {
        "shelf.quickActions.\(rawValue)"
    }
}

/// Pure selection semantics shared by SwiftUI and the AppKit keyboard path.
/// An expanded stack always owns the explicit selection; a top-level stack
/// must never be acted on accidentally while its children are visible.
enum ShelfActionSelectionResolver {
    static func explicitItems(
        topLevelItems: [ShelfItem],
        topLevelSelection: Set<UUID>,
        expandedStackID: UUID?,
        childSelection: Set<UUID>
    ) -> [ShelfItem] {
        if let expandedStackID {
            guard let stack = topLevelItems.first(where: { $0.id == expandedStackID }),
                  stack.kind == .stack else { return [] }
            return (stack.children ?? []).filter { childSelection.contains($0.id) }
        }
        return topLevelItems.filter { topLevelSelection.contains($0.id) }
    }

    /// Context-menu semantics: an anchor already in the explicit selection
    /// applies to that whole selection; otherwise it applies only to itself.
    static func contextualItems(
        anchor: ShelfItem,
        visibleItems: [ShelfItem],
        selectedIDs: Set<UUID>
    ) -> [ShelfItem] {
        guard selectedIDs.contains(anchor.id) else { return [anchor] }
        return visibleItems.filter { selectedIDs.contains($0.id) }
    }
}

/// Fast, side-effect-free availability used to render truthful disabled states.
/// Execution still re-resolves bookmarks and checks file existence because an
/// external disk can disappear between rendering and clicking.
enum ShelfActionCatalog {
    static func canPerform(_ action: ShelfAction, on items: [ShelfItem]) -> Bool {
        let leaves = DragPayloadBuilder.flattenedItems(items)
        switch action {
        case .share:
            return leaves.contains(where: canShare)
        case .copyPath, .revealInFinder:
            return leaves.contains(where: isFileBackedCandidate)
        }
    }

    static func hasAnyAction(for items: [ShelfItem]) -> Bool {
        ShelfAction.allCases.contains { canPerform($0, on: items) }
    }

    private static func isFileBackedCandidate(_ item: ShelfItem) -> Bool {
        guard item.availability == .available else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.bookmark != nil || item.fileURL != nil
        case .text, .url, .stack:
            return false
        }
    }

    private static func canShare(_ item: ShelfItem) -> Bool {
        guard item.availability == .available else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.bookmark != nil || item.fileURL != nil
        case .text:
            return item.text?.isEmpty == false
        case .url:
            guard let value = item.urlString else { return false }
            return URL(string: value) != nil
        case .stack:
            return false
        }
    }
}

/// Executes selection actions and owns the asynchronous AppKit share session.
/// No action mutates shelf contents or invokes drag-out delivery policy.
@MainActor
final class ShelfActionRunner: NSObject {
    struct Result: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case completed
            case presented
            case unavailable
            case busy
        }

        var state: State
        var succeededCount: Int
        var skippedCount: Int
    }

    private struct ResolvedFileBatch {
        var urls: [URL]
        var accessedURLs: [URL]
        var skippedCount: Int
    }

    private struct ActiveShare {
        var picker: NSSharingServicePicker
        var accessedURLs: [URL]
        var sharedCount: Int
        var skippedCount: Int
    }

    private let bookmarkService: BookmarkService
    private let notices: ShelfNoticeModel
    private let pasteboard: NSPasteboard
    private let fileExists: (String) -> Bool
    private let revealFiles: ([URL]) -> Void
    private var activeShare: ActiveShare?

    init(
        bookmarkService: BookmarkService,
        notices: ShelfNoticeModel,
        pasteboard: NSPasteboard = .general,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:),
        revealFiles: @escaping ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        }
    ) {
        self.bookmarkService = bookmarkService
        self.notices = notices
        self.pasteboard = pasteboard
        self.fileExists = fileExists
        self.revealFiles = revealFiles
        super.init()
    }

    @discardableResult
    func perform(
        _ action: ShelfAction,
        on items: [ShelfItem],
        relativeTo anchorView: NSView? = nil
    ) -> Result {
        switch action {
        case .share:
            guard let anchorView else {
                notices.show(String(localized: "The selected items could not be shared."))
                return Result(state: .unavailable, succeededCount: 0,
                              skippedCount: DragPayloadBuilder.flattenedItems(items).count)
            }
            return presentShare(items, relativeTo: anchorView)
        case .copyPath:
            return copyPaths(items)
        case .revealInFinder:
            return revealInFinder(items)
        }
    }

    private func copyPaths(_ items: [ShelfItem]) -> Result {
        let batch = resolveFiles(in: items)
        defer { stopAccessing(batch.accessedURLs) }

        guard !batch.urls.isEmpty else {
            notices.show(String(localized: "The selected file paths could not be copied."))
            return Result(state: .unavailable, succeededCount: 0,
                          skippedCount: batch.skippedCount)
        }

        let paths = batch.urls.map(\.path).joined(separator: "\n")
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(paths, forType: PasteboardTypes.plainText)
        guard didWrite else {
            notices.show(String(localized: "The selected file paths could not be copied."))
            return Result(state: .unavailable, succeededCount: 0,
                          skippedCount: batch.skippedCount + batch.urls.count)
        }

        notices.show(pathCopyStatus(copied: batch.urls.count, skipped: batch.skippedCount))
        return Result(state: .completed, succeededCount: batch.urls.count,
                      skippedCount: batch.skippedCount)
    }

    private func revealInFinder(_ items: [ShelfItem]) -> Result {
        let batch = resolveFiles(in: items)
        defer { stopAccessing(batch.accessedURLs) }

        guard !batch.urls.isEmpty else {
            notices.show(String(localized: "The selected items could not be shown in Finder."))
            return Result(state: .unavailable, succeededCount: 0,
                          skippedCount: batch.skippedCount)
        }

        revealFiles(batch.urls)
        notices.show(revealStatus(shown: batch.urls.count, skipped: batch.skippedCount))
        return Result(state: .completed, succeededCount: batch.urls.count,
                      skippedCount: batch.skippedCount)
    }

    private func presentShare(_ items: [ShelfItem], relativeTo anchorView: NSView) -> Result {
        guard activeShare == nil else {
            notices.show(String(localized: "A share is already in progress."))
            return Result(state: .busy, succeededCount: 0, skippedCount: 0)
        }

        let flattened = DragPayloadBuilder.flattenedItems(items)
        var payload: [Any] = []
        var accessedURLs: [URL] = []

        for item in flattened where item.availability == .available {
            switch item.kind {
            case .file, .folder, .image:
                guard let resolved = resolveFile(item) else { continue }
                payload.append(resolved.url as NSURL)
                if resolved.didStartAccess { accessedURLs.append(resolved.url) }
            case .text:
                guard let text = item.text, !text.isEmpty else { continue }
                payload.append(text as NSString)
            case .url:
                guard let value = item.urlString, let url = URL(string: value) else { continue }
                payload.append(url as NSURL)
            case .stack:
                break
            }
        }

        guard !payload.isEmpty else {
            stopAccessing(accessedURLs)
            notices.show(String(localized: "The selected items could not be shared."))
            return Result(state: .unavailable, succeededCount: 0,
                          skippedCount: flattened.count)
        }

        let picker = NSSharingServicePicker(items: payload)
        picker.delegate = self
        activeShare = ActiveShare(
            picker: picker,
            accessedURLs: accessedURLs,
            sharedCount: payload.count,
            skippedCount: flattened.count - payload.count
        )
        if NSApp.currentEvent?.type == .leftMouseDown {
            // AppKit requires `show` during mouseDown. Pointer activation from
            // ShelfActionButton deliberately reaches this branch on mouseDown.
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        } else {
            // Keyboard and accessibility activation have no mouseDown event.
            // The system-provided menu item is AppKit's supported non-pointer
            // entry point and preserves the same picker/delegate lifecycle.
            let menuItem = picker.standardShareMenuItem
            guard let action = menuItem.action,
                  NSApp.sendAction(action, to: menuItem.target, from: menuItem) else {
                finishShare(success: false)
                notices.show(String(localized: "The selected items could not be shared."))
                return Result(state: .unavailable, succeededCount: 0,
                              skippedCount: flattened.count)
            }
        }
        return Result(state: .presented, succeededCount: 0,
                      skippedCount: flattened.count - payload.count)
    }

    private func resolveFiles(in items: [ShelfItem]) -> ResolvedFileBatch {
        let flattened = DragPayloadBuilder.flattenedItems(items)
        var urls: [URL] = []
        var accessedURLs: [URL] = []

        for item in flattened where item.availability == .available {
            switch item.kind {
            case .file, .folder, .image:
                guard let resolved = resolveFile(item) else { continue }
                urls.append(resolved.url)
                if resolved.didStartAccess { accessedURLs.append(resolved.url) }
            case .text, .url, .stack:
                continue
            }
        }
        return ResolvedFileBatch(
            urls: urls,
            accessedURLs: accessedURLs,
            skippedCount: flattened.count - urls.count
        )
    }

    private func resolveFile(_ item: ShelfItem) -> (url: URL, didStartAccess: Bool)? {
        guard let url = ItemActions.resolveFileURL(for: item, bookmarkService: bookmarkService) else {
            return nil
        }
        let didStartAccess = bookmarkService.startAccessing(url)
        guard fileExists(url.path) else {
            if didStartAccess { bookmarkService.stopAccessing(url) }
            return nil
        }
        return (url, didStartAccess)
    }

    private func stopAccessing(_ urls: [URL]) {
        for url in urls { bookmarkService.stopAccessing(url) }
    }

    private func finishShare(success: Bool) {
        guard let share = activeShare else { return }
        activeShare = nil
        stopAccessing(share.accessedURLs)
        if success {
            notices.show(shareStatus(shared: share.sharedCount, skipped: share.skippedCount))
        }
    }

    private func pathCopyStatus(copied: Int, skipped: Int) -> String {
        if skipped > 0 {
            return String(
                format: String(localized: "%lld file paths copied; %lld unavailable items skipped."),
                Int64(copied), Int64(skipped)
            )
        }
        return String(
            format: String(localized: "%lld file paths copied to the Clipboard."),
            Int64(copied)
        )
    }

    private func revealStatus(shown: Int, skipped: Int) -> String {
        if skipped > 0 {
            return String(
                format: String(localized: "%lld items shown in Finder; %lld unavailable items skipped."),
                Int64(shown), Int64(skipped)
            )
        }
        return String(
            format: String(localized: "%lld items shown in Finder."),
            Int64(shown)
        )
    }

    private func shareStatus(shared: Int, skipped: Int) -> String {
        if skipped > 0 {
            return String(
                format: String(localized: "%lld items shared; %lld unavailable items skipped."),
                Int64(shared), Int64(skipped)
            )
        }
        return String(format: String(localized: "%lld items shared."), Int64(shared))
    }
}

extension ShelfActionRunner: @preconcurrency NSSharingServicePickerDelegate,
                             NSSharingServiceDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        // Cancellation is intentionally silent; it is not an error and must
        // still release every security-scoped URL acquired for the picker.
        if service == nil { finishShare(success: false) }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishShare(success: true)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        finishShare(success: false)
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.Code.userCancelled.rawValue {
            return
        }
        notices.show(String(localized: "Sharing failed. The selected items remain on the shelf."))
    }
}

private struct ShelfActionRunnerEnvironmentKey: EnvironmentKey {
    static var defaultValue: ShelfActionRunner? { nil }
}

extension EnvironmentValues {
    var shelfActionRunner: ShelfActionRunner? {
        get { self[ShelfActionRunnerEnvironmentKey.self] }
        set { self[ShelfActionRunnerEnvironmentKey.self] = newValue }
    }
}
