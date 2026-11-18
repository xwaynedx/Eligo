import Foundation
import XCTest
@testable import Eligo

@MainActor
final class RoutingPreferencesStoreTests: XCTestCase {
    func testMissingKeyLoadsSafeDefaults() {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        let store = RoutingPreferencesStore(userDefaults: userDefaults)

        XCTAssertEqual(store.settings, .default)
        XCTAssertNil(store.configurationIssueMessage)
        XCTAssertNil(userDefaults.object(forKey: RoutingPreferencesStore.storageKey))
    }

    func testWrongTypesStayProtectedAcrossReconstructionUntilReset() throws {
        let settings = try makeRoutingSettings()
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        let values: [NSObject] = [
            json as NSString,
            "not JSON" as NSString,
            42 as NSNumber,
            ["rules": ["preserve", "all"], "nested": ["number": 17, "enabled": true]] as NSDictionary
        ]

        for value in values {
            let suiteName = "EligoTests.RoutingProtection.\(UUID().uuidString)"
            let (userDefaults, cleanup) = makeIsolatedUserDefaults(suiteName: suiteName)
            defer { cleanup() }
            userDefaults.set(value, forKey: RoutingPreferencesStore.storageKey)
            userDefaults.set(Data("browser preferences".utf8), forKey: BrowserPreferences.storageKey)
            userDefaults.set("simplifiedChinese", forKey: AppLanguageStore.preferencesKey)
            userDefaults.set(["keep", "unrelated"], forKey: "UnrelatedSetting")
            var savedPreferences = try XCTUnwrap(userDefaults.persistentDomain(forName: suiteName))
            let originalPreferences = NSDictionary(dictionary: savedPreferences)

            for _ in 0..<2 {
                let store = RoutingPreferencesStore(userDefaults: userDefaults)
                XCTAssertEqual(store.settings, .default)
                XCTAssertNotNil(store.configurationIssueMessage)
                XCTAssertEqual(userDefaults.persistentDomain(forName: suiteName) as NSDictionary?, originalPreferences)

                XCTAssertThrowsError(try store.replace(with: settings)) { error in
                    XCTAssertEqual(error as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
                }

                XCTAssertEqual(store.settings, .default)
                XCTAssertNotNil(store.configurationIssueMessage)
                XCTAssertEqual(userDefaults.persistentDomain(forName: suiteName) as NSDictionary?, originalPreferences)
            }

            let store = RoutingPreferencesStore(userDefaults: userDefaults)
            store.reset()

            XCTAssertEqual(store.settings, .default)
            XCTAssertNil(store.configurationIssueMessage)
            XCTAssertNil(userDefaults.object(forKey: RoutingPreferencesStore.storageKey))
            savedPreferences.removeValue(forKey: RoutingPreferencesStore.storageKey)
            XCTAssertEqual(userDefaults.persistentDomain(forName: suiteName) as NSDictionary?, NSDictionary(dictionary: savedPreferences))

            try store.replace(with: settings)
            let reloaded = RoutingPreferencesStore(userDefaults: userDefaults)
            XCTAssertEqual(reloaded.settings, settings)
            XCTAssertNil(reloaded.configurationIssueMessage)
        }
    }

    func testVersionOneDevelopmentSettingsAreIgnored() throws {
        let (userDefaults, cleanup) = makeRecordingUserDefaults()
        defer { cleanup() }
        let versionOneData = try JSONEncoder().encode(makeRoutingSettings())
        userDefaults.set(versionOneData, forKey: "RoutingPreferences.v1")
        XCTAssertNil(userDefaults.object(forKey: RoutingPreferencesStore.storageKey))
        userDefaults.clearRecordedMutations()

        for initialization in 1...2 {
            let store = RoutingPreferencesStore(userDefaults: userDefaults)

            XCTAssertEqual(store.settings, .default)
            XCTAssertEqual(store.settings.scope, .allDomains)
            XCTAssertEqual(store.settings.rules, [])
            XCTAssertFalse(store.settings.alwaysShowChooser)
            XCTAssertNil(store.configurationIssueMessage)
            XCTAssertEqual(userDefaults.data(forKey: "RoutingPreferences.v1"), versionOneData)
            XCTAssertNil(userDefaults.object(forKey: RoutingPreferencesStore.storageKey))
            XCTAssertEqual(userDefaults.mutations, [], "Injected defaults must have no recorded mutations through initialization \(initialization)")
        }
    }

    func testCompleteConfigurationRoundTrips() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let settings = try makeRoutingSettings()
        let store = RoutingPreferencesStore(userDefaults: userDefaults)

        try store.replace(with: settings)

        let reloadedStore = RoutingPreferencesStore(userDefaults: userDefaults)
        XCTAssertEqual(reloadedStore.settings, settings)
        XCTAssertNil(reloadedStore.configurationIssueMessage)
    }

