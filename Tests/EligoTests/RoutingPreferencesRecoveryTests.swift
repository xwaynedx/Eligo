import Foundation
import XCTest
@testable import Eligo

@MainActor
final class RoutingPreferencesRecoveryTests: XCTestCase {
    // Encoded with the legacy host normalizer; preserve the fixture's original bytes.
    // Inputs in order: untouched.example, example.com。, middle.example,
    // example.com, example.com (the last matcher includes subdomains).
    private func legacyData() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(
            forResource: "host-normalization-v2", withExtension: "json", subdirectory: "Fixtures"
        )))
    }

    func testLegacyInvalidHostsCanBeInspectedBeforeChoosingWhatToDiscard() throws {
        let original = try Data(contentsOf: XCTUnwrap(Bundle.module.url(
            forResource: "host-legacy-invalid-v2", withExtension: "json", subdirectory: "Fixtures"
        )))
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingSettings.self, from: original))
        let recovery = try RoutingPreferencesRecovery(originalData: original)
        XCTAssertEqual(recovery.invalidRules.map(\.number), [2])
        XCTAssertEqual(recovery.invalidRules.map(\.originalHost), ["example.com.."])
        XCTAssertEqual(recovery.invalidRules.first?.reason, .invalidHost)
        XCTAssertEqual(recovery.invalidRules.first?.destinationID.mode, .privateBrowsing)
        XCTAssertEqual(recovery.invalidScopeEntries.map(\.number), [3])
        XCTAssertEqual(recovery.invalidScopeEntries.map(\.originalHost), ["broken-scope.example.."])
        XCTAssertEqual(recovery.conflicts.map { $0.entries.map(\.number) }, [[3, 4]])
        XCTAssertEqual(recovery.scopeConflicts.map { $0.entries.map(\.number) }, [[1, 2]])
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4]))
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4], discardingRuleNumbers: [2], keepingScopeNumbers: [2]))
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4], discardingRuleNumbers: [1, 2],
                                                   keepingScopeNumbers: [2], discardingScopeNumbers: [3]))
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4], discardingRuleNumbers: [2],
                                                   keepingScopeNumbers: [2], discardingScopeNumbers: [3, 4]))
        let candidate = try recovery.candidate(keepingRuleNumbers: [4], discardingRuleNumbers: [2],
                                               keepingScopeNumbers: [2], discardingScopeNumbers: [3])
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
        XCTAssertNotNil(RoutingPreferencesStore(userDefaults: defaults).configurationIssueMessage)
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        defaults.set(candidate, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertNil(store.configurationIssueMessage)
        XCTAssertEqual(store.settings.rules.map(\.matcher.normalizedHost), ["untouched.example", "example.com", "a~b.com"])
        XCTAssertEqual(store.settings.rules.map(\.id), [1, 4, 5].map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        })
        XCTAssertEqual(store.settings.rules[1].destinationID.mode, .privateBrowsing)
        XCTAssertTrue(store.settings.alwaysShowChooser)
        let expectedScope = RoutingScope.onlyThese(matchers: [
            try DomainMatcher(host: "scope.example", includesSubdomains: true),
            try DomainMatcher(host: "outside.example", includesSubdomains: true)
        ], bypassDestinationID: OpenDestinationID(browserID: "com.apple.Safari", mode: .normal))
        XCTAssertEqual(store.settings.scope, expectedScope)
        let editor = RoutingSettingsEditor(store: store)
        let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: "com.apple.Safari")
        defer { browser.cleanup() }
        try editor.saveScope(expectedScope, browserRepository: browser.repository)
        try editor.setAlwaysShowChooser(false)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
    }

    func testScopeOnlyDuplicatesRequireAChoiceAndRecoverIntoAnEditableScope() throws {
        for kind in ["onlyThese", "allExceptThese"] {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
            document["rules"] = []
            document["scope"] = [
                "kind": kind,
                "bypassDestinationID": ["browserID": "com.apple.Safari", "mode": "normal"],
                "matchers": [
                    ["normalizedHost": "example.com.", "includesSubdomains": false],
                    ["normalizedHost": "example.com", "includesSubdomains": false, "annotation": "keep"],
                    ["normalizedHost": "example.com", "includesSubdomains": true],
                    ["normalizedHost": "unrelated.example", "includesSubdomains": false]
                ]
            ]
            let recovery = try RoutingPreferencesRecovery(originalData: JSONSerialization.data(withJSONObject: document))
            XCTAssertTrue(recovery.conflicts.isEmpty)
            XCTAssertEqual(recovery.scopeConflicts.map { $0.entries.map(\.number) }, [[1, 2]])
            for choices: Set<Int> in [[], [1, 2], [3], [99]] {
                XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [], keepingScopeNumbers: choices))
            }
            let candidate = try recovery.candidate(keepingRuleNumbers: [], keepingScopeNumbers: [2])
            let settings = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
            let matchers: [DomainMatcher]
            switch settings.scope {
            case let .onlyThese(value, _):
                XCTAssertEqual(kind, "onlyThese")
                matchers = value
            case let .allExceptThese(value, _):
                XCTAssertEqual(kind, "allExceptThese")
                matchers = value
            case .allDomains: return XCTFail("Limited scope was lost")
            }
            XCTAssertEqual(matchers.map(\.normalizedHost), ["example.com", "example.com", "unrelated.example"])
            XCTAssertEqual(matchers.map(\.includesSubdomains), [false, true, false])
            let drafts = matchers.map(ScopeMatcherDraft.init)
            XCTAssertTrue(ScopeMatcherDraftLogic.validation(for: drafts).invalidDraftIDs.isEmpty)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: candidate) as? [String: Any])
            let rawScope = try XCTUnwrap(raw["scope"] as? [String: Any])
            XCTAssertEqual((rawScope["matchers"] as? [[String: Any]])?.first?["annotation"] as? String, "keep")
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            defaults.set(candidate, forKey: RoutingPreferencesStore.storageKey)
            let store = RoutingPreferencesStore(userDefaults: defaults)
            let browser = try ScopeDestinationFixture(userDefaults: defaults, browserID: "com.apple.Safari")
            defer { browser.cleanup() }
            try RoutingSettingsEditor(store: store).saveScope(settings.scope, browserRepository: browser.repository)
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, settings)
        }
    }

    func testInvalidHostWithoutDuplicateRulesStillRequiresExplicitDiscard() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
        var rules = try XCTUnwrap(document["rules"] as? [[String: Any]])
        rules = [rules[0], rules[2]]
        rules[0]["matcher"] = ["normalizedHost": "example.com..", "includesSubdomains": false]
        document["rules"] = rules
        let recovery = try RoutingPreferencesRecovery(originalData: JSONSerialization.data(withJSONObject: document))
        XCTAssertTrue(recovery.conflicts.isEmpty)
        XCTAssertEqual(recovery.invalidRules.map(\.number), [1])
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: []))
        let settings = try JSONDecoder().decode(RoutingSettings.self, from: recovery.candidate(
            keepingRuleNumbers: [], discardingRuleNumbers: [1]
        ))
        XCTAssertEqual(settings.rules.map(\.matcher.normalizedHost), ["middle.example"])
    }

    func testLegacyConflictRequiresExplicitChoiceAndRecoveredSettingsRemainEditable() throws {
        let original = try legacyData()
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        defaults.set(original, forKey: RoutingPreferencesStore.storageKey)
        let blockedStore = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertNotNil(blockedStore.configurationIssueMessage)
        XCTAssertThrowsError(try blockedStore.replace(with: .default))

        let recovery = try RoutingPreferencesRecovery(originalData: original)
        XCTAssertEqual(recovery.conflicts.count, 1)
        let conflict = try XCTUnwrap(recovery.conflicts.first)
        XCTAssertEqual(conflict.matcher.normalizedHost, "example.com")
        XCTAssertEqual(conflict.entries.map(\.number), [2, 4])
        XCTAssertEqual(conflict.entries.map(\.originalHost), ["example.com.", "example.com"])
        XCTAssertEqual(conflict.entries.map(\.rule.destinationID), [
            OpenDestinationID(browserID: "com.apple.Safari", mode: .normal),
            OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)
        ])
        for choices: Set<Int> in [[], [2, 4], [1], [99]] {
            XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: choices))
        }
        // Inspecting, cancelling, and invalid choices have no write path.
        XCTAssertEqual(defaults.data(forKey: RoutingPreferencesStore.storageKey), original)

        let candidate = try recovery.candidate(keepingRuleNumbers: [4])
        let recovered = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
        XCTAssertEqual(recovered.rules.map(\.id), [1, 3, 4, 5].map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        })
        XCTAssertEqual(recovered.rules.map(\.matcher.normalizedHost), [
            "untouched.example", "middle.example", "example.com", "example.com"
        ])
        XCTAssertEqual(recovered.rules.map(\.matcher.includesSubdomains), [false, false, false, true])
        XCTAssertEqual(recovered.rules[2].destinationID, conflict.entries[1].rule.destinationID)
        XCTAssertEqual(recovered.rules[0].destinationID, conflict.entries[0].rule.destinationID)
        XCTAssertTrue(recovered.alwaysShowChooser)
        XCTAssertEqual(recovered.scope, .onlyThese(
            matchers: [try DomainMatcher(host: "example.com", includesSubdomains: true)],
            bypassDestinationID: OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
        ))
        XCTAssertEqual(try JSONDecoder().decode(RoutingSettings.self, from: JSONEncoder().encode(recovered)), recovered)

        // Simulate explicitly installing the candidate into an isolated suite.
        defaults.set(candidate, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: defaults)
        XCTAssertNil(store.configurationIssueMessage)
        let editor = RoutingSettingsEditor(store: store)
        try editor.setAlwaysShowChooser(false)
        try editor.saveRule(existingRuleID: recovered.rules[2].id, host: "example.com。",
                            includesSubdomains: false, destinationID: recovered.rules[2].destinationID)
        XCTAssertEqual(store.settings.rules, recovered.rules)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
    }

    func testNonDataExportsRemainUnsupportedForOfflineRecovery() throws {
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(RoutingSettings.default), encoding: .utf8))
        for value: Any in [json, 42, ["rules": []]] {
            let export = try PropertyListSerialization.data(fromPropertyList: [
                RoutingPreferencesStore.storageKey: value,
                "unrelated": ["keep": true]
            ], format: .binary, options: 0)

            XCTAssertThrowsError(try RoutingRecoveryExport(data: export)) { error in
                XCTAssertEqual(error as? RoutingPreferencesRecoveryError, .invalidExport)
            }
        }
    }

    func testExportRepairBacksUpExactBytesAndPreservesOtherPreferences() throws {
        let original = try legacyData()
        let export = try PropertyListSerialization.data(fromPropertyList: [
            RoutingPreferencesStore.storageKey: original,
            "BrowserPreferences.v1": Data([0, 1, 2, 255]),
            "unrelated": ["nested": "retained"]
        ], format: .binary, options: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("export.plist")
        try export.write(to: source)
        let recovery = try RoutingRecoveryExport(data: Data(contentsOf: source))
        let output = root.appendingPathComponent("prepared")
        try recovery.writeCandidate(keepingRuleNumbers: [4], to: output)

        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("original-routing.json")), original)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("original.plist")), export)
        let candidateBlob = try Data(contentsOf: output.appendingPathComponent("candidate-routing.json"))
        let candidateExport = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: output.appendingPathComponent("candidate.plist")), format: nil
        ) as? [String: Any])
        XCTAssertEqual(candidateExport[RoutingPreferencesStore.storageKey] as? Data, candidateBlob)
        XCTAssertEqual(candidateExport["BrowserPreferences.v1"] as? Data, Data([0, 1, 2, 255]))
        XCTAssertEqual(candidateExport["unrelated"] as? [String: String], ["nested": "retained"])
        XCTAssertEqual(try Data(contentsOf: source), export)
        XCTAssertNoThrow(try JSONDecoder().decode(RoutingSettings.self, from: candidateBlob))

        // Failed validation creates no output. A destination write failure and
        // a retry cannot overwrite either the source or a previous backup.
        let invalidOutput = root.appendingPathComponent("invalid")
        XCTAssertThrowsError(try recovery.writeCandidate(keepingRuleNumbers: [], to: invalidOutput))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))
        XCTAssertThrowsError(try recovery.writeCandidate(keepingRuleNumbers: [2], to: output)) {
            // Both an existing directory and a concurrent creator reach mkdir's EEXIST.
            XCTAssertEqual($0 as? RoutingPreferencesRecoveryError, .outputAlreadyExists)
        }
        XCTAssertThrowsError(try recovery.writeCandidate(
            keepingRuleNumbers: [4], to: source.appendingPathComponent("not-a-directory")
        ))
        XCTAssertEqual(try Data(contentsOf: source), export)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("original-routing.json")), original)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("candidate-routing.json")), candidateBlob)
    }

    func testEveryConflictNeedsAChoiceAndUnknownFieldsSurviveRepair() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData()) as? [String: Any])
        var rules = try XCTUnwrap(document["rules"] as? [[String: Any]])
        var additionalRule = rules[2]
        additionalRule["id"] = "00000000-0000-0000-0000-000000000006"
        additionalRule["matcher"] = ["normalizedHost": "middle.example%2e", "includesSubdomains": false]
        rules.append(additionalRule)
        rules[0]["futureRuleField"] = "preserved"
        document["rules"] = rules
        document["futureSettingsField"] = ["preserved": true]
        let recovery = try RoutingPreferencesRecovery(originalData: JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(recovery.conflicts.map { $0.entries.map(\.number) }, [[2, 4], [3, 6]])
        XCTAssertThrowsError(try recovery.candidate(keepingRuleNumbers: [4]))
        let candidate = try recovery.candidate(keepingRuleNumbers: [4, 6])
        let recovered = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
        XCTAssertEqual(recovered.rules.map(\.id), [1, 4, 5, 6].map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        })
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: candidate) as? [String: Any])
        XCTAssertEqual(raw["futureSettingsField"] as? [String: Bool], ["preserved": true])
        XCTAssertEqual((raw["rules"] as? [[String: Any]])?.first?["futureRuleField"] as? String, "preserved")
    }

    func testUnrelatedCorruptionAndHealthyConfigurationsAreNotRepaired() throws {
        for invalid in ["not JSON", "{}"] {
            XCTAssertThrowsError(try RoutingPreferencesRecovery(originalData: Data(invalid.utf8)))
        }
        let legacy = String(decoding: try legacyData(), as: UTF8.self)
        for invalid in [
            legacy.replacingOccurrences(of: "onlyThese", with: "unsupportedScope"),
            legacy.replacingOccurrences(of: "normal", with: "unsupportedMode")
        ] {
            XCTAssertThrowsError(try RoutingPreferencesRecovery(originalData: Data(invalid.utf8)))
        }
        let healthy = try RoutingPreferencesRecovery(originalData: JSONEncoder().encode(RoutingSettings.default))
        XCTAssertTrue(healthy.conflicts.isEmpty)
        XCTAssertThrowsError(try healthy.candidate(keepingRuleNumbers: []))
    }
}
