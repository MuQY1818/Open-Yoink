import XCTest
import ServiceManagement
@testable import OpenYoink

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnable_registersAndRefreshesSystemStatus() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setRequested(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isRequested)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisable_unregistersAnApprovalPendingRequest() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.setRequested(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
    }

    func testRegistrationFailureKeepsActualStatusAndShowsError() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.denied
        let controller = LaunchAtLoginController(service: service)

        controller.setRequested(true)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(controller.errorMessage, TestError.denied.localizedDescription)
    }

    func testRequiresApprovalIsStillARegisteredRequest() {
        let controller = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(status: .requiresApproval)
        )

        XCTAssertTrue(controller.isRequested)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testExternalStatusChangeClearsStaleOperationError() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.denied
        let controller = LaunchAtLoginController(service: service)
        controller.setRequested(true)
        XCTAssertNotNil(controller.errorMessage)

        service.status = .enabled
        controller.refresh()

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testMissingInitialSystemRecordIsTreatedAsNotRegistered() {
        XCTAssertEqual(
            SystemLaunchAtLoginService.map(.notFound),
            .notRegistered
        )
    }

    func testUnavailableFutureStatusDoesNotAttemptRegistration() {
        let service = FakeLaunchAtLoginService(status: .unavailable)
        let controller = LaunchAtLoginController(service: service)

        controller.setRequested(true)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(controller.status, .unavailable)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginController.Status
    var registerError: Error?
    var unregisterError: Error?
    var registerCount = 0
    var unregisterCount = 0
    var openSettingsCount = 0

    init(status: LaunchAtLoginController.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private enum TestError: LocalizedError {
    case denied

    var errorDescription: String? { "Registration denied" }
}
