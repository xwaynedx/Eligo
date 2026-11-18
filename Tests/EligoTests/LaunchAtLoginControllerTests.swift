import ServiceManagement
import XCTest
@testable import Eligo

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testInitialStatusAndDerivedFlagsComeFromService() {
        XCTAssertTrue(LaunchAtLoginController(service: StubLaunchItemService(status: .enabled)).isEnabled)
        XCTAssertTrue(LaunchAtLoginController(service: StubLaunchItemService(status: .requiresApproval)).requiresApproval)
        XCTAssertFalse(LaunchAtLoginController(service: StubLaunchItemService(status: .notFound)).isAvailable)
        XCTAssertTrue(LaunchAtLoginController(service: StubLaunchItemService(status: .notRegistered)).isAvailable)
    }

    func testEnableRegistersAndRefreshesStatus() {
        let service = StubLaunchItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.setEnabled(true))

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testDisableUnregistersAndRefreshesStatus() {
        let service = StubLaunchItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.setEnabled(false))

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
    }

    func testFailedUpdateKeepsStatusAndRecordsError() {
        let service = StubLaunchItemService(status: .notRegistered)
        service.error = TestError.registerFailed
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.setEnabled(true))

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(controller.lastErrorMessage, TestError.registerFailed.localizedDescription)
    }
}

private enum TestError: Error {
    case registerFailed
}

private final class StubLaunchItemService: LaunchItemService {
    private(set) var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var error: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let error { throw error }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let error { throw error }
        status = .notRegistered
    }
}
