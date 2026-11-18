import Foundation
import XCTest
@testable import Eligo

@MainActor
final class UnavailableLinkRoutingTests: XCTestCase {
    func testRuleAndScopeUseReplacementWhileUnavailableCustomRecordIsRetained() async throws {
        for useScopeBypass in [false, true] {
            let fixture = try DiscoveryRoutingFixture()
            defer { fixture.cleanup() }
            try fixture.preferences.saveCustomBrowser(fixture.old)
            try fixture.preferences.saveScannedBrowsers([fixture.replacement], at: Date())
            try fixture.removeOldExecutable()
            let mode: OpeningMode = useScopeBypass ? .normal : .privateBrowsing
            let destinationID = OpenDestinationID(browserID: fixture.old.id, mode: mode)
            if useScopeBypass {
                try fixture.store.replace(with: RoutingSettings(
                    scope: .onlyThese(matchers: [try DomainMatcher(host: "inside.example", includesSubdomains: false)], bypassDestinationID: destinationID),
                    rules: [], alwaysShowChooser: false
                ))
            } else {
                try fixture.saveRule(mode: mode)
            }
            await fixture.coordinator.route(fixture.link) { fixture.completed += 1 }.value
            XCTAssertEqual(fixture.repository.unavailableCustomBrowsers.map(\.appURL), [fixture.old.appURL])
            XCTAssertEqual(fixture.launcher.opened.map(\.browser.appURL), [fixture.replacement.appURL])
            XCTAssertEqual(fixture.launcher.opened.map(\.id), [destinationID])
            XCTAssertTrue(fixture.clock.scheduled.isEmpty)
            XCTAssertEqual(fixture.completed, 1)
        }
    }

