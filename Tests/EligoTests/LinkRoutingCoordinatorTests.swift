import Foundation
import XCTest
@testable import Eligo

@MainActor
final class LinkRoutingCoordinatorTests: XCTestCase {
    func testRuleCreationOutcomesKeepOriginalLinkUntilDismissalAndOpenFinalDestinationOnce() async throws {
        for outcome in ["create", "update", "expand", "reuseExact", "reuseCovered", "coexist"] {
            try await assertRuleCreationOpensPendingLinkOnce(outcome: outcome)
        }
    }

    private func assertRuleCreationOpensPendingLinkOnce(outcome: String) async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let preferences = BrowserPreferences(userDefaults: defaults)
        try preferences.saveScannedBrowsers([safari, chrome], at: Date())
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let finalDestination = OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing)
        let previousRules: [DomainRule] = outcome == "create" ? [] : [DomainRule(
            matcher: try DomainMatcher(host: "example.com", includesSubdomains: outcome == "reuseCovered"),
            destinationID: ["update", "coexist"].contains(outcome)
                ? OpenDestinationID(browserID: safari.id, mode: .normal) : finalDestination
        )]
        try store.replace(with: RoutingSettings(scope: .allDomains, rules: previousRules, alwaysShowChooser: true))
        let session = DomainRuleSettingsSession(store: store)
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [true])
        var completed = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: store, appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}, onCreateRule: { host, destination, completion in
                session.onChooserRuleFinished = completion
                _ = session.send(.requestRuleFromChooser(host: host, destinationID: destination.id))
            }
        )
        let link = IncomingLink(url: URL(string: "https://example.com/original?x=1#anchor")!, source: .unknown)
        await coordinator.route(link) { completed += 1 }.value
        chooser.createRule?("example.com", OpenDestination(browser: safari, mode: .normal))
        XCTAssertEqual(completed, 0)
        let id = try XCTUnwrap(session.state.presentation?.id)
        try session.commit(.singleRule(presentationID: id, host: "example.com", includesSubdomains: ["expand", "coexist"].contains(outcome),
                                       destinationID: finalDestination))
        XCTAssertTrue(launcher.openedURLs.isEmpty)
        XCTAssertEqual(completed, 0)
        _ = session.send(.presentationEnded(id: id))
        _ = session.send(.presentationEnded(id: id))
        XCTAssertEqual(launcher.openedURLs, [link.url])
        XCTAssertEqual(launcher.openedDestinations.map(\.id), [finalDestination])
        XCTAssertEqual(repository.recentBrowserIdentifier, chrome.id)
        XCTAssertEqual(completed, 1)
        if outcome.hasPrefix("reuse") {
            XCTAssertEqual(store.settings.rules, previousRules)
        }
    }

    func testCancelledRuleEditingReturnsSameLinkAndSourceToChooser() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [true])
        var finishEditing: ((OpenDestinationID?) -> Void)?
        var completed = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(), appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}, onCreateRule: { _, _, completion in finishEditing = completion }
        )
        let link = IncomingLink(url: URL(string: "https://example.com/pending")!, source: .unknown)
        await coordinator.route(link) { completed += 1 }.value
        let originalSelection = chooser.selectionCompletion
        chooser.createRule?("example.com", OpenDestination(browser: safari, mode: .normal))
        originalSelection?(nil)
        finishEditing?(nil)
        XCTAssertEqual(chooser.presentedURL, link.url)
        XCTAssertEqual(chooser.presentedSource, link.source)
        XCTAssertTrue(launcher.openedURLs.isEmpty)
        XCTAssertEqual(completed, 0)
        chooser.selectionCompletion?(OpenDestination(browser: safari, mode: .normal))
        XCTAssertEqual(launcher.openedURLs, [link.url])
        XCTAssertEqual(completed, 1)
    }

    func testRecoveryEnableAfterScanRemovesBrowserPointsToRescanInSettings() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        try preferences.save([ConfiguredBrowser(browser: safari, isEnabled: false)])
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [])
        var settingsOpened = 0
        var completed = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: { settingsOpened += 1 }
        )
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Enable Safari")
        let scan = await repository.rescan().value
        XCTAssertEqual(scan, .applied)
        XCTAssertTrue(repository.browsers.isEmpty)
        chooser.primaryRecoveryAction?.perform()

        XCTAssertEqual(repository.operationFeedback, .mutationRejected(.notFound))
        XCTAssertEqual(chooser.recoveryMessage,
            "That browser is no longer available. Open Settings to rescan and try again.")
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Open Settings")
        XCTAssertNil(chooser.secondaryRecoveryAction)
        XCTAssertTrue(launcher.openedDestinations.isEmpty)
        XCTAssertEqual(completed, 0)
        chooser.primaryRecoveryAction?.perform()
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(completed, 1)
    }

    func testBackgroundScanPreservesLaterRecentSaveFailureAfterManualOpen() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var failEncoding = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        try preferences.saveScannedBrowsers([safari, firefox], at: Date(timeIntervalSince1970: 1))
        try preferences.saveRecentBrowserIdentifier(safari.id)
        let scanner = ControlledBrowserScanner(results: [[safari, firefox]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let scan = repository.rescan()
        await waitUntil { scanner.scanCount == 1 }
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [true])
        var completed = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
        )
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
        failEncoding = true
        chooser.selectionCompletion?(OpenDestination(browser: firefox, mode: .normal))
        XCTAssertEqual(repository.operationFeedback, .recentSaveFailed(.encodingFailed))
        failEncoding = false
        scanner.finish(0)
        let result = await scan.value
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(repository.recentBrowserIdentifier, safari.id)
        XCTAssertEqual(try preferences.recentBrowserIdentifier(), safari.id)
        XCTAssertEqual(repository.operationFeedback, .recentSaveFailed(.encodingFailed))
        XCTAssertEqual(launcher.openedDestinations.count, 1)
        XCTAssertEqual(completed, 1)
    }

    func testInitialScanSaveFailureReachesLinksArrivingBeforeOrAfterCompletion() async {
        for linkArrivesAfterScan in [false, true] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            let preferences = BrowserPreferences(userDefaults: defaults, encode: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
            let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
            let scanner = ControlledBrowserScanner(results: [[safari]])
            defer { scanner.finishAll() }
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            let scan = repository.rescan()
            await waitUntil { scanner.scanCount == 1 }
            if linkArrivesAfterScan {
                scanner.finish(0)
                let result = await scan.value
                XCTAssertEqual(result, .storageFailure(.encodingFailed))
            }
            let chooser = RecordingBrowserChooser()
            let launcher = RecordingDestinationLauncher(results: [])
            var completed = 0
            let coordinator = LinkRoutingCoordinator(
                browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
                routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
                appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
            )
            let route = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }
            if !linkArrivesAfterScan {
                await Task.yield()
                XCTAssertNil(chooser.recoveryMessage)
                scanner.finish(0)
            }
            await route.value
            XCTAssertEqual(chooser.recoveryMessage,
                "Browser settings could not be saved. Your previous settings are unchanged. Try again.")
            XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Open Settings")
            XCTAssertNil(chooser.presentedURL)
            XCTAssertTrue(launcher.openedDestinations.isEmpty)
            XCTAssertTrue(repository.browsers.isEmpty)
            XCTAssertNil(defaults.object(forKey: BrowserPreferences.storageKey))
            XCTAssertEqual(completed, 0)
            chooser.cancelRecovery?()
            XCTAssertEqual(completed, 1)
        }
    }

    func testAcceptedCustomBrowserRemovalPreservesRuleAndPrivateRecovery() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: defaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let custom = makeBrowser(name: "Custom", bundleIdentifier: "com.google.Chrome", isCustom: true)
        try preferences.saveScannedBrowsers([safari], at: Date())
        try preferences.saveCustomBrowser(custom)
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let settings = try RoutingSettings(scope: .allDomains, rules: [DomainRule(
            matcher: try DomainMatcher(host: "example.com", includesSubdomains: false),
            destinationID: OpenDestinationID(browserID: custom.id, mode: .privateBrowsing)
        )], alwaysShowChooser: false)
        try store.replace(with: settings)
        let bytes = defaults.data(forKey: RoutingPreferencesStore.storageKey)
        XCTAssertNotNil(DestinationCatalog(enabledBrowsers: repository.enabledBrowsers).destination(for:
            OpenDestinationID(browserID: custom.id, mode: .privateBrowsing)))
        XCTAssertEqual(repository.removeCustomBrowser(id: custom.id), .applied)
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [true])
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: store, appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
        )
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {}).value
        XCTAssertEqual(chooser.recoveryMessage, "Saved destination com.google.Chrome is unavailable.")
        XCTAssertTrue(launcher.openedDestinations.isEmpty)
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), bytes)
    }

    func testCorruptConfigurationRoutesDirectlyToSettingsRecoveryWithoutScanning() async {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey)
        let scanner = StubBrowserScanner(result: [])
        let repository = BrowserRepository(scanner: scanner, preferences: BrowserPreferences(userDefaults: defaults))
        let chooser = RecordingBrowserChooser()
        var completed = 0
        var settingsOpened = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: { settingsOpened += 1 }
        )
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
        XCTAssertEqual(chooser.recoveryMessage, "Saved browser settings could not be read. Reset Settings to repair them.")
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Open Settings")
        XCTAssertNil(chooser.secondaryRecoveryAction)
        XCTAssertEqual(scanner.scanCount, 0)
        XCTAssertEqual(completed, 0)
        chooser.primaryRecoveryAction?.perform()
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(completed, 1)
    }

    func testFailedRecoveryEnableKeepsReasonVisibleUntilCancel() async throws {
        for corrupt in [false, true] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            var failEncoding = false
            let preferences = BrowserPreferences(userDefaults: defaults, encode: {
                if failEncoding { throw CocoaError(.fileWriteUnknown) }
                return try JSONEncoder().encode($0)
            })
            let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
            try preferences.saveScannedBrowsers([safari], at: Date())
            try preferences.save([ConfiguredBrowser(browser: safari, isEnabled: false)])
            let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
            let chooser = RecordingBrowserChooser()
            var completed = 0
            let coordinator = LinkRoutingCoordinator(
                browserRepository: repository,
                destinationLauncher: RecordingDestinationLauncher(results: []),
                chooser: chooser,
                routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
                appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
            )
            await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
            if corrupt { defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey) }
            failEncoding = true
            chooser.primaryRecoveryAction?.perform()
            XCTAssertEqual(completed, 0)
            XCTAssertNil(chooser.presentedURL)
            XCTAssertEqual(chooser.recoveryMessage, corrupt
                ? "Saved browser settings could not be read. Reset Settings to repair them."
                : "Browser settings could not be saved. Your previous settings are unchanged. Try again.")
            XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Open Settings")
            chooser.cancelRecovery?()
            XCTAssertEqual(completed, 1)
        }
    }

    func testRecentWriteFailureAfterSuccessfulManualOpenDoesNotReopenOrBlockCompletion() async throws {
        for corrupt in [false, true] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            var failEncoding = false
            let preferences = BrowserPreferences(userDefaults: defaults, encode: {
                if failEncoding { throw CocoaError(.fileWriteUnknown) }
                return try JSONEncoder().encode($0)
            })
            let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
            try preferences.saveScannedBrowsers([safari], at: Date())
            let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
            let chooser = RecordingBrowserChooser()
            let launcher = RecordingDestinationLauncher(results: [true])
            var completed = 0
            var settingsOpened = 0
            let coordinator = LinkRoutingCoordinator(
                browserRepository: repository, destinationLauncher: launcher, chooser: chooser,
                routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
                appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: { settingsOpened += 1 }
            )
            await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
            // Corruption after submission must not turn a delivered URL into a retry.
            launcher.beforeCompletion = {
                if corrupt { defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey) }
            }
            failEncoding = true
            let bytes = corrupt ? Data("broken".utf8) : defaults.data(forKey: BrowserPreferences.storageKey)
            chooser.selectionCompletion?(try XCTUnwrap(chooser.presentedDestinations.first))
            XCTAssertEqual(launcher.openedDestinations.count, 1)
            XCTAssertEqual(completed, 1)
            XCTAssertEqual(settingsOpened, 0)
            XCTAssertNil(chooser.recoveryMessage)
            XCTAssertNil(repository.recentBrowserIdentifier)
            XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
            XCTAssertEqual(repository.operationFeedback, .recentSaveFailed(corrupt ? .unreadableConfiguration : .encodingFailed))
            if corrupt {
                // The persistent repair banner owns the cause; the operation line keeps only the outcome.
                XCTAssertEqual(repository.availability, .configurationUnreadable)
                let language = makeEnglishAppLanguageStore()
                let feedback = try XCTUnwrap(repository.operationFeedback)
                XCTAssertEqual(feedback.text(using: language), "The link opened, but Recent Browser could not be saved.")
                language.select(.simplifiedChinese)
                XCTAssertEqual(feedback.text(using: language), "链接已打开，但无法记录最近使用的浏览器。")
            }
        }
    }

    func testLinkWaitingForInvalidatedScanStopsWaitingBeforePhysicalScanFinishes() async {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let scanner = ControlledBrowserScanner(results: [[]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: BrowserPreferences(userDefaults: defaults))
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser, routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
        )
        var completed = 0
        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }
        await waitUntil { scanner.scanCount == 1 }
        defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey)
        let result = await repository.rescan().value
        XCTAssertEqual(result, .storageFailure(.unreadableConfiguration))
        await waitUntil { chooser.recoveryMessage != nil }
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Open Settings")
        XCTAssertFalse(repository.isScanning)
        chooser.cancelRecovery?()
        XCTAssertEqual(completed, 1)
        scanner.finish(0)
        await task.value
    }

    func testRecoveryRescanFailureShowsCauseWithoutCompletingLink() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var failEncoding = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let chooser = RecordingBrowserChooser()
        var completed = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository, destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser, routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(), onOpenSettings: {}
        )
        await coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) { completed += 1 }.value
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Rescan")
        failEncoding = true
        chooser.primaryRecoveryAction?.perform()
        await waitUntil { chooser.primaryRecoveryAction?.title == "Open Settings" }
        XCTAssertEqual(chooser.recoveryMessage, "Browser settings could not be saved. Your previous settings are unchanged. Try again.")
        XCTAssertEqual(completed, 0)
        chooser.cancelRecovery?()
        XCTAssertEqual(completed, 1)
    }

    func testFirstUncachedLinkWaitsForBackgroundDiscovery() async {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let scanner = BlockingBrowserScanner(result: [safari])
        defer { scanner.resume() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: [true]),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )
        var completionCount = 0

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) {
            completionCount += 1
        }
        await waitUntil { scanner.didStart }

        XCTAssertNil(chooser.presentedURL)
        XCTAssertEqual(completionCount, 0)

        scanner.resume()
        await routeTask.value

        XCTAssertEqual(chooser.presentedURL, URL(string: "https://example.com")!)
        XCTAssertEqual(
            chooser.presentedDestinations.map(\.id),
            [OpenDestinationID(browserID: safari.id, mode: .normal)]
        )
        XCTAssertEqual(completionCount, 0)
    }

    func testNoDetectedBrowserCanOpenSettingsAndCompletesTheQueuedURL() async {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences
        )
        let chooser = RecordingBrowserChooser()
        var settingsOpenCount = 0
        var completionCount = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: { settingsOpenCount += 1 }
        )

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) {
            completionCount += 1
        }
        await routeTask.value

        XCTAssertEqual(chooser.recoveryMessage, "No browser apps were found. Rescan or add one in Settings.")
        XCTAssertEqual(chooser.secondaryRecoveryAction?.title, "Open Settings")
        XCTAssertEqual(completionCount, 0)

        chooser.secondaryRecoveryAction?.perform()

        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    func testDisabledBrowserCanBeEnabledWithoutDroppingTheLink() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        try preferences.save([ConfiguredBrowser(browser: safari, isEnabled: false)])
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            now: { now }
        )
        let chooser = RecordingBrowserChooser()
        var completionCount = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) {
            completionCount += 1
        }
        await routeTask.value

        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Enable Safari")
        chooser.primaryRecoveryAction?.perform()

        XCTAssertEqual(repository.enabledBrowsers.map(\.id), [safari.id])
        XCTAssertEqual(
            chooser.presentedDestinations.map(\.id),
            [OpenDestinationID(browserID: safari.id, mode: .normal)]
        )
        XCTAssertEqual(completionCount, 0)
    }

    func testLaunchFailureCanRetryBeforeCompletingTheQueuedURL() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            now: { now }
        )
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [false, true])
        var completionCount = 0
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: launcher,
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) {
            completionCount += 1
        }
        await routeTask.value
        chooser.selectionCompletion?(OpenDestination(browser: safari, mode: .normal))

        XCTAssertEqual(
            launcher.openedDestinations.map(\.id),
            [OpenDestinationID(browserID: safari.id, mode: .normal)]
        )
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Try Again")
        XCTAssertEqual(completionCount, 0)

        chooser.primaryRecoveryAction?.perform()

        XCTAssertEqual(
            launcher.openedDestinations.map(\.id),
            [
                OpenDestinationID(browserID: safari.id, mode: .normal),
                OpenDestinationID(browserID: safari.id, mode: .normal)
            ]
        )
        XCTAssertEqual(try preferences.recentBrowserIdentifier(), safari.id)
        XCTAssertEqual(completionCount, 1)
    }

    func testPrivateLaunchFailureNamesPrivateModeAndRetriesPrivateDestination() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        try preferences.saveScannedBrowsers([chrome], at: now)
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [false, true])
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: { now }),
            destinationLauncher: launcher,
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await task.value
        let privateDestination = OpenDestination(browser: chrome, mode: .privateBrowsing)
        chooser.selectionCompletion?(privateDestination)

        XCTAssertEqual(chooser.recoveryMessage, "Google Chrome could not be opened in Private mode.")
        chooser.primaryRecoveryAction?.perform()
        XCTAssertEqual(launcher.openedDestinations.map(\.id), [privateDestination.id, privateDestination.id])
    }

    func testChooserPresentationCarriesTheLinkSource() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: { now }),
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )
        let source = LinkSource.app(AppSender(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            appURL: URL(fileURLWithPath: "/Applications/Slack.app", isDirectory: true)
        ))

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!, source: source), completion: {})
        await task.value

        XCTAssertEqual(chooser.presentedURL, URL(string: "https://example.com")!)
        XCTAssertEqual(chooser.presentedSource, source)
    }

    func testFailedOpenRecoveryCarriesTheLinkSource() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: { now }),
            destinationLauncher: RecordingDestinationLauncher(results: [false]),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!, source: .unknown), completion: {})
        await task.value
        chooser.selectionCompletion?(OpenDestination(browser: safari, mode: .normal))

        XCTAssertNotNil(chooser.recoveryMessage)
        XCTAssertEqual(chooser.recoverySource, .unknown)
    }

    func testFailedManualChoiceDoesNotChangeRecentBrowser() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences),
            destinationLauncher: RecordingDestinationLauncher(results: [false]),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await task.value
        chooser.selectionCompletion?(OpenDestination(browser: safari, mode: .normal))

        XCTAssertNil(try preferences.recentBrowserIdentifier())
    }

    func testCachedLinkDoesNotWaitForBackgroundRefresh() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let cacheDate = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: cacheDate)
        let scanner = BlockingBrowserScanner(result: [safari])
        defer { scanner.resume() }
        let repository = BrowserRepository(
            scanner: scanner,
            preferences: preferences,
            cacheMaximumAge: 3_600,
            now: { cacheDate.addingTimeInterval(3_601) }
        )
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await waitUntil { scanner.didStart }
        for _ in 0..<1_000 where chooser.presentedURL == nil {
            await Task.yield()
        }
        XCTAssertNotNil(chooser.presentedURL)
        XCTAssertTrue(scanner.didStart)

        XCTAssertEqual(
            chooser.presentedDestinations.map(\.id),
            [OpenDestinationID(browserID: safari.id, mode: .normal)]
        )
        scanner.resume()
        await routeTask.value
    }

    func testCancellingChooserCompletesQueuedURL() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            now: { now }
        )
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )
        var completionCount = 0

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!)) {
            completionCount += 1
        }
        await routeTask.value
        chooser.selectionCompletion?(nil)

        XCTAssertEqual(completionCount, 1)
    }

    func testChooserReceivesPrivateDestinationForSupportedBrowser() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        try preferences.saveScannedBrowsers([chrome, safari], at: now)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            now: { now }
        )
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: repository,
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: makeIsolatedRoutingPreferencesStore(),
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let routeTask = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await routeTask.value

        XCTAssertEqual(chooser.presentedDestinations.map(\.mode), [.normal, .normal, .privateBrowsing])
        XCTAssertEqual(chooser.presentedDestinations.map(\.browser.id), [safari.id, chrome.id, chrome.id])
    }

    func testDomainRuleOpensItsAvailableDestinationWithoutChangingRecentBrowser() async throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        try preferences.saveScannedBrowsers([safari, chrome], at: Date())
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        let chromeDestination = OpenDestinationID(browserID: chrome.id, mode: .normal)
        try store.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(
                matcher: try DomainMatcher(host: "example.com", includesSubdomains: false),
                destinationID: chromeDestination
            )],
            alwaysShowChooser: false
        ))
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [true])
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: Date.init),
            destinationLauncher: launcher,
            chooser: chooser,
            routingPreferencesStore: store,
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await task.value

        XCTAssertEqual(launcher.openedDestinations.map(\.id), [chromeDestination])
        XCTAssertNil(chooser.presentedURL)
        XCTAssertNil(try preferences.recentBrowserIdentifier())
    }

    func testAlwaysShowChooserUsesRecentManualBrowserInsteadOfRuleDestination() async throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        try preferences.saveScannedBrowsers([safari, chrome], at: Date())
        try preferences.saveRecentBrowserIdentifier(safari.id)
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        let destinationID = OpenDestinationID(browserID: chrome.id, mode: .normal)
        try store.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false), destinationID: destinationID)],
            alwaysShowChooser: true
        ))
        let chooser = RecordingBrowserChooser()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: Date.init),
            destinationLauncher: RecordingDestinationLauncher(results: []),
            chooser: chooser,
            routingPreferencesStore: store,
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await task.value

        XCTAssertEqual(chooser.presentedRecentBrowserID, safari.id)
        XCTAssertEqual(chooser.routingHint, .init(destinationID: destinationID, matchedDomain: "example.com"))
    }

    func testUnavailableRuleDestinationEntersRecoveryWithoutFallback() async throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        let unavailableID = OpenDestinationID(browserID: "com.example.missing", mode: .normal)
        try store.replace(with: RoutingSettings(
            scope: .allDomains,
            rules: [DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false), destinationID: unavailableID)],
            alwaysShowChooser: false
        ))
        let chooser = RecordingBrowserChooser()
        let launcher = RecordingDestinationLauncher(results: [])
        let coordinator = LinkRoutingCoordinator(
            browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: Date.init),
            destinationLauncher: launcher,
            chooser: chooser,
            routingPreferencesStore: store,
            appLanguageStore: makeEnglishAppLanguageStore(),
            onOpenSettings: {}
        )

        let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
        await task.value

        XCTAssertEqual(chooser.recoveryMessage, "Saved destination com.example.missing is unavailable.")
        XCTAssertEqual(chooser.primaryRecoveryAction?.title, "Choose Another Browser")
        XCTAssertTrue(launcher.openedDestinations.isEmpty)
        chooser.primaryRecoveryAction?.perform()
        XCTAssertEqual(chooser.presentedDestinations.map(\.id), [OpenDestinationID(browserID: safari.id, mode: .normal)])
    }

    func testUnavailableBypassDestinationEntersRecoveryWithoutLaunching() async throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let unavailableID = OpenDestinationID(browserID: "com.example.missing", mode: .normal)

        let settings = try RoutingSettings(
                scope: .onlyThese(matchers: [try DomainMatcher(host: "inside.example.com", includesSubdomains: false)], bypassDestinationID: unavailableID),
                rules: [],
                alwaysShowChooser: false
            )
            let store = RoutingPreferencesStore(userDefaults: userDefaults)
            try store.replace(with: settings)
            let chooser = RecordingBrowserChooser()
            let launcher = RecordingDestinationLauncher(results: [])
            let coordinator = LinkRoutingCoordinator(
                browserRepository: BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences, now: Date.init),
                destinationLauncher: launcher,
                chooser: chooser,
                routingPreferencesStore: store,
                appLanguageStore: makeEnglishAppLanguageStore(),
                onOpenSettings: {}
            )

            let task = coordinator.route(IncomingLink(url: URL(string: "https://example.com")!), completion: {})
            await task.value

            XCTAssertEqual(chooser.recoveryMessage, "Saved destination com.example.missing is unavailable.")
            XCTAssertTrue(launcher.openedDestinations.isEmpty)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}

