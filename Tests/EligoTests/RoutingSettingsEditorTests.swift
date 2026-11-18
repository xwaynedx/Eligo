import Foundation
import XCTest
@testable import Eligo

@MainActor
final class RoutingSettingsEditorTests: XCTestCase {
    func testSingleRuleCreationFromBothEntrypointsUsesTheSamePersistenceAndRoutingDecisions() throws {
        for fromChooser in [false, true] {
            for existingIncludesSubdomains in [false, true] {
                for requestedIncludesSubdomains in [false, true] {
                    for sameDestination in [false, true] {
                        let fixture = RoutingSettingsEditorFixture()
                        defer { fixture.cleanup() }
                        let existingRule = DomainRule(
                            matcher: try DomainMatcher(host: "example.com", includesSubdomains: existingIncludesSubdomains),
                            destinationID: safariOpenDestination
                        )
                        let baseline = try makeBaselineRoutingSettings()
                        let original = try baseline.replacing(rules: baseline.rules + [existingRule])
                        try fixture.store.replace(with: original)
                        let writes = fixture.userDefaults.routingSettingsWriteCount
                        let destination = sameDestination ? safariOpenDestination : chromeOpenDestination
                        let session = DomainRuleSettingsSession(store: fixture.store, editor: fixture.editor)
                        _ = session.send(fromChooser
                            ? .requestRuleFromChooser(host: "example.com", destinationID: destination)
                            : .presentSingleRuleCreate)
                        var relay = DomainRuleSettingsPresentationRelay()
                        _ = relay.synchronize(with: session.state.presentation, rules: original.rules, destinations: [])
                        guard case let .single(item)? = relay.item else {
                            return XCTFail("两个入口都应打开单条创建表单")
                        }
                        XCTAssertNil(item.draft.existingRuleID)
                        var draft = item.draft
                        draft.host = "https://EXAMPLE.com./path?source=test"
                        draft.includesSubdomains = requestedIncludesSubdomains
                        draft.destinationID = destination
                        try DomainRuleSettingsAdapter.commitSingle(
                            item: item, draft: draft.normalizedForSaving(), session: session
                        )

                        let sameMatcher = existingIncludesSubdomains == requestedIncludesSubdomains
                        let reusesExisting = sameDestination && (sameMatcher || existingIncludesSubdomains)
                        let keepsBoth = !sameDestination && !sameMatcher
                        let saved = fixture.store.settings
                        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount - writes, reusesExisting ? 0 : 1)
                        XCTAssertEqual(saved.scope, original.scope)
                        XCTAssertEqual(saved.alwaysShowChooser, original.alwaysShowChooser)
                        XCTAssertEqual(Array(saved.rules.prefix(baseline.rules.count)), baseline.rules)
                        if reusesExisting {
                            XCTAssertEqual(saved, original)
                        } else if keepsBoth {
                            XCTAssertEqual(saved.rules.count, original.rules.count + 1)
                            XCTAssertEqual(saved.rules.first(where: { $0.id == existingRule.id }), existingRule)
                            XCTAssertNotEqual(saved.rules.last?.id, existingRule.id)
                        } else {
                            XCTAssertEqual(saved.rules.map(\.id), original.rules.map(\.id))
                            XCTAssertEqual(saved.rules.last?.matcher.includesSubdomains, requestedIncludesSubdomains)
                            XCTAssertEqual(saved.rules.last?.destinationID, destination)
                        }
                        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, saved)
                        if keepsBoth {
                            let routedSettings = try saved.replacing(scope: .allDomains)
                            XCTAssertEqual(RoutingPolicy().basePlan(for: URL(string: "https://example.com")!, settings: routedSettings),
                                .open(destinationID: requestedIncludesSubdomains ? safariOpenDestination : destination, reason: .domainRule))
                            XCTAssertEqual(RoutingPolicy().basePlan(for: URL(string: "https://sub.example.com")!, settings: routedSettings),
                                .open(destinationID: requestedIncludesSubdomains ? destination : safariOpenDestination, reason: .domainRule))
                        }
                    }
                }
            }
        }
    }

    func testCreationUsesFinalHostAndPrivateModeWithoutMutatingTheOriginallyPrefilledRule() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let original = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: original)
        let rule = try XCTUnwrap(original.rules.first)
        let session = DomainRuleSettingsSession(store: fixture.store)
        _ = session.send(.requestRuleFromChooser(host: rule.matcher.normalizedHost, destinationID: rule.destinationID))
        let id = try XCTUnwrap(session.state.presentation?.id)
        let privateDestination = OpenDestinationID(browserID: rule.destinationID.browserID, mode: .privateBrowsing)
        try session.commit(.singleRule(presentationID: id, host: "changed.example.com", includesSubdomains: true,
                                       destinationID: privateDestination))
        XCTAssertEqual(Array(fixture.store.settings.rules.prefix(original.rules.count)), original.rules)
        XCTAssertEqual(fixture.store.settings.rules.last?.matcher.normalizedHost, "changed.example.com")
        XCTAssertEqual(fixture.store.settings.rules.last?.destinationID, privateDestination)
        XCTAssertEqual(fixture.store.settings.rules.count, original.rules.count + 1)
    }

    func testCreationUpdatesExactMatcherBeforeConsideringSameDestinationInBroaderRule() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let exact = DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false),
                               destinationID: safariOpenDestination)
        let broad = DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: true),
                               destinationID: chromeOpenDestination)
        try fixture.store.replace(with: RoutingSettings(scope: .allDomains, rules: [broad, exact], alwaysShowChooser: false))
        try fixture.editor.createRule(host: "example.com", includesSubdomains: false, destinationID: chromeOpenDestination)
        XCTAssertEqual(fixture.store.settings.rules.map(\.id), [broad.id, exact.id])
        XCTAssertEqual(fixture.store.settings.rules.first, broad)
        XCTAssertEqual(fixture.store.settings.rules.last?.destinationID, chromeOpenDestination)
        XCTAssertEqual(RoutingPolicy().basePlan(for: URL(string: "https://example.com")!, settings: fixture.store.settings),
                       .open(destinationID: chromeOpenDestination, reason: .domainRule))
    }

    func testCreationValidationErrorsDoNotWriteOrChangeSettings() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let original = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: original)
        let writes = fixture.userDefaults.routingSettingsWriteCount
        XCTAssertThrowsError(try fixture.editor.createRule(host: "example.com", includesSubdomains: false, destinationID: nil)) {
            XCTAssertEqual($0 as? RoutingSettingsEditorError, .destinationRequired)
        }
        XCTAssertThrowsError(try fixture.editor.createRule(host: "invalid/path", includesSubdomains: false, destinationID: safariOpenDestination)) {
            XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost)
        }
        XCTAssertThrowsError(try fixture.editor.createRule(host: "127.0.0.1", includesSubdomains: true, destinationID: safariOpenDestination)) {
            XCTAssertEqual($0 as? DomainMatcherValidationError, .ipAddressesCannotIncludeSubdomains)
        }
        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount, writes)
        XCTAssertEqual(fixture.store.settings, original)
    }

    func testScopeSaveRejectsUnavailableTargetsAndUnreadableConfigurationWithoutWriting() throws {
        for change in ["uninstalled", "disabled", "removed", "private", "unreadable"] {
            let fixture = RoutingSettingsEditorFixture()
            defer { fixture.cleanup() }
            let browser = try ScopeDestinationFixture(userDefaults: fixture.userDefaults)
            defer { browser.cleanup() }
            let original = try makeBaselineRoutingSettings()
            try fixture.store.replace(with: original)
            let bytes = fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey)
            let writes = fixture.userDefaults.routingSettingsWriteCount
            var target = browser.destinationID
            switch change {
            case "uninstalled":
                try FileManager.default.removeItem(at: browser.browser.appURL)
                XCTAssertFalse(browser.repository.enabledBrowsers.isEmpty, "The repository still has its scan cache")
            case "disabled":
                try browser.preferences.save([ConfiguredBrowser(browser: browser.browser, isEnabled: false)])
            case "removed":
                try browser.preferences.saveScannedBrowsers([], at: Date())
            case "private":
                target = OpenDestinationID(browserID: browser.browser.id, mode: .privateBrowsing)
            case "unreadable":
                fixture.userDefaults.set(Data("corrupt".utf8), forKey: BrowserPreferences.storageKey)
            default: XCTFail("Unknown fixture")
            }
            let scope = RoutingScope.onlyThese(
                matchers: [try DomainMatcher(host: "new.example", includesSubdomains: false)],
                bypassDestinationID: target
            )
            XCTAssertThrowsError(try fixture.editor.saveScope(scope, browserRepository: browser.repository), change) {
                XCTAssertEqual($0 as? ScopeSaveError,
                               change == "unreadable" ? .browserConfigurationUnavailable : .bypassDestinationUnavailable)
            }
            XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount, writes, change)
            XCTAssertEqual(fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey), bytes, change)
            XCTAssertEqual(fixture.store.settings, original, change)
        }
    }

    func testScopeSaveCanRetryAfterTargetReturnsAndPreservesLatestOtherSettings() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: fixture.userDefaults)
        defer { browser.cleanup() }
        let scope = RoutingScope.allExceptThese(
            matchers: [try DomainMatcher(host: "example.com", includesSubdomains: true)],
            bypassDestinationID: browser.destinationID
        )
        try browser.preferences.save([ConfiguredBrowser(browser: browser.browser, isEnabled: false)])
        XCTAssertThrowsError(try fixture.editor.saveScope(scope, browserRepository: browser.repository))
        try browser.preferences.save([ConfiguredBrowser(browser: browser.browser, isEnabled: true)])
        try fixture.editor.setAlwaysShowChooser(true)
        try fixture.editor.saveRule(existingRuleID: nil, host: "latest.example", includesSubdomains: false,
                                    destinationID: browser.destinationID)
        let rules = fixture.store.settings.rules
        let writes = fixture.userDefaults.routingSettingsWriteCount
        try fixture.editor.saveScope(scope, browserRepository: browser.repository)
        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount, writes + 1)
        let reloaded = RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings
        XCTAssertEqual(reloaded.scope, scope)
        XCTAssertEqual(reloaded.rules, rules)
        XCTAssertTrue(reloaded.alwaysShowChooser)
    }

    func testAllDomainsSaveDoesNotRequireReadableBrowserConfiguration() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: fixture.userDefaults)
        defer { browser.cleanup() }
        try fixture.store.replace(with: makeBaselineRoutingSettings())
        let corrupt = Data("corrupt".utf8)
        fixture.userDefaults.set(corrupt, forKey: BrowserPreferences.storageKey)
        XCTAssertThrowsError(try browser.repository.currentNormalDestination(for: browser.destinationID))
        try fixture.editor.saveScope(.allDomains, browserRepository: browser.repository)
        XCTAssertEqual(fixture.store.settings.scope, .allDomains)
        XCTAssertEqual(fixture.userDefaults.data(forKey: BrowserPreferences.storageKey), corrupt)
    }

    func testAddingRuleMatcherDoesNotAcquireFullScopeTargetAvailabilityRequirement() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        try fixture.store.replace(with: makeBaselineRoutingSettings())
        let originalTarget = fixture.store.settings.scope.bypassDestinationID
        let addition = try DomainMatcher(host: "outside.example", includesSubdomains: false)
        XCTAssertTrue(try fixture.editor.addRuleMatcherToScope(addition))
        XCTAssertEqual(fixture.store.settings.scope.bypassDestinationID, originalTarget)
        XCTAssertTrue(fixture.store.settings.scope.contains(addition))
    }

    func testAlwaysShowChooserMutationPersistsThroughEditor() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }

        try fixture.editor.setAlwaysShowChooser(true)

        XCTAssertTrue(fixture.store.settings.alwaysShowChooser)
        XCTAssertTrue(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings.alwaysShowChooser
        )
        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount, 1)
    }

    func testCreateDomainRulePreservesExistingDomainRulesAndPersistsOnce() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let existingDomainRuleIDs = Set(settingsBefore.rules.map(\.id))
        let newDomainMatcher = try DomainMatcher(host: "new.example.com", includesSubdomains: false)

        try fixture.editor.saveRule(
            existingRuleID: nil,
            host: newDomainMatcher.normalizedHost,
            includesSubdomains: newDomainMatcher.includesSubdomains,
            destinationID: chromeOpenDestination
        )

        let currentSettings = fixture.store.settings
        let createdDomainRule = try XCTUnwrap(
            currentSettings.rules.first(where: { $0.matcher == newDomainMatcher })
        )
        XCTAssertEqual(currentSettings.rules.count, settingsBefore.rules.count + 1)
        for existingDomainRule in settingsBefore.rules {
            XCTAssertEqual(
                currentSettings.rules.first(where: { $0.id == existingDomainRule.id }),
                existingDomainRule
            )
        }
        XCTAssertFalse(existingDomainRuleIDs.contains(createdDomainRule.id))
        XCTAssertEqual(createdDomainRule.destinationID, chromeOpenDestination)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            currentSettings
        )
    }

    func testEditExistingDomainRuleReplacesInPlaceAndPreservesRuleOrder() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let targetDomainRule = try XCTUnwrap(settingsBefore.rules.first)
        let otherDomainRules = settingsBefore.rules.filter { $0.id != targetDomainRule.id }

        try fixture.editor.saveRule(
            existingRuleID: targetDomainRule.id,
            host: "edited.example.com",
            includesSubdomains: true,
            destinationID: chromeOpenDestination
        )

        let currentSettings = fixture.store.settings
        let editedDomainRules = currentSettings.rules.filter { $0.id == targetDomainRule.id }
        let editedDomainRule = try XCTUnwrap(editedDomainRules.first)
        XCTAssertEqual(editedDomainRules.count, 1)
        XCTAssertEqual(editedDomainRule.matcher.normalizedHost, "edited.example.com")
        XCTAssertTrue(editedDomainRule.matcher.includesSubdomains)
        XCTAssertEqual(editedDomainRule.destinationID, chromeOpenDestination)
        for otherDomainRule in otherDomainRules {
            XCTAssertEqual(
                currentSettings.rules.first(where: { $0.id == otherDomainRule.id }),
                otherDomainRule
            )
        }
        XCTAssertEqual(
            currentSettings.rules.map(\.id),
            settingsBefore.rules.map(\.id)
        )
        XCTAssertEqual(currentSettings.scope, settingsBefore.scope)
        XCTAssertEqual(currentSettings.alwaysShowChooser, settingsBefore.alwaysShowChooser)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            currentSettings
        )
    }

    func testStaleDomainRuleEditWithValidContentThrowsRuleNotFoundAndPreservesSnapshot() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let initialSettings = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: initialSettings)
        let deletedDomainRule = try XCTUnwrap(initialSettings.rules.first)
        try fixture.editor.deleteRules(withIDs: [deletedDomainRule.id])
        let settingsBefore = fixture.store.settings
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let storedDataBefore = fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey)

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: deletedDomainRule.id,
                host: "stale.example.com",
                includesSubdomains: false,
                destinationID: chromeOpenDestination
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsEditorError, .ruleNotFound)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
        XCTAssertEqual(
            fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey),
            storedDataBefore
        )
    }

    func testStaleDomainRuleEditWithMissingOpenDestinationUsesDestinationRequiredPriority() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let staleDomainRuleID = makeStaleDomainRuleID(notIn: settingsBefore)

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: staleDomainRuleID,
                host: "stale.example.com",
                includesSubdomains: false,
                destinationID: nil
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsEditorError, .destinationRequired)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testStaleDomainRuleEditWithInvalidDomainMatcherUsesInvalidHostPriority() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let staleDomainRuleID = makeStaleDomainRuleID(notIn: settingsBefore)

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: staleDomainRuleID,
                host: "https://stale.example.com/path",
                includesSubdomains: false,
                destinationID: chromeOpenDestination
            )
        ) { error in
            XCTAssertEqual(error as? DomainMatcherValidationError, .invalidHost)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testStaleDomainRuleEditWithExactDomainMatcherDuplicateUsesDuplicatePriority() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let staleDomainRuleID = makeStaleDomainRuleID(notIn: settingsBefore)
        let existingDomainRule = try XCTUnwrap(settingsBefore.rules.first)

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: staleDomainRuleID,
                host: existingDomainRule.matcher.normalizedHost,
                includesSubdomains: existingDomainRule.matcher.includesSubdomains,
                destinationID: chromeOpenDestination
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsValidationError, .duplicateRuleMatcher)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testBulkCreateDomainRulesPersistsAllRulesOnce() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let domainMatchers = try [
            DomainMatcher(host: "docs.example.com", includesSubdomains: false),
            DomainMatcher(host: "support.example.com", includesSubdomains: true)
        ]
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            domainMatchers,
            destinationID: safariOpenDestination,
            replaceExisting: false
        )

        XCTAssertEqual(fixture.store.settings.rules.map(\.matcher), domainMatchers)
        XCTAssertTrue(
            fixture.store.settings.rules.allSatisfy {
                $0.destinationID == safariOpenDestination
            }
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
    }

    func testBulkCreateWithEmptyMatchersThrowsEmptyBulkSubmissionWithoutPersistence() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertThrowsError(
            try fixture.editor.saveRulesInBulk(
                [],
                destinationID: safariOpenDestination,
                replaceExisting: false
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsEditorError, .emptyBulkSubmission)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testBulkCreateSkipsExactDomainMatcherWhenReplacementIsDisabled() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let domainMatcher = try DomainMatcher(host: "docs.example.com", includesSubdomains: false)

        try fixture.editor.saveRulesInBulk(
            [domainMatcher],
            destinationID: safariOpenDestination,
            replaceExisting: false
        )
        let settingsBefore = fixture.store.settings
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            [domainMatcher],
            destinationID: chromeOpenDestination,
            replaceExisting: false
        )

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
    }

    func testBulkCreateDeduplicatesRepeatedExactDomainMatchers() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let domainMatcher = try DomainMatcher(host: "docs.example.com", includesSubdomains: false)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            [domainMatcher, domainMatcher],
            destinationID: safariOpenDestination,
            replaceExisting: false
        )

        XCTAssertEqual(fixture.store.settings.rules.count, 1)
        XCTAssertEqual(fixture.store.settings.rules.first?.matcher, domainMatcher)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
    }

    func testBulkCreateReplacesExactDomainMatcherAndPreservesIdentityWhenRequested() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let domainMatcher = try DomainMatcher(host: "docs.example.com", includesSubdomains: false)

        try fixture.editor.saveRulesInBulk(
            [domainMatcher],
            destinationID: safariOpenDestination,
            replaceExisting: false
        )
        let existingDomainRule = try XCTUnwrap(fixture.store.settings.rules.first)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            [domainMatcher],
            destinationID: chromeOpenDestination,
            replaceExisting: true
        )

        XCTAssertEqual(
            fixture.store.settings.rules,
            [
                DomainRule(
                    id: existingDomainRule.id,
                    matcher: domainMatcher,
                    destinationID: chromeOpenDestination
                )
            ]
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            fixture.store.settings
        )
    }

    func testBulkReplacePersistsOrderIdentityDestinationsAndPreservesScope() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let existingIDs = settingsBefore.rules.map(\.id)
        let docs = settingsBefore.rules[0].matcher
        let support = settingsBefore.rules[1].matcher
        let newTop = try DomainMatcher(host: "new.example.com", includesSubdomains: false)
        let newSubdomains = try DomainMatcher(host: "new.example.com", includesSubdomains: true)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            [newTop, docs, support, newSubdomains, docs],
            destinationID: chromeOpenDestination,
            replaceExisting: true
        )

        let savedSettings = fixture.store.settings
        XCTAssertEqual(savedSettings.rules.map(\.matcher), [docs, support, newTop, newSubdomains])
        XCTAssertEqual(Array(savedSettings.rules.map(\.id).prefix(2)), existingIDs)
        XCTAssertEqual(
            savedSettings.rules.map(\.destinationID),
            [chromeOpenDestination, chromeOpenDestination, chromeOpenDestination, chromeOpenDestination]
        )
        XCTAssertFalse(existingIDs.contains(savedSettings.rules[2].id))
        XCTAssertFalse(existingIDs.contains(savedSettings.rules[3].id))
        XCTAssertNotEqual(savedSettings.rules[2].id, savedSettings.rules[3].id)
        XCTAssertEqual(savedSettings.scope, settingsBefore.scope)
        XCTAssertEqual(savedSettings.alwaysShowChooser, settingsBefore.alwaysShowChooser)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, savedSettings)
        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount - writeCountBefore, 1)
    }

    func testBulkSkipKeepsExistingRulesAndDeduplicatesInputWithoutExtraWrites() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let docs = settingsBefore.rules[0].matcher
        let newTop = try DomainMatcher(host: "new.example.com", includesSubdomains: false)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.saveRulesInBulk(
            [newTop, docs, newTop],
            destinationID: chromeOpenDestination,
            replaceExisting: false
        )

        let savedSettings = fixture.store.settings
        XCTAssertEqual(savedSettings.rules.map(\.matcher), settingsBefore.rules.map(\.matcher) + [newTop])
        XCTAssertEqual(Array(savedSettings.rules.map(\.id).prefix(2)), settingsBefore.rules.map(\.id))
        XCTAssertEqual(savedSettings.rules[0], settingsBefore.rules[0])
        XCTAssertEqual(savedSettings.rules[2].destinationID, chromeOpenDestination)
        XCTAssertEqual(savedSettings.scope, settingsBefore.scope)
        XCTAssertEqual(savedSettings.alwaysShowChooser, settingsBefore.alwaysShowChooser)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, savedSettings)
        XCTAssertEqual(fixture.userDefaults.routingSettingsWriteCount - writeCountBefore, 1)
    }

    func testBulkSaveFailureKeepsStoredBytesAndDoesNotAdoptCandidates() throws {
        let (userDefaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let corrupt = Data("corrupt".utf8)
        userDefaults.set(corrupt, forKey: RoutingPreferencesStore.storageKey)
        let store = RoutingPreferencesStore(userDefaults: userDefaults)
        let editor = RoutingSettingsEditor(store: store)
        let matcher = try DomainMatcher(host: "docs.example.com", includesSubdomains: false)

        XCTAssertThrowsError(
            try editor.saveRulesInBulk(
                [matcher],
                destinationID: safariOpenDestination,
                replaceExisting: true
            )
        ) { error in
            XCTAssertEqual(error as? RoutingPreferencesStoreError, .savedSettingsUnreadable)
        }

        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(userDefaults.data(forKey: RoutingPreferencesStore.storageKey), corrupt)
    }

    func testDeleteDomainRulesRemovesRequestedDomainRuleAndPreservesOthers() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        try fixture.editor.saveRulesInBulk(
            [
                try DomainMatcher(host: "first.example.com", includesSubdomains: false),
                try DomainMatcher(host: "second.example.com", includesSubdomains: false)
            ],
            destinationID: safariOpenDestination,
            replaceExisting: false
        )
        let domainRules = fixture.store.settings.rules
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        try fixture.editor.deleteRules(withIDs: [domainRules[0].id])

        XCTAssertEqual(fixture.store.settings.rules, [domainRules[1]])
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings.rules,
            [domainRules[1]]
        )
    }

    func testDeleteUnknownDomainRuleLeavesSnapshotUnchanged() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let unknownDomainRuleID = makeStaleDomainRuleID(notIn: settingsBefore)

        try fixture.editor.deleteRules(withIDs: [unknownDomainRuleID])

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
    }

    func testAddDomainMatcherToRoutingScopePersistsAndPreservesBypassDestination() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        let existingScopeMatcher = try DomainMatcher(
            host: "scope.example.com",
            includesSubdomains: false
        )
        let settingsWithRoutingScope = try RoutingSettings(
            scope: .onlyThese(
                matchers: [existingScopeMatcher],
                bypassDestinationID: chromeOpenDestination
            ),
            rules: settingsBefore.rules,
            alwaysShowChooser: settingsBefore.alwaysShowChooser
        )
        try fixture.store.replace(with: settingsWithRoutingScope)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let addedDomainMatcher = try DomainMatcher(
            host: "added.example.com",
            includesSubdomains: true
        )

        XCTAssertTrue(try fixture.editor.addRuleMatcherToScope(addedDomainMatcher))

        let expectedSettings = try settingsWithRoutingScope.replacing(
            scope: .onlyThese(
                matchers: [existingScopeMatcher, addedDomainMatcher],
                bypassDestinationID: chromeOpenDestination
            )
        )
        XCTAssertEqual(fixture.store.settings, expectedSettings)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            expectedSettings
        )
    }

    func testAddDuplicateDomainMatcherToRoutingScopeIsNoOp() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        let existingScopeMatcher = try DomainMatcher(
            host: "scope.example.com",
            includesSubdomains: false
        )
        let settingsWithRoutingScope = try RoutingSettings(
            scope: .onlyThese(
                matchers: [existingScopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: settingsBefore.rules,
            alwaysShowChooser: settingsBefore.alwaysShowChooser
        )
        try fixture.store.replace(with: settingsWithRoutingScope)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertFalse(try fixture.editor.addRuleMatcherToScope(existingScopeMatcher))

        XCTAssertEqual(fixture.store.settings, settingsWithRoutingScope)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsWithRoutingScope
        )
    }

    func testAddMatcherAlreadyCoveredByRoutingScopeIsNoOp() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let broadMatcher = try DomainMatcher(
            host: "example.com",
            includesSubdomains: true
        )
        let nestedMatcher = try DomainMatcher(
            host: "sub.example.com",
            includesSubdomains: false
        )
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [broadMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [],
            alwaysShowChooser: false
        )
        try fixture.store.replace(with: settings)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertFalse(try fixture.editor.addRuleMatcherToScope(nestedMatcher))
        XCTAssertEqual(fixture.store.settings, settings)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testAddSubdomainMatcherWhenScopeOnlyCoversBaseExactly() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let exactScopeMatcher = try DomainMatcher(
            host: "example.com",
            includesSubdomains: false
        )
        let subdomainMatcher = try DomainMatcher(
            host: "example.com",
            includesSubdomains: true
        )
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [exactScopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [],
            alwaysShowChooser: false
        )
        try fixture.store.replace(with: settings)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertTrue(try fixture.editor.addRuleMatcherToScope(subdomainMatcher))

        XCTAssertEqual(
            fixture.store.settings.scope,
            .onlyThese(
                matchers: [exactScopeMatcher, subdomainMatcher],
                bypassDestinationID: safariOpenDestination
            )
        )
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            1
        )
    }

    func testAddDomainMatcherToAllDomainsRoutingScopeIsNoOp() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        let settingsWithRoutingScope = try RoutingSettings(
            scope: .allDomains,
            rules: settingsBefore.rules,
            alwaysShowChooser: settingsBefore.alwaysShowChooser
        )
        try fixture.store.replace(with: settingsWithRoutingScope)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let domainMatcher = try DomainMatcher(host: "added.example.com", includesSubdomains: false)

        XCTAssertFalse(try fixture.editor.addRuleMatcherToScope(domainMatcher))

        XCTAssertEqual(fixture.store.settings, settingsWithRoutingScope)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsWithRoutingScope
        )
    }

    func testAddDomainMatcherToAllExceptTheseRoutingScopeIsNoOp() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        let excludedDomainMatcher = try DomainMatcher(
            host: "excluded.example.com",
            includesSubdomains: false
        )
        let settingsWithRoutingScope = try RoutingSettings(
            scope: .allExceptThese(
                matchers: [excludedDomainMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: settingsBefore.rules,
            alwaysShowChooser: settingsBefore.alwaysShowChooser
        )
        try fixture.store.replace(with: settingsWithRoutingScope)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let domainMatcher = try DomainMatcher(host: "added.example.com", includesSubdomains: false)

        XCTAssertFalse(try fixture.editor.addRuleMatcherToScope(domainMatcher))

        XCTAssertEqual(fixture.store.settings, settingsWithRoutingScope)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsWithRoutingScope
        )
    }

    func testExactDomainMatcherDuplicateIsRejectedWithoutChangingSnapshot() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount
        let existingDomainRule = try XCTUnwrap(settingsBefore.rules.first)

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: nil,
                host: "DOCS.EXAMPLE.COM.",
                includesSubdomains: existingDomainRule.matcher.includesSubdomains,
                destinationID: chromeOpenDestination
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsValidationError, .duplicateRuleMatcher)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settingsBefore
        )
    }

    func testMissingOpenDestinationIsRejectedWithoutPersistence() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: nil,
                host: "new.example.com",
                includesSubdomains: false,
                destinationID: nil
            )
        ) { error in
            XCTAssertEqual(error as? RoutingSettingsEditorError, .destinationRequired)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    func testInvalidDomainMatcherIsRejectedWithoutPersistence() throws {
        let fixture = RoutingSettingsEditorFixture()
        defer { fixture.cleanup() }
        let settingsBefore = try makeBaselineRoutingSettings()
        try fixture.store.replace(with: settingsBefore)
        let writeCountBefore = fixture.userDefaults.routingSettingsWriteCount

        XCTAssertThrowsError(
            try fixture.editor.saveRule(
                existingRuleID: nil,
                host: "https://new.example.com/path",
                includesSubdomains: false,
                destinationID: safariOpenDestination
            )
        ) { error in
            XCTAssertEqual(error as? DomainMatcherValidationError, .invalidHost)
        }

        XCTAssertEqual(fixture.store.settings, settingsBefore)
        XCTAssertEqual(
            fixture.userDefaults.routingSettingsWriteCount - writeCountBefore,
            0
        )
    }

    private var safariOpenDestination: OpenDestinationID {
        OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
    }

    private var chromeOpenDestination: OpenDestinationID {
        OpenDestinationID(browserID: "com.google.Chrome", mode: .normal)
    }

    private func makeBaselineRoutingSettings() throws -> RoutingSettings {
        try RoutingSettings(
            scope: .onlyThese(
                matchers: [
                    try DomainMatcher(host: "scope.example.com", includesSubdomains: false)
                ],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [
                DomainRule(
                    matcher: try DomainMatcher(host: "docs.example.com", includesSubdomains: false),
                    destinationID: safariOpenDestination
                ),
                DomainRule(
                    matcher: try DomainMatcher(host: "support.example.com", includesSubdomains: true),
                    destinationID: chromeOpenDestination
                )
            ],
            alwaysShowChooser: true
        )
    }

    private func makeStaleDomainRuleID(notIn settings: RoutingSettings) -> UUID {
        var staleDomainRuleID = UUID()
        while settings.rules.contains(where: { $0.id == staleDomainRuleID }) {
            staleDomainRuleID = UUID()
        }
        return staleDomainRuleID
    }
}

@MainActor
private final class RoutingSettingsEditorFixture {
    let userDefaults: CountingUserDefaults
    let store: RoutingPreferencesStore
    let editor: RoutingSettingsEditor

    private let suiteName: String

    init() {
        let suiteName = "EligoTests.RoutingSettingsEditor.\(UUID().uuidString)"
        self.suiteName = suiteName
        userDefaults = CountingUserDefaults(
            suiteName: suiteName,
            countedKey: RoutingPreferencesStore.storageKey
        )
        store = RoutingPreferencesStore(userDefaults: userDefaults)
        editor = RoutingSettingsEditor(store: store)
    }

    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private final class CountingUserDefaults: UserDefaults {
    private(set) var routingSettingsWriteCount = 0
    private let countedKey: String

    init(suiteName: String, countedKey: String) {
        self.countedKey = countedKey
        super.init(suiteName: suiteName)!
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == countedKey {
            routingSettingsWriteCount += 1
        }
        super.set(value, forKey: defaultName)
    }
}
