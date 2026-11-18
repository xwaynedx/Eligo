import Foundation
import XCTest
@testable import Eligo

final class BrowserPreferencesTests: XCTestCase {
    func testDefaultOrderBreaksEqualNameAndPriorityTiesByBundleIdentifier() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }
        let orion = makeBrowser(name: "Orion", bundleIdentifier: "com.kagi.kagimacOS")
        let orionRC = makeBrowser(name: "Orion", bundleIdentifier: "com.kagi.kagimacOS.RC")

        for input in [[orion, orionRC], [orionRC, orion]] {
            XCTAssertEqual(try preferences.apply(to: input).map(\.id), [orion.id, orionRC.id])
        }

        try preferences.save([orionRC, orion].map { ConfiguredBrowser(browser: $0, isEnabled: true) })
        XCTAssertEqual(try preferences.apply(to: [orion, orionRC]).map(\.id), [orionRC.id, orion.id])
    }

    func testReadContractDistinguishesMissingReadableAndUnreadableValues() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let preferences = BrowserPreferences(userDefaults: defaults)
        guard case .missing = preferences.loadResult() else { return XCTFail("Missing key is a normal installation") }
        defaults.set(Data("{}".utf8), forKey: BrowserPreferences.storageKey)
        guard case .readable = preferences.loadResult() else { return XCTFail("Legacy missing fields remain readable") }
        defaults.set("not stored data", forKey: BrowserPreferences.storageKey)
        guard case .unreadable = preferences.loadResult() else { return XCTFail("Wrong storage type must not be treated as missing") }
        XCTAssertThrowsError(try preferences.load()) { error in
            XCTAssertEqual(error as? BrowserPreferencesError, .unreadableConfiguration)
        }
        XCTAssertThrowsError(try preferences.saveRecentBrowserIdentifier("com.example.a"))
        XCTAssertEqual(defaults.string(forKey: BrowserPreferences.storageKey), "not stored data")
    }

    func testBrowserCacheRefreshPolicyUsesSavedScanDate() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let scanDate = Date(timeIntervalSince1970: 1_000)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")

        XCTAssertTrue(try preferences.shouldRefreshBrowserCache(now: scanDate, maximumAge: 3_600))

        try preferences.saveScannedBrowsers([safari], at: scanDate)

        XCTAssertFalse(
            try preferences.shouldRefreshBrowserCache(
                now: scanDate.addingTimeInterval(3_599),
                maximumAge: 3_600
            )
        )
        XCTAssertTrue(
            try preferences.shouldRefreshBrowserCache(
                now: scanDate.addingTimeInterval(3_601),
                maximumAge: 3_600
            )
        )
    }

    func testResetPreservesDetectedBrowserCacheAndClearsUserChoices() throws {
        let (preferences, cleanup) = makeIsolatedPreferences()
        defer { cleanup() }

        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let custom = makeBrowser(
            name: "Work Browser",
            bundleIdentifier: "com.example.work-browser",
            isCustom: true,
            priority: 1_000
        )

        try preferences.saveScannedBrowsers([safari], at: Date(timeIntervalSince1970: 1_000))
        try preferences.saveCustomBrowser(custom)
        try preferences.save([
            ConfiguredBrowser(browser: custom, isEnabled: true),
            ConfiguredBrowser(browser: safari, isEnabled: false)
        ])
        try preferences.saveRecentBrowserIdentifier(custom.id)

        try preferences.reset()

        XCTAssertEqual(try preferences.cachedScannedBrowsers().map(\.id), [safari.id])
        XCTAssertTrue(try preferences.customBrowsers().isEmpty)
        XCTAssertNil(try preferences.recentBrowserIdentifier())

        let resetBrowsers = try preferences.apply(to: [safari])
        XCTAssertEqual(resetBrowsers.map(\.id), [safari.id])
        XCTAssertEqual(resetBrowsers.map(\.isEnabled), [true])
    }

    func testUnreadablePreferencesArePreservedUntilExplicitReset() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let unreadableData = Data("not-json".utf8)
        userDefaults.set(unreadableData, forKey: "BrowserPreferences.v1")
        let preferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")

        XCTAssertThrowsError(try preferences.saveScannedBrowsers([safari], at: Date(timeIntervalSince1970: 1_000)))

        XCTAssertEqual(userDefaults.data(forKey: "BrowserPreferences.v1"), unreadableData)

        try preferences.reset()

        XCTAssertNil(userDefaults.data(forKey: "BrowserPreferences.v1"))
    }

    func testDuplicatePersistedBrowserIdentifiersAreSanitized() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let stored: [String: Any] = [
            "orderedBundleIdentifiers": ["com.apple.Safari", "com.apple.Safari"],
            "disabledBundleIdentifiers": ["com.apple.Safari", "com.apple.Safari"],
            "customBrowsers": [],
            "scannedBrowsers": [
                [
                    "name": "Old Safari",
                    "bundleIdentifier": "com.apple.Safari",
                    "appPath": "/Applications/Safari.app",
                    "priority": 10
                ],
                [
                    "name": "Safari",
                    "bundleIdentifier": "com.apple.Safari",
                    "appPath": "/Applications/Safari.app",
                    "priority": 10
                ]
            ]
        ]
        userDefaults.set(
            try JSONSerialization.data(withJSONObject: stored),
            forKey: BrowserPreferences.storageKey
        )
        let preferences = BrowserPreferences(userDefaults: userDefaults)

        let cached = try preferences.cachedScannedBrowsers()
        let configured = try preferences.apply(to: cached)

        XCTAssertEqual(cached.map(\.name), ["Safari"])
        XCTAssertEqual(configured.map(\.id), ["com.apple.Safari"])
        XCTAssertEqual(configured.map(\.isEnabled), [false])
        let chrome = makeBrowser(name: "Chrome", bundleIdentifier: "com.google.Chrome")
        let reordered = [ConfiguredBrowser(browser: chrome, isEnabled: true)] + configured
        try preferences.save(reordered)
        XCTAssertEqual(try preferences.load().orderedBundleIdentifiers, [chrome.id, "com.apple.Safari"])
        XCTAssertEqual(try preferences.apply(to: [chrome] + cached).map(\.id), reordered.map(\.id))
        XCTAssertEqual(try preferences.apply(to: [chrome] + cached).map(\.isEnabled), [true, false])
    }
}
