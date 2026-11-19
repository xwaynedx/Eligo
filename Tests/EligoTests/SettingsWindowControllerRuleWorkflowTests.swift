import AppKit
import SwiftUI
import XCTest
@testable import Eligo

@MainActor
final class SettingsWindowControllerRuleWorkflowTests: XCTestCase {
    func testWindowHandoffReturnsFinalSavedDestinationAfterSheetEnds() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        var results: [OpenDestinationID?] = []
        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination()) { results.append($0) }
        let session = controller.domainRuleSessionForTesting
        let id = try XCTUnwrap(session.state.presentation?.id)
        let finalDestination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)
        try session.commit(.singleRule(presentationID: id, host: "example.com",
                                       includesSubdomains: false, destinationID: finalDestination))
        XCTAssertTrue(results.isEmpty)
        _ = session.send(.presentationEnded(id: id))
        XCTAssertEqual(results, [finalDestination])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        XCTAssertEqual(results, [finalDestination])
    }

    private func makeFixture(rules: [DomainRule] = []) throws -> SettingsWindowControllerRuleWorkflowFixture {
        let fixture = try SettingsWindowControllerRuleWorkflowFixture(rules: rules)
        addTeardownBlock { await fixture.cleanup() }
        return fixture
    }

    private func makeDestination() -> OpenDestination {
        OpenDestination(
            browser: makeBrowser(
                name: "Workflow Browser",
                bundleIdentifier: SettingsWindowControllerRuleWorkflowFixture.browserID
            ),
            mode: .normal
        )
    }

    // MARK: - Window lifecycle

    func testWindowOwnsOneSessionForItsLifetime() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()

        let sessionBefore = controller.domainRuleSessionForTesting
        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        // The same session instance serves the request: a Chooser handoff must not
        // rebuild the hosting root and create a second session.
        XCTAssertTrue(sessionBefore === controller.domainRuleSessionForTesting)
    }

    func testSettingsViewObservesWindowOwnedSectionSelection() throws {
        // Regression: a Chooser handoff writes `sectionSelection.section = .rules`
        // on the window side. `SettingsView` must observe that change and re-render,
        // which requires it to hold the SAME ObservableObject (not a detached bare
        // Binding whose writes leave the view stuck on the old section). Before the
        // fix the injected Binding forwarded writes but the view never saw them, so
        // switching tabs in the Settings window did nothing.
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let hostingController = try XCTUnwrap(
            controller.contentViewController as? NSHostingController<SettingsView>
        )

        let windowOwnedSelection = controller.sectionSelectionForTesting
        let viewOwnedSelection = hostingController.rootView.sectionSelection

        // Same ObservableObject instance: writes from the window side propagate as
        // objectWillChange to the SwiftUI view.
        XCTAssertTrue(windowOwnedSelection === viewOwnedSelection)

        // A window-driven reveal actually moves the value the view renders.
        XCTAssertEqual(viewOwnedSelection.section, .general)
        windowOwnedSelection.section = .rules
        XCTAssertEqual(viewOwnedSelection.section, .rules)
        XCTAssertEqual(hostingController.rootView.sectionSelection.section, .rules)
    }

    func testWindowWillCloseSynchronouslyClearsTransientSessionState() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        // Seed some transient state, including a deferred Chooser request.
        session.send(.presentSingleRuleCreate)
        session.send(.requestRuleFromChooser(host: "example.com", destinationID: makeDestination().id))
        XCTAssertEqual(session.state.hasDeferredChooserRequest, true)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))

        XCTAssertEqual(session.state.presentation, nil)
        XCTAssertEqual(session.state.hasDeferredChooserRequest, false)
        XCTAssertEqual(session.state.selectedRuleIDs, [])
    }

    // MARK: - Chooser handoff

    func testChooserRequestWhileIdleRevealsRulesAndActivatesPresentation() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        controller.selectedSection = .general
        let session = controller.domainRuleSessionForTesting

        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        XCTAssertEqual(controller.selectedSection, .rules)
        guard case .singleRuleCreate = session.state.presentation else {
            XCTFail("Expected a single-rule create presentation, got \(String(describing: session.state.presentation))")
            return
        }
    }

    func testChooserRequestDoesNotReplaceHostingRoot() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()

        let contentViewControllerBefore = controller.contentViewController

        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        // The hosting controller identity is unchanged: a Chooser handoff must not
        // rebuild the hosting root (which would destroy the active SwiftUI subtree).
        XCTAssertTrue(controller.contentViewController === contentViewControllerBefore)
        // The reveal drives section selection through the bound holder rather than
        // a freshly constructed SettingsView carrying an initial draft.
        XCTAssertEqual(controller.selectedSection, .rules)
    }

    func testChooserRequestWithExactDuplicateKeepsCreateIntentAndUpdatesOnCommit() throws {
        let existingRule = try makeDomainRule(host: "example.com")
        let fixture = try makeFixture(rules: [existingRule])
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        guard case let .singleRuleCreate(id, prefill) = session.state.presentation else {
            XCTFail("应保留单条创建意图，实际为 \(String(describing: session.state.presentation))")
            return
        }
        XCTAssertEqual(prefill?.matcher.normalizedHost, "example.com")
        let target = OpenDestinationID(browserID: makeDestination().browser.id, mode: .privateBrowsing)
        try session.commit(.singleRule(presentationID: id, host: "example.com",
            includesSubdomains: false, destinationID: target))
        XCTAssertEqual(fixture.store.settings.rules.map(\.id), [existingRule.id])
        XCTAssertEqual(fixture.store.settings.rules.first?.destinationID, target)
    }

    // MARK: - Deferred latest-wins

    func testChooserRequestWhileEditorActiveIsDeferredWithoutTouchingCurrentPresentation() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        session.send(.presentSingleRuleCreate)
        let originalPresentation = session.state.presentation

        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        XCTAssertEqual(session.state.presentation, originalPresentation)
        XCTAssertEqual(session.state.hasDeferredChooserRequest, true)
    }

    func testDeferredChooserRequestIsPromotedAfterPresentationEnds() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        session.send(.presentSingleRuleCreate)
        let originalPresentationID = session.state.presentation?.id
        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        // Simulate the adapter dismissing the active editor via presentationEnded.
        let effect = session.send(.presentationEnded(id: originalPresentationID!))

        XCTAssertEqual(effect, .revealRules)
        guard case .singleRuleCreate = session.state.presentation else {
            XCTFail("Expected the deferred request to promote a single-rule create, got \(String(describing: session.state.presentation))")
            return
        }
        XCTAssertEqual(session.state.hasDeferredChooserRequest, false)
    }

    // MARK: - Effect once-only

    func testRevealEffectIsNotReplayedByUnrelatedIntents() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())

        // Reading state and sending unrelated intents must not return the effect.
        XCTAssertNil(session.send(.setRuleSelection(id: UUID(), isSelected: true)))
        XCTAssertNil(session.send(.clearSelection))
    }

    // MARK: - windowClosed discards pending

    func testWindowClosedDiscardsPendingChooserRequest() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting

        session.send(.presentSingleRuleCreate)
        let originalPresentationID = session.state.presentation?.id
        controller.requestRuleFromChooser(host: "example.com", destination: makeDestination())
        XCTAssertEqual(session.state.hasDeferredChooserRequest, true)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))

        // After close, a stale presentation-ended must not promote anything.
        let effect = session.send(.presentationEnded(id: originalPresentationID!))
        XCTAssertNil(effect)
        XCTAssertEqual(session.state.presentation, nil)
        XCTAssertEqual(session.state.hasDeferredChooserRequest, false)
    }

    // MARK: - Production writer delegation

    func testIdleChooserRequestThenCommitPersistsRuleThroughProductionWriter() throws {
        let fixture = try makeFixture()
        let controller = fixture.makeController()
        let session = controller.domainRuleSessionForTesting
        let destination = makeDestination()

        controller.requestRuleFromChooser(host: "example.com", destination: destination)
        guard case let .singleRuleCreate(presentationID, _) = session.state.presentation else {
            XCTFail("Expected a single-rule create presentation")
            return
        }

        try session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "example.com",
                includesSubdomains: false,
                destinationID: destination.id
            )
        )

        XCTAssertTrue(fixture.store.settings.rules.contains { $0.matcher.normalizedHost == "example.com" })
    }
}