    func testTurningOffAlwaysShowChooserDuringDiscoveryRestoresOriginalPrivateTarget() async throws {
        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        try fixture.saveRule(mode: .privateBrowsing, alwaysShowChooser: true)
        try fixture.removeOldExecutable()
        let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        try fixture.saveRule(browserID: fixture.other.id, alwaysShowChooser: false)
        fixture.scanner.finish(0)
        await task.value
        XCTAssertEqual(fixture.chooser.presentations, 0)
        XCTAssertEqual(fixture.launcher.opened.map(\.id), [OpenDestinationID(browserID: fixture.old.id, mode: .privateBrowsing)])
        XCTAssertEqual(fixture.launcher.opened.first?.browser.appURL, fixture.replacement.appURL)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testChooseAnotherBrowserWaitsWhenLastAlternativeDisappears() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let (url, remove) = try makeApplicationBundle(name: "Alternative", bundleIdentifier: "test.alternative", urlSchemes: ["https"])
        let (replacementURL, removeReplacement) = try makeApplicationBundle(name: "Replacement", bundleIdentifier: "test.alternative", urlSchemes: ["https"])
        defer { remove(); removeReplacement() }
        let alternative = Browser(name: "Alternative", bundleIdentifier: "test.alternative", appURL: url, priority: 1)
        let replacement = Browser(name: "Replacement", bundleIdentifier: alternative.id, appURL: replacementURL, priority: 1)
        try preferences.saveScannedBrowsers([alternative], at: Date())
        let scanner = ControlledBrowserScanner(results: [[replacement]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let store = makeIsolatedRoutingPreferencesStore()
        try store.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false), destinationID: OpenDestinationID(browserID: "test.missing", mode: .normal))],
            alwaysShowChooser: false
        ))
        let chooser = DiscoveryChooser()
        let launcher = DiscoveryLauncher()
        let clock = ActivationTestClock()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: store, appLanguageStore: makeEnglishAppLanguageStore(),
            now: { clock.now }, schedule: clock.schedule, onOpenSettings: {}
        )
        var completed = 0
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
        XCTAssertEqual(chooser.primary?.title, "Choose Another Browser")
        clock.advance(to: 10)
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/MacOS/TestExecutable"))
        chooser.primary?.perform()
        await waitForBrowserCondition { scanner.scanCount == 1 }
        await waitForBrowserCondition { !clock.scheduled.isEmpty || chooser.primary?.title == "Rescan" }
        XCTAssertEqual(clock.scheduled.map(\.deadline), [12])
        XCTAssertEqual(chooser.primary?.title, "Choose Another Browser", "Do not replace recovery while its automatic scan is pending")
        scanner.finish(0)
        await waitForBrowserCondition { chooser.presentations == 1 || repository.discoveryTask == nil }
        await waitForBrowserCondition { chooser.presentations == 1 }
        XCTAssertEqual(chooser.destinations.map(\.browser.appURL), [replacementURL])
        chooser.selection?(OpenDestination(browser: replacement, mode: .normal))
        XCTAssertEqual(launcher.opened.map(\.browser.appURL), [replacementURL])
        XCTAssertEqual(completed, 1)
    }

    func testTryAgainAfterCoordinatorReleaseFinishesOnceAndAdvancesURLRouter() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let browser = makeBrowser(name: "Retry", bundleIdentifier: "test.retry")
        try preferences.saveScannedBrowsers([browser], at: Date())
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: [browser]), preferences: preferences)
        let chooser = DiscoveryChooser()
        let launcher = DiscoveryLauncher()
        launcher.results = [false]
        var coordinator: LinkRoutingCoordinator? = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(), appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )
        weak var owner = coordinator
        let router = URLRouter()
        var completed = 0
        var nextLinks = 0
        router.setHandler { [weak coordinator] link, finish in
            guard let coordinator else { nextLinks += 1; finish(); return }
            coordinator.route(link) { completed += 1; finish() }
        }
        router.route(IncomingLink(url: URL(string: "https://example.com/first")!))
        router.route(IncomingLink(url: URL(string: "https://example.com/second")!))
        await waitForBrowserCondition { chooser.selection != nil }
        chooser.selection?(OpenDestination(browser: browser, mode: .normal))
        XCTAssertEqual(chooser.primary?.title, "Try Again")
        coordinator = nil
        await waitForBrowserCondition { owner == nil }
        let retry = try XCTUnwrap(chooser.primary)
        retry.perform()
        retry.perform()
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(nextLinks, 1)
        XCTAssertEqual(launcher.opened.count, 1)
    }

    func testChooserSelectionAfterAnEarlierWaitGetsANewTwoSecondBudget() async throws {
        for mode in [OpeningMode.normal, .privateBrowsing] {
            let (preferences, cleanup) = makeIsolatedPreferences()
            defer { cleanup() }
            let (firstURL, removeFirst) = try makeApplicationBundle(name: "First", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
            let (secondURL, removeSecond) = try makeApplicationBundle(name: "Second", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
            let (thirdURL, removeThird) = try makeApplicationBundle(name: "Third", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
            defer { removeFirst(); removeSecond(); removeThird() }
            let first = Browser(name: "First", bundleIdentifier: "com.google.Chrome", appURL: firstURL, priority: 1)
            let second = Browser(name: "Second", bundleIdentifier: first.id, appURL: secondURL, priority: 1)
            let third = Browser(name: "Third", bundleIdentifier: first.id, appURL: thirdURL, priority: 1)
            try preferences.saveScannedBrowsers([first], at: Date())
            let scanner = ControlledBrowserScanner(results: [[second], [third]])
            defer { scanner.finishAll() }
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            let chooser = DiscoveryChooser()
            let launcher = DiscoveryLauncher()
            let clock = ActivationTestClock()
            let coordinator = LinkRoutingCoordinator(
                browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
                routingPreferencesStore: makeIsolatedRoutingPreferencesStore(), appLanguageStore: makeEnglishAppLanguageStore(),
                now: { clock.now }, schedule: clock.schedule, onOpenSettings: {}
            )
            try FileManager.default.removeItem(at: firstURL.appendingPathComponent("Contents/MacOS/TestExecutable"))
            var completed = 0
            let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }
            await waitForBrowserCondition { scanner.scanCount == 1 }
            scanner.finish(0)
            await task.value
            XCTAssertEqual(chooser.presentations, 1)
            clock.advance(to: 10)
            try FileManager.default.removeItem(at: secondURL.appendingPathComponent("Contents/MacOS/TestExecutable"))
            chooser.selection?(OpenDestination(browser: second, mode: mode))
            await waitForBrowserCondition { scanner.scanCount == 2 && !clock.scheduled.isEmpty }
            XCTAssertEqual(clock.scheduled.map(\.deadline), [12])
            XCTAssertTrue(launcher.opened.isEmpty)
            clock.advance(to: 11.9)
            scanner.finish(1)
            await waitForBrowserCondition { completed == 1 || chooser.message != nil }
            XCTAssertEqual(launcher.opened.map(\.browser.appURL), [thirdURL])
            XCTAssertEqual(launcher.opened.map(\.mode), [mode])
            XCTAssertEqual(completed, 1)
        }
    }

    func testScanCompletionAfterDeadlineCannotWinAgainstDelayedTimeoutCallback() async throws {
        for instant in [2.0, 2.1] {
            let fixture = try DiscoveryRoutingFixture()
            defer { fixture.cleanup() }
            try fixture.saveRule(mode: .privateBrowsing)
            try fixture.removeOldExecutable()
            let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
            await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
            // Simulate a blocked main queue: time has elapsed, but its timer has not run.
            fixture.clock.now = instant
            fixture.scanner.finish(0)
            await task.value
            XCTAssertTrue(fixture.launcher.opened.isEmpty)
            XCTAssertEqual(fixture.chooser.primary?.title, "Choose Another Browser")
            fixture.chooser.cancel?()
            fixture.clock.advance(to: 3)
            XCTAssertEqual(fixture.completed, 1)
            XCTAssertTrue(fixture.launcher.opened.isEmpty)
        }
    }

    func testRepeatedManualRescanAfterTimeoutRetainsOriginalPrivatePlan() async throws {
        let fixture = try DiscoveryRoutingFixture(discoveries: [false, true])
        defer { fixture.cleanup() }
        try fixture.saveRule(mode: .privateBrowsing)
        try fixture.removeOldExecutable()
        let first = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { fixture.scanner.scanCount == 1 }
        fixture.scanner.finish(0)
        await first.value
        XCTAssertEqual(fixture.chooser.primary?.title, "Rescan")
        fixture.chooser.primary?.perform()
        await waitForBrowserCondition { fixture.scanner.scanCount == 2 }
        await waitForBrowserCondition { fixture.clock.scheduled.contains { !fixture.clock.cancelled.contains($0.id) } }
        fixture.clock.advance(to: 2)
        await waitForBrowserCondition { fixture.chooser.message?.contains("timed out") == true }
        XCTAssertEqual(fixture.chooser.primary?.title, "Rescan")
        fixture.chooser.primary?.perform()
        await waitForBrowserCondition { fixture.clock.scheduled.contains { !fixture.clock.cancelled.contains($0.id) } }
        fixture.scanner.finish(1)
        await waitForBrowserCondition { !fixture.launcher.opened.isEmpty || fixture.chooser.presentations > 0 }
        XCTAssertEqual(fixture.launcher.opened.map(\.id), [OpenDestinationID(browserID: fixture.old.id, mode: .privateBrowsing)])
        XCTAssertEqual(fixture.launcher.opened.first?.browser.appURL, fixture.replacement.appURL)
        XCTAssertEqual(fixture.chooser.presentations, 0)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testWaitingKeepsOriginalRuleTargetButHonorsCurrentAlwaysShowChooser() async throws {
        for alwaysShow in [false, true] {
            let fixture = try DiscoveryRoutingFixture(healthyOther: true)
            defer { fixture.cleanup() }
            try fixture.saveRule(mode: .privateBrowsing)
            try fixture.removeOldExecutable()
            let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
            await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
            try fixture.saveRule(browserID: fixture.other.id, alwaysShowChooser: alwaysShow)
            fixture.scanner.finish(0)
            await task.value
            if alwaysShow {
                XCTAssertTrue(fixture.launcher.opened.isEmpty)
                XCTAssertEqual(fixture.chooser.presentations, 1)
                fixture.chooser.selection?(nil)
            } else {
                XCTAssertEqual(fixture.launcher.opened.map(\.id), [OpenDestinationID(browserID: fixture.old.id, mode: .privateBrowsing)])
            }
            XCTAssertEqual(fixture.completed, 1)
        }
    }

    func testChooserSelectionRevalidatesInstallationAndPreservesSelectedMode() async throws {
        for mode in [OpeningMode.normal, .privateBrowsing] {
            let fixture = try DiscoveryRoutingFixture()
            defer { fixture.cleanup() }
            await fixture.coordinator.route(fixture.link) { fixture.completed += 1 }.value
            let select = try XCTUnwrap(fixture.chooser.selection)
            try fixture.removeOldExecutable()

            select(OpenDestination(browser: fixture.old, mode: mode))
            await waitForBrowserCondition { fixture.scanner.scanCount == 1 || !fixture.launcher.opened.isEmpty }
            XCTAssertTrue(fixture.launcher.opened.isEmpty, "Never submit the captured dead path")
            fixture.scanner.finish(0)
            await waitForBrowserCondition { fixture.launcher.opened.count == 1 }

            XCTAssertEqual(fixture.launcher.opened.first?.browser.appURL, fixture.replacement.appURL)
            XCTAssertEqual(fixture.launcher.opened.first?.mode, mode)
            XCTAssertEqual(fixture.completed, 1)
            select(nil)
            XCTAssertEqual(fixture.completed, 1, "Old chooser callbacks cannot finish twice")
        }
    }

    func testRuleAndBypassWaitForTheOriginalDestinationOnly() async throws {
        for mode in [OpeningMode.normal, .privateBrowsing] {
            let fixture = try DiscoveryRoutingFixture(healthyOther: true)
            defer { fixture.cleanup() }
            try fixture.saveRule(mode: mode)
            try fixture.removeOldExecutable()
            let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
            await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
            XCTAssertTrue(fixture.launcher.opened.isEmpty)
            XCTAssertEqual(fixture.chooser.presentations, 0)
            fixture.clock.advance(to: 1.9)
            fixture.scanner.finish(0)
            await task.value
            XCTAssertEqual(fixture.launcher.opened.map(\.id), [OpenDestinationID(browserID: fixture.old.id, mode: mode)])
            XCTAssertEqual(fixture.launcher.opened.first?.browser.appURL, fixture.replacement.appURL)
            XCTAssertNil(try fixture.preferences.recentBrowserIdentifier())
            XCTAssertEqual(fixture.completed, 1)
        }

        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        try fixture.store.replace(with: RoutingSettings(
            scope: .onlyThese(matchers: [try DomainMatcher(host: "inside.example", includesSubdomains: false)], bypassDestinationID: OpenDestinationID(browserID: fixture.old.id, mode: .normal)),
            rules: [], alwaysShowChooser: false
        ))
        try fixture.removeOldExecutable()
        let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        fixture.scanner.finish(0)
        await task.value
        XCTAssertEqual(fixture.launcher.opened.first?.browser, fixture.replacement)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testHealthyTargetAndAlwaysShowChooserDoNotWaitForUnrelatedMissingPath() async throws {
        for choose in [true, false] {
            let fixture = try DiscoveryRoutingFixture(healthyOther: true)
            defer { fixture.cleanup() }
            if choose { try fixture.saveRule(mode: .privateBrowsing, alwaysShowChooser: true) }
            else { try fixture.saveRule(browserID: fixture.other.id) }
            try fixture.removeOldExecutable()
            await fixture.coordinator.route(fixture.link) { fixture.completed += 1 }.value
            XCTAssertTrue(fixture.repository.isScanning)
            XCTAssertTrue(fixture.clock.scheduled.isEmpty)
            if choose {
                XCTAssertEqual(fixture.chooser.destinations.map(\.browser.id), [fixture.other.id])
                XCTAssertTrue(fixture.launcher.opened.isEmpty)
                fixture.chooser.selection?(nil)
            } else {
                XCTAssertEqual(fixture.launcher.opened.map(\.browser.id), [fixture.other.id])
            }
            XCTAssertEqual(fixture.completed, 1)
        }
    }

    func testTimeoutBudgetDoesNotRestartAndLateDiscoveryCannotOpenOrFinishAgain() async throws {
        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        try fixture.saveRule(mode: .privateBrowsing)
        try fixture.removeOldExecutable()
        let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        let staleTimeout = try XCTUnwrap(fixture.clock.scheduled.first).action
        fixture.clock.advance(to: 1)
        for _ in 0..<5 { fixture.repository.refreshInstallations() }
        XCTAssertEqual(fixture.clock.scheduled.map(\.deadline), [2])
        fixture.clock.advance(to: 1.999)
        XCTAssertNil(fixture.chooser.message)
        fixture.clock.advance(to: 2)
        await task.value
        XCTAssertEqual(fixture.chooser.primary?.title, "Choose Another Browser")
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        let cancel = try XCTUnwrap(fixture.chooser.cancel)
        cancel(); cancel()
        XCTAssertEqual(fixture.completed, 1)
        let scan = try XCTUnwrap(fixture.repository.discoveryTask)
        fixture.scanner.finish(0)
        _ = await scan.value
        staleTimeout()
        XCTAssertEqual(fixture.repository.enabledBrowsers, [fixture.replacement])
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testCancelWaitingRequestCompletesBeforePhysicalScanAndNeverPresentsLateUI() async throws {
        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        try fixture.removeOldExecutable()
        let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        let scan = try XCTUnwrap(fixture.repository.discoveryTask)
        task.cancel()
        await task.value
        XCTAssertEqual(fixture.completed, 1)
        XCTAssertTrue(fixture.repository.isScanning)
        fixture.scanner.finish(0)
        _ = await scan.value
        fixture.clock.advance(to: 3)
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        XCTAssertNil(fixture.chooser.message)
        XCTAssertEqual(fixture.chooser.presentations, 0)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testScanFailureAndInvalidationUseRecoveryWithoutPublishingOrOpening() async throws {
        for failure in 0..<3 {
            let fixture = try DiscoveryRoutingFixture()
            defer { fixture.cleanup() }
            try fixture.saveRule(mode: .privateBrowsing)
            try fixture.removeOldExecutable()
            let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
            await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
            let bytes = fixture.defaults.data(forKey: BrowserPreferences.storageKey)
            switch failure {
            case 0: fixture.encoder.fail = true; fixture.scanner.finish(0)
            case 1: XCTAssertEqual(fixture.repository.resetPreferences(), .applied)
            default:
                fixture.defaults.set("unreadable", forKey: BrowserPreferences.storageKey)
                fixture.repository.refreshInstallations()
            }
            await task.value
            XCTAssertEqual(fixture.chooser.primary?.title, "Open Settings")
            XCTAssertTrue(fixture.launcher.opened.isEmpty)
            if failure == 0 { XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), bytes) }
            let cancel = try XCTUnwrap(fixture.chooser.cancel)
            cancel(); cancel()
            fixture.scanner.finish(0)
            await waitForBrowserCondition { !fixture.repository.isScanning }
            XCTAssertTrue(fixture.launcher.opened.isEmpty)
            XCTAssertEqual(fixture.completed, 1)
        }
    }

    func testTryAgainResolvesLatestPathAndIgnoresOldRecoveryAndLaunchCompletions() async throws {
        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        fixture.launcher.results = [false, true]
        await fixture.coordinator.route(fixture.link) { fixture.completed += 1 }.value
        fixture.chooser.selection?(OpenDestination(browser: fixture.old, mode: .privateBrowsing))
        XCTAssertEqual(fixture.chooser.primary?.title, "Try Again")
        let staleCancel = try XCTUnwrap(fixture.chooser.cancel)
        let retry = try XCTUnwrap(fixture.chooser.primary)
        try fixture.removeOldExecutable()
        retry.perform(); retry.perform()
        await waitForBrowserCondition { fixture.scanner.scanCount == 1 }
        XCTAssertEqual(fixture.launcher.opened.count, 1)
        fixture.scanner.finish(0)
        await waitForBrowserCondition { fixture.completed == 1 }
        XCTAssertEqual(fixture.launcher.opened.map(\.browser.appURL), [fixture.old.appURL, fixture.replacement.appURL])
        XCTAssertEqual(fixture.launcher.opened.map(\.mode), [.privateBrowsing, .privateBrowsing])
        fixture.launcher.completions.forEach { $0(true); $0(false) }
        staleCancel()
        XCTAssertEqual(fixture.completed, 1)
        XCTAssertEqual(fixture.launcher.opened.count, 2)
    }

    func testAbsentPrivateTargetDoesNotFallBackAndExplicitChooserUsesLatestCatalog() async throws {
        let fixture = try DiscoveryRoutingFixture(foundReplacement: false, healthyOther: true)
        defer { fixture.cleanup() }
        try fixture.saveRule(mode: .privateBrowsing)
        try fixture.removeOldExecutable()
        let task = fixture.coordinator.route(fixture.link) { fixture.completed += 1 }
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        fixture.scanner.finish(0)
        await task.value
        XCTAssertEqual(fixture.chooser.primary?.title, "Choose Another Browser")
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        fixture.chooser.primary?.perform()
        XCTAssertEqual(fixture.chooser.destinations.map(\.browser.id), [fixture.other.id])
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        fixture.chooser.selection?(nil)
        XCTAssertEqual(fixture.completed, 1)
    }

    func testUnreadablePreferencesAtChooserSelectionRejectBeforeDelivery() async throws {
        let fixture = try DiscoveryRoutingFixture()
        defer { fixture.cleanup() }
        await fixture.coordinator.route(fixture.link) { fixture.completed += 1 }.value
        fixture.defaults.set("unreadable", forKey: BrowserPreferences.storageKey)
        fixture.chooser.selection?(OpenDestination(browser: fixture.old, mode: .normal))
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        XCTAssertEqual(fixture.chooser.primary?.title, "Open Settings")
        fixture.chooser.cancel?()
        XCTAssertEqual(fixture.completed, 1)
        XCTAssertEqual(fixture.defaults.string(forKey: BrowserPreferences.storageKey), "unreadable")
    }

    func testTimedOutRequestKeepsSerialQueueUntilCancelAndLateScanCannotConsumeNextLink() async throws {
        let fixture = try DiscoveryRoutingFixture(healthyOther: true)
        defer { fixture.cleanup() }
        try fixture.saveRule(mode: .privateBrowsing)
        try fixture.removeOldExecutable()
        let router = URLRouter()
        var tasks: [Task<Void, Never>] = []
        router.setHandler { link, completion in
            tasks.append(fixture.coordinator.route(link) { fixture.completed += 1; completion() })
        }
        router.route(fixture.link)
        router.route(IncomingLink(url: URL(string: "https://other.example/second")!))
        await waitForBrowserCondition { !fixture.clock.scheduled.isEmpty }
        XCTAssertEqual(tasks.count, 1)
        fixture.clock.advance(to: 2)
        await tasks[0].value
        XCTAssertEqual(tasks.count, 1)
        let staleCancel = try XCTUnwrap(fixture.chooser.cancel)
        staleCancel()
        await waitForBrowserCondition { tasks.count == 2 }
        await tasks[1].value
        XCTAssertEqual(fixture.chooser.presentations, 1)
        XCTAssertEqual(fixture.completed, 1)
        let scan = try XCTUnwrap(fixture.repository.discoveryTask)
        fixture.scanner.finish(0)
        _ = await scan.value
        staleCancel()
        XCTAssertEqual(fixture.completed, 1)
        XCTAssertTrue(fixture.launcher.opened.isEmpty)
        fixture.chooser.selection?(nil)
        XCTAssertEqual(fixture.completed, 2)
    }
}

@MainActor
private final class DiscoveryRoutingFixture {
    let defaults: UserDefaults
    let preferences: BrowserPreferences
    let repository: BrowserRepository
    let store: RoutingPreferencesStore
    let old: Browser
    let replacement: Browser
    let other = makeBrowser(name: "Other", bundleIdentifier: "test.other")
    let scanner: ControlledBrowserScanner
    let clock = ActivationTestClock()
    let encoder = DiscoveryEncoder()
    let chooser = DiscoveryChooser()
    let launcher = DiscoveryLauncher()
    let coordinator: LinkRoutingCoordinator
    let link = IncomingLink(url: URL(string: "https://example.com/link")!)
    var completed = 0
    private let removeFixtures: () -> Void

    init(foundReplacement: Bool = true, healthyOther: Bool = false, discoveries: [Bool]? = nil) throws {
        let (defaults, removeDefaults) = makeIsolatedUserDefaults()
        self.defaults = defaults
        let (oldURL, removeOld) = try makeApplicationBundle(name: "Old Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
        let (newURL, removeNew) = try makeApplicationBundle(name: "New Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
        old = Browser(name: "Old Chrome", bundleIdentifier: "com.google.Chrome", appURL: oldURL, priority: 1)
        replacement = Browser(name: "New Chrome", bundleIdentifier: old.id, appURL: newURL, priority: 1)
        removeFixtures = { removeDefaults(); removeOld(); removeNew() }
        let encoder = encoder
        preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if encoder.fail { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        try preferences.saveScannedBrowsers([old] + (healthyOther ? [other] : []), at: Date())
        let replacement = replacement
        let other = other
        scanner = ControlledBrowserScanner(results: (discoveries ?? [foundReplacement]).map {
            ($0 ? [replacement] : []) + (healthyOther ? [other] : [])
        })
        repository = BrowserRepository(scanner: scanner, preferences: preferences)
        store = RoutingPreferencesStore(userDefaults: defaults)
        let clock = clock
        coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: store, appLanguageStore: makeEnglishAppLanguageStore(),
            now: { clock.now }, schedule: clock.schedule, onOpenSettings: {}
        )
    }

    func saveRule(browserID: String? = nil, mode: OpeningMode = .normal, alwaysShowChooser: Bool = false) throws {
        try store.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false), destinationID: OpenDestinationID(browserID: browserID ?? old.id, mode: mode))],
            alwaysShowChooser: alwaysShowChooser
        ))
    }

    func removeOldExecutable() throws {
        try FileManager.default.removeItem(at: old.appURL.appendingPathComponent("Contents/MacOS/TestExecutable"))
    }

    func cleanup() { scanner.finishAll(); removeFixtures() }
}

