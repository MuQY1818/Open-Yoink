import Foundation

/// Runtime-only availability of a shelf item.
///
/// Missing external references and missing OpenYoink-managed copies are kept
/// separate because their safe recovery actions are fundamentally different:
/// an external reference may be reconnected by the user, while a managed copy
/// must go through storage/recovery and must never be rebound to arbitrary data.
enum ItemAvailability: Sendable, Equatable {
    case available
    case externalFileOffline
    case managedCopyMissing
}

/// Resolves bookmarks and recomputes availability without discarding an item.
/// The result also identifies whether path/bookmark fields changed and should
/// be persisted; availability itself intentionally remains runtime-only.
enum ItemAvailabilityResolver {
    struct Result: Sendable, Equatable {
        var item: ShelfItem
        var requiresPersistence: Bool
    }

    static func refresh(
        _ item: ShelfItem,
        bookmarkService: BookmarkService,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> Result {
        var updated = item
        var requiresPersistence = false

        if var children = item.children {
            var childrenChanged = false
            for index in children.indices {
                let result = refresh(children[index],
                                     bookmarkService: bookmarkService,
                                     fileExists: fileExists)
                if result.item != children[index] {
                    children[index] = result.item
                    childrenChanged = true
                }
                requiresPersistence = requiresPersistence || result.requiresPersistence
            }
            if childrenChanged {
                updated.children = children
            }
            updated.availability = aggregateAvailability(of: children)
            return Result(item: updated, requiresPersistence: requiresPersistence)
        }

        guard item.kind == .file || item.kind == .folder || item.kind == .image else {
            updated.availability = .available
            return Result(item: updated, requiresPersistence: false)
        }

        var resolvedURL = item.fileURL
        var accessedURL: URL?
        if let bookmark = item.bookmark {
            do {
                let resolved = try bookmarkService.resolve(bookmark)
                resolvedURL = resolved.url
                if bookmarkService.startAccessing(resolved.url) {
                    accessedURL = resolved.url
                }
                if item.path != resolved.url.path {
                    updated.path = resolved.url.path
                    requiresPersistence = true
                }
                if resolved.isStale,
                   let refreshedBookmark = try? bookmarkService.createBookmark(for: resolved.url) {
                    updated.bookmark = refreshedBookmark
                    requiresPersistence = true
                }
            } catch {
                updated.availability = unavailableState(for: item)
                return Result(item: updated, requiresPersistence: false)
            }
        }
        defer {
            if let accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
        }

        guard let resolvedURL, fileExists(resolvedURL.path) else {
            updated.availability = unavailableState(for: item)
            return Result(item: updated, requiresPersistence: requiresPersistence)
        }
        updated.availability = .available
        return Result(item: updated, requiresPersistence: requiresPersistence)
    }

    private static func unavailableState(for item: ShelfItem) -> ItemAvailability {
        item.isCut ? .managedCopyMissing : .externalFileOffline
    }

    /// A stack surfaces the strongest child issue so the collapsed card never
    /// hides missing data. Expanding the stack reveals the exact child/action.
    private static func aggregateAvailability(of children: [ShelfItem]) -> ItemAvailability {
        if children.contains(where: { $0.availability == .managedCopyMissing }) {
            return .managedCopyMissing
        }
        if children.contains(where: { $0.availability == .externalFileOffline }) {
            return .externalFileOffline
        }
        return .available
    }
}

/// Pure relocation mutation used by the UI controller and unit tests.
enum ItemRelocationPlanner {
    static func relocatedItem(from item: ShelfItem, to url: URL, bookmark: Data) -> ShelfItem? {
        guard item.availability == .externalFileOffline, !item.isCut,
              item.kind == .file || item.kind == .folder || item.kind == .image else {
            return nil
        }
        var updated = item
        updated.path = url.path
        updated.bookmark = bookmark
        updated.displayName = url.lastPathComponent
        updated.availability = .available
        return updated
    }
}