@MainActor
private final class SettingsWindowControllerRuleWorkflowFixture {
    static let browserID = "com.example.WorkflowBrowser"

    let userDefaults: UserDefaults
    let store: RoutingPreferencesStore
    let browserRepository: BrowserRepository
    let appLanguageStore: AppLanguageStore
    let launchAtLoginController: LaunchAtLoginController
    let applicationPresentationController: ApplicationPresentationController
    private let suiteName: String

    init(rules: [DomainRule]) throws {
        suiteName = "EligoTests.SettingsWindowControllerRuleWorkflow.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        store = RoutingPreferencesStore(userDefaults: userDefaults)
        try store.replace(with: RoutingSettings(scope: .allDomains, rules: rules, alwaysShowChooser: false))
        appLanguageStore = AppLanguageStore(userDefaults: userDefaults, systemPreferredLanguages: ["en-US"])
        // A scanner with a known browser keeps the repository deterministic and
        // gives the workflow a stable Open Destination to hand off.
        browserRepository = BrowserRepository(
            scanner: StubBrowserScanner(result: [
                makeBrowser(name: "Workflow Browser", bundleIdentifier: Self.browserID)
            ]),
            preferences: BrowserPreferences(userDefaults: userDefaults)
        )
        launchAtLoginController = LaunchAtLoginController()
        applicationPresentationController = ApplicationPresentationController()
    }

    func makeController() -> SettingsWindowController {
        SettingsWindowController(
            browserRepository: browserRepository,
            routingPreferencesStore: store,
            appLanguageStore: appLanguageStore,
            launchAtLoginController: launchAtLoginController,
            defaultBrowserController: DefaultBrowserController(manager: ControlledDefaultBrowserHandlers(), bundleIdentifier: "test.eligo"),
            applicationPresentationController: applicationPresentationController
        )
    }

    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makeDomainRule(host: String) throws -> DomainRule {
    DomainRule(
        matcher: try DomainMatcher(host: host, includesSubdomains: false),
        destinationID: OpenDestinationID(
            browserID: SettingsWindowControllerRuleWorkflowFixture.browserID,
            mode: .normal
        )
    )
}