@MainActor
private final class DiscoveryChooser: BrowserChoosing {
    var selection: ((OpenDestination?) -> Void)?
    var destinations: [OpenDestination] = []
    var primary: ChooserRecoveryAction?
    var secondary: ChooserRecoveryAction?
    var cancel: (@MainActor @Sendable () -> Void)?
    var message: String?
    var presentations = 0

    func present(link: IncomingLink, destinations: [OpenDestination], recentBrowserID: Browser.ID?, routingHint: ChooserRoutingHint?, onCreateRule: ((String, OpenDestination) -> Void)?, completion: @escaping (OpenDestination?) -> Void) {
        self.destinations = destinations
        selection = completion
        presentations += 1
    }

    func presentRecovery(message: String, source: LinkSource?, primaryAction: ChooserRecoveryAction, secondaryAction: ChooserRecoveryAction?, onCancel: @escaping @MainActor @Sendable () -> Void) {
        self.message = message
        primary = primaryAction
        secondary = secondaryAction
        cancel = onCancel
    }
}

@MainActor
private final class DiscoveryLauncher: DestinationLaunching {
    var opened: [OpenDestination] = []
    var results = [true]
    var completions: [@MainActor @Sendable (Bool) -> Void] = []
    func open(_ url: URL, in destination: OpenDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        opened.append(destination)
        completions.append(completion)
        completion(results.isEmpty ? true : results.removeFirst())
    }
    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) { completion() }
}

private final class DiscoveryEncoder { var fail = false }
