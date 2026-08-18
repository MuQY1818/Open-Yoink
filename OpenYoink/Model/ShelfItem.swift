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
    /// Cut mode (⌘+drop): the original file was moved into the app's managed
    /// directory (`path`/`bookmark` point at that copy) and the item is
    /// delivered — then removed from the shelf — on drag out. Persisted;
    /// JSON written by older versions lacks the key and decodes as false.
    var isCut: Bool
    /// Runtime-only availability. Never persisted — recomputed on launch and
    /// whenever the shelf is shown. External references and managed copies use
    /// different recovery paths; see `ItemAvailability`.
    var availability: ItemAvailability = .available

    /// Compatibility shorthand retained for call sites and older focused tests.
    /// New code should inspect `availability` to choose a safe recovery action.
    var isStale: Bool {
        get { availability != .available }
        set {
            availability = newValue
                ? (isCut ? .managedCopyMissing : .externalFileOffline)
                : .available
        }
    }

    private enum CodingKeys: String, CodingKey {
        // `availability` / `isStale` are deliberately excluded (runtime-only).
        case id, kind, path, bookmark, displayName, addedAt, sourceApp, text, urlString, children, isCut
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
        children: [ShelfItem]? = nil,
        isCut: Bool = false
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
        self.isCut = isCut
    }

    /// Custom decoder solely for backward compatibility: `isCut` was added
    /// after the first persisted schema, so a missing key decodes as false.
    /// Everything else matches the synthesized memberwise decoding.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ItemKind.self, forKey: .kind)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        displayName = try container.decode(String.self, forKey: .displayName)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        sourceApp = try container.decodeIfPresent(SourceAppInfo.self, forKey: .sourceApp)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        children = try container.decodeIfPresent([ShelfItem].self, forKey: .children)
        isCut = try container.decodeIfPresent(Bool.self, forKey: .isCut) ?? false
    }

    /// Convenience file URL for kinds backed by an on-disk file.
    var fileURL: URL? {
        path.map { URL(fileURLWithPath: $0) }
    }
}
