import Foundation
import XCTest
@testable import Eligo

@MainActor
final class UnavailableBrowserTests: XCTestCase {
    func testScannedOnlyLocationRestoredBeforeEmptyScanPublishesIsNotLost() async throws {
        for automatic in [true, false] {
            let (preferences, cleanup) = makeIsolatedPreferences()
            defer { cleanup() }
            let (app, removeApp) = try makeApplicationBundle(name: "During Scan", bundleIdentifier: "test.during-scan", urlSchemes: ["https"])
            defer { removeApp() }
            let browser = Browser(name: "During Scan", bundleIdentifier: "test.during-scan", appURL: app, priority: 1)
            try preferences.saveScannedBrowsers([browser], at: Date())
            let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
            let bytes = try Data(contentsOf: executable)
            let scanner = ControlledBrowserScanner(results: [[], []])
            defer { scanner.finishAll() }
            let repository = BrowserRepository(scanner: scanner, preferences: preferences)
            if !automatic { repository.rescan() }
            try FileManager.default.removeItem(at: executable)
            repository.refreshInstallations()
            let first = try XCTUnwrap(repository.discoveryTask)
            await waitForBrowserCondition { scanner.scanCount == 1 }
            try bytes.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            if !automatic {
                repository.refreshInstallations()
                XCTAssertEqual(repository.enabledBrowsers, [browser])
            }
            scanner.finish(0)
            _ = await first.value
            XCTAssertEqual(repository.enabledBrowsers, [browser])
            XCTAssertEqual(try preferences.cachedScannedBrowsers(), [browser])
            try FileManager.default.removeItem(at: executable)
            repository.refreshInstallations()
            let second = try XCTUnwrap(repository.discoveryTask)
            scanner.finish(1)
            _ = await second.value
            XCTAssertEqual(scanner.scanCount, 2)
        }
    }

