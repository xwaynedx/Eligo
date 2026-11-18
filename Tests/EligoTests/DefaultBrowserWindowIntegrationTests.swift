import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import Eligo

@MainActor
final class DefaultBrowserWindowIntegrationTests: XCTestCase {
    func testGeneralKeepsPreferencesVisibleAndExpandsRepairWhenDefaultIsLost() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(SettingsSection.allCases, [.general, .browsers, .rules])
        fixture.handlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
        fixture.controller.refresh()
        XCTAssertFalse(try fixture.settingsView().generalSettings.showsSetupRepair)
        fixture.handlers.handlers = ["http": "browser.a", "https": "browser.a"]
        fixture.controller.refresh()
        XCTAssertTrue(try fixture.settingsView().generalSettings.showsSetupRepair)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
    }

    func testFirstRunSettingsAndWelcomeShareOrderedDetectionAndExplicitOverride() throws {
        let cases: [(languages: [String], expected: AppLanguage)] = [
            (["en-US", "zh-Hans-SG"], .english),
            (["fr-FR", "zh-Hant-TW", "en-US"], .simplifiedChinese)
        ]
        for testCase in cases {
            let fixture = try DefaultBrowserWindowFixture(systemPreferredLanguages: testCase.languages)
            defer { fixture.cleanup() }
            fixture.welcome.show()
            let settings = try fixture.settingsView()
            let welcome = try fixture.welcomeView()
            XCTAssertTrue(settings.appLanguageStore === welcome.appLanguageStore)
            XCTAssertEqual(settings.appLanguageStore.language, testCase.expected)
            XCTAssertEqual(welcome.appLanguageStore.language, testCase.expected)
            XCTAssertNil(fixture.defaults.string(forKey: AppLanguageStore.preferencesKey))

            let explicit: AppLanguage = testCase.expected == .english ? .simplifiedChinese : .english
            fixture.language.select(explicit)
            XCTAssertEqual(settings.appLanguageStore.language, explicit)
            XCTAssertEqual(welcome.appLanguageStore.language, explicit)
            fixture.language.reset()
            XCTAssertEqual(settings.appLanguageStore.language, testCase.expected)
            XCTAssertEqual(welcome.appLanguageStore.language, testCase.expected)
            XCTAssertNil(fixture.defaults.string(forKey: AppLanguageStore.preferencesKey))
            XCTAssertTrue(fixture.handlers.writes.isEmpty)
            XCTAssertEqual(fixture.login.mutations, 0)
        }
    }

    func testWindowsShareFactsAndOnePollingChainAcrossRebuildCloseAndReopen() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let welcome = fixture.welcome
        let originalRoot = settings.contentViewController
        let originalSession = settings.domainRuleSessionForTesting
        settings.show()
        settings.show()
        welcome.show()
        let firstWelcomeRoot = welcome.contentViewController
        welcome.show()
        XCTAssertFalse(firstWelcomeRoot === welcome.contentViewController)
        XCTAssertTrue(originalRoot === settings.contentViewController)
        XCTAssertTrue(originalSession === settings.domainRuleSessionForTesting)
        XCTAssertEqual(fixture.scheduler.ticks.count, 1)
        let settingsView = try fixture.settingsView()
        let welcomeView = try fixture.welcomeView()
        XCTAssertTrue(settingsView.defaultBrowserController === welcomeView.defaultBrowserController)

        fixture.handlers.responses = [(0, false), (-54, false)]
        settingsView.setAsDefaultBrowser()
        XCTAssertEqual(welcomeView.activationStep.defaultBrowserState.feedback, .notConfirmed)
        XCTAssertEqual(settingsView.generalSettings.defaultBrowserState, welcomeView.activationStep.defaultBrowserState)
        welcome.window?.close()
        fixture.handlers.handlers = ["http": "browser.b", "https": "browser.b"]
        fixture.scheduler.tick()
        XCTAssertEqual(settingsView.generalSettings.defaultBrowserState.observation, .init(http: "browser.b", https: "browser.b"))
        XCTAssertEqual(fixture.scheduler.ticks.count, 1)
        settings.window?.close()
        let readsAfterClose = fixture.handlers.readCount
        fixture.controller.applicationDidBecomeActive()
        XCTAssertEqual(fixture.handlers.readCount, readsAfterClose)
        welcome.show()
        XCTAssertEqual(fixture.handlers.readCount, readsAfterClose + 2) // Immediate refresh.
        fixture.scheduler.tick() // Old Settings tick is invalid after all windows closed.
        XCTAssertEqual(fixture.handlers.readCount, readsAfterClose + 2)
        XCTAssertEqual(fixture.scheduler.ticks.count, 1)
        welcome.window?.close()
        fixture.scheduler.tick()
        XCTAssertTrue(fixture.scheduler.ticks.isEmpty)
        XCTAssertEqual(fixture.handlers.writes.count, 2)
    }

    func testMixedStatusStaysUnconfirmedInBothWindowsUntilPollingObservesDefaultHandlers() throws {
        for requestFromWelcome in [false, true] {
            let fixture = try DefaultBrowserWindowFixture()
            defer { fixture.cleanup() }
            fixture.settings.show()
            fixture.welcome.show()
            let settings = try fixture.settingsView()
            let welcome = try fixture.welcomeView()
            fixture.handlers.responses = [(0, false), (-54, false)]

            // Exercise production action wiring, without navigating Welcome's
            // visible steps or clicking a system confirmation dialog.
            if requestFromWelcome {
                welcome.activationStep.onSetAsDefaultBrowser()
            } else {
                settings.setAsDefaultBrowser()
            }

            // Only unchanged handler observations are simulated here. They do
            // not identify whether a system prompt is open or was cancelled.
            for _ in 0..<3 {
                fixture.scheduler.tick()
                for state in [settings.generalSettings.defaultBrowserState, welcome.activationStep.defaultBrowserState] {
                    XCTAssertEqual(state.observation, .init(http: "browser.a", https: "browser.a"))
                    XCTAssertEqual(state.feedback, .notConfirmed)
                    XCTAssertEqual(
                        state.feedbackText(using: fixture.language),
                        "The change is not confirmed. You can retry or choose Eligo in System Settings."
                    )
                    XCTAssertFalse(state.isDefaultBrowser)
                    XCTAssertTrue(state.canRequest)
                }
                XCTAssertEqual(fixture.scheduler.ticks.count, 1)
                XCTAssertEqual(fixture.handlers.writes, ["http|test.eligo", "https|test.eligo"])
            }

            fixture.handlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
            fixture.scheduler.tick()
            for state in [settings.generalSettings.defaultBrowserState, welcome.activationStep.defaultBrowserState] {
                XCTAssertEqual(state.observation, .init(http: "test.eligo", https: "test.eligo"))
                XCTAssertTrue(state.isDefaultBrowser)
                XCTAssertNil(state.feedback)
                XCTAssertFalse(state.canRequest)
            }
            XCTAssertEqual(fixture.scheduler.ticks.count, 1)
            XCTAssertEqual(fixture.handlers.writes, ["http|test.eligo", "https|test.eligo"])
        }
    }

    func testEveryWelcomeExitReleasesWindowDemandBeforeNavigation() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        for exit in 0..<4 {
            fixture.welcome.show()
            let view = try fixture.welcomeView()
            switch exit {
            case 0: fixture.welcome.window?.performClose(nil)
            case 1: view.onClose() // Skip and Start Using Eligo share this closure.
            case 2: view.onOpenSettings()
            default: view.onAddFirstRule()
            }
            let reads = fixture.handlers.readCount
            fixture.scheduler.tick()
            fixture.controller.applicationDidBecomeActive()
            XCTAssertEqual(fixture.handlers.readCount, reads)
            XCTAssertTrue(fixture.scheduler.ticks.isEmpty)
        }
        XCTAssertEqual(fixture.navigation, ["settings", "rules"])
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
    }

    func testLossOfKeyAndMinimizingDoNotStopObservationAndForegroundRefreshesImmediately() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        fixture.settings.show()
        fixture.settings.window?.miniaturize(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.settings.window)
        fixture.handlers.handlers = ["http": "browser.b", "https": "browser.a"]
        fixture.scheduler.tick()
        XCTAssertEqual(fixture.controller.state.observation, .init(http: "browser.b", https: "browser.a"))
        fixture.handlers.handlers = ["http": "browser.a", "https": "browser.b"]
        fixture.controller.applicationDidBecomeActive()
        XCTAssertEqual(fixture.controller.state.observation, .init(http: "browser.a", https: "browser.b"))
        XCTAssertEqual(fixture.scheduler.ticks.count, 1)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
    }

    func testLaunchAtLoginToggleDoesNotWriteSystemDefaults() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let observation = fixture.controller.state.observation
        let binding = try fixture.settingsView().generalSettings.launchAtLoginStep.enabledBinding

        for enabled in [false, true] {
            binding.wrappedValue = enabled

            XCTAssertEqual(binding.wrappedValue, enabled)
            XCTAssertEqual(fixture.controller.state.observation, observation)
            XCTAssertTrue(fixture.handlers.writes.isEmpty)
        }
        XCTAssertEqual(fixture.login.mutations, 2)
    }

    func testRuleCreationAndEditingPersistWithoutWritingSystemDefaults() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let settings = try fixture.settingsView()
        let session = settings.domainRuleSession
        let observation = fixture.controller.state.observation
        var createdRuleID: DomainRule.ID?

        for host in ["example.com", "edited.example.com"] {
            let action: RulesSettingsAction = createdRuleID.map { .editRule(ruleID: $0) } ?? .addRule
            DomainRuleSettingsAdapter.send(action, to: session)
            var relay = DomainRuleSettingsPresentationRelay()
            _ = relay.synchronize(
                with: session.state.presentation,
                rules: settings.routingPreferencesStore.settings.rules,
                destinations: settings.availableDestinations
            )
            guard case let .single(item) = relay.item else {
                XCTFail("Expected the production rule editor presentation")
                return
            }
            var draft = item.draft
            draft.host = host
            draft.includesSubdomains = createdRuleID != nil
            try DomainRuleSettingsAdapter.commitSingle(
                item: item, draft: draft, session: session
            )

            let persisted = RoutingPreferencesStore(userDefaults: fixture.defaults).settings
            XCTAssertEqual(persisted.rules.count, 1)
            let rule = try XCTUnwrap(persisted.rules.first)
            XCTAssertEqual(rule.matcher.normalizedHost, host)
            XCTAssertEqual(rule.matcher.includesSubdomains, createdRuleID != nil)
            if let createdRuleID { XCTAssertEqual(rule.id, createdRuleID) }
            createdRuleID = rule.id
            XCTAssertEqual(fixture.controller.state.observation, observation)
            XCTAssertTrue(fixture.handlers.writes.isEmpty)
            DomainRuleSettingsAdapter.endPresentation(item.id, in: session, onEffect: { _ in })
        }
    }

    func testScopeEditsPersistWithoutWritingSystemDefaults() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let settings = try fixture.settingsView()
        let observation = fixture.controller.state.observation
        let destinationID = try XCTUnwrap(settings.availableDestinations.first?.id)
        let matchers = [try DomainMatcher(host: "example.com", includesSubdomains: true)]
        let scopes: [RoutingScope] = [
            .onlyThese(matchers: matchers, bypassDestinationID: destinationID),
            .allExceptThese(matchers: matchers, bypassDestinationID: destinationID),
            .allDomains
        ]

        for scope in scopes {
            settings.presentScopeEditor()
            let item = try XCTUnwrap(settings.scopePresentation.item)
            switch scope {
            case .allDomains: item.session.setMode(.allDomains)
            case .onlyThese: item.session.setMode(.onlyThese)
            case .allExceptThese: item.session.setMode(.allExceptThese)
            }
            if item.session.validation.drafts.isEmpty, item.session.mode != .allDomains {
                let row = try XCTUnwrap(item.session.addDomain())
                item.session.editHost(rowID: row, text: "example.com")
            }
            item.session.selectBypassDestination(destinationID)
            XCTAssertTrue(item.session.save())
            settings.scopePresentation.requestClose(id: item.id)
            settings.scopePresentation.didDismiss(id: item.id)

            XCTAssertEqual(settings.routingPreferencesStore.settings.scope, scope)
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.defaults).settings.scope, scope)
            XCTAssertEqual(fixture.controller.state.observation, observation)
            XCTAssertTrue(fixture.handlers.writes.isEmpty)
        }
    }

    func testAppDelegateForegroundCallbackRefreshesWithoutWritingSystemDefaults() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let settings = try fixture.settingsView()
        let delegate = AppDelegate(
            browserRepository: fixture.repository,
            routingPreferencesStore: settings.routingPreferencesStore,
            setupGuideStore: SetupGuideStore(userDefaults: fixture.defaults),
            appLanguageStore: fixture.language,
            launchAtLoginController: settings.launchAtLoginController,
            defaultBrowserController: fixture.controller
        )
        let notification = Notification(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        fixture.settings.show()
        fixture.handlers.handlers = ["http": "browser.b", "https": "browser.a"]
        let reads = fixture.handlers.readCount

        delegate.applicationDidBecomeActive(notification)

        XCTAssertEqual(fixture.handlers.readCount, reads + 2)
        XCTAssertEqual(fixture.controller.state.observation, .init(http: "browser.b", https: "browser.a"))
        XCTAssertTrue(fixture.handlers.writes.isEmpty)

        fixture.settings.window?.close()
        fixture.handlers.handlers = ["http": "browser.c", "https": "browser.c"]
        let readsAfterClose = fixture.handlers.readCount
        delegate.applicationDidBecomeActive(notification)
        XCTAssertEqual(fixture.handlers.readCount, readsAfterClose)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
    }

    func testBothPresentationsRenderExistingFeedbackInCurrentLanguageWithoutRepeatingRequest() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        fixture.welcome.show()
        let settingsView = try fixture.settingsView()
        let welcomeView = try fixture.welcomeView()
        let cases: [(responses: [(OSStatus, Bool)], english: String, chinese: String)] = [
            ([(0, false), (-54, false)], "The change is not confirmed.", "更改尚未确认。"),
            ([(-50, false), (-50, false)], "Your default browser settings are unchanged.", "默认浏览器设置未改变。"),
            ([(0, true), (-50, false), (0, true)], "Your previous default browser settings were restored.", "此前的默认浏览器设置已恢复。"),
            ([(0, true), (-50, false), (-50, false)], "could not be fully restored.", "未能完整恢复此前的默认设置。")
        ]
        for testCase in cases {
            fixture.handlers.handlers = ["http": "browser.a", "https": "browser.a"]
            fixture.handlers.responses = testCase.responses
            fixture.language.select(.english)
            welcomeView.activationStep.onSetAsDefaultBrowser()
            let writes = fixture.handlers.writes.count
            let state = fixture.controller.state
            for language in [AppLanguage.english, .simplifiedChinese, .english] {
                fixture.language.select(language)
                let settingsState = settingsView.generalSettings.defaultBrowserState
                let welcomeState = welcomeView.activationStep.defaultBrowserState
                let message = try XCTUnwrap(settingsState.feedbackText(using: fixture.language))
                XCTAssertEqual(message, welcomeState.feedbackText(using: fixture.language))
                XCTAssertTrue(message.contains(language == .english ? testCase.english : testCase.chinese))
                XCTAssertEqual(welcomeState.actionTitle(using: fixture.language), language == .english ? "Retry" : "重试")
                XCTAssertTrue(settingsState.canRequest)
                XCTAssertEqual(fixture.controller.state, state)
            }
            XCTAssertEqual(fixture.handlers.writes.count, writes)
            XCTAssertEqual(fixture.controller.state.statusText(using: fixture.language).contains("browser.a"), true)
        }
    }

    func testNeutralFeedbackReachesBothPresentationsAndChangesLanguageWithoutNewWrites() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        let handlers = fixture.handlers
        handlers.handlers = [:]
        handlers.responses = [(0, true), (-50, false)]
        handlers.onRead = { [unowned handlers] scheme in
            if scheme == "https", handlers.handlers["http"] == "test.eligo" {
                handlers.handlers = [:]
            }
        }
        fixture.settings.show()
        fixture.welcome.show()
        let settings = try fixture.settingsView()
        let welcome = try fixture.welcomeView()
        welcome.activationStep.onSetAsDefaultBrowser()
        let result = fixture.controller.state

        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            let message = language == .english
                ? "Automatic setup did not complete. You can retry or choose Eligo in System Settings."
                : "自动设置未完成。你可以重试，或在系统设置中选择 Eligo。"
            let status = language == .english
                ? "Current defaults: HTTP Unknown; HTTPS Unknown"
                : "当前默认浏览器：HTTP 未知；HTTPS 未知"
            for state in [settings.generalSettings.defaultBrowserState, welcome.activationStep.defaultBrowserState] {
                XCTAssertEqual(state.feedbackText(using: fixture.language), message)
                XCTAssertEqual(state.statusText(using: fixture.language), status)
                XCTAssertEqual(state.actionTitle(using: fixture.language), language == .english ? "Retry" : "重试")
                XCTAssertTrue(state.canRequest)
                XCTAssertEqual(state, result)
            }
        }
        fixture.controller.refresh()
        XCTAssertEqual(fixture.controller.state, result)
        XCTAssertEqual(handlers.writes, ["http|test.eligo", "https|test.eligo"])
    }

    func testRealCorruptBrowserConfigurationDoesNotUndoDefaultFactOrClaimActivationComplete() throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        fixture.handlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
        fixture.controller.refresh()
        let corruptBytes = Data("broken browser configuration".utf8)
        fixture.defaults.set(corruptBytes, forKey: BrowserPreferences.storageKey)
        // Execute the real repository mutation/read boundary, not a fake availability flag.
        _ = fixture.repository.setEnabled(true, for: "browser.a")
        XCTAssertEqual(fixture.repository.availability, .configurationUnreadable)
        fixture.welcome.show()
        let welcome = try fixture.welcomeView()
        XCTAssertFalse(welcome.activationComplete)
        XCTAssertTrue(welcome.activationStep.defaultBrowserState.isDefaultBrowser)
        XCTAssertTrue(welcome.activationStep.browserConfigurationUnreadable)
        XCTAssertFalse(welcome.activationStep.hasUsableBrowsers)
        XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), corruptBytes)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)

        try fixture.settingsView().confirmPendingDestructiveAction(.reset)
        XCTAssertTrue(fixture.controller.state.isDefaultBrowser)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
    }

    func testSettingsRescanResetAndOrdinaryAddFailureDoNotWriteSystemDefaults() async throws {
        let fixture = try DefaultBrowserWindowFixture()
        defer { fixture.cleanup() }
        fixture.handlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
        fixture.controller.refresh()
        fixture.welcome.show()
        let welcome = try fixture.welcomeView()
        let settings = try fixture.settingsView()
        let browsers = fixture.repository.enabledBrowsers
        _ = fixture.repository.addCustomBrowser(appURL: URL(fileURLWithPath: "/nonexistent/EligoTest.app"))
        XCTAssertEqual(fixture.repository.enabledBrowsers, browsers)
        XCTAssertTrue(welcome.activationComplete)
        settings.rescanBrowsers()
        _ = await fixture.repository.rescan().value
        settings.confirmPendingDestructiveAction(.reset)
        XCTAssertTrue(fixture.controller.state.isDefaultBrowser)
        XCTAssertTrue(fixture.handlers.writes.isEmpty)
        XCTAssertEqual(fixture.login.mutations, 0)
    }
}

