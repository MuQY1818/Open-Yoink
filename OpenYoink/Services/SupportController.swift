import AppKit
import Foundation
import Observation

/// Explicit, user-initiated support actions. No report is sent in the
/// background, and the diagnostic snapshot deliberately excludes paths,
/// file names, clipboard data, shelf contents, account identifiers and logs.
@MainActor
@Observable
final class SupportController {
    struct DiagnosticSnapshot: Equatable {
        let version: String
        let build: String
        let operatingSystem: String
        let architecture: String
        let language: SettingsStore.LanguagePreference
        let shelfPosition: SettingsStore.ShelfPosition
        let dragAutoAppearMode: SettingsStore.DragAutoAppearMode
        let edgeTabEnabled: Bool
        let hotKeyEnabled: Bool
        let shakeTriggerEnabled: Bool
        let autoHide: Bool
        let autoHideWhenEmpty: Bool
        let dragOutRemovalPolicy: SettingsStore.DragOutRemovalPolicy
        let autoUpdateCheckEnabled: Bool
    }

    static let helpURL = URL(string: "https://muqy1818.github.io/OpenYoink/#usage")!
    private static let newIssueURL = URL(string: "https://github.com/MuQY1818/OpenYoink/issues/new")!

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var diagnosticSummary: String {
        Self.diagnosticSummary(for: snapshot())
    }

    func openHelp() {
        NSWorkspace.shared.open(Self.helpURL)
    }

    func reportIssue() {
        NSWorkspace.shared.open(Self.reportIssueURL(diagnosticSummary: diagnosticSummary))
    }

    @discardableResult
    func copyDiagnosticSummary(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(diagnosticSummary, forType: .string)
    }

    static func diagnosticSummary(for snapshot: DiagnosticSnapshot) -> String {
        """
        OpenYoink diagnostics
        Version: \(snapshot.version) (\(snapshot.build))
        macOS: \(snapshot.operatingSystem)
        Architecture: \(snapshot.architecture)
        Language: \(snapshot.language.rawValue)
        Shelf position: \(snapshot.shelfPosition.rawValue)
        Drag auto-appear: \(snapshot.dragAutoAppearMode.rawValue)
        Edge tab: \(enabled(snapshot.edgeTabEnabled))
        Global shortcut: \(enabled(snapshot.hotKeyEnabled))
        Mouse shake: \(enabled(snapshot.shakeTriggerEnabled))
        Auto-hide after delivery: \(enabled(snapshot.autoHide))
        Auto-hide when empty: \(enabled(snapshot.autoHideWhenEmpty))
        Drag-out policy: \(snapshot.dragOutRemovalPolicy.rawValue)
        Automatic update checks: \(enabled(snapshot.autoUpdateCheckEnabled))
        """
    }

    static func reportIssueURL(diagnosticSummary: String) -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: """
            ## What happened?


            ## Steps to reproduce
            1.

            ## What did you expect?


            <details>
            <summary>Diagnostic summary (no file names, paths, clipboard or shelf contents)</summary>

            ```text
            \(diagnosticSummary)
            ```
            </details>
            """)
        ]
        return components.url!
    }

    private func snapshot() -> DiagnosticSnapshot {
        let info = Bundle.main.infoDictionary
        return DiagnosticSnapshot(
            version: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            build: info?["CFBundleVersion"] as? String ?? "Unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            language: settings.language,
            shelfPosition: settings.shelfPosition,
            dragAutoAppearMode: settings.dragAutoAppearMode,
            edgeTabEnabled: settings.edgeTabEnabled,
            hotKeyEnabled: settings.hotKeyEnabled,
            shakeTriggerEnabled: settings.shakeTriggerEnabled,
            autoHide: settings.autoHide,
            autoHideWhenEmpty: settings.autoHideWhenEmpty,
            dragOutRemovalPolicy: settings.dragOutRemovalPolicy,
            autoUpdateCheckEnabled: settings.autoUpdateCheckEnabled
        )
    }

    private static func enabled(_ value: Bool) -> String {
        value ? "enabled" : "disabled"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
