import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ActivationQueueIntegrationTests: XCTestCase {
    func testZenPrivateClicksReportedByBothMonitorsDeliverEveryQueuedLinkColdAndWarm() async throws {
        for warm in [false, true] {
            for count in [2, 3] {
                let fixture = try ActivationQueueFixture(
                    browser: makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen")
                )
                defer { fixture.cleanup() }
                if warm {
                    fixture.system.application = ControlledActivationApplication()
                    fixture.system.application?.isActive = true
                    fixture.system.isSourceActive = false
                }
                fixture.enqueue(count)
                for index in 0..<count {
                    await fixture.routeTasks[index].value
                    let panel = fixture.panels[index]
                    let view = try fixture.chooserView(index)
                    let row = try XCTUnwrap(browserChooserRows(in: view).first)
                    let button = try XCTUnwrap(browserChooserPrivateButton(in: row))
                    fixture.clock.advance(to: fixture.clock.now + 0.01)
                    let event = fixture.mouse.click(in: panel, at: fixture.clock.now)
                    let globalCopy = fixture.mouse.click(in: panel, at: fixture.clock.now)
                    XCTAssertTrue(fixture.mouse.localHandlers[index](event) === event)
                    fixture.mouse.globalHandlers[index](globalCopy)

                    XCTAssertEqual(fixture.completed, index, "warm=\(warm), chooser=\(index)")
                    XCTAssertEqual(fixture.routeTasks.count, index + 1)
                    XCTAssertEqual(fixture.gecko.deliveredURLs.count, index)
                    // Fail cleanly before following a prematurely consumed request.
                    guard fixture.completed == index else { break }
                    button.performClick(nil)
                    if !warm && index == 0 {
                        fixture.clock.advance(to: 0.1)
                        fixture.system.application = ControlledActivationApplication()
                        fixture.clock.advance(to: 0.35)
                        fixture.confirmFocus()
                    }
                    XCTAssertEqual(fixture.completed, index + 1)
                    XCTAssertEqual(fixture.gecko.deliveredURLs.count, index + 1)
                    fixture.system.application?.isActive = true
                    fixture.system.isSourceActive = false
                }
                XCTAssertEqual(fixture.completed, count)
                XCTAssertEqual(fixture.gecko.deliveredURLs, (1...count).map { "https://example.com/\($0)" })
                XCTAssertTrue(fixture.workspace.deliveredURLs.isEmpty)
                XCTAssertEqual(fixture.system.application?.activationCount, warm ? 0 : 1)
            }
        }
    }

    func testZenPrivateLateFocusCannotConsumeQueuedLinksAfterColdOrWarmHandoff() async throws {
        for warm in [false, true] {
            for count in [2, 3] {
                let fixture = try ActivationQueueFixture(
                    browser: makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen")
                )
                defer { fixture.cleanup() }
                if warm {
                    fixture.system.application = ControlledActivationApplication()
                    fixture.system.application?.isActive = true
                    fixture.system.isSourceActive = false
                }
                fixture.enqueue(count)
                await fixture.routeTasks[0].value
                try fixture.chooserView(0).onSelect?(fixture.privateDestination)
                if !warm {
                    fixture.clock.advance(to: 0.1)
                    fixture.system.application = ControlledActivationApplication()
                    fixture.clock.advance(to: 0.35)
                    fixture.confirmFocus()
                }
                XCTAssertEqual(fixture.routeTasks.count, 2)
                guard fixture.routeTasks.count == 2 else { continue }

                for index in 1..<count {
                    await fixture.routeTasks[index].value
                    let view = try fixture.chooserView(index)
                    // Real logs: the app handoff has settled, but a browser window
                    // takes focus 0.1–0.2s after this *current* chooser appeared.
                    // Repeat well beyond the retry budget to reject timer guards.
                    for delay in [0.117, 0.171, 5.0] {
                        fixture.clock.advance(to: fixture.clock.now + delay)
                        fixture.chooser.windowDidResignKey(Notification(
                            name: NSWindow.didResignKeyNotification, object: fixture.panels[index]
                        ))
                    }
                    XCTAssertEqual(fixture.completed, index, "warm=\(warm), chooser=\(index)")
                    XCTAssertEqual(fixture.panels.count, index + 1)
                    XCTAssertNotNil(view.onSelect)
                    XCTAssertNotNil(view.onCancel)
                    guard fixture.completed == index else { break }
                    fixture.system.application?.isActive = true
                    fixture.system.isSourceActive = false
                    view.onSelect?(fixture.privateDestination)
                }
                XCTAssertEqual(fixture.completed, count)
                XCTAssertEqual(fixture.gecko.deliveredURLs, (1...count).map { "https://example.com/\($0)" })
                XCTAssertTrue(fixture.workspace.deliveredURLs.isEmpty)
                XCTAssertEqual(fixture.system.application?.activationCount, warm ? 0 : 1)
            }
        }
    }

    func testBackgroundHandoffAtDelayedDeadlinePreservesSecondAndThirdLinks() async throws {
        for mode in [OpeningMode.normal, .privateBrowsing] {
            for count in [2, 3] {
                let fixture = try ActivationQueueFixture()
                defer { fixture.cleanup() }
                fixture.system.isSourceActive = false
                fixture.system.application = ControlledActivationApplication()
                fixture.enqueue(count)
                await fixture.routeTasks[0].value
                let first = try fixture.chooserView(0)
                first.onSelect?(OpenDestination(browser: fixture.browser, mode: mode))
                let staleTicks = fixture.clock.scheduled.map(\.action)
                let staleObservers = Array(fixture.system.observers.values)

                fixture.system.application?.isActive = true
                fixture.clock.advanceAfterMainThreadBlock(to: 3)
                XCTAssertEqual(fixture.routeTasks.count, 2)
                guard fixture.routeTasks.count == 2 else { continue }
                await fixture.routeTasks[1].value
                XCTAssertEqual(fixture.displayTimes, [0, 3])
                XCTAssertEqual(fixture.repository.recentBrowserIdentifier, fixture.browser.id)

                staleTicks.forEach { $0() }
                staleObservers.forEach { $0(.activated(bundleIdentifier: fixture.browser.bundleIdentifier, processIdentifier: 42)) }
                first.onCancel?()
                fixture.chooser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: fixture.panels[0]))
                XCTAssertEqual(fixture.completed, 1)
                XCTAssertEqual(fixture.system.application?.activationCount, 1)

                try fixture.chooserView(1).onCancel?()
                if count == 3 {
                    await fixture.routeTasks[2].value
                    try fixture.chooserView(2).onCancel?()
                }
                XCTAssertEqual(fixture.completed, count)
                XCTAssertEqual(fixture.workspace.deliveredURLs.count, mode == .normal ? 1 : 0)
                XCTAssertEqual(fixture.gecko.deliveredURLs.count, mode == .privateBrowsing ? 1 : 0)
            }
        }
    }

    func testUnboundProcessNotificationsCannotConsumeLaterLinks() async throws {
        for count in [2, 3] {
            for earlyResult: ApplicationActivationResult? in [nil, .timedOut, .cancelled] {
                for wrongProcessExited in [false, true] {
                    let fixture = try ActivationQueueFixture()
                    defer { fixture.cleanup() }
                    fixture.enqueue(count)
                    await fixture.routeTasks[0].value
                    try fixture.chooserView(0).onSelect?(fixture.privateDestination)
                    let staleObservers = Array(fixture.system.observers.values)
                    let staleTicks = fixture.clock.scheduled.map(\.action)
                    if earlyResult == .timedOut { fixture.clock.advance(to: 2) }
                    if earlyResult == .cancelled { fixture.launcher.cancelPendingActivations() }
                    let wrongEvent: ApplicationActivationEvent = wrongProcessExited
                        ? .terminated(bundleIdentifier: fixture.browser.bundleIdentifier, processIdentifier: 99)
                        : .activated(bundleIdentifier: fixture.browser.bundleIdentifier, processIdentifier: 99)
                    for _ in 0..<2 {
                        fixture.system.emit(wrongEvent)
                        fixture.system.emit(.sourceDeactivated)
                    }
                    await fixture.routeTasks.last?.value
                    XCTAssertEqual(fixture.routeTasks.count, 1)
                    XCTAssertEqual(fixture.panels.count, 1)
                    XCTAssertEqual(fixture.completed, 0)
                    XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
                    XCTAssertTrue(fixture.workspace.deliveredURLs.isEmpty)

                    fixture.system.application = ControlledActivationApplication()
                    fixture.system.emit(wrongEvent) // Discovery binds 42, not this notification's 99.
                    fixture.system.emit(.sourceDeactivated)
                    XCTAssertEqual(fixture.routeTasks.count, 1)
                    fixture.confirmFocus()
                    // Avoid an out-of-bounds crash if a regression stalls resumption.
                    XCTAssertEqual(fixture.routeTasks.count, 2)
                    guard fixture.routeTasks.count == 2 else { continue }
                    await fixture.routeTasks[1].value
                    XCTAssertEqual(fixture.panels.count, 2)
                    XCTAssertEqual(fixture.completed, 1)
                    XCTAssertEqual(fixture.repository.recentBrowserIdentifier, fixture.browser.id)
                    XCTAssertTrue(fixture.system.observers.isEmpty)
                    XCTAssertTrue(fixture.clock.scheduled.allSatisfy { fixture.clock.cancelled.contains($0.id) })
                    staleObservers.forEach { $0(wrongEvent) }
                    staleTicks.forEach { $0() }
                    fixture.confirmFocus()
                    XCTAssertEqual(fixture.completed, 1)
                    XCTAssertEqual(fixture.system.application?.activationCount, 0)

                    fixture.system.application?.isActive = true
                    let second = try fixture.chooserView(1)
                    second.onSelect?(OpenDestination(browser: fixture.browser, mode: .normal))
                    XCTAssertEqual(fixture.workspace.deliveredURLs, [URL(string: "https://example.com/2")!])
                    if count == 3 {
                        await fixture.routeTasks[2].value
                        second.onCancel?()
                        staleObservers.forEach { $0(wrongEvent) }
                        XCTAssertEqual(fixture.completed, 2)
                        try fixture.chooserView(2).onCancel?()
                    }
                    XCTAssertEqual(fixture.completed, count)
                    XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
                }
            }
        }
    }

    func testAutomaticRoutesCannotOverlapUnsettledActivationForTheSameProcess() async throws {
        let fixture = try ActivationQueueFixture()
        defer { fixture.cleanup() }
        try fixture.routingPreferences.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(matcher: try DomainMatcher(host: "auto.example", includesSubdomains: false), destinationID: fixture.privateDestination.id)],
            alwaysShowChooser: false
        ))
        fixture.system.application = ControlledActivationApplication()
        fixture.system.application?.activationResults = [true, true]
        for host in ["auto.example/1", "auto.example/2", "choose.example/3"] {
            fixture.router.route(IncomingLink(url: URL(string: "https://\(host)")!))
        }
        await fixture.routeTasks[0].value
        fixture.clock.advance(to: 2)
        await fixture.routeTasks.last?.value
        XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
        XCTAssertEqual(fixture.system.application?.activationCount, 1)
        XCTAssertEqual(fixture.completed, 0)
        fixture.clock.advance(to: 5)
        fixture.system.application?.isActive = true
        fixture.confirmFocus()
        await fixture.routeTasks.last?.value
        await fixture.routeTasks.last?.value
        XCTAssertEqual(fixture.gecko.deliveredURLs.count, 2)
        XCTAssertEqual(fixture.system.application?.activationCount, 1)
        XCTAssertEqual(fixture.panels.count, 1)
        XCTAssertNil(fixture.repository.recentBrowserIdentifier)
        try fixture.chooserView(0).onCancel?()
        XCTAssertEqual(fixture.completed, 3)
    }

    func testColdStartKeepsSecondAndThirdLinksOwnedByTheirPresentations() async throws {
        for count in [2, 3] {
            let fixture = try ActivationQueueFixture()
            defer { fixture.cleanup() }
            fixture.enqueue(count)
            await fixture.routeTasks[0].value
            let firstView = try fixture.chooserView(0)
            firstView.onSelect?(fixture.privateDestination)
            XCTAssertEqual(fixture.panels.count, 1)
            fixture.clock.advance(to: 0.1) // First retry still cannot discover the process.
            fixture.system.application = ControlledActivationApplication()
            fixture.clock.advance(to: 0.35)
            XCTAssertEqual(fixture.system.application?.activationCount, 1)
            XCTAssertEqual(fixture.panels.count, 1)
            fixture.clock.advance(to: 0.4)
            fixture.confirmFocus()
            await fixture.routeTasks[1].value
            XCTAssertEqual(fixture.displayTimes, [0, 0.4])
            XCTAssertEqual(fixture.repository.recentBrowserIdentifier, fixture.browser.id)
            XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
            fixture.chooser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: fixture.panels[0]))
            firstView.onCancel?()
            fixture.clock.advance(to: 10)
            XCTAssertEqual(fixture.routeTasks.count, 2)
            XCTAssertEqual(fixture.system.application?.activationCount, 1)
            // The second link can still make its own explicit selection.
            fixture.system.application?.isActive = true
            fixture.system.isSourceActive = false
            let second = try fixture.chooserView(1)
            second.onSelect?(OpenDestination(browser: fixture.browser, mode: .normal))
            XCTAssertEqual(fixture.workspace.deliveredURLs, [URL(string: "https://example.com/2")!])
            if count == 3 {
                await fixture.routeTasks[2].value
                XCTAssertEqual(fixture.panels.count, 3)
                second.onCancel?() // Old callbacks cannot consume link 3.
                let third = try fixture.chooserView(2)
                third.onCancel?() // Its own Escape/cancel is still effective.
            }
            XCTAssertEqual(fixture.completed, count)
        }
    }

    func testTimeoutAndCancellationKeepNextPresentationHiddenUntilLateSystemEvent() async throws {
        for cancel in [false, true] {
            let fixture = try ActivationQueueFixture()
            defer { fixture.cleanup() }
            fixture.system.application = ControlledActivationApplication()
            fixture.enqueue(3)
            await fixture.routeTasks[0].value
            try fixture.chooserView(0).onSelect?(fixture.privateDestination)
            if cancel { fixture.launcher.cancelPendingActivations() }
            fixture.clock.advance(to: 2)
            XCTAssertEqual(fixture.routeTasks.count, 1)
            XCTAssertEqual(fixture.completed, 0) // Router retains ownership despite launch completion.
            XCTAssertEqual(fixture.panels.count, 1) // Request ID alone would not protect a shown panel.
            XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
            XCTAssertEqual(fixture.repository.recentBrowserIdentifier, fixture.browser.id)
            fixture.clock.advance(to: 5)
            fixture.confirmFocus()
            await fixture.routeTasks[1].value
            XCTAssertEqual(fixture.displayTimes, [0, 5])
            XCTAssertEqual(fixture.system.application?.activationCount, 1)
            fixture.confirmFocus() // Duplicate/late events cannot cancel link 2.
            XCTAssertEqual(fixture.completed, 1)
            fixture.mouse.globalHandlers.last?(fixture.mouse.click(at: fixture.clock.now + 1))
            await fixture.routeTasks[2].value
            XCTAssertEqual(fixture.panels.count, 3)
            try fixture.chooserView(2).onCancel?()
            XCTAssertEqual(fixture.completed, 3)
            XCTAssertEqual(fixture.gecko.deliveredURLs.count, 1)
        }
    }

    func testNormalForegroundHandoffIsImmediateWhenWarmAndGuardsLateColdActivation() async throws {
        for warm in [true, false] {
            let fixture = try ActivationQueueFixture()
            defer { fixture.cleanup() }
            if warm {
                fixture.system.application = ControlledActivationApplication()
                fixture.system.application?.isActive = true
                fixture.system.isSourceActive = false
            }
            fixture.enqueue(2)
            await fixture.routeTasks[0].value
            try fixture.chooserView(0).onSelect?(OpenDestination(browser: fixture.browser, mode: .normal))
            if !warm {
                fixture.clock.advance(to: 2)
                // Normal URL delivery now allows OS activation. Its late handoff
                // can still steal focus, even when Eligo has not found the process.
                XCTAssertEqual(fixture.routeTasks.count, 1)
                XCTAssertEqual(fixture.panels.count, 1)
                XCTAssertEqual(fixture.completed, 0)
                XCTAssertEqual(fixture.workspace.deliveredURLs.count, 1)
                fixture.clock.advance(to: 5)
                fixture.system.application = ControlledActivationApplication()
                fixture.confirmFocus()
            }
            XCTAssertEqual(fixture.routeTasks.count, 2)
            let nextTask = try XCTUnwrap(fixture.routeTasks.dropFirst().first)
            await nextTask.value
            XCTAssertEqual(fixture.displayTimes, [0, warm ? 0 : 5])
            XCTAssertEqual(fixture.workspace.deliveredURLs.count, 1)
            try fixture.chooserView(1).onCancel?()
            XCTAssertEqual(fixture.completed, 2)
        }
    }

    func testFailedPrivateDeliveryKeepsRecoveryAndDoesNotRecordRecentOrActivate() async throws {
        let fixture = try ActivationQueueFixture()
        defer { fixture.cleanup() }
        fixture.gecko.succeeds = false
        fixture.enqueue(2)
        await fixture.routeTasks[0].value
        try fixture.chooserView(0).onSelect?(fixture.privateDestination)
        XCTAssertEqual(fixture.panels.count, 2) // Existing launch-failure recovery, not link 2.
        XCTAssertEqual(fixture.completed, 0)
        XCTAssertNil(fixture.repository.recentBrowserIdentifier)
        XCTAssertTrue(fixture.system.observers.isEmpty)
        XCTAssertTrue(fixture.workspace.deliveredURLs.isEmpty)
        fixture.chooser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: fixture.panels[1]))
        await fixture.routeTasks[1].value
        try fixture.chooserView(2).onCancel?()
        XCTAssertEqual(fixture.completed, 2)
    }
}

