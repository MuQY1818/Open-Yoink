import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class SupportControllerTests: XCTestCase {
    private let snapshot = SupportController.DiagnosticSnapshot(
        version: "1.1.9",
        build: "14",
        operatingSystem: "macOS 26.5 (Build 25F70)",
        architecture: "arm64",
        language: .system,
        shelfPosition: .right,
        dragAutoAppearMode: .immediate,
        edgeTabEnabled: true,
        hotKeyEnabled: true,
        shakeTriggerEnabled: false,
        autoHide: false,
        autoHideWhenEmpty: true,
        dragOutRemovalPolicy: .keep,
        autoUpdateCheckEnabled: true
    )

    func testDiagnosticSummaryContainsOnlyAllowlistedEnvironmentAndSettings() {
        let summary = SupportController.diagnosticSummary(for: snapshot)

        XCTAssertTrue(summary.contains("Version: 1.1.9 (14)"))
        XCTAssertTrue(summary.contains("macOS: macOS 26.5 (Build 25F70)"))
        XCTAssertTrue(summary.contains("Architecture: arm64"))
        XCTAssertTrue(summary.contains("Shelf position: right"))
        XCTAssertTrue(summary.contains("Mouse shake: disabled"))
        XCTAssertFalse(summary.contains("/Users/"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("clipboard:"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("file name:"))
    }

    func testReportIssueURLPercentEncodesAndRoundTripsMultilineSummary() throws {
        let summary = SupportController.diagnosticSummary(for: snapshot)
        let url = SupportController.reportIssueURL(diagnosticSummary: summary)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "body" })?.value)

        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/MuQY1818/OpenYoink/issues/new")
        XCTAssertTrue(body.contains(summary))
        XCTAssertTrue(body.contains("no file names, paths, clipboard or shelf contents"))
    }

    func testCopyDiagnosticSummaryWritesOnlyTheGeneratedText() {
        let suiteName = "SupportControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let controller = SupportController(settings: settings)
        let pasteboard = NSPasteboard(name: .init("SupportControllerTests-\(UUID().uuidString)"))

        XCTAssertTrue(controller.copyDiagnosticSummary(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), controller.diagnosticSummary)
    }
}
