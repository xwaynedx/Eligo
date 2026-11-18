import Foundation
import XCTest
@testable import Eligo

@MainActor
final class BrowserRepositoryTests: XCTestCase {
    func testSuccessfulScanRetryClearsInitialFailureForLaterLinks() async {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        for retryBrowsers in [[], [safari]] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            var failEncoding = true
            let preferences = BrowserPreferences(userDefaults: defaults, encode: {
                if failEncoding { throw CocoaError(.fileWriteUnknown) }
                return try JSONEncoder().encode($0)
            })
            let scanner = ControlledBrowserScanner(results: [[safari], retryBrowsers])
            defer { scanner.finishAll() }
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            let firstScan = repository.rescan()
            scanner.finish(0)
            let failure = await firstScan.value
            XCTAssertEqual(failure, .storageFailure(.encodingFailed))
            let lateArrival = repository.discoveryResult
            XCTAssertEqual(lateArrival, failure)

            failEncoding = false
            let retry = repository.rescan()
            scanner.finish(1)
            let success = await retry.value
            XCTAssertEqual(success, .applied)
            let nextArrival = repository.discoveryResult
            XCTAssertTrue(nextArrival.wasAccepted)
            XCTAssertEqual(repository.enabledBrowsers, retryBrowsers)
            XCTAssertNil(repository.operationFeedback)
        }
    }

    func testScanPreservesARepeatedRecentFailureWithTheSameMessage() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var failEncoding = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let scanner = ControlledBrowserScanner(results: [[safari]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        failEncoding = true
        XCTAssertEqual(repository.recordSelection(safari), .storageFailure(.encodingFailed))
        let scan = repository.rescan()
        await waitForScanCount(1, scanner: scanner)
        XCTAssertEqual(repository.recordSelection(safari), .storageFailure(.encodingFailed))
        failEncoding = false
        scanner.finish(0)
        let result = await scan.value
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(repository.operationFeedback, .recentSaveFailed(.encodingFailed))
        XCTAssertNil(repository.recentBrowserIdentifier)

        XCTAssertEqual(repository.recordSelection(safari), .applied)
        XCTAssertEqual(repository.recentBrowserIdentifier, safari.id)
        XCTAssertNil(repository.operationFeedback)
    }

    func testMoveTargetsDisplayedBrowserWhenStoredOrderHasChanged() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let a = makeBrowser(name: "A", bundleIdentifier: "com.example.a")
        let b = makeBrowser(name: "B", bundleIdentifier: "com.example.b")
        let c = makeBrowser(name: "C", bundleIdentifier: "com.example.c")
        try preferences.saveScannedBrowsers([a, b, c], at: Date())
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        XCTAssertEqual(repository.browsers.map(\.id), [a.id, b.id, c.id])

        // The fresh read differs from the visible rows; row 0 still means A to the user.
        try preferences.save([
            ConfiguredBrowser(browser: b, isEnabled: false),
            ConfiguredBrowser(browser: a, isEnabled: true),
            ConfiguredBrowser(browser: c, isEnabled: true)
        ])
        XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 0), to: 3), .applied)
        XCTAssertEqual(repository.browsers.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(repository.browsers.map(\.isEnabled), [false, true, true])
        let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        XCTAssertEqual(reloaded.browsers.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(reloaded.browsers.map(\.isEnabled), [false, true, true])
    }

    func testMoveUsesDisplayedOrderForSameNameBrowsersAfterScanAndReset() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let orion = makeBrowser(name: "Orion", bundleIdentifier: "com.kagi.kagimacOS")
        let orionRC = makeBrowser(name: "Orion", bundleIdentifier: "com.kagi.kagimacOS.RC")
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: [orionRC, orion]), preferences: preferences)
        _ = await repository.rescan().value

        for afterReset in [false, true] {
            if afterReset { XCTAssertEqual(repository.resetPreferences(), .applied) }
            XCTAssertTrue(try preferences.load().orderedBundleIdentifiers.isEmpty)
            let displayed = repository.browsers.map(\.id)
            XCTAssertEqual(displayed.count, 2)
            guard displayed.count == 2 else { return }
            XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 0), to: 2), .applied)
            XCTAssertEqual(repository.browsers.map(\.id), [displayed[1], displayed[0]])
            let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
            XCTAssertEqual(reloaded.browsers.map(\.id), [displayed[1], displayed[0]])
        }
    }

    func testSuccessfulScanRetryReplacesEarlierWriteFailureFeedback() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var failEncoding = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: Date())
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: [safari]), preferences: preferences)
        failEncoding = true
        let failed = await repository.rescan().value
        XCTAssertEqual(failed, .storageFailure(.encodingFailed))
        failEncoding = false
        let accepted = await repository.rescan().value
        XCTAssertEqual(accepted, .applied)
        XCTAssertNil(repository.operationFeedback)
    }

    func testResetInvalidatesOldScanRegardlessOfPhysicalCompletionOrder() async throws {
        for oldFinishesFirst in [true, false] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            let oldBrowser = makeBrowser(name: "Old", bundleIdentifier: "com.example.old")
            let newBrowser = makeBrowser(name: "New", bundleIdentifier: "com.example.new")
            let scanner = ControlledBrowserScanner(results: [[oldBrowser], [newBrowser]])
            defer { scanner.finishAll() }
            let preferences = BrowserPreferences(userDefaults: defaults)
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            let oldTask = repository.rescan()
            await waitForScanCount(1, scanner: scanner)
            defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey)

            XCTAssertEqual(repository.resetPreferences(), .applied)
            let invalidated = await oldTask.value
            XCTAssertEqual(invalidated, .superseded)
            let newTask = repository.rescan()
            await waitForScanCount(2, scanner: scanner)

            if oldFinishesFirst {
                scanner.finish(0)
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(repository.isScanning)
                XCTAssertTrue(repository.browsers.isEmpty)
                // Reusing the new request must not create a third scan.
                let reusedTask = repository.rescan()
                scanner.finish(1)
                let reusedResult = await reusedTask.value
                XCTAssertEqual(reusedResult, .applied)
            } else {
                scanner.finish(1)
            }
            let newResult = await newTask.value
            XCTAssertEqual(newResult, .applied)
            if !oldFinishesFirst {
                scanner.finish(0)
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(repository.browsers.map(\.id), [newBrowser.id])
            XCTAssertEqual(try preferences.cachedScannedBrowsers().map(\.id), [newBrowser.id])
            XCTAssertFalse(repository.isScanning)
            XCTAssertEqual(scanner.scanCount, 2)
        }
    }

    func testScanMergesChoicesAcceptedWhileDiscoveryIsInFlight() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        try preferences.saveScannedBrowsers([safari, firefox], at: Date())
        let scanner = ControlledBrowserScanner(results: [[firefox, safari]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let task = repository.rescan()
        await waitForScanCount(1, scanner: scanner)
        let (app, cleanupApp) = try makeApplicationBundle(
            name: "Work", bundleIdentifier: "com.example.work", urlSchemes: ["https"]
        )
        defer { cleanupApp() }
        guard case let .added(custom) = repository.addCustomBrowser(appURL: app) else {
            return XCTFail("Expected accepted custom app")
        }
        XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 2), to: 0), .applied)
        XCTAssertEqual(repository.setEnabled(false, for: safari.id), .applied)
        XCTAssertEqual(repository.recordSelection(custom), .applied)
        let accepted = repository.browsers
        let reusedTask = repository.rescan()
        scanner.finish(0)
        let result = await task.value
        let reusedResult = await reusedTask.value
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(reusedResult, .applied)
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(repository.browsers, accepted)
        XCTAssertEqual(repository.recentBrowserIdentifier, custom.id)
        let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        XCTAssertEqual(reloaded.browsers, accepted)
        XCTAssertEqual(reloaded.recentBrowserIdentifier, custom.id)
    }

    func testCorruptionDiscoveredAtScanCompletionPreservesBytesAndRejectsResults() async {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let scanner = ControlledBrowserScanner(results: [[safari]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: BrowserPreferences(userDefaults: defaults))
        let task = repository.rescan()
        await waitForScanCount(1, scanner: scanner)
        let bytes = Data("corrupted-during-scan".utf8)
        defaults.set(bytes, forKey: BrowserPreferences.storageKey)
        scanner.finish(0)
        let result = await task.value
        XCTAssertEqual(result, .storageFailure(.unreadableConfiguration))
        XCTAssertEqual(repository.availability, .configurationUnreadable)
        XCTAssertTrue(repository.enabledBrowsers.isEmpty)
        XCTAssertFalse(repository.isScanning)
        XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
    }

    func testHealthyResetKeepsCacheAndNormalMutationsSurviveReload() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        try preferences.saveScannedBrowsers([safari, firefox], at: Date())
        let scanner = StubBrowserScanner(result: [])
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let (app, cleanupApp) = try makeApplicationBundle(
            name: "Work", bundleIdentifier: "com.example.work", urlSchemes: ["https"]
        )
        defer { cleanupApp() }
        let added = repository.addCustomBrowser(appURL: app)
        XCTAssertEqual(repository.addCustomBrowser(appURL: app), added)
        XCTAssertEqual(repository.browsers.count, 3)
        XCTAssertEqual(repository.setEnabled(false, for: safari.id), .applied)
        XCTAssertEqual(repository.setEnabled(false, for: safari.id), .unchanged)
        XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 0), to: 3), .applied)
        XCTAssertEqual(repository.removeCustomBrowser(id: "com.example.work"), .applied)
        let reloaded = BrowserRepository(scanner: scanner, preferences: preferences)
        XCTAssertEqual(reloaded.browsers, repository.browsers)
        XCTAssertEqual(repository.resetPreferences(), .applied)
        XCTAssertEqual(Set(repository.enabledBrowsers.map(\.id)), [safari.id, firefox.id])
        XCTAssertEqual(scanner.scanCount, 0)
    }

    private func waitForScanCount(_ count: Int, scanner: ControlledBrowserScanner) async {
        for _ in 0..<1_000 where scanner.scanCount < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(scanner.scanCount, count)
    }

    func testEncodingFailurePreservesAcceptedListRecentAndBytes() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var failEncoding = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if failEncoding { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let custom = makeBrowser(name: "Work", bundleIdentifier: "com.example.work", isCustom: true)
        try preferences.saveScannedBrowsers([safari], at: Date())
        try preferences.saveCustomBrowser(custom)
        try preferences.saveRecentBrowserIdentifier(safari.id)
        let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        let accepted = repository.browsers
        let bytes = defaults.data(forKey: BrowserPreferences.storageKey)
        let (app, cleanupApp) = try makeApplicationBundle(
            name: "New Browser", bundleIdentifier: "com.example.new", urlSchemes: ["https"]
        )
        defer { cleanupApp() }
        failEncoding = true

        XCTAssertEqual(repository.setEnabled(false, for: safari.id), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 0), to: 2), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.removeCustomBrowser(id: custom.id), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.addCustomBrowser(appURL: app), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.recordSelection(custom), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.operationFeedback, .recentSaveFailed(.encodingFailed))
        let scanResult = await repository.rescan().value
        XCTAssertEqual(scanResult, .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.resetPreferences(), .storageFailure(.encodingFailed))

        XCTAssertEqual(repository.browsers, accepted)
        XCTAssertEqual(repository.availability, .ready)
        XCTAssertEqual(repository.recentBrowserIdentifier, safari.id)
        XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
        let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        XCTAssertEqual(reloaded.browsers, accepted)
        XCTAssertEqual(reloaded.recentBrowserIdentifier, safari.id)
    }

    func testEveryMutationDetectsCorruptionIncludingUnchangedRequests() async throws {
        for operation in 0..<7 {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            let preferences = BrowserPreferences(userDefaults: defaults)
            let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
            let custom = makeBrowser(name: "Work", bundleIdentifier: "com.example.work", isCustom: true)
            try preferences.saveScannedBrowsers([safari], at: Date())
            try preferences.saveCustomBrowser(custom)
            let scanner = StubBrowserScanner(result: [safari])
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            let bytes = Data("invalid-settings".utf8)
            defaults.set(bytes, forKey: BrowserPreferences.storageKey)
            let result: BrowserMutationResult
            switch operation {
            case 0: result = repository.setEnabled(false, for: safari.id)
            case 1: result = repository.setEnabled(true, for: safari.id)
            case 2: result = repository.moveBrowser(from: IndexSet(integer: 0), to: 2)
            case 3: result = repository.moveBrowser(from: IndexSet(integer: 0), to: 0)
            case 4: result = repository.removeCustomBrowser(id: custom.id)
            case 5: result = repository.recordSelection(safari)
            default: result = await repository.rescan().value
            }
            XCTAssertEqual(result, .storageFailure(.unreadableConfiguration), "operation \(operation)")
            XCTAssertFalse(result.wasAccepted)
            XCTAssertEqual(repository.availability, .configurationUnreadable)
            XCTAssertTrue(DestinationCatalog(enabledBrowsers: repository.enabledBrowsers).destinations.isEmpty)
            XCTAssertNil(repository.recentBrowserIdentifier)
            XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
            let rescan = await repository.rescan().value
            XCTAssertEqual(rescan, .storageFailure(.unreadableConfiguration))
            XCTAssertFalse(repository.isScanning)
            XCTAssertEqual(scanner.scanCount, 0)
        }
    }

    func testAddingValidAppToUnreadableConfigurationIsRejected() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let bytes = Data("broken-browser-settings".utf8)
        defaults.set(bytes, forKey: BrowserPreferences.storageKey)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: BrowserPreferences(userDefaults: defaults)
        )
        let (app, cleanupApp) = try makeApplicationBundle(
            name: "Test Browser", bundleIdentifier: "com.example.test", urlSchemes: ["https"]
        )
        defer { cleanupApp() }

        if case .added = repository.addCustomBrowser(appURL: app) {
            XCTFail("A refused write must not report that the app was added")
        }
        XCTAssertTrue(repository.enabledBrowsers.isEmpty)
        XCTAssertFalse(SetupGuideActivation.isComplete(isDefaultBrowser: true, hasUsableBrowsers: !repository.enabledBrowsers.isEmpty))
        XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
    }

    func testUnreadableConfigurationDoesNotStartOrWaitForDiscovery() async {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let bytes = Data("broken-browser-settings".utf8)
        defaults.set(bytes, forKey: BrowserPreferences.storageKey)
        let scanner = StubBrowserScanner(result: [])
        let repository = BrowserRepository(
            scanner: scanner,
            preferences: BrowserPreferences(userDefaults: defaults)
        )

        XCTAssertFalse(repository.isScanning)
        _ = await repository.rescan().value
        XCTAssertEqual(scanner.scanCount, 0)
        XCTAssertTrue(repository.enabledBrowsers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
    }

    func testFreshCacheIsAvailableImmediatelyWithoutScanning() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try preferences.saveScannedBrowsers([safari], at: now)
        let scanner = StubBrowserScanner(result: [])

        let repository = BrowserRepository(
            scanner: scanner,
            preferences: preferences,
            cacheMaximumAge: 3_600,
            now: { now.addingTimeInterval(60) }
        )

        XCTAssertEqual(repository.browsers.map(\.id), [safari.id])
        XCTAssertFalse(repository.isScanning)
        XCTAssertEqual(scanner.scanCount, 0)
    }

    func testMissingCacheScansOffMainThreadAndPublishesResults() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        let scanner = StubBrowserScanner(result: [firefox])
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)

        _ = await repository.rescan().value

        XCTAssertEqual(repository.browsers.map(\.id), [firefox.id])
        XCTAssertEqual(try preferences.cachedScannedBrowsers().map(\.id), [firefox.id])
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertFalse(scanner.ranOnMainThread)
        XCTAssertFalse(repository.isScanning)
    }

    func testDisablingLastEnabledBrowserIsRejected() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let now = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox", priority: 20)
        try preferences.saveScannedBrowsers([safari, firefox], at: now)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            now: { now }
        )

        XCTAssertEqual(repository.setEnabled(false, for: safari.id), .applied)
        XCTAssertEqual(repository.setEnabled(false, for: firefox.id), .wouldLeaveNoEnabledBrowser)
        XCTAssertEqual(repository.enabledBrowsers.map(\.id), [firefox.id])
    }

    func testRemovingLastEnabledCustomBrowserIsRejected() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let custom = makeBrowser(
            name: "Work Browser",
            bundleIdentifier: "com.example.work-browser",
            isCustom: true,
            priority: 1_000
        )
        try preferences.saveCustomBrowser(custom)
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences
        )

        XCTAssertEqual(repository.removeCustomBrowser(id: custom.id), .wouldLeaveNoEnabledBrowser)
        XCTAssertEqual(repository.browsers.map(\.id), [custom.id])
    }

    func testAvailabilitySuggestsRecoveryWhenEveryBrowserIsDisabled() throws {
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

        XCTAssertEqual(
            repository.availability,
            .allDisabled(suggestedBrowser: safari)
        )
    }

    func testCustomAppMustDeclareWebURLSupport() throws {
        let (preferences, cleanupPreferences) = makeIsolatedPreferences()
        defer { cleanupPreferences() }

        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences
        )
        let (unsupportedApp, cleanupUnsupportedApp) = try makeApplicationBundle(
            name: "Notes App",
            bundleIdentifier: "com.example.notes",
            urlSchemes: nil
        )
        defer { cleanupUnsupportedApp() }
        let (browserApp, cleanupBrowserApp) = try makeApplicationBundle(
            name: "Test Browser",
            bundleIdentifier: "com.example.test-browser",
            urlSchemes: ["https"]
        )
        defer { cleanupBrowserApp() }
        let (appWithoutExecutable, cleanupAppWithoutExecutable) = try makeApplicationBundle(
            name: "Broken Browser",
            bundleIdentifier: "com.example.broken-browser",
            urlSchemes: ["https"],
            includeExecutable: false
        )
        defer { cleanupAppWithoutExecutable() }

        XCTAssertEqual(
            repository.addCustomBrowser(appURL: appWithoutExecutable),
            .invalidApplication
        )

        XCTAssertEqual(
            repository.addCustomBrowser(appURL: unsupportedApp),
            .doesNotHandleWebURLs
        )

        guard case let .added(browser) = repository.addCustomBrowser(appURL: browserApp) else {
            XCTFail("Expected a browser app with HTTPS support to be added")
            return
        }
        XCTAssertEqual(browser.name, "Test Browser")
        XCTAssertEqual(browser.bundleIdentifier, "com.example.test-browser")
    }

    func testCurrentApplicationCannotBeAddedAsACustomBrowser() throws {
        let (preferences, cleanupPreferences) = makeIsolatedPreferences()
        defer { cleanupPreferences() }
        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences
        )
        let (currentApp, cleanupCurrentApp) = try makeApplicationBundle(
            name: "Eligo",
            bundleIdentifier: LaunchServicesBrowserManager.bundleIdentifier,
            urlSchemes: ["http", "https"]
        )
        defer { cleanupCurrentApp() }

        XCTAssertEqual(repository.addCustomBrowser(appURL: currentApp), .currentApplicationNotAllowed)
        XCTAssertTrue(repository.browsers.isEmpty)
    }

    func testPersistedCurrentApplicationAliasIsFilteredByResolvedAppURL() throws {
        let (preferences, cleanupPreferences) = makeIsolatedPreferences()
        defer { cleanupPreferences() }
        let currentAppURL = URL(fileURLWithPath: "/Applications/Eligo.app", isDirectory: true)
        let persistedAlias = Browser(
            name: "Renamed Eligo",
            bundleIdentifier: "com.example.eligo-alias",
            appURL: currentAppURL,
            priority: 1_000,
            isCustom: true
        )
        try preferences.saveCustomBrowser(persistedAlias)

        let repository = BrowserRepository(
            scanner: StubBrowserScanner(result: []),
            preferences: preferences,
            currentApplicationBundleIdentifier: LaunchServicesBrowserManager.bundleIdentifier,
            currentApplicationURL: currentAppURL
        )

        XCTAssertTrue(repository.browsers.isEmpty)
    }

    func testStaleCacheIsShownImmediatelyThenRefreshedInBackground() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let cacheDate = Date(timeIntervalSince1970: 10_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let firefox = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        try preferences.saveScannedBrowsers([safari], at: cacheDate)
        let scanner = StubBrowserScanner(result: [firefox])
        let repository = BrowserRepository(
            scanner: scanner,
            preferences: preferences,
            cacheMaximumAge: 3_600,
            now: { cacheDate.addingTimeInterval(3_601) }
        )

        XCTAssertEqual(repository.browsers.map(\.id), [safari.id])
        XCTAssertTrue(repository.isScanning)

        _ = await repository.rescan().value

        XCTAssertEqual(repository.browsers.map(\.id), [firefox.id])
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertFalse(scanner.ranOnMainThread)
    }
}
