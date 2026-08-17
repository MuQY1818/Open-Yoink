import Foundation

/// One entry on the shelf.
///
/// Stack modeling: a stack is a `ShelfItem` with `kind == .stack` whose members
/// are embedded inline in `children`, not referenced by id (so there is no
/// separate `ShelfStack` model file). Rationale: the shelf holds at most a few
/// hundred items, so embedding keeps persistence a single self-contained JSON
/// tree and avoids a normalized id-lookup layer. The costs — children have no
/// top-level identity, and two stacks cannot share a child — are acceptable for
/// this use case.
struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: ItemKind
    /// Absolute path of the backing file on disk (kinds `.file`/`.folder`/`.image`).
    /// The path alone does not grant sandbox access — that is what `bookmark` is
    /// for; the path is kept for display and as a fallback hint when the bookmark
    /// can no longer be resolved.
    var path: String?
    /// Security-scoped bookmark data used to regain file access across launches.
    var bookmark: Data?
    var displayName: String
    var addedAt: Date
    /// The app the item was dragged in from, if known.
    var sourceApp: SourceAppInfo?
    /// Inline text content. Only meaningful for `kind == .text`.
    var text: String?
    /// String form of the URL. Only meaningful for `kind == .url`.
    var urlString: String?
    /// Embedded stack members. Only meaningful for `kind == .stack`;
    /// see the type-level note for the embedding tradeoff.
    var children: [ShelfItem]?
    /// Runtime-only flag: true when the backing file could not be resolved at
    /// launch (bookmark dead). Never persisted — recomputed on every launch via
    /// `BookmarkService`, so the UI can show "unavailable" instead of dropping
    /// the item silently.
    var isStale = false

    private enum CodingKeys: String, CodingKey {
        // `isStale` is deliberately excluded (runtime-only, see above).
        case id, kind, path, bookmark, displayName, addedAt, sourceApp, text, urlString, children
    }

    init(
        id: UUID = UUID(),
        kind: ItemKind,
        path: String? = nil,
        bookmark: Data? = nil,
        displayName: String,
        addedAt: Date = Date(),
        sourceApp: SourceAppInfo? = nil,
        text: String? = nil,
        urlString: String? = nil,
        children: [ShelfItem]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.bookmark = bookmark
        self.displayName = displayName
        self.addedAt = addedAt
        self.sourceApp = sourceApp
        self.text = text
        self.urlString = urlString
        self.children = children
    }

    /// Convenience file URL for kinds backed by an on-disk file.
    var fileURL: URL? {
        path.map { URL(fileURLWithPath: $0) }
    }
}
