import AppKit

/// Ignore-list matching (plan §2.2): apps in which the shake and edge
/// triggers stay silent. The global hot key is never filtered — it is the
/// unambiguous main entry point (research report §7.2).
///
/// The pure matcher (`isIgnored(bundleID:in:)`) is isolated from
/// `NSWorkspace` so it can be unit-tested headlessly; the `MainActor`
/// convenience reads the frontmost app.
enum IgnoreListService {
    /// Pure match: true when `bundleID` appears in the ignore list.
    /// Comparison is case-insensitive and tolerant of surrounding whitespace
    /// in list entries. Nil/empty bundle IDs and an empty list never match.
    nonisolated static func isIgnored(bundleID: String?, in ignoredBundleIDs: [String]) -> Bool {
        guard let bundleID else { return false }
        let needle = bundleID.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        return ignoredBundleIDs.contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == needle
        }
    }

    /// True when the frontmost application is on the ignore list.
    @MainActor
    static func frontmostAppIsIgnored(in ignoredBundleIDs: [String]) -> Bool {
        guard !ignoredBundleIDs.isEmpty else { return false }
        return isIgnored(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                         in: ignoredBundleIDs)
    }
}