private final class BlockingBrowserScanner: BrowserScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let result: [Browser]
    private var storedDidStart = false

    init(result: [Browser]) {
        self.result = result
    }

    func scan() -> [Browser] {
        lock.lock()
        storedDidStart = true
        lock.unlock()
        semaphore.wait()
        return result
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDidStart
    }

    func resume() {
        semaphore.signal()
    }
}

@MainActor
private final class RecordingBrowserChooser: BrowserChoosing {
    private(set) var presentedURL: URL?
    private(set) var presentedSource: LinkSource?
    private(set) var presentedDestinations: [OpenDestination] = []
    private(set) var presentedRecentBrowserID: Browser.ID?
    private(set) var recoveryMessage: String?
    private(set) var recoverySource: LinkSource?
    private(set) var primaryRecoveryAction: ChooserRecoveryAction?
    private(set) var secondaryRecoveryAction: ChooserRecoveryAction?
    private(set) var cancelRecovery: (@MainActor @Sendable () -> Void)?
    var selectionCompletion: ((OpenDestination?) -> Void)?
    var createRule: ((String, OpenDestination) -> Void)?
    var routingHint: ChooserRoutingHint?

    func present(
        link: IncomingLink,
        destinations: [OpenDestination],
        recentBrowserID: Browser.ID?,
        routingHint: ChooserRoutingHint?,
        onCreateRule: ((String, OpenDestination) -> Void)?,
        completion: @escaping (OpenDestination?) -> Void
    ) {
        presentedURL = link.url
        presentedSource = link.source
        presentedDestinations = destinations
        presentedRecentBrowserID = recentBrowserID
        selectionCompletion = completion
        createRule = onCreateRule
        self.routingHint = routingHint
    }

    func presentRecovery(
        message: String,
        source: LinkSource?,
        primaryAction: ChooserRecoveryAction,
        secondaryAction: ChooserRecoveryAction?,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        recoveryMessage = message
        recoverySource = source
        primaryRecoveryAction = primaryAction
        secondaryRecoveryAction = secondaryAction
        cancelRecovery = onCancel
    }
}

@MainActor
final class RecordingDestinationLauncher: DestinationLaunching {
    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) { completion() }

    private var results: [Bool]
    private(set) var openedDestinations: [OpenDestination] = []
    private(set) var openedURLs: [URL] = []
    var beforeCompletion: (() -> Void)?

    init(results: [Bool]) {
        self.results = results
    }

    func open(
        _ url: URL,
        in destination: OpenDestination,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        openedDestinations.append(destination)
        openedURLs.append(url)
        beforeCompletion?()
        completion(results.isEmpty ? false : results.removeFirst())
    }
}
