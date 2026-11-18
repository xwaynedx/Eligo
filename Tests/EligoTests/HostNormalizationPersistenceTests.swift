import Foundation
import XCTest
@testable import Eligo

@MainActor
final class HostNormalizationPersistenceTests: XCTestCase {
    private let normal = OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
    private let privateDestination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)

    func testPreviouslyRoundTrippableHostsLoadAndRemainEditableAfterUpgrade() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(
            forResource: "host-legacy-compatible-v2", withExtension: "json", subdirectory: "Fixtures"
        )))
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(data, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertNil(store.configurationIssueMessage)
        XCTAssertEqual(store.settings.rules.map(\.matcher.normalizedHost), [
            "a~b.com", "a+b.com", "example..com", "xn--mgba3gch31f060k.ir", "xn--11b2ezcw70k.com"
        ])
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), data)
        let settings = store.settings
        let editor = RoutingSettingsEditor(store: store)
        try editor.setAlwaysShowChooser(false)
        for rule in settings.rules {
            let matcher = try DomainMatcher(host: rule.matcher.normalizedHost, includesSubdomains: false)
            XCTAssertEqual(matcher, rule.matcher)
            try editor.saveRule(existingRuleID: rule.id, host: matcher.normalizedHost,
                                includesSubdomains: false, destinationID: rule.destinationID)
            let url = try XCTUnwrap(URL(string: "https://\(matcher.normalizedHost)/path"))
            XCTAssertEqual(RoutingPolicy().plan(for: url, settings: store.settings),
                           .open(destinationID: rule.destinationID, reason: .domainRule))
        }
        XCTAssertEqual(store.settings.rules, settings.rules)
        XCTAssertEqual(store.settings.scope, settings.scope)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
    }

    func testPercentEscapesAreDecodedOnceAcrossEveryHostEntryPoint() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        try editor.saveRule(existingRuleID: nil, host: "example.com", includesSubdomains: false,
                            destinationID: normal)
        let original = defaults.data(forKey: RoutingPreferencesStore.storageKey)
        for suffix in ["%252e", "%25E3%2580%2582", "%25252e"] {
            let host = "example.com" + suffix
            let absolute = "https://\(host)/path"
            XCTAssertThrowsError(try editor.saveRule(existingRuleID: nil, host: host,
                includesSubdomains: false, destinationID: privateDestination))
            for input in [host, absolute] {
                let parsed = DomainListParser().parse(input, includesSubdomains: false)
                XCTAssertEqual(parsed.invalidInputs, [input])
                XCTAssertTrue(parsed.matchers.isEmpty)
                XCTAssertThrowsError(try editor.saveRulesInBulk(parsed.matchers,
                    destinationID: privateDestination, replaceExisting: true))
                XCTAssertThrowsError(try ScopeMatcherDraftLogic.matcher(for: ScopeMatcherDraft(host: input, includesSubdomains: false)))
            }
            let url = try XCTUnwrap(URL(string: absolute))
            XCTAssertNil(DomainMatcher.normalizedHost(from: url))
            XCTAssertEqual(RoutingPolicy().plan(for: url, settings: store.settings), .choose(reason: .missingHost))
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        }
        for suffix in ["%2e", "%E3%80%82", "%EF%BC%8E", "%EF%BD%A1"] {
            let url = try XCTUnwrap(URL(string: "https://example.com\(suffix)/path"))
            XCTAssertEqual(DomainMatcher.normalizedHost(from: url), "example.com")
            XCTAssertEqual(DomainListParser().parse(url.absoluteString, includesSubdomains: false).matchers,
                           store.settings.rules.map(\.matcher))
            XCTAssertEqual(RoutingPolicy().plan(for: url, settings: store.settings), .open(destinationID: normal, reason: .domainRule))
        }
    }

    func testSingleRuleRejectsEquivalentAndInvalidInputsBeforeWriting() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        try editor.saveRule(existingRuleID: nil, host: "example.com。", includesSubdomains: false,
                            destinationID: privateDestination)
        let saved = defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let firstRule = try XCTUnwrap(store.settings.rules.first)
        XCTAssertEqual(firstRule.matcher.normalizedHost, "example.com")

        for input in ["example.com", "EXAMPLE.COM.", "example.com%2e", "example.com%E3%80%82"] {
            XCTAssertThrowsError(try editor.saveRule(existingRuleID: nil, host: input,
                includesSubdomains: false, destinationID: normal)) {
                XCTAssertEqual($0 as? RoutingSettingsValidationError, .duplicateRuleMatcher)
            }
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), saved)
        }
        for input in ["example.com..", "example.com...", "example.com。。", "example.com.%2e"] {
            for _ in 0..<2 {
                XCTAssertThrowsError(try editor.saveRule(existingRuleID: nil, host: input,
                    includesSubdomains: false, destinationID: normal)) {
                    XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost)
                }
                XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), saved)
                XCTAssertEqual(store.settings.rules, [firstRule])
            }
        }
        // The subdomain switch remains part of matcher identity.
        try editor.saveRule(existingRuleID: nil, host: "example.com．", includesSubdomains: true,
                            destinationID: normal)
        XCTAssertEqual(store.settings.rules.count, 2)
        XCTAssertEqual(store.settings.rules[0], firstRule)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
    }

    func testSharedParserScopeAndBulkEditorPersistTheSameCanonicalMatchers() throws {
        let text = """
        example.com。 EXAMPLE.COM. https://example.com%2e/path
        BÜCHER.example｡ https://xn--bcher-kva.example./page
        example.com.. example.com。%2e https://example.com%2e%2e/path
        https://user@example.com/path example.com/path
        """
        let parsed = DomainListParser().parse(text, includesSubdomains: false)
        XCTAssertEqual(parsed.matchers.map(\.normalizedHost), ["example.com", "xn--bcher-kva.example"])
        XCTAssertEqual(parsed.duplicateInputs, [
            "EXAMPLE.COM.", "https://example.com%2e/path", "https://xn--bcher-kva.example./page"
        ])
        XCTAssertEqual(parsed.invalidInputs, [
            "example.com..", "example.com。%2e", "https://example.com%2e%2e/path",
            "https://user@example.com/path", "example.com/path"
        ])

        let drafts = [ScopeMatcherDraft(host: "https://example.com。/path", includesSubdomains: false)]
        let appended = ScopeMatcherDraftLogic.validation(for: drafts).appending(parsed.matchers)
        XCTAssertEqual(appended.addedCount, 1)
        XCTAssertEqual(appended.skippedDuplicateCount, 1)
        let validation = ScopeMatcherDraftLogic.validation(for: appended.drafts)
        XCTAssertTrue(validation.invalidDraftIDs.isEmpty)
        let validatedMatchers = try XCTUnwrap(validation.validatedMatchers(for: appended.drafts))
        XCTAssertEqual(validatedMatchers, parsed.matchers)
        let duplicate = ScopeMatcherDraft(host: "example.com%2e", includesSubdomains: false)
        let duplicateDrafts = drafts + [duplicate]
        XCTAssertEqual(
            ScopeMatcherDraftLogic.validation(for: duplicateDrafts).issue(for: duplicate.id),
            .duplicate
        )
        XCTAssertThrowsError(try ScopeMatcherDraftLogic.matcher(for: ScopeMatcherDraft(host: "example.com。。")))
        XCTAssertThrowsError(try ScopeMatcherDraftLogic.matcher(for: ScopeMatcherDraft(host: "127.0.0.1。")))
        XCTAssertEqual(try DomainMatcher(host: "127.0.0.1%2e", includesSubdomains: false).normalizedHost, "127.0.0.1")

        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normal.browserID)
        defer { browser.cleanup() }
        try editor.saveScope(.onlyThese(matchers: validatedMatchers,
                                        bypassDestinationID: normal), browserRepository: browser.repository)
        try editor.setAlwaysShowChooser(true)
        try editor.saveRulesInBulk(parsed.matchers, destinationID: privateDestination, replaceExisting: false)
        let ruleIDs = store.settings.rules.map(\.id)
        let aliases = DomainListParser().parse("example.com． bücher.example%2e", includesSubdomains: false)
        try editor.saveRulesInBulk(aliases.matchers, destinationID: normal, replaceExisting: false)
        XCTAssertEqual(store.settings.rules.map(\.destinationID), [privateDestination, privateDestination])
        try editor.saveRulesInBulk(aliases.matchers, destinationID: normal, replaceExisting: true)
        XCTAssertEqual(store.settings.rules.map(\.id), ruleIDs)
        XCTAssertEqual(store.settings.rules.map(\.destinationID), [normal, normal])

        let saved = try XCTUnwrap(defaults.data(forKey: RoutingPreferencesStore.storageKey))
        let decoded = try JSONDecoder().decode(RoutingSettings.self, from: saved)
        XCTAssertEqual(decoded, store.settings)
        XCTAssertEqual(try JSONDecoder().decode(RoutingSettings.self, from: JSONEncoder().encode(decoded)), decoded)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, decoded)
        XCTAssertTrue(decoded.alwaysShowChooser)
    }

    func testInvalidBulkSubmissionAndUnreadableStoreNeverOverwriteSavedBytes() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let original = Data("unreadable routing settings".utf8)
        defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        let valid = DomainListParser().parse("example.com。 example.com", includesSubdomains: false)
        XCTAssertEqual(valid.matchers.count, 1)
        XCTAssertThrowsError(try editor.saveRulesInBulk(valid.matchers, destinationID: normal, replaceExisting: false)) {
            XCTAssertEqual($0 as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
        }
        let invalid = DomainListParser().parse("example.com.. example.com。。", includesSubdomains: false)
        XCTAssertTrue(invalid.matchers.isEmpty)
        XCTAssertThrowsError(try editor.saveRulesInBulk(invalid.matchers, destinationID: normal, replaceExisting: false))
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normal.browserID)
        defer { browser.cleanup() }
        XCTAssertThrowsError(try editor.saveScope(.onlyThese(matchers: valid.matchers, bypassDestinationID: normal),
                                                  browserRepository: browser.repository))
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        XCTAssertNotNil(store.configurationIssueMessage)
    }

    func testOutOfRangeLegacyIPv4BlocksTheWholeSnapshotWithoutDiscardingBytes() throws {
        let originalSettings = try RoutingSettings(scope: .allDomains, rules: [
            DomainRule(matcher: try DomainMatcher(host: "old.example", includesSubdomains: false), destinationID: normal),
            DomainRule(matcher: try DomainMatcher(host: "kept.example", includesSubdomains: false), destinationID: normal)
        ], alwaysShowChooser: true)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalSettings)) as? [String: Any])
        var rules = try XCTUnwrap(payload["rules"] as? [[String: Any]])
        var matcher = try XCTUnwrap(rules[0]["matcher"] as? [String: Any])
        matcher["normalizedHost"] = "256.0.0.1"
        rules[0]["matcher"] = matcher
        payload["rules"] = rules
        let legacyBytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingSettings.self, from: legacyBytes)) {
            XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost)
        }
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(legacyBytes, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store.settings, .default)
        XCTAssertNotNil(store.configurationIssueMessage)
        XCTAssertThrowsError(try RoutingSettingsEditor(store: store).setAlwaysShowChooser(false)) {
            XCTAssertEqual($0 as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
        }
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), legacyBytes)
    }
}
