import Foundation

/// The application an item was dragged in from, if known.
struct SourceAppInfo: Codable, Equatable, Sendable {
    /// Bundle identifier, e.g. `com.apple.finder`.
    var bundleID: String?
    /// Display name, e.g. `Finder`.
    var name: String?

    init(bundleID: String? = nil, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}
