import XCTest
@testable import Eligo

final class WelcomeGuideModelTests: XCTestCase {
    // MARK: - Navigation bounds

    func testStartsOnLanguageStep() {
        let model = WelcomeGuideModel(activationComplete: false)
        XCTAssertEqual(model.step, .language)
        XCTAssertFalse(model.canGoBack)
        XCTAssertTrue(model.canGoForward)
    }

    func testWalksForwardThroughAllStepsInOrder() {
        var model = WelcomeGuideModel(activationComplete: false)
        model.goForward()
        XCTAssertEqual(model.step, .welcome)
        model.goForward()
        XCTAssertEqual(model.step, .howItWorks)
        model.goForward()
        XCTAssertEqual(model.step, .rulesAndScope)
        model.goForward()
        XCTAssertEqual(model.step, .activation)
        model.goForward()
        XCTAssertEqual(model.step, .complete)
    }

    func testCannotAdvancePastCompleteStep() {
        var model = WelcomeGuideModel(activationComplete: false)
        for _ in 0..<WelcomeGuideModel.Step.allCases.count { model.goForward() }
        XCTAssertEqual(model.step, .complete)
        XCTAssertFalse(model.canGoForward)
        model.goForward()
        XCTAssertEqual(model.step, .complete)
    }

    func testCannotGoBackBeforeLanguageStep() {
        var model = WelcomeGuideModel(activationComplete: false)
        model.goBack()
        XCTAssertEqual(model.step, .language)
    }

    func testCanGoBackFromEveryLaterStep() {
        var model = WelcomeGuideModel(activationComplete: false)
        model.goForward()
        model.goForward()
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertEqual(model.step, .welcome)
        model.goBack()
        XCTAssertEqual(model.step, .language)
        XCTAssertFalse(model.canGoBack)
    }

    // MARK: - Skip

    func testSkipIsAlwaysAvailable() {
        var model = WelcomeGuideModel(activationComplete: false)
        for step in WelcomeGuideModel.Step.allCases {
            while model.step != step { model.goForward() }
            XCTAssertTrue(model.canSkip, "skip must be available on \(step)")
        }
    }

    // MARK: - Activation presentation

    func testActivationStepShowsPendingWhileIncomplete() {
        let model = WelcomeGuideModel(activationComplete: false)
        XCTAssertEqual(model.activationPresentation, .pending)
    }

    func testActivationStepShowsSucceededWhenComplete() {
        let model = WelcomeGuideModel(activationComplete: true)
        XCTAssertEqual(model.activationPresentation, .succeeded)
    }

    // MARK: - Auto-advance trigger

    private func makeModelOnActivationStep(activationComplete: Bool = false) -> WelcomeGuideModel {
        var model = WelcomeGuideModel(activationComplete: activationComplete)
        while model.step != .activation { model.goForward() }
        return model
    }

    func testActivationFlipOnActivationStepTriggersAutoAdvanceOnce() {
        var model = makeModelOnActivationStep()
        XCTAssertTrue(model.noteActivationComplete(true))
        XCTAssertEqual(model.activationPresentation, .succeeded)
        // The cue fires exactly once; repeated polls must not retrigger it.
        XCTAssertFalse(model.noteActivationComplete(true))
    }

    func testActivationFlipOnAnotherStepDoesNotTriggerAutoAdvance() {
        var model = WelcomeGuideModel(activationComplete: false)
        XCTAssertFalse(model.noteActivationComplete(true))
        XCTAssertTrue(model.activationComplete)
    }

    func testReachingActivationStepAlreadyCompleteDoesNotTriggerAutoAdvance() {
        var model = makeModelOnActivationStep(activationComplete: true)
        XCTAssertFalse(model.noteActivationComplete(true))
        XCTAssertEqual(model.activationPresentation, .succeeded)
    }

    func testActivationStatusDropAfterCompletionDoesNotReArmTrigger() {
        var model = makeModelOnActivationStep()
        XCTAssertTrue(model.noteActivationComplete(true))
        XCTAssertFalse(model.noteActivationComplete(false))
        XCTAssertFalse(model.noteActivationComplete(true))
    }
}