@MainActor
private final class ActivationQueueFixture {
    let clock = ActivationTestClock()
    let system = ControlledActivationSystem()
    let gate = ActivationHandoffGate(resume: { $0() })
    let browser: Browser
    var privateDestination: OpenDestination { OpenDestination(browser: browser, mode: .privateBrowsing) }
    let workspace = DeliveredWorkspace()
    let gecko = DeliveredGecko()
    let mouse = ChooserMouseEventSource()
    let repository: BrowserRepository
    let cleanPreferences: () -> Void
    let routingPreferences = makeIsolatedRoutingPreferencesStore()
    lazy var activator = NSRunningApplicationActivator(system: system, gate: gate, now: { [clock] in clock.now }, schedule: clock.schedule)
    lazy var launcher = BrowserLauncher(workspace: workspace, geckoPrivateLauncher: gecko, applicationActivator: activator)
    var panels: [NSPanel] = []
    var displayTimes: [TimeInterval] = []
    lazy var chooser = ChooserWindowController(appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { [weak self] panel in
        self?.panels.append(panel)
        self?.displayTimes.append(self?.clock.now ?? -1)
    }, mouseEvents: mouse.events, now: { [clock] in clock.now })
    lazy var coordinator = LinkRoutingCoordinator(
        browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
        routingPreferencesStore: routingPreferences, appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
    )
    let router = URLRouter()
    var routeTasks: [Task<Void, Never>] = []
    var completed = 0