@MainActor
private final class DefaultBrowserWindowFixture {
    let defaults: UserDefaults
    let clearDefaults: () -> Void
    let handlers = ControlledDefaultBrowserHandlers()
    let scheduler = DefaultBrowserTestScheduler()
    let controller: DefaultBrowserController
    let repository: BrowserRepository
    let scopeDestination: ScopeDestinationFixture
    let language: AppLanguageStore
    let login = DefaultBrowserTestLoginService()
    let settings: SettingsWindowController
    var navigation: [String] = []
    lazy var welcome = WelcomeWindowController(
        appLanguageStore: language, browserRepository: repository, defaultBrowserController: controller,
        onOpenSettings: { [weak self] in self?.navigation.append("settings") },
        onAddFirstRule: { [weak self] in self?.navigation.append("rules") }
    )

    init(systemPreferredLanguages: [String] = ["en-US"]) throws {
        _ = NSApplication.shared
        (defaults, clearDefaults) = makeIsolatedUserDefaults()
        scopeDestination = try ScopeDestinationFixture(userDefaults: defaults, browserID: "browser.a")
        repository = scopeDestination.repository
        language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: systemPreferredLanguages)
        controller = DefaultBrowserController(manager: handlers, bundleIdentifier: "test.eligo", schedule: scheduler.schedule)
        settings = SettingsWindowController(
            browserRepository: repository, routingPreferencesStore: RoutingPreferencesStore(userDefaults: defaults),
            appLanguageStore: language, launchAtLoginController: LaunchAtLoginController(service: login),
            defaultBrowserController: controller, applicationPresentationController: ApplicationPresentationController()
        )
    }

    func settingsView() throws -> SettingsView {
        try XCTUnwrap(settings.contentViewController as? NSHostingController<SettingsView>).rootView
    }

    func welcomeView() throws -> WelcomeGuideView {
        try XCTUnwrap(welcome.contentViewController as? NSHostingController<WelcomeGuideView>).rootView
    }

    func cleanup() {
        settings.window?.close()
        welcome.window?.close()
        clearDefaults()
        scopeDestination.cleanup()
    }
}

private final class DefaultBrowserTestLoginService: LaunchItemService {
    var status: SMAppService.Status = .enabled
    var mutations = 0
    func register() throws {
        mutations += 1
        status = .enabled
    }
    func unregister() throws {
        mutations += 1
        status = .notRegistered
    }
}