    func testScannedOnlyLocationRecoversAfterEmptyScanAndRepositoryReload() async throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: defaults)
        let (app, removeApp) = try makeApplicationBundle(name: "Scanned Only", bundleIdentifier: "test.scanned-only", urlSchemes: ["https"])
        defer { removeApp() }
        let browser = Browser(name: "Scanned Only", bundleIdentifier: "test.scanned-only", appURL: app, priority: 1)
        try preferences.saveScannedBrowsers([browser], at: Date())
        let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
        let bytes = try Data(contentsOf: executable)
        try FileManager.default.removeItem(at: executable)
        let scanner = ControlledBrowserScanner(results: [[], []])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let first = try XCTUnwrap(repository.discoveryTask)
        scanner.finish(0)
        _ = await first.value
        XCTAssertEqual(repository.availability, .noneDetected)
        XCTAssertTrue(repository.browsers.isEmpty)
        XCTAssertEqual(try preferences.cachedScannedBrowsers(), [browser], "Keep unavailable location metadata for future checkpoints")
        try bytes.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(repository.browsers.isEmpty, "Recovery is observed only at a checkpoint")
        repository.refreshInstallations()
        XCTAssertEqual(repository.enabledBrowsers, [browser])
        XCTAssertFalse(repository.isScanning)
        let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: BrowserPreferences(userDefaults: defaults))
        XCTAssertEqual(reloaded.enabledBrowsers, [browser])
        try FileManager.default.removeItem(at: executable)
        repository.refreshInstallations()
        let second = try XCTUnwrap(repository.discoveryTask)
        scanner.finish(1)
        _ = await second.value
        XCTAssertEqual(scanner.scanCount, 2)
        XCTAssertTrue(repository.enabledBrowsers.isEmpty)
    }

    func testPrivatePathIdentityAndQuotaSurviveWholeApplicationRemoval() async throws {
        let (source, removeSource) = try makeApplicationBundle(name: "Private Path", bundleIdentifier: "test.private-path", urlSchemes: ["https"])
        defer { removeSource() }
        let root = URL(fileURLWithPath: "/private/tmp/EligoUnavailableBrowser-\(UUID())", isDirectory: true)
        let app = root.appendingPathComponent("Private Path.app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: source, to: app)
        let custom = Browser(name: "Private Path", bundleIdentifier: "test.private-path", appURL: app, priority: 1, isCustom: true)
        let identity = custom.installationID
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        try preferences.saveScannedBrowsers([custom], at: Date())
        try preferences.saveCustomBrowser(custom)
        let scanner = ControlledBrowserScanner(results: [[], []])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        for cycle in 0..<2 {
            try FileManager.default.removeItem(at: app)
            XCTAssertEqual(custom.installationID, identity, "File existence must not change the quota key")
            repository.refreshInstallations()
            guard let scan = repository.discoveryTask else { XCTFail("Every restored-then-missing cycle gets one scan"); break }
            scanner.finish(cycle)
            _ = await scan.value
            try FileManager.default.copyItem(at: source, to: app)
            XCTAssertEqual(custom.installationID, identity)
            repository.refreshInstallations()
            XCTAssertEqual(repository.enabledBrowsers.map(\.id), [custom.id])
        }
        XCTAssertEqual(scanner.scanCount, 2)
    }

    func testAcceptedScanObservingSamePathRecoveryRenewsAutomaticQuota() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let (app, cleanupApp) = try makeApplicationBundle(name: "Scan Recovery", bundleIdentifier: "test.scan-recovery", urlSchemes: ["https"])
        defer { cleanupApp() }
        let custom = Browser(name: "Scan Recovery", bundleIdentifier: "test.scan-recovery", appURL: app, priority: 1, isCustom: true)
        try preferences.saveCustomBrowser(custom)
        let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
        let contents = try Data(contentsOf: executable)
        try FileManager.default.removeItem(at: executable)
        let scanner = ControlledBrowserScanner(results: [[], [custom], []])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let initial = try XCTUnwrap(repository.discoveryTask)
        scanner.finish(0)
        _ = await initial.value
        try contents.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manual = repository.rescan()
        scanner.finish(1)
        _ = await manual.value
        XCTAssertEqual(repository.enabledBrowsers, [custom])
        try FileManager.default.removeItem(at: executable)
        repository.refreshInstallations()
        XCTAssertNotNil(repository.discoveryTask, "A successful scan already observed restoration; no extra view refresh is required to renew quota")
        if let next = repository.discoveryTask { scanner.finish(2); _ = await next.value }
    }

    func testUnrelatedChoicesPreserveUnavailableOrderSlotAndInFlightScanDoesNotUndoThem() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let a = makeBrowser(name: "A", bundleIdentifier: "test.order.a")
        let b = makeBrowser(name: "B", bundleIdentifier: "test.order.b")
        let missing = Browser(name: "Missing", bundleIdentifier: "test.order.missing", appURL: URL(fileURLWithPath: "/tmp/Eligo-order-\(UUID()).app", isDirectory: true), priority: 1, isCustom: true)
        try preferences.saveScannedBrowsers([a, b], at: Date())
        try preferences.saveCustomBrowser(missing)
        try preferences.save([
            ConfiguredBrowser(browser: a, isEnabled: true), ConfiguredBrowser(browser: missing, isEnabled: false), ConfiguredBrowser(browser: b, isEnabled: true)
        ])
        let scanner = ControlledBrowserScanner(results: [[a, b]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let scan = try XCTUnwrap(repository.discoveryTask)
        XCTAssertEqual(repository.setEnabled(false, for: a.id), .applied)
        XCTAssertEqual(try preferences.load().orderedBundleIdentifiers, [a.id, missing.id, b.id])
        XCTAssertEqual(repository.moveBrowser(from: IndexSet(integer: 0), to: 2), .applied)
        XCTAssertEqual(repository.recordSelection(b), .applied)
        scanner.finish(0)
        _ = await scan.value
        let snapshot = try preferences.load()
        XCTAssertEqual(snapshot.orderedBundleIdentifiers, [b.id, missing.id, a.id])
        XCTAssertEqual(Set(snapshot.disabledBundleIdentifiers), [a.id, missing.id])
        XCTAssertEqual(snapshot.recentBrowserIdentifier, b.id)
        XCTAssertEqual(try preferences.customBrowsers(), [missing])
    }

    func testInstallationChecksUseCurrentDiskIdentityAndRequireAnExecutableFile() throws {
        let (app, cleanup) = try makeApplicationBundle(name: "Identity", bundleIdentifier: "test.original", urlSchemes: ["https"])
        defer { cleanup() }
        let browser = Browser(name: "Identity", bundleIdentifier: "test.original", appURL: app, priority: 1)
        XCTAssertTrue(browser.isAvailable)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = "test.replacement"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        XCTAssertFalse(browser.isAvailable, "Foundation may cache Bundle metadata; availability must read the current disk identity")

        let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        XCTAssertNil(Browser.application(at: app), "An executable directory is not an executable file")
    }

    func testUnavailableCustomDoesNotHideValidScannedInstallation() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let (oldApp, removeOld) = try makeApplicationBundle(
            name: "Old Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"]
        )
        defer { removeOld() }
        let (newApp, removeNew) = try makeApplicationBundle(
            name: "New Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"]
        )
        defer { removeNew() }
        let custom = Browser(name: "Old Chrome", bundleIdentifier: "com.google.Chrome", appURL: oldApp, priority: 1000, isCustom: true)
        let scanned = Browser(name: "New Chrome", bundleIdentifier: custom.id, appURL: newApp, priority: 10)
        let preferences = BrowserPreferences(userDefaults: defaults)
        try preferences.saveScannedBrowsers([scanned], at: Date())
        try preferences.saveCustomBrowser(custom)
        try FileManager.default.removeItem(at: oldApp.appendingPathComponent("Contents/MacOS/TestExecutable"))

        let repository = BrowserRepository(scanner: StubBrowserScanner(result: [scanned]), preferences: preferences)

        XCTAssertEqual(repository.enabledBrowsers, [scanned])
        XCTAssertEqual(try preferences.customBrowsers(), [custom], "Keep the unavailable record for explicit management")
        XCTAssertEqual(DestinationCatalog(enabledBrowsers: repository.enabledBrowsers).normalDestinations.first?.browser.appURL, newApp)
        XCTAssertEqual(repository.unavailableCustomBrowsers, [custom])
        XCTAssertNotEqual(custom.installationID, scanned.installationID)
    }

    func testScannerSkipsInvalidRegisteredCandidateBeforeSelectingDirectoryInstallation() throws {
        let (dead, cleanupDead) = try makeApplicationBundle(name: "Registered Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"], includeExecutable: false)
        let (live, cleanupLive) = try makeApplicationBundle(name: "Directory Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
        defer { cleanupDead(); cleanupLive() }
        let scanner = BrowserScanner(searchRoots: [live.deletingLastPathComponent()], registeredApplicationURLs: { [dead] })
        XCTAssertEqual(scanner.scan().map { $0.appURL.resolvingSymlinksInPath() }, [live.resolvingSymlinksInPath()])
    }

    func testRemovingUnavailableRecordPreservesSameIDChoicesRoutingAndReload() async throws {
        for enabled in [false, true] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            let (oldURL, cleanupOld) = try makeApplicationBundle(name: "Custom Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
            let (newURL, cleanupNew) = try makeApplicationBundle(name: "Scanned Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
            defer { cleanupOld(); cleanupNew() }
            let custom = Browser(name: "Custom Chrome", bundleIdentifier: "com.google.Chrome", appURL: oldURL, priority: 1000, isCustom: true)
            let scanned = Browser(name: "Scanned Chrome", bundleIdentifier: custom.id, appURL: newURL, priority: 1)
            let other = makeBrowser(name: "Other", bundleIdentifier: "test.other")
            let preferences = BrowserPreferences(userDefaults: defaults)
            try preferences.saveScannedBrowsers([scanned, other], at: Date())
            try preferences.saveCustomBrowser(custom)
            try preferences.save([ConfiguredBrowser(browser: other, isEnabled: true), ConfiguredBrowser(browser: custom, isEnabled: enabled)])
            try preferences.saveRecentBrowserIdentifier(custom.id)
            let routing = RoutingPreferencesStore(userDefaults: defaults)
            let normal = OpenDestinationID(browserID: custom.id, mode: .normal)
            try routing.replace(with: RoutingSettings(
                scope: .onlyThese(matchers: [try DomainMatcher(host: "inside.example", includesSubdomains: false)], bypassDestinationID: normal),
                rules: [DomainRule(matcher: try DomainMatcher(host: "inside.example", includesSubdomains: false), destinationID: OpenDestinationID(browserID: custom.id, mode: .privateBrowsing))],
                alwaysShowChooser: true
            ))
            let routingBytes = defaults.data(forKey: RoutingPreferencesStore.storageKey)
            try FileManager.default.removeItem(at: oldURL)
            let repository = BrowserRepository(scanner: StubBrowserScanner(result: [scanned, other]), preferences: preferences)
            _ = await repository.rescan().value
            let before = try preferences.load()
            XCTAssertEqual(repository.removeUnavailableCustomBrowser(custom.installationID), .applied)
            let after = try preferences.load()
            XCTAssertTrue(after.customBrowsers.isEmpty)
            XCTAssertEqual(after.orderedBundleIdentifiers, before.orderedBundleIdentifiers)
            XCTAssertEqual(after.disabledBundleIdentifiers, before.disabledBundleIdentifiers)
            XCTAssertEqual(after.recentBrowserIdentifier, before.recentBrowserIdentifier)
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), routingBytes)
            let reloaded = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: BrowserPreferences(userDefaults: defaults))
            XCTAssertEqual(reloaded.browsers.map(\.id), [other.id, scanned.id])
            XCTAssertEqual(reloaded.browsers.map(\.isEnabled), [true, enabled])
            XCTAssertEqual(reloaded.browsers.last?.browser.appURL, newURL)
            XCTAssertEqual(reloaded.recentBrowserIdentifier, custom.id)
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, routing.settings)
            if enabled { XCTAssertNotNil(try reloaded.currentNormalDestination(for: normal)) }
        }
    }

    func testOnlyUnavailableCustomCanBeRemovedAndDoesNotSuggestEnablingIt() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let custom = Browser(name: "Missing", bundleIdentifier: "test.missing", appURL: URL(fileURLWithPath: "/tmp/Eligo-nonexistent-\(UUID()).app", isDirectory: true), priority: 1, isCustom: true)
        try preferences.saveCustomBrowser(custom)
        try preferences.save([ConfiguredBrowser(browser: custom, isEnabled: false)])
        try preferences.saveRecentBrowserIdentifier(custom.id)
        let scanner = ControlledBrowserScanner(results: [[]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        XCTAssertEqual(repository.availability, .noneDetected)
        XCTAssertTrue(repository.browsers.isEmpty)
        XCTAssertEqual(repository.unavailableCustomBrowsers, [custom])
        XCTAssertEqual(repository.removeUnavailableCustomBrowser(custom.installationID), .applied)
        XCTAssertTrue(try preferences.customBrowsers().isEmpty)
        XCTAssertTrue(repository.unavailableCustomBrowsers.isEmpty)
        let saved = try preferences.load()
        XCTAssertEqual(saved.orderedBundleIdentifiers, [custom.id])
        XCTAssertEqual(saved.disabledBundleIdentifiers, [custom.id])
        XCTAssertEqual(saved.recentBrowserIdentifier, custom.id)
    }

    func testScannedCacheAndCustomRemovalAreIndependentAndManualScanFindsReplacement() async throws {
        for cachedOldPath in [true, false] {
            let (preferences, cleanup) = makeIsolatedPreferences()
            defer { cleanup() }
            let (oldURL, cleanupOld) = try makeApplicationBundle(name: "Old Firefox", bundleIdentifier: "org.mozilla.firefox", urlSchemes: ["https"])
            let (newURL, cleanupNew) = try makeApplicationBundle(name: "New Firefox", bundleIdentifier: "org.mozilla.firefox", urlSchemes: ["https"])
            defer { cleanupOld(); cleanupNew() }
            let old = Browser(name: "Old Firefox", bundleIdentifier: "org.mozilla.firefox", appURL: oldURL, priority: 1, isCustom: true)
            let other = makeBrowser(name: "Other", bundleIdentifier: "test.control")
            let cachedOld = Browser(name: old.name, bundleIdentifier: old.id, appURL: oldURL, priority: 1)
            try preferences.saveScannedBrowsers(cachedOldPath ? [cachedOld, other] : [other], at: Date())
            try preferences.saveCustomBrowser(old)
            let actualScanner = BrowserScanner(searchRoots: [newURL.deletingLastPathComponent()], registeredApplicationURLs: { [oldURL] })
            let repository = BrowserRepository(scanner: actualScanner, preferences: preferences)
            XCTAssertEqual(repository.removeCustomBrowser(id: old.id), .applied)
            XCTAssertEqual(try preferences.cachedScannedBrowsers().contains(where: { $0.appURL == oldURL }), cachedOldPath)
            try FileManager.default.removeItem(at: oldURL)
            XCTAssertTrue(repository.refreshInstallations().wasAccepted)
            XCTAssertFalse(repository.browsers.contains(where: { $0.browser.appURL == oldURL }))
            _ = await repository.rescan().value
            XCTAssertEqual(repository.enabledBrowsers.map { $0.appURL.resolvingSymlinksInPath() }, [newURL.resolvingSymlinksInPath()])
            XCTAssertTrue(repository.unavailableCustomBrowsers.isEmpty)
            XCTAssertEqual(try preferences.cachedScannedBrowsers().map { $0.appURL.resolvingSymlinksInPath() }, [newURL.resolvingSymlinksInPath()])
        }
    }

    func testAutomaticQuotaSurvivesRefreshManualRescanAndViewLifetimeAndRenewsAfterRecoveryOrRestart() async throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let (app, cleanupApp) = try makeApplicationBundle(name: "Recoverable", bundleIdentifier: "test.recoverable", urlSchemes: ["https"])
        defer { cleanupApp() }
        let custom = Browser(name: "Recoverable", bundleIdentifier: "test.recoverable", appURL: app, priority: 1, isCustom: true)
        try preferences.saveCustomBrowser(custom)
        let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
        try FileManager.default.removeItem(at: executable)
        let scanner = ControlledBrowserScanner(results: [[], [], []])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        await waitForBrowserCondition { scanner.scanCount == 1 }
        let initial = repository.rescan()
        for _ in 0..<5 { repository.refreshInstallations(); _ = repository.availability; _ = repository.browsers }
        XCTAssertEqual(scanner.scanCount, 1)
        scanner.finish(0)
        _ = await initial.value
        for _ in 0..<5 { repository.refreshInstallations() }
        XCTAssertFalse(repository.isScanning)
        let manual = repository.rescan()
        await waitForBrowserCondition { scanner.scanCount == 2 }
        scanner.finish(1)
        _ = await manual.value
        repository.refreshInstallations()
        XCTAssertFalse(repository.isScanning, "Manual scanning does not replenish the automatic quota")

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        repository.refreshInstallations()
        XCTAssertEqual(repository.enabledBrowsers, [custom])
        try FileManager.default.removeItem(at: executable)
        repository.refreshInstallations()
        let next = try XCTUnwrap(repository.discoveryTask)
        await waitForBrowserCondition { scanner.scanCount == 3 }
        scanner.finish(2)
        _ = await next.value
        repository.refreshInstallations()
        XCTAssertFalse(repository.isScanning)
        let restartedScanner = ControlledBrowserScanner(results: [[]])
        defer { restartedScanner.finishAll() }
        let restarted = BrowserRepository(scanner: restartedScanner, preferences: preferences)
        XCTAssertTrue(restarted.isScanning)
        await waitForBrowserCondition { restartedScanner.scanCount == 1 }
    }

    func testUnavailableRemovalFailurePreservesRecordAndAllAcceptedPreferences() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        var fail = false
        let preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if fail { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let missing = Browser(name: "Missing", bundleIdentifier: "test.missing", appURL: URL(fileURLWithPath: "/tmp/Eligo-missing-\(UUID()).app", isDirectory: true), priority: 1, isCustom: true)
        try preferences.saveCustomBrowser(missing)
        let scanner = ControlledBrowserScanner(results: [[]])
        defer { scanner.finishAll() }
        let repository = BrowserRepository(scanner: scanner, preferences: preferences)
        let bytes = defaults.data(forKey: BrowserPreferences.storageKey)
        fail = true
        XCTAssertEqual(repository.removeUnavailableCustomBrowser(missing.installationID), .storageFailure(.encodingFailed))
        XCTAssertEqual(repository.unavailableCustomBrowsers, [missing])
        XCTAssertEqual(defaults.data(forKey: BrowserPreferences.storageKey), bytes)
        defaults.set("unreadable", forKey: BrowserPreferences.storageKey)
        XCTAssertEqual(repository.refreshInstallations(), .storageFailure(.unreadableConfiguration))
        XCTAssertEqual(repository.availability, .configurationUnreadable)
        XCTAssertNil(repository.discoveryTask)
        XCTAssertEqual(defaults.string(forKey: BrowserPreferences.storageKey), "unreadable")
    }
}
