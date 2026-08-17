import Foundation
import Synchronization

/// Result of resolving a bookmark.
struct ResolvedBookmark: Equatable, Sendable {
    let url: URL
    /// True when the bookmark data is outdated (e.g. the file was moved and the
    /// bookmark resolved via file id) and a fresh bookmark should be created
    /// and stored. Not an error.
    let isStale: Bool
}

/// Errors thrown by `BookmarkService`. Resolution failures are surfaced
/// explicitly so callers can mark items stale — never silently dropped.
enum BookmarkError: LocalizedError {
    case creationFailed(url: URL, underlying: Error)
    case resolutionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let url, let underlying):
            "Failed to create security-scoped bookmark for \(url.path): \(underlying.localizedDescription)"
        case .resolutionFailed(let underlying):
            "Failed to resolve security-scoped bookmark: \(underlying.localizedDescription)"
        }
    }
}

/// Creates and resolves security-scoped bookmarks and manages the
/// `startAccessingSecurityScopedResource` lifecycle.
///
/// Access is reference-counted per URL: a resource is only stopped once its
/// last accessor stops, and `stopAccessingAll()` releases everything (call on
/// termination). Thread-safe; callable from any queue (file-promise work in
/// S4/S5 happens off the main actor).
final class BookmarkService: Sendable {
    /// Open access counts keyed by URL, guarding balanced start/stop calls.
    private let accessCounts = Mutex<[URL: Int]>([:])

    init() {}

    /// Creates a security-scoped bookmark for a file the app can currently
    /// access (e.g. one just dropped onto the shelf).
    func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.creationFailed(url: url, underlying: error)
        }
    }

    /// Resolves a bookmark. Outdated-but-resolvable bookmarks succeed with
    /// `isStale == true` (file moved; caller should re-create and store a fresh
    /// bookmark). Unresolvable bookmarks throw `BookmarkError.resolutionFailed`.
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw BookmarkError.resolutionFailed(underlying: error)
        }
    }

    /// Starts accessing a security-scoped URL. Reference-counted: repeated
    /// starts for the same URL are balanced by the same number of stops.
    /// Returns the underlying `startAccessingSecurityScopedResource` result, or
    /// true when the URL was already started by an earlier call. Note that for
    /// URLs inside the app's own container the underlying call may return false
    /// while access still works — treat the result as informational.
    @discardableResult
    func startAccessing(_ url: URL) -> Bool {
        let needsStart = accessCounts.withLock { counts -> Bool in
            let count = counts[url, default: 0]
            counts[url] = count + 1
            return count == 0
        }
        guard needsStart else { return true }
        let started = url.startAccessingSecurityScopedResource()
        if !started {
            // Roll the count back so a later stopAccessing is not unbalanced.
            accessCounts.withLock { counts in
                if let count = counts[url] {
                    counts[url] = count > 1 ? count - 1 : nil
                }
            }
        }
        return started
    }

    /// Stops one access to a URL previously passed to `startAccessing(_:)`.
    /// The underlying stop runs only when the last accessor stops.
    func stopAccessing(_ url: URL) {
        let shouldStop = accessCounts.withLock { counts -> Bool in
            guard let count = counts[url] else { return false }
            if count > 1 {
                counts[url] = count - 1
                return false
            }
            counts[url] = nil
            return true
        }
        if shouldStop {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Stops every currently accessed URL. Call on termination.
    func stopAccessingAll() {
        let urls = accessCounts.withLock { counts -> [URL] in
            let open = counts.compactMap { $0.value > 0 ? $0.key : nil }
            counts.removeAll()
            return open
        }
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Scoped access helper guaranteeing a balanced start/stop pair.
    func withSecurityScopedAccess<T>(
        to url: URL,
        _ body: () throws -> T
    ) rethrows -> T {
        startAccessing(url)
        defer { stopAccessing(url) }
        return try body()
    }
}