    init(browser: Browser = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")) throws {
        self.browser = browser
        let (preferences, cleanup) = makeIsolatedPreferences()
        cleanPreferences = cleanup
        try preferences.saveScannedBrowsers([browser], at: Date())
        repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        router.setHandler { [weak self] link, completion in
            guard let self else { return }
            routeTasks.append(coordinator.route(link) { [weak self] in
                self?.completed += 1
                completion()
            })
        }
    }
    func enqueue(_ count: Int) {
        for index in 1...count { router.route(IncomingLink(url: URL(string: "https://example.com/\(index)")!)) }
    }
    func chooserView(_ index: Int) throws -> ChooserView {
        try XCTUnwrap(browserChooserView(in: panels[index].contentView))
    }
    func confirmFocus() {
        system.emit(.activated(bundleIdentifier: browser.bundleIdentifier, processIdentifier: 42))
        system.emit(.sourceDeactivated)
    }
    func cleanup() {
        router.setHandler(nil)
        cleanPreferences()
    }
}

@MainActor
private final class DeliveredWorkspace: WorkspaceOpening {
    var deliveredURLs: [URL] = []
    func openURLs(_ urls: [URL], withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Bool) -> Void) {
        deliveredURLs += urls
        completion(true)
        completion(true) // Even a duplicated delivery callback must be idempotent.
    }
    func openApplication(at applicationURL: URL, arguments: [String], createsNewApplicationInstance: Bool, completion: @escaping @MainActor (Bool, NSRunningApplication?) -> Void) {
        completion(true, nil)
    }
}

@MainActor
private final class DeliveredGecko: GeckoPrivateLaunching {
    var succeeds = true
    var deliveredURLs: [String] = []
    func openPrivateWindow(at applicationURL: URL, bundleIdentifier: String, arguments: [String], completion: @escaping @MainActor (Bool) -> Void) {
        deliveredURLs.append(arguments.last!)
        completion(succeeds)
    }
}
