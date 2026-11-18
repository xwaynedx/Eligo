import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ApplicationPresentationControllerTests: XCTestCase {
    func testBackgroundModeUsesAccessoryPolicy() {
        let application = RecordingApplication(activationPolicy: .regular)
        let controller = ApplicationPresentationController(application: application)

        controller.enterBackgroundMode()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.activationPolicy(), .accessory)
        XCTAssertEqual(application.activationCount, 0)
    }

    func testShowingSettingsUsesRegularPolicyAndActivatesApplication() {
        let application = RecordingApplication(activationPolicy: .accessory)
        let controller = ApplicationPresentationController(application: application)

        controller.settingsWillShow()

        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(application.activationPolicy(), .regular)
        XCTAssertEqual(application.activationCount, 1)
    }

    func testClosingSettingsRestoresAccessoryPolicy() {
        let application = RecordingApplication(activationPolicy: .regular)
        let controller = ApplicationPresentationController(application: application)

        controller.settingsDidClose()

        XCTAssertEqual(application.requestedPolicies, [.accessory])
        XCTAssertEqual(application.activationPolicy(), .accessory)
    }

    func testTransitionDoesNotResetAnAlreadyMatchingPolicy() {
        let application = RecordingApplication(activationPolicy: .accessory)
        let controller = ApplicationPresentationController(application: application)

        controller.enterBackgroundMode()

        XCTAssertTrue(application.requestedPolicies.isEmpty)
    }
}

@MainActor
private final class RecordingApplication: ApplicationActivationPolicyControlling {
    private var currentActivationPolicy: NSApplication.ActivationPolicy
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    init(activationPolicy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = activationPolicy
    }

    func activationPolicy() -> NSApplication.ActivationPolicy {
        currentActivationPolicy
    }

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(activationPolicy)
        currentActivationPolicy = activationPolicy
        return true
    }

    func activate() {
        activationCount += 1
    }
}
