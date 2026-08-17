import Foundation

/// The kind of content a shelf item represents.
///
/// Raw values are persisted verbatim in `shelf.json`; renaming a case is a
/// breaking format change and requires a migration in `PersistenceController`.
enum ItemKind: String, Codable, CaseIterable, Sendable {
    /// A regular file, referenced by path + security-scoped bookmark.
    case file
    /// A folder, referenced by path + security-scoped bookmark.
    case folder
    /// Inline plain text; content lives in `ShelfItem.text`.
    case text
    /// An image. File-backed like `.file` (image data dragged in without a file
    /// is materialized to disk first), rendered with image previews in the UI.
    case image
    /// A web URL; the URL string lives in `ShelfItem.urlString`.
    case url
    /// A stack grouping multiple items; children are embedded in `ShelfItem.children`.
    case stack
}