    func testVersionTwoSettingsTakePrecedenceOverVersionOneWithoutWriting() throws {
        let (userDefaults, cleanup) = makeRecordingUserDefaults()
        defer { cleanup() }
        let versionOneData = try JSONEncoder().encode(makeRoutingSettings())
        let versionTwoSettings = try RoutingSettings(scope: .allDomains, rules: [], alwaysShowChooser: true)
        let versionTwoData = try JSONEncoder().encode(versionTwoSettings)
        userDefaults.set(versionOneData, forKey: "RoutingPreferences.v1")
        userDefaults.set(versionTwoData, forKey: RoutingPreferencesStore.storageKey)
        userDefaults.clearRecordedMutations()

        for initialization in 1...2 {
            let store = RoutingPreferencesStore(userDefaults: userDefaults)

            XCTAssertEqual(store.settings, versionTwoSettings)
            XCTAssertNil(store.configurationIssueMessage)
            XCTAssertEqual(userDefaults.data(forKey: "RoutingPreferences.v1"), versionOneData)
            XCTAssertEqual(userDefaults.data(forKey: RoutingPreferencesStore.storageKey), versionTwoData)
            XCTAssertEqual(userDefaults.mutations, [], "Injected defaults must have no recorded mutations through initialization \(initialization)")
        }
    }

    func testMutationRecorderObservesWritesEvenWhenStoredValuesDoNotChange() throws {
        let suiteName = "EligoTests.RoutingRecorder.\(UUID().uuidString)"
        let (userDefaults, cleanup) = makeRecordingUserDefaults(suiteName: suiteName)
        defer { cleanup() }
        let base: UserDefaults = userDefaults
        let versionOneData = try JSONEncoder().encode(makeRoutingSettings())
        userDefaults.set(versionOneData, forKey: "RoutingPreferences.v1")
        userDefaults.clearRecordedMutations()
        XCTAssertEqual(userDefaults.mutations, [])

        base.set(versionOneData, forKey: "RoutingPreferences.v1")
        XCTAssertTrue(userDefaults.mutations.contains(.set("RoutingPreferences.v1")))

        userDefaults.clearRecordedMutations()
        base.removeObject(forKey: RoutingPreferencesStore.storageKey)
        XCTAssertTrue(userDefaults.mutations.contains(.removeObject(RoutingPreferencesStore.storageKey)))

        let originalDomain = try XCTUnwrap(userDefaults.persistentDomain(forName: suiteName))
        userDefaults.clearRecordedMutations()
        base.setPersistentDomain(originalDomain, forName: suiteName)
        XCTAssertTrue(userDefaults.mutations.contains(.setPersistentDomain(suiteName)))

        userDefaults.clearRecordedMutations()
        base.removePersistentDomain(forName: suiteName + ".absent")
        XCTAssertTrue(userDefaults.mutations.contains(.removePersistentDomain(suiteName + ".absent")))
        XCTAssertEqual(userDefaults.data(forKey: "RoutingPreferences.v1"), versionOneData)
        XCTAssertNil(userDefaults.object(forKey: RoutingPreferencesStore.storageKey))
    }

    func testReplacingRoutingSettingsDoesNotRewriteBrowserPreferences() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browserPreferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try browserPreferences.saveScannedBrowsers([safari], at: Date(timeIntervalSince1970: 1_000))
        try browserPreferences.save([ConfiguredBrowser(browser: safari, isEnabled: false)])
        let savedBrowserData = userDefaults.data(forKey: "BrowserPreferences.v1")

        try RoutingPreferencesStore(userDefaults: userDefaults).replace(with: makeRoutingSettings())

