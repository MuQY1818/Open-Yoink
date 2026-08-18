import XCTest

@MainActor
final class OpenYoinkSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testShelfLaunchesIntoAccessibleEmptyState() throws {
        let app = launch(surface: "--ui-testing-show-shelf")
        defer { app.terminate() }

        XCTAssertTrue(element("shelf.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("shelf.emptyState", in: app).waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Empty shelf smoke test"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsSidebarNavigatesToStorage() throws {
        let app = launch(surface: "--ui-testing-open-settings")
        defer { app.terminate() }

        XCTAssertTrue(element("settings.content.general", in: app).waitForExistence(timeout: 5))
        let storage = element("settings.pane.storage", in: app)
        XCTAssertTrue(storage.waitForExistence(timeout: 2))
        storage.click()
        XCTAssertTrue(element("settings.content.storage", in: app).waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Storage settings smoke test"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsPassesCoreAccessibilityAudit() throws {
        let app = launch(surface: "--ui-testing-open-settings")
        defer { app.terminate() }
        XCTAssertTrue(element("settings.content.general", in: app).waitForExistence(timeout: 5))

        let popupIdentifiers = [
            "settings.dragOutRemovalPolicy",
        ]
        let systemZoomButton = app.buttons.matching(
            identifier: "_XCUI:ZoomWindow"
        ).firstMatch

        try app.performAccessibilityAudit(
            for: [
                .sufficientElementDescription,
                .action,
                .parentChild,
            ],
            { issue in
                // SwiftUI's native macOS Picker is exposed as an actionable
                // PopUpButton and is exercised by testSettingsPopupPickerOpens,
                // but the XCTest audit still reports a missing action.
                // Suppress only that verified framework control; every other
                // issue still fails.
                if issue.auditType.contains(.action),
                   let element = issue.element,
                   element.elementType == .popUpButton,
                   popupIdentifiers.contains(element.identifier) {
                    return true
                }

                // AppKit owns the nested decoration groups inside the green
                // zoom traffic-light button. XCTest reports a parent/child
                // mismatch for that system element on macOS 26.5; scope the
                // exception to a group geometrically contained by that button.
                if issue.auditType.contains(.parentChild),
                   let element = issue.element,
                   element.elementType == .group,
                   systemZoomButton.exists,
                   systemZoomButton.frame.insetBy(dx: -1, dy: -1).contains(element.frame) {
                    return true
                }

                // XCTest includes the disabled, system-generated Touch Bar
                // container in the app hierarchy on Touch Bar Macs even when
                // OpenYoink defines no Touch Bar content.
                if issue.auditType.contains(.sufficientElementDescription),
                   let element = issue.element,
                   element.elementType == .touchBar,
                   !element.isEnabled {
                    return true
                }

                print("AUDIT ISSUE: \(issue.compactDescription)")
                print(issue.element?.debugDescription ?? "No associated element")
                return false
            }
        )
    }

    func testSettingsPopupPickerOpens() throws {
        let app = launch(surface: "--ui-testing-open-settings")
        defer { app.terminate() }

        let picker = element("settings.dragOutRemovalPolicy", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        picker.click()
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    private func launch(surface: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENYOINK_UI_TESTING"] = "1"
        app.launchArguments = [
            "-OpenYoink.onboardingVersion", "1",
            "-OpenYoink.autoUpdateCheckEnabled", "NO",
            surface,
        ]
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
