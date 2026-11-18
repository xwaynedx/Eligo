import Foundation
import XCTest
@testable import Eligo

@MainActor
final class IPv6RoutingPersistenceTests: XCTestCase {
    private let normalDestination = OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
    private let privateDestination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)

    // Raw v2 spellings accepted before IPv6 address canonicalization. The two
    // rule groups include both identical and different destination/mode pairs.
    private func legacyData() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(
            forResource: "host-ipv6-legacy-v2", withExtension: "json", subdirectory: "Fixtures"
        )))
    }

    private func scopeOnlyData(kind: String) throws -> Data {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
        document["rules"] = []
        var scope = try XCTUnwrap(document["scope"] as? [String: Any])
        scope["kind"] = kind
        document["scope"] = scope
        return try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
    }

    func testParserSingleAndBulkEditorsPersistOneIPv6IdentityAndKeepRuleIDs() throws {
        let expanded = "2001:0DB8:0000:0000:0000:0000:0000:0001"
        let urlInput = "https://[\(expanded)]:8443/path"
        let parsed = DomainListParser().parse("2001:db8::1 \(urlInput) [::1] 0:0:0:0:0:0:0:1", includesSubdomains: true)
        XCTAssertEqual(parsed.matchers.map(\.normalizedHost), ["2001:db8::1", "::1"])
        XCTAssertEqual(parsed.matchers.map(\.includesSubdomains), [false, false])
        XCTAssertEqual(parsed.duplicateInputs, [urlInput, "0:0:0:0:0:0:0:1"])
        XCTAssertTrue(parsed.invalidInputs.isEmpty)

        let drafts = [ScopeMatcherDraft(host: urlInput, includesSubdomains: false)]
        let appended = ScopeMatcherDraftLogic.validation(for: drafts).appending(parsed.matchers)
        XCTAssertEqual(appended.addedCount, 1)
        XCTAssertEqual(appended.skippedDuplicateCount, 1)
        let validated = try XCTUnwrap(ScopeMatcherDraftLogic.validation(for: appended.drafts)
            .validatedMatchers(for: appended.drafts))
        XCTAssertEqual(validated, parsed.matchers)

        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normalDestination.browserID)
        defer { browser.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        let scope = RoutingScope.onlyThese(matchers: validated, bypassDestinationID: normalDestination)
        try editor.saveScope(scope, browserRepository: browser.repository)
        try editor.setAlwaysShowChooser(true)
        try editor.saveRule(existingRuleID: nil, host: expanded, includesSubdomains: false, destinationID: privateDestination)
        let firstRule = try XCTUnwrap(store.settings.rules.first)
        XCTAssertEqual(firstRule.matcher, parsed.matchers[0])
        let original = defaults.data(forKey: RoutingPreferencesStore.storageKey)
        for host in ["2001:db8::1", "[\(expanded)]"] {
            XCTAssertThrowsError(try editor.saveRule(existingRuleID: nil, host: host,
                includesSubdomains: false, destinationID: normalDestination)) {
                XCTAssertEqual($0 as? RoutingSettingsValidationError, .duplicateRuleMatcher)
            }
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        }
        try editor.saveRulesInBulk(parsed.matchers, destinationID: normalDestination, replaceExisting: false)
        XCTAssertEqual(store.settings.rules[0], firstRule)
        XCTAssertEqual(store.settings.rules.map(\.destinationID), [privateDestination, normalDestination])
        let ruleIDs = store.settings.rules.map(\.id)
        try editor.saveRulesInBulk(parsed.matchers, destinationID: privateDestination, replaceExisting: true)
        try editor.saveRule(existingRuleID: firstRule.id, host: "[2001:DB8::0001]",
                            includesSubdomains: false, destinationID: privateDestination)
        XCTAssertEqual(store.settings.rules.map(\.id), ruleIDs)
        XCTAssertEqual(store.settings.rules.map(\.matcher), parsed.matchers)
        XCTAssertEqual(store.settings.rules.map(\.destinationID), [privateDestination, privateDestination])
        XCTAssertEqual(store.settings.scope, scope)
        XCTAssertTrue(store.settings.alwaysShowChooser)
        let saved = try XCTUnwrap(defaults.data(forKey: RoutingPreferencesStore.storageKey))
        let decoded = try JSONDecoder().decode(RoutingSettings.self, from: saved)
        XCTAssertEqual(decoded, store.settings)
        XCTAssertEqual(try JSONDecoder().decode(RoutingSettings.self, from: JSONEncoder().encode(decoded)), decoded)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, decoded)
    }

    func testLegacyEquivalentRulesRefuseLoadingAndWritesWithoutChangingAnyPreferences() throws {
        let legacy = try legacyData()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        let rules = try XCTUnwrap(document["rules"] as? [[String: Any]])
        // Exercise each group alone too: a same-target conflict must not be
        // silently collapsed just because no different-target conflict exists.
        let individualConflicts = try [[1, 3], [2, 4]].map { indices in
            var group = document
            group["rules"] = indices.map { rules[$0] }
            return try JSONSerialization.data(withJSONObject: group, options: .sortedKeys)
        }
        for original in [legacy] + individualConflicts {
            XCTAssertThrowsError(try JSONDecoder().decode(RoutingSettings.self, from: original)) {
                XCTAssertEqual($0 as? RoutingSettingsValidationError, .duplicateRuleMatcher)
            }
            let suiteName = "EligoTests.\(UUID().uuidString)"
            let (defaults, cleanup) = makeIsolatedUserDefaults(suiteName: suiteName)
            defer { cleanup() }
            defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
            defaults.set(["preserve": 42], forKey: "UnrelatedSetting")
            let snapshot = NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: suiteName)))
            for _ in 0..<2 {
                let store = RoutingPreferencesStore(userDefaults: defaults)
                XCTAssertEqual(store.settings, .default)
                XCTAssertNotNil(store.configurationIssueMessage)
                XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
                XCTAssertThrowsError(try store.replace(with: .default)) {
                    XCTAssertEqual($0 as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
                }
                XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: suiteName))), snapshot)
            }
        }
    }

    func testScopeOnlyIPv6DuplicatesLoadAllRowsAndRequireExplicitEditorOrRecoveryChoices() throws {
        for kind in ["onlyThese", "allExceptThese"] {
            let original = try scopeOnlyData(kind: kind)
            let suiteName = "EligoTests.\(UUID().uuidString)"
            let (defaults, cleanup) = makeIsolatedUserDefaults(suiteName: suiteName)
            defer { cleanup() }
            defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
            defaults.set("keep", forKey: "UnrelatedSetting")
            let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normalDestination.browserID)
            defer { browser.cleanup() }
            let snapshot = NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: suiteName)))
            let store = RoutingPreferencesStore(userDefaults: defaults)
            XCTAssertNil(store.configurationIssueMessage)
            let expectedMatchers = try ["2001:db8::1", "2001:db8::1", "unrelated.scope.example"].enumerated().map {
                try DomainMatcher(host: $0.element, includesSubdomains: $0.offset == 2)
            }
            let expectedScope: RoutingScope = kind == "onlyThese"
                ? .onlyThese(matchers: expectedMatchers, bypassDestinationID: normalDestination)
                : .allExceptThese(matchers: expectedMatchers, bypassDestinationID: normalDestination)
            XCTAssertEqual(store.settings.scope, expectedScope)
            XCTAssertTrue(store.settings.rules.isEmpty)
            XCTAssertTrue(store.settings.alwaysShowChooser)
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)

            let session = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store),
                                             browserRepository: browser.repository)
            defer { session.end() }
            let rows = session.validation.drafts
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(session.validation.invalidDraftIDs, Set(rows.prefix(2).map(\.id)))
            for row in rows.prefix(2) { XCTAssertEqual(session.validation.issue(for: row.id), .duplicate) }
            XCTAssertFalse(session.canSave)
            XCTAssertFalse(session.save())
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
            XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: suiteName))), snapshot)

            let recovery = try RoutingPreferencesRecovery(originalData: original)
            XCTAssertTrue(recovery.conflicts.isEmpty)
            XCTAssertEqual(recovery.scopeConflicts.map { $0.entries.map(\.number) }, [[1, 2]])
            XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: []))
            let candidate = try recovery.candidate(keepingRuleNumbers: [], keepingScopeNumbers: [2])
            let recovered = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
            XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)

            session.removeDomain(rowID: rows[0].id)
            XCTAssertTrue(session.validation.invalidDraftIDs.isEmpty)
            XCTAssertTrue(session.canSave)
            XCTAssertTrue(session.save())
            XCTAssertEqual(store.settings, recovered)
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, recovered)
            XCTAssertEqual(defaults.string(forKey: "UnrelatedSetting"), "keep")
        }
    }

    func testAllDomainsCanSaveWithHiddenEquivalentIPv6ScopeRows() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let original = try scopeOnlyData(kind: "onlyThese")
        defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normalDestination.browserID)
        defer { browser.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let session = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store),
                                         browserRepository: browser.repository)
        defer { session.end() }
        XCTAssertFalse(session.validation.invalidDraftIDs.isEmpty)
        session.setMode(.allDomains)
        XCTAssertTrue(session.canSave)
        XCTAssertNil(session.displayedIssue)
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        XCTAssertTrue(session.save())
        XCTAssertEqual(store.settings.scope, .allDomains)
        XCTAssertTrue(store.settings.alwaysShowChooser)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
    }

    func testIPv6RecoveryReportsAllTargetsAndPreservesChosenAndUnrelatedData() throws {
        let original = try legacyData()
        let recovery = try RoutingPreferencesRecovery(originalData: original)
        XCTAssertEqual(recovery.conflicts.map { $0.matcher.normalizedHost }, ["::1", "2001:db8::1"])
        XCTAssertEqual(recovery.conflicts.map { $0.entries.map(\.number) }, [[2, 4], [3, 5]])
        XCTAssertEqual(recovery.conflicts.map { $0.entries.map(\.originalHost) }, [
            ["::1", "0:0:0:0:0:0:0:1"], ["2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001"]
        ])
        let firefoxPrivate = OpenDestinationID(browserID: "org.mozilla.firefox", mode: .privateBrowsing)
        XCTAssertEqual(recovery.conflicts.map { $0.entries.map(\.rule.destinationID) }, [
            [normalDestination, firefoxPrivate], [privateDestination, privateDestination]
        ])
        XCTAssertTrue(recovery.invalidRules.isEmpty)
        XCTAssertTrue(recovery.invalidScopeEntries.isEmpty)
        XCTAssertEqual(recovery.scopeConflicts.map { $0.entries.map(\.number) }, [[1, 2]])
        XCTAssertEqual(recovery.scopeConflicts.first?.entries.map(\.originalHost),
                       ["2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001"])
        for choices: Set<Int> in [[], [4], [2, 4, 5], [1, 4, 5], [4, 5, 99]] {
            XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: choices, keepingScopeNumbers: [2]))
        }
        for choices: Set<Int> in [[], [1, 2], [3]] {
            XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4, 5], keepingScopeNumbers: choices))
        }
        XCTAssertEqual(recovery.originalData, original)
        let candidate = try recovery.candidate(keepingRuleNumbers: [4, 5], keepingScopeNumbers: [2])
        let recovered = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
        XCTAssertEqual(recovered.rules.map(\.id), [1, 4, 5, 6].map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        })
        XCTAssertEqual(recovered.rules.map(\.matcher.normalizedHost), ["untouched.example", "::1", "2001:db8::1", "2001:db8::2"])
        XCTAssertEqual(recovered.rules.map(\.destinationID), [normalDestination, firefoxPrivate, privateDestination, normalDestination])
        XCTAssertEqual(recovered.scope, .onlyThese(matchers: [
            try DomainMatcher(host: "2001:db8::1", includesSubdomains: false),
            try DomainMatcher(host: "unrelated.scope.example", includesSubdomains: true)
        ], bypassDestinationID: normalDestination))
        XCTAssertTrue(recovered.alwaysShowChooser)
        XCTAssertEqual(try JSONDecoder().decode(RoutingSettings.self, from: JSONEncoder().encode(recovered)), recovered)

        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: candidate) as? [String: Any])
        let rawRules = try XCTUnwrap(document["rules"] as? [[String: Any]])
        let rawScope = try XCTUnwrap(document["scope"] as? [String: Any])
        XCTAssertEqual(document["futureSettingsField"] as? [String: Bool], ["preserved": true])
        XCTAssertEqual(rawRules[0]["futureRuleField"] as? String, "preserved")
        XCTAssertEqual((rawRules[1]["matcher"] as? [String: Any])?["futureMatcherField"] as? Int, 42)
        XCTAssertEqual(rawScope["futureScopeField"] as? String, "preserved")
        XCTAssertEqual((rawScope["matchers"] as? [[String: Any]])?.first?["annotation"] as? String, "keep")

        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(candidate, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertNil(store.configurationIssueMessage)
        let editor = RoutingSettingsEditor(store: store)
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: normalDestination.browserID)
        defer { browser.cleanup() }
        try editor.saveScope(recovered.scope, browserRepository: browser.repository)
        try editor.saveRule(existingRuleID: recovered.rules[1].id, host: "0000:0000:0000:0000:0000:0000:0000:0001",
                            includesSubdomains: false, destinationID: firefoxPrivate)
        XCTAssertEqual(store.settings, recovered)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, recovered)
    }
}