        XCTAssertEqual(userDefaults.data(forKey: "BrowserPreferences.v1"), savedBrowserData)
    }

    func testInvalidLimitedScopeIsRejectedWithoutChangingStoredSettings() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        let validSettings = try makeRoutingSettings()
        try store.replace(with: validSettings)

        XCTAssertThrowsError(
            try RoutingSettings(
                scope: .onlyThese(
                    matchers: [try DomainMatcher(host: "example.com", includesSubdomains: false)],
                    bypassDestinationID: OpenDestinationID(
                        browserID: "com.google.Chrome",
                        mode: .privateBrowsing
                    )
                ),
                rules: [],
                alwaysShowChooser: false
            )
        )

        XCTAssertEqual(store.settings, validSettings)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: userDefaults).settings, validSettings)
    }

    func testCorruptDataUsesDefaultsWithoutOverwritingStoredBytes() {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let corruptData = Data("not valid routing preferences".utf8)
        userDefaults.set(corruptData, forKey: RoutingPreferencesStore.storageKey)

        let store = RoutingPreferencesStore(userDefaults: userDefaults)

        XCTAssertEqual(store.settings, .default)
        XCTAssertNotNil(store.configurationIssueMessage)
        XCTAssertEqual(userDefaults.data(forKey: RoutingPreferencesStore.storageKey), corruptData)
    }

    func testReplaceIsRefusedWhileSavedDataIsUnreadable() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let corruptData = Data("not valid routing preferences".utf8)
        userDefaults.set(corruptData, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: userDefaults)

        XCTAssertThrowsError(try store.replace(with: try makeRoutingSettings())) { error in
            XCTAssertEqual(error as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
        }

        XCTAssertEqual(userDefaults.data(forKey: RoutingPreferencesStore.storageKey), corruptData)
        XCTAssertEqual(store.settings, .default)
        XCTAssertNotNil(store.configurationIssueMessage)
    }

    func testResetRepairsUnreadableSavedDataAndAllowsWritesAgain() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        userDefaults.set(
            Data("not valid routing preferences".utf8),
            forKey: RoutingPreferencesStore.storageKey
        )
        let store = RoutingPreferencesStore(userDefaults: userDefaults)

        store.reset()
        let settings = try makeRoutingSettings()
        try store.replace(with: settings)

        XCTAssertNil(store.configurationIssueMessage)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: userDefaults).settings, settings)
    }

    func testResetClearsRoutingSettingsAndPreservesBrowserCache() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browserPreferences = BrowserPreferences(userDefaults: userDefaults)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        try browserPreferences.saveScannedBrowsers([safari], at: Date(timeIntervalSince1970: 1_000))
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        try store.replace(with: makeRoutingSettings())

        store.reset()

        XCTAssertEqual(store.settings, .default)
        XCTAssertNil(store.configurationIssueMessage)
        XCTAssertNil(userDefaults.data(forKey: RoutingPreferencesStore.storageKey))
        XCTAssertEqual(try browserPreferences.cachedScannedBrowsers().map(\.id), [safari.id])
    }

    private func makeRoutingSettings() throws -> RoutingSettings {
        let normalDestination = OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
        let privateDestination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)
        return try RoutingSettings(
            scope: .onlyThese(
                matchers: [try DomainMatcher(host: "example.com", includesSubdomains: true)],
                bypassDestinationID: normalDestination
            ),
            rules: [
                DomainRule(
                    matcher: try DomainMatcher(host: "docs.example.com", includesSubdomains: false),
                    destinationID: privateDestination
                )
            ],
            alwaysShowChooser: true
        )
    }

    private func makeRecordingUserDefaults(
        suiteName: String = "EligoTests.RoutingInitialization.\(UUID().uuidString)"
    ) -> (MutationRecordingUserDefaults, () -> Void) {
        let userDefaults = MutationRecordingUserDefaults(suiteName: suiteName)!
        return (userDefaults, { userDefaults.removePersistentDomain(forName: suiteName) })
    }
}

/// Observe only the injected instance's four overridden APIs with real UUID-suite I/O.
/// Other instances, .standard, and other mutation APIs are outside this observation.
/// Setup is cleared once; both constructions share a cumulative window before cleanup.
private final class MutationRecordingUserDefaults: UserDefaults {
    enum Mutation: Equatable {
        case set(String)
        case removeObject(String)
        case setPersistentDomain(String)
        case removePersistentDomain(String)
    }

    private(set) var mutations: [Mutation] = []

    func clearRecordedMutations() {
        mutations.removeAll()
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        mutations.append(.set(defaultName))
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        mutations.append(.removeObject(defaultName))
        super.removeObject(forKey: defaultName)
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        mutations.append(.setPersistentDomain(domainName))
        super.setPersistentDomain(domain, forName: domainName)
    }

    override func removePersistentDomain(forName domainName: String) {
        mutations.append(.removePersistentDomain(domainName))
        super.removePersistentDomain(forName: domainName)
    }
}
