import XCTest
@testable import Eligo

final class SetupGuideActivationTests: XCTestCase {
    func testActivationIsCompleteOnlyWithDefaultBrowserAndUsableBrowsers() {
        XCTAssertTrue(SetupGuideActivation.isComplete(isDefaultBrowser: true, hasUsableBrowsers: true))
        XCTAssertFalse(SetupGuideActivation.isComplete(isDefaultBrowser: false, hasUsableBrowsers: true))
        XCTAssertFalse(SetupGuideActivation.isComplete(isDefaultBrowser: true, hasUsableBrowsers: false))
        XCTAssertFalse(SetupGuideActivation.isComplete(isDefaultBrowser: false, hasUsableBrowsers: false))
    }

    func testAutoShowsSetupWhenNeverShownAndActivationIncomplete() {
        XCTAssertTrue(
            SetupGuideActivation.shouldAutoShow(
                hasAutoShownSetup: false,
                isDefaultBrowser: false,
                hasUsableBrowsers: true
            )
        )
        XCTAssertTrue(
            SetupGuideActivation.shouldAutoShow(
                hasAutoShownSetup: false,
                isDefaultBrowser: true,
                hasUsableBrowsers: false
            )
        )
    }

    func testDoesNotAutoShowSetupAfterItWasAlreadyShown() {
        XCTAssertFalse(
            SetupGuideActivation.shouldAutoShow(
                hasAutoShownSetup: true,
                isDefaultBrowser: false,
                hasUsableBrowsers: false
            )
        )
    }

    func testDoesNotAutoShowSetupWhenActivationIsComplete() {
        XCTAssertFalse(
            SetupGuideActivation.shouldAutoShow(
                hasAutoShownSetup: false,
                isDefaultBrowser: true,
                hasUsableBrowsers: true
            )
        )
    }
}
