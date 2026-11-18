import Combine
import CoreServices
import XCTest
@testable import Eligo

@MainActor
final class DefaultBrowserControllerTests: XCTestCase {
    func testUnknownErrorLeavesTargetsUnchangedAndDoesNotClaimRestoration() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, false), (-999, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .unchanged)
        XCTAssertEqual(controller.state.observation, DefaultBrowserObservation(http: "browser.a", https: "browser.a"))
        XCTAssertFalse(controller.state.isDefaultBrowser)
        XCTAssertTrue(controller.state.canRequest)
        XCTAssertEqual(manager.writes, ["http|test.eligo", "https|test.eligo"])
    }

    func testOnlyAgreedUnchangedStatusPairsAreUnconfirmed() {
        let cases: [(OSStatus, OSStatus, DefaultBrowserFeedback)] = [
            (0, 0, .notConfirmed), (0, -54, .notConfirmed), (-54, 0, .notConfirmed),
            (-54, -54, .unchanged), (-50, -50, .unchanged), (0, -999, .unchanged), (-999, 0, .unchanged)
        ]
        for (http, https, feedback) in cases {
            let manager = ControlledDefaultBrowserHandlers()
            manager.responses = [(http, false), (https, false)]
            let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
            controller.requestDefaultBrowser()
            XCTAssertEqual(controller.state.feedback, feedback, "statuses: \(http)/\(https)")
            XCTAssertEqual(manager.writes.count, 2)
            controller.refresh() // A cancelled or still-open prompt is indistinguishable.
            XCTAssertEqual(controller.state.feedback, feedback)
            XCTAssertFalse(controller.state.isDefaultBrowser)
            manager.handlers = ["http": "test.eligo", "https": "test.eligo"]
            controller.refresh()
            XCTAssertTrue(controller.state.isDefaultBrowser)
            XCTAssertNil(controller.state.feedback)
        }
    }

    func testActualDefaultsWinEvenWhenBothWritesReportErrors() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(-50, true), (-54, true)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertTrue(controller.state.isDefaultBrowser)
        XCTAssertNil(controller.state.feedback)
        XCTAssertEqual(manager.writes.count, 2)
        controller.requestDefaultBrowser()
        XCTAssertEqual(manager.writes.count, 2) // Already default: no registration or write.
    }

    func testRetryRefreshesTargetsAndReplacesFeedback() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, false), (-54, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        manager.handlers = ["http": "browser.b", "https": "browser.b"]
        manager.responses = [(0, true), (-50, false), (0, true)]
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .restored)
        XCTAssertEqual(controller.state.observation, .init(http: "browser.b", https: "browser.b"))
        XCTAssertEqual(manager.writes.last, "http|browser.b")
        manager.handlers = ["http": "test.eligo", "https": "test.eligo"]
        controller.requestDefaultBrowser()
        XCTAssertNil(controller.state.feedback)
        XCTAssertEqual(manager.writes.count, 5)
    }

    func testPartialUpdateOnlyRestoresChangedSchemeWithKnownOriginal() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, true), (0, false), (-54, true)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .restored) // Facts win over restore status too.
        XCTAssertEqual(manager.writes, ["http|test.eligo", "https|test.eligo", "http|browser.a"])
        XCTAssertEqual(controller.state.observation, .init(http: "browser.a", https: "browser.a"))
    }

    func testFailedRestoreReportsActualTargets() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, true), (-50, false), (-50, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .restorationIncomplete)
        XCTAssertEqual(controller.state.observation, .init(http: "test.eligo", https: "browser.a"))
    }

    func testMissingOriginalCannotBeInventedForRestoration() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.handlers = [:]
        manager.responses = [(0, true), (-50, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        XCTAssertFalse(controller.state.isDefaultBrowser)
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .restorationIncomplete)
        XCTAssertEqual(controller.state.observation, .init(http: "test.eligo", https: nil))
        XCTAssertEqual(manager.writes.count, 2)
    }

    func testReturnToUnknownOriginalWithoutRestoreUsesNeutralFeedback() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.handlers = [:]
        manager.responses = [(0, true), (-50, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        manager.onRead = { [unowned manager] scheme in
            // An external change follows the partial-update observation.
            if scheme == "https", manager.handlers["http"] == "test.eligo" {
                manager.handlers = [:]
            }
        }

        controller.requestDefaultBrowser()

        let language = makeEnglishAppLanguageStore()
        let message = "Automatic setup did not complete. You can retry or choose Eligo in System Settings."
        XCTAssertEqual(controller.state.observation, .init(http: nil, https: nil))
        XCTAssertEqual(controller.state.feedbackText(using: language), message)
        XCTAssertTrue(controller.state.canRequest)
        XCTAssertEqual(manager.writes, ["http|test.eligo", "https|test.eligo"])
        controller.refresh()
        XCTAssertEqual(controller.state.feedbackText(using: language), message)
        XCTAssertEqual(manager.writes.count, 2)
    }

    func testSuccessObservedAfterRestoreOverridesFailureExplanation() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, true), (-50, false), (-50, false)]
        manager.onWrite = { [unowned manager] in
            if manager.writes.count == 3 {
                manager.handlers = ["http": "test.eligo", "https": "test.eligo"]
            }
        }
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertTrue(controller.state.isDefaultBrowser)
        XCTAssertNil(controller.state.feedback)
    }

    func testRequestCannotReenterAndPublishesCoherentFactsWithFeedback() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, false), (-54, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        var published: [DefaultBrowserState] = []
        let subscription = controller.$state.dropFirst().sink { state in
            published.append(state)
            controller.requestDefaultBrowser()
        }
        manager.onWrite = { [unowned controller] in
            controller.refresh()
            controller.requestDefaultBrowser()
        }
        controller.requestDefaultBrowser()
        XCTAssertEqual(manager.writes.count, 2)
        XCTAssertEqual(published.count, 2)
        XCTAssertTrue(published[0].isRequesting)
        XCTAssertFalse(published[0].canRequest)
        XCTAssertEqual(published[1].feedback, .notConfirmed)
        XCTAssertTrue(published[1].canRequest)
        XCTAssertTrue(published.allSatisfy { !$0.isDefaultBrowser })
        withExtendedLifetime(subscription) {}
    }

    func testCompleteObservationChangesPublishAndInvalidateFeedbackButStableReadsDoNot() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.responses = [(0, false), (-54, false)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        var published: [DefaultBrowserState] = []
        let subscription = controller.$state.dropFirst().sink { published.append($0) }
        controller.refresh()
        XCTAssertTrue(published.isEmpty)
        for (http, https) in [("b", "b"), ("a", "b"), ("b", "a"), ("test.eligo", "test.eligo"), ("a", "a")] {
            manager.handlers = ["http": http, "https": https]
            controller.refresh()
            XCTAssertEqual(controller.state.observation, .init(http: http, https: https))
            XCTAssertNil(controller.state.feedback)
            controller.refresh()
        }
        XCTAssertEqual(published.count, 5)
        XCTAssertFalse(controller.state.isDefaultBrowser)
        withExtendedLifetime(subscription) {}
    }

    func testWindowDemandDeduplicatesPollingAndInvalidatesOldTicks() {
        let manager = ControlledDefaultBrowserHandlers()
        let scheduler = DefaultBrowserTestScheduler()
        let settings = NSObject()
        let welcome = NSObject()
        let controller = DefaultBrowserController(
            manager: manager, bundleIdentifier: "test.eligo", schedule: scheduler.schedule
        )
        controller.beginObserving(for: settings)
        controller.beginObserving(for: settings)
        controller.beginObserving(for: welcome)
        XCTAssertEqual(scheduler.ticks.count, 1)
        controller.endObserving(for: settings)
        scheduler.tick()
        XCTAssertEqual(scheduler.ticks.count, 1)
        controller.endObserving(for: welcome)
        let reads = manager.readCount
        controller.beginObserving(for: welcome)
        XCTAssertEqual(scheduler.ticks.count, 2)
        scheduler.tick() // Queued before close: may not read or spawn another chain.
        XCTAssertEqual(manager.readCount, reads + 2)
        XCTAssertEqual(scheduler.ticks.count, 1)
        controller.endObserving(for: welcome)
        scheduler.tick()
        XCTAssertEqual(manager.readCount, reads + 2)
        XCTAssertTrue(scheduler.ticks.isEmpty)
    }


    func testCloseRetainsUnconfirmedFeedbackAndReopenOnlyKeepsItForUnchangedTargets() {
        let manager = ControlledDefaultBrowserHandlers()
        let scheduler = DefaultBrowserTestScheduler()
        let window = NSObject()
        manager.responses = [(0, false), (-54, false)]
        let controller = DefaultBrowserController(
            manager: manager, bundleIdentifier: "test.eligo", schedule: scheduler.schedule
        )
        controller.beginObserving(for: window)
        controller.requestDefaultBrowser()
        controller.endObserving(for: window)
        scheduler.tick()
        XCTAssertEqual(controller.state.feedback, .notConfirmed)
        controller.beginObserving(for: window)
        XCTAssertEqual(controller.state.feedback, .notConfirmed)
        controller.endObserving(for: window)
        manager.handlers = ["http": "test.eligo", "https": "test.eligo"]
        controller.beginObserving(for: window)
        XCTAssertTrue(controller.state.isDefaultBrowser)
        XCTAssertNil(controller.state.feedback)
        XCTAssertEqual(manager.writes.count, 2)
    }

    func testWindowReopenedDuringPublicationDoesNotReviveOriginalPollingChain() {
        let manager = ControlledDefaultBrowserHandlers()
        let scheduler = DefaultBrowserTestScheduler()
        let window = NSObject()
        let controller = DefaultBrowserController(
            manager: manager, bundleIdentifier: "test.eligo", schedule: scheduler.schedule
        )
        let subscription = controller.$state.dropFirst().sink { _ in
            controller.endObserving(for: window)
            controller.beginObserving(for: window)
        }
        manager.handlers = ["http": "browser.b", "https": "browser.b"]
        controller.beginObserving(for: window) // Subscriber closes and reopens during initial refresh.
        XCTAssertEqual(scheduler.ticks.count, 1)
        manager.handlers = ["http": "browser.a", "https": "browser.b"]
        scheduler.tick() // Same reentry during a tick may only schedule the new generation.
        XCTAssertEqual(scheduler.ticks.count, 1)
        controller.endObserving(for: window)
        scheduler.tick()
        XCTAssertTrue(scheduler.ticks.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testOnlyChangedHTTPSIsRestoredAndUnknownHandlerRendersHonestly() {
        let manager = ControlledDefaultBrowserHandlers()
        manager.handlers = ["https": "browser.b"]
        manager.responses = [(-50, false), (0, true), (0, true)]
        let controller = DefaultBrowserController(manager: manager, bundleIdentifier: "test.eligo")
        controller.requestDefaultBrowser()
        XCTAssertEqual(controller.state.feedback, .restored)
        XCTAssertEqual(manager.writes, ["http|test.eligo", "https|test.eligo", "https|browser.b"])
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        XCTAssertEqual(controller.state.statusText(using: language), "Current defaults: HTTP Unknown; HTTPS browser.b")
        language.select(.simplifiedChinese)
        XCTAssertEqual(controller.state.statusText(using: language), "当前默认浏览器：HTTP 未知；HTTPS browser.b")
    }

}

final class ControlledDefaultBrowserHandlers: DefaultBrowserHandlerManaging {
    var handlers: [String: String] = ["http": "browser.a", "https": "browser.a"]
    var responses: [(OSStatus, Bool)] = []
    var writes: [String] = []
    var readCount = 0
    var onRead: ((String) -> Void)?
    var onWrite: (() -> Void)?

    func defaultHandler(for scheme: String) -> String? {
        readCount += 1
        let handler = handlers[scheme]
        onRead?(scheme)
        return handler
    }

    func setDefaultHandler(_ bundleIdentifier: String, for scheme: String) -> OSStatus {
        writes.append("\(scheme)|\(bundleIdentifier)")
        let (status, applies) = responses.isEmpty ? (0, true) : responses.removeFirst()
        if applies { handlers[scheme] = bundleIdentifier }
        onWrite?()
        return status
    }
}

@MainActor
final class DefaultBrowserTestScheduler {
    var ticks: [@MainActor @Sendable () -> Void] = []
    func schedule(_ tick: @escaping @MainActor @Sendable () -> Void) { ticks.append(tick) }
    func tick() { ticks.removeFirst()() }
}
