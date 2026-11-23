import XCTest
@testable import Eligo

@MainActor
final class DomainRuleSettingsAdapterTests: XCTestCase {
    func testCreationFeedbackTracksHostScopeAndDestinationChanges() throws {
        let safari = OpenDestination(browser: makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari"), mode: .normal)
        let chrome = OpenDestination(browser: makeBrowser(name: "Chrome", bundleIdentifier: "com.google.Chrome"), mode: .normal)
        let privateChrome = OpenDestination(browser: chrome.browser, mode: .privateBrowsing)
        let destinations = [safari, chrome, privateChrome]
        let rule = try makeRule(host: "example.com", destinationID: safari.id)
        let fixture = try AdapterFixture(rules: [rule])
        defer { fixture.cleanup() }
        fixture.languageStore.select(.simplifiedChinese)
        var draft = RuleEditorDraft(destinationID: safari.id, host: "https://EXAMPLE.com/path")
        var plan = try XCTUnwrap(draft.creationPlan(in: [rule]))
        XCTAssertEqual(plan.action, .reuse(rule))
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: false)), "完成")
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: true)), "使用已有规则并打开")
        XCTAssertEqual(plan.message(destinations: destinations, using: fixture.languageStore),
                       "该规则已存在：example.com → Safari，无需重复创建。")

        draft.includesSubdomains = true
        plan = try XCTUnwrap(draft.creationPlan(in: [rule]))
        XCTAssertEqual(plan.action, .expand(rule))
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: false)), "扩展现有规则")
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: true)), "扩展规则并打开")
        XCTAssertEqual(plan.message(destinations: destinations, using: fixture.languageStore),
                       "已有规则仅将 example.com 交给 Safari，将扩展为包含子域名。")

        draft.destinationID = privateChrome.id
        plan = try XCTUnwrap(draft.creationPlan(in: [rule]))
        XCTAssertEqual(plan.action, .create)
        let privateName = privateChrome.displayName(using: fixture.languageStore)
        XCTAssertEqual(plan.message(destinations: destinations, using: fixture.languageStore),
                       "将保留两种范围：example.com 使用 Safari；子域名默认使用 \(privateName)。更具体的规则优先。")

        draft.includesSubdomains = false
        plan = try XCTUnwrap(draft.creationPlan(in: [rule]))
        XCTAssertEqual(plan.action, .update(rule))
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: false)), "更新已有规则")
        XCTAssertEqual(fixture.languageStore.text(plan.saveTitle(opensPendingLink: true)), "更新规则并打开")
        XCTAssertEqual(plan.message(destinations: destinations, using: fixture.languageStore),
                       "相同范围的规则已存在，将更新打开目标：Safari → \(privateName)。")
        fixture.languageStore.select(.english)
        XCTAssertEqual(plan.saveTitle(opensPendingLink: true), "Update Rule and Open")
        XCTAssertEqual(plan.message(destinations: destinations, using: fixture.languageStore),
                       "A rule with this scope already exists. Update its destination: Safari → \(privateChrome.displayName(using: fixture.languageStore)).")

        draft.host = "other.example.com"
        plan = try XCTUnwrap(draft.creationPlan(in: [rule]))
        XCTAssertEqual(plan.action, .create)
        XCTAssertNil(plan.message(destinations: destinations, using: fixture.languageStore))
        XCTAssertEqual(plan.saveTitle(opensPendingLink: false), "Save")
        draft.destinationID = nil
        XCTAssertNil(draft.creationPlan(in: [rule]))
        XCTAssertNil(RuleEditorDraft(rule: rule).creationPlan(in: [rule]))
    }

    func testCoveredScopeFeedbackAndSameBrowserPrivateModeRemainDistinct() throws {
        let browser = makeBrowser(name: "Chrome", bundleIdentifier: "com.google.Chrome")
        let normal = OpenDestination(browser: browser, mode: .normal)
        let privateMode = OpenDestination(browser: browser, mode: .privateBrowsing)
        let broad = DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: true), destinationID: normal.id)
        let fixture = try AdapterFixture(rules: [broad])
        defer { fixture.cleanup() }
        fixture.languageStore.select(.simplifiedChinese)
        var draft = RuleEditorDraft(destinationID: normal.id, host: "example.com")
        let covered = try XCTUnwrap(draft.creationPlan(in: [broad]))
        XCTAssertEqual(covered.action, .reuse(broad))
        XCTAssertEqual(covered.message(destinations: [normal, privateMode], using: fixture.languageStore),
                       "已有规则将 example.com 及其子域名交给 Chrome，已覆盖当前范围，无需新增。")
        draft.destinationID = privateMode.id
        let exception = try XCTUnwrap(draft.creationPlan(in: [broad]))
        XCTAssertEqual(exception.action, .create)
        XCTAssertEqual(exception.message(destinations: [normal, privateMode], using: fixture.languageStore),
                       "将保留两种范围：example.com 使用 \(privateMode.displayName(using: fixture.languageStore))；子域名默认使用 Chrome。更具体的规则优先。")
        draft.includesSubdomains = true
        XCTAssertEqual(draft.creationPlan(in: [broad])?.action, .update(broad))
    }

    func testRuleSearchAndBrowserFilterComposeWithoutChangingSelection() throws {
        let safari = OpenDestination(browser: makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari"), mode: .normal)
        let chrome = OpenDestination(browser: makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"), mode: .privateBrowsing)
        let rules = try [makeRule(host: "docs.example.com", destinationID: safari.id),
                         makeRule(host: "github.com", destinationID: chrome.id)]
        let fixture = try AdapterFixture(rules: rules)
        defer { fixture.cleanup() }
        _ = fixture.session.send(.selectAllRules)
        // Chrome is retained in the browser directory while unavailable as a new target.
        let browserNames = [safari.browser.id: safari.browser.name, chrome.browser.id: "Work Browser"]
        func search(_ query: String, _ browser: Browser.ID? = nil) -> [DomainRule.ID] {
            RulesSettingsView.filteredRules(rules, query: query, browserID: browser,
                context: .init(destinations: [safari], browserNames: browserNames, appLanguageStore: fixture.languageStore)).map(\.id)
        }
        XCTAssertEqual(search(" DOCS "), [rules[0].id])
        XCTAssertEqual(search("work browser"), [rules[1].id])
        XCTAssertEqual(search("", chrome.browser.id), [rules[1].id])
        XCTAssertTrue(search("docs", chrome.browser.id).isEmpty)
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, Set(rules.map(\.id)))
        XCTAssertEqual(DomainRuleSettingsAdapter.pageMessage(for: .updateRuleDestination(ruleID: rules[0].id),
            appLanguageStore: fixture.languageStore), "The rule destination could not be saved.")
    }

    func testSingleDraftsUsePersistentSnapshotAndChooserPrefillWithoutDestinationFallback() throws {
        let firstDestination = OpenDestination(
            browser: makeBrowser(name: "First", bundleIdentifier: "com.example.First"),
            mode: .normal
        )
        let existingRule = try makeRule(
            host: "stored.example.com",
            destinationID: adapterDestination
        )
        let chooserDestination = OpenDestinationID(
            browserID: "com.example.UnavailableChooserDestination",
            mode: .privateBrowsing
        )
        var relay = DomainRuleSettingsPresentationRelay()

        let createID = DomainRuleSettingsSession.PresentationID()
        _ = relay.synchronize(
            with: .singleRuleCreate(id: createID, prefill: nil),
            rules: [existingRule],
            destinations: [firstDestination]
        )
        guard case let .single(createItem)? = relay.item else {
            return XCTFail("Expected create item")
        }
        XCTAssertEqual(createItem.id, createID)
        XCTAssertNil(createItem.draft.existingRuleID)
        XCTAssertEqual(createItem.draft.host, "")
        XCTAssertFalse(createItem.draft.includesSubdomains)
        XCTAssertEqual(createItem.draft.destinationID, firstDestination.id)

        let chooserMatcher = try DomainMatcher(
            host: "CHOOSER.example.com.",
            includesSubdomains: true
        )
        let chooserCreateID = DomainRuleSettingsSession.PresentationID()
        _ = relay.synchronize(
            with: .singleRuleCreate(
                id: chooserCreateID,
                prefill: .init(matcher: chooserMatcher, destinationID: chooserDestination)
            ),
            rules: [existingRule],
            destinations: [firstDestination]
        )
        guard case let .single(chooserCreateItem)? = relay.item else {
            return XCTFail("Expected chooser create item")
        }
        XCTAssertEqual(chooserCreateItem.draft.host, "chooser.example.com")
        XCTAssertTrue(chooserCreateItem.draft.includesSubdomains)
        XCTAssertEqual(chooserCreateItem.draft.destinationID, chooserDestination)

        let editID = DomainRuleSettingsSession.PresentationID()
        _ = relay.synchronize(
            with: .singleRuleEdit(id: editID, ruleID: existingRule.id),
            rules: [existingRule],
            destinations: [firstDestination]
        )
        guard case let .single(editItem)? = relay.item else {
            return XCTFail("Expected ordinary edit item")
        }
        XCTAssertEqual(editItem.draft.existingRuleID, existingRule.id)
        XCTAssertEqual(editItem.draft.host, existingRule.matcher.normalizedHost)
        XCTAssertEqual(editItem.draft.destinationID, existingRule.destinationID)
    }

    func testCapturedPresentationIDDrivesSubmissionsAndDismissalEffectOnce() throws {
        let existingRule = try makeRule(host: "existing.example.com")
        let fixture = try AdapterFixture(rules: [existingRule])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()

        DomainRuleSettingsAdapter.send(.editRule(ruleID: existingRule.id), to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [existingRule],
            destinations: []
        )
        guard case let .single(item)? = relay.item else {
            return XCTFail("Expected edit item")
        }
        let forgedDraft = RuleEditorDraft(
            existingRuleID: UUID(),
            destinationID: adapterDestination,
            host: "updated.example.com",
            includesSubdomains: true
        )

        let sheet = RuleEditorSheet(
            draft: forgedDraft,
            rules: [existingRule],
            destinationContext: .init(destinations: [], browserNames: [:], appLanguageStore: fixture.languageStore)
        ) { (draft: RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void in
            try DomainRuleSettingsAdapter.commitSingle(item: item, draft: draft, session: fixture.session)
        }
        let save: (RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void = sheet.onSave
        try save(forgedDraft)
        let updatedRule = try XCTUnwrap(
            fixture.store.settings.rules.first(where: { $0.id == existingRule.id })
        )
        XCTAssertEqual(fixture.store.settings.rules.count, 1)
        XCTAssertEqual(updatedRule.matcher.normalizedHost, "updated.example.com")
        XCTAssertTrue(updatedRule.matcher.includesSubdomains)
        XCTAssertEqual(updatedRule.destinationID, adapterDestination)
        XCTAssertEqual(fixture.session.state.presentation?.id, item.id)

        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "pending.example.com",
                destinationID: adapterDestination
            )
        )
        relay.presentationWillDismiss()
        let capturedID = try XCTUnwrap(relay.presentationDidDismiss())
        var effects: [DomainRuleSettingsSession.Effect] = []
        DomainRuleSettingsAdapter.endPresentation(
            capturedID,
            in: fixture.session,
            onEffect: { effects.append($0) }
        )
        XCTAssertEqual(effects, [.revealRules])
        XCTAssertNotEqual(fixture.session.state.presentation?.id, capturedID)

        DomainRuleSettingsAdapter.endPresentation(
            capturedID,
            in: fixture.session,
            onEffect: { effects.append($0) }
        )
        XCTAssertEqual(effects, [.revealRules])
        XCTAssertNil(relay.presentationDidDismiss())
    }

    func testSamePresentationIdentityDoesNotReinitializeDraft() throws {
        let rule = try makeRule(host: "before.example.com")
        let changedRule = DomainRule(
            id: rule.id,
            matcher: try DomainMatcher(host: "after.example.com", includesSubdomains: true),
            destinationID: OpenDestinationID(browserID: "com.example.After", mode: .normal)
        )
        let presentationID = DomainRuleSettingsSession.PresentationID()
        var relay = DomainRuleSettingsPresentationRelay()
        _ = relay.synchronize(
            with: .singleRuleEdit(id: presentationID, ruleID: rule.id),
            rules: [rule],
            destinations: []
        )
        guard case let .single(initialItem)? = relay.item else {
            return XCTFail("Expected edit item")
        }

        _ = relay.synchronize(
            with: .singleRuleEdit(id: presentationID, ruleID: rule.id),
            rules: [changedRule],
            destinations: []
        )
        guard case let .single(sameItem)? = relay.item else {
            return XCTFail("Expected the same edit item")
        }
        XCTAssertEqual(sameItem.draft.id, initialItem.draft.id)
        XCTAssertEqual(sameItem.draft.host, "before.example.com")
        XCTAssertFalse(sameItem.draft.includesSubdomains)
        XCTAssertEqual(sameItem.draft.destinationID, adapterDestination)
    }

    func testBulkSubmissionUsesCapturedPresentationIDAndAllFields() throws {
        let fixture = try AdapterFixture(rules: [])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.addRulesInBulk, to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .bulk(item)? = relay.item else {
            return XCTFail("Expected bulk item")
        }
        let matchers = try [
            DomainMatcher(host: "one.example.com", includesSubdomains: false),
            DomainMatcher(host: "two.example.com", includesSubdomains: true)
        ]

        let sheet = BatchRuleEditorSheet(destinations: [], appLanguageStore: fixture.languageStore) {
            (matchers: [DomainMatcher], destinationID: OpenDestinationID, replaceExisting: Bool)
                throws(DomainRuleSettingsDisplayError) -> Void in
            try DomainRuleSettingsAdapter.commitBulk(
                item: item, matchers: matchers, destinationID: destinationID,
                replaceExisting: replaceExisting, session: fixture.session
            )
        }
        let save: ([DomainMatcher], OpenDestinationID, Bool) throws(DomainRuleSettingsDisplayError) -> Void = sheet.onSave
        try save(matchers, adapterDestination, true)

        XCTAssertEqual(
            Set(fixture.store.settings.rules.map(\.matcher)),
            Set(matchers)
        )
        XCTAssertTrue(
            fixture.store.settings.rules.allSatisfy {
                $0.destinationID == adapterDestination
            }
        )
        XCTAssertEqual(fixture.session.state.presentation?.id, item.id)
    }

    func testCommitErrorsAndPageFailuresMapExhaustivelyInBothLanguages() throws {
        let fixture = try AdapterFixture(rules: [])
        defer { fixture.cleanup() }
        let errors: [(DomainRuleSettingsSession.CommitError, String, String)] = [
            (.destinationRequired, "Choose an enabled Open Destination before saving this rule.", "保存此规则前请选择一个已启用的打开目标。"),
            (.invalidMatcher(.invalidHost), "Enter a valid host or an absolute HTTP/HTTPS URL.", "请输入有效的主机名或完整的 HTTP/HTTPS URL。"),
            (.invalidMatcher(.ipAddressesCannotIncludeSubdomains), "IP addresses cannot include subdomains.", "IP 地址不能包含子域名。"),
            (.duplicateRuleMatcher, "A rule with this domain and subdomain setting already exists.", "已存在域名和子域名设置相同的规则。"),
            (.ruleNotFound, "This rule no longer exists. Close the editor and try again.", "此规则已不存在。请关闭编辑器后重试。"),
            (.emptyBulkSubmission, "Add at least one valid domain.", "请至少添加一个有效域名。"),
            (.persistenceFailure, "The rules could not be saved.", "规则保存失败。"),
            (.stalePresentation, "This editor is no longer active. Close it and try again.", "此编辑器已失效。请关闭后重试。"),
            (.wrongPresentationKind, "This editor is no longer active. Close it and try again.", "此编辑器已失效。请关闭后重试。"),
            (.alreadyCommitted, "This editor is no longer active. Close it and try again.", "此编辑器已失效。请关闭后重试。")
        ]

        for (error, english, chinese) in errors {
            let displayError = DomainRuleSettingsAdapter.displayError(for: error)
            for language in [AppLanguage.english, .simplifiedChinese, .english] {
                fixture.languageStore.select(language)
                XCTAssertEqual(displayError.text(using: fixture.languageStore), language == .english ? english : chinese)
            }
        }
        XCTAssertEqual(
            DomainRuleSettingsAdapter.pageMessage(
                for: .deleteRules(target: .selected(ruleIDs: [])),
                appLanguageStore: fixture.languageStore
            ),
            "The rules could not be deleted."
        )
        XCTAssertEqual(
            DomainRuleSettingsAdapter.pageMessage(
                for: .addRuleMatcherToRoutingScope(
                    ruleID: UUID(),
                    matcher: try DomainMatcher(host: "scope.example.com", includesSubdomains: false)
                ),
                appLanguageStore: fixture.languageStore
            ),
            "Routing Scope could not be updated."
        )
        fixture.languageStore.select(.simplifiedChinese)

        XCTAssertEqual(
            DomainRuleSettingsAdapter.pageMessage(
                for: .deleteRules(target: .selected(ruleIDs: [])),
                appLanguageStore: fixture.languageStore
            ),
            "规则删除失败。"
        )
        XCTAssertEqual(
            DomainRuleSettingsAdapter.pageMessage(
                for: .addRuleMatcherToRoutingScope(
                    ruleID: UUID(),
                    matcher: try DomainMatcher(host: "scope.example.com", includesSubdomains: false)
                ),
                appLanguageStore: fixture.languageStore
            ),
            "无法更新路由范围。"
        )
        XCTAssertNil(
            DomainRuleSettingsAdapter.pageMessage(
                for: nil,
                appLanguageStore: fixture.languageStore
            )
        )
    }

    func testDeletePresentationUsesFrozenTargetForCopyAndLifecycle() throws {
        let firstRule = try makeRule(host: "first.example.com")
        let secondRule = try makeRule(host: "second.example.com")
        let fixture = try AdapterFixture(rules: [firstRule, secondRule])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(
            .setRuleSelection(ruleID: firstRule.id, isSelected: true),
            to: fixture.session
        )
        DomainRuleSettingsAdapter.send(.requestDeleteSelectedRules, to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [firstRule, secondRule],
            destinations: []
        )
        guard case let .delete(item)? = relay.item else {
            return XCTFail("Expected delete item")
        }

        DomainRuleSettingsAdapter.send(
            .setRuleSelection(ruleID: secondRule.id, isSelected: true),
            to: fixture.session
        )
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deleteTitle(for: item, appLanguageStore: fixture.languageStore),
            "Delete selected rules?"
        )
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deleteMessage(for: item, appLanguageStore: fixture.languageStore),
            "This will remove 1 selected rules."
        )

        DomainRuleSettingsAdapter.confirmDelete(item: item, in: fixture.session)
        XCTAssertEqual(fixture.store.settings.rules, [secondRule])
        relay.presentationWillDismiss()
        DomainRuleSettingsAdapter.endPresentation(
            try XCTUnwrap(relay.presentationDidDismiss()),
            in: fixture.session,
            onEffect: { _ in XCTFail("Delete dismissal should not reveal rules") }
        )
        XCTAssertNil(fixture.session.state.pageFailure)
    }

    func testCancelDeleteEndsCapturedPresentationWithoutWriting() throws {
        let rule = try makeRule(host: "cancel.example.com")
        let fixture = try AdapterFixture(rules: [rule])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.requestDeleteRule(ruleID: rule.id), to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [rule],
            destinations: []
        )
        guard case let .delete(item)? = relay.item else {
            return XCTFail("Expected row delete")
        }
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deleteMessage(for: item, appLanguageStore: fixture.languageStore),
            "The rule for cancel.example.com will be removed."
        )

        relay.presentationWillDismiss()
        DomainRuleSettingsAdapter.endPresentation(
            try XCTUnwrap(relay.presentationDidDismiss()),
            in: fixture.session,
            onEffect: { _ in XCTFail("Cancel should not emit an effect") }
        )

        XCTAssertEqual(fixture.store.settings.rules, [rule])
        XCTAssertNil(fixture.session.state.presentation)
    }

    func testDeleteDismissalStartDoesNotEndSessionUntilCompletionCallback() throws {
        let rule = try makeRule(host: "delete-lifecycle.example.com")
        let fixture = try AdapterFixture(rules: [rule])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.requestDeleteRule(ruleID: rule.id), to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [rule],
            destinations: []
        )
        guard case let .delete(item)? = relay.item else {
            return XCTFail("Expected row delete")
        }
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "deferred-after-delete.example.com",
                destinationID: adapterDestination
            )
        )

        DomainRuleSettingsAdapter.confirmDelete(item: item, in: fixture.session)
        relay.presentationWillDismiss()

        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(id: item.id, target: item.target)
        )
        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertTrue(fixture.store.settings.rules.isEmpty)

        var effects: [DomainRuleSettingsSession.Effect] = []
        DomainRuleSettingsAdapter.endPresentation(
            try XCTUnwrap(relay.presentationDidDismiss()),
            in: fixture.session,
            onEffect: { effects.append($0) }
        )
        XCTAssertEqual(effects, [.revealRules])
        XCTAssertNotEqual(fixture.session.state.presentation?.id, item.id)
    }

    func testAllDeleteCopyUsesFrozenTargetCount() throws {
        let firstRule = try makeRule(host: "first.example.com")
        let secondRule = try makeRule(host: "second.example.com")
        var relay = DomainRuleSettingsPresentationRelay()
        let presentationID = DomainRuleSettingsSession.PresentationID()
        _ = relay.synchronize(
            with: .deleteConfirmation(
                id: presentationID,
                target: .all(ruleIDs: [firstRule.id, secondRule.id])
            ),
            rules: [firstRule, secondRule],
            destinations: []
        )
        guard case let .delete(item)? = relay.item else {
            return XCTFail("Expected all delete")
        }
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let languageStore = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])

        XCTAssertEqual(
            DomainRuleSettingsAdapter.deleteTitle(for: item, appLanguageStore: languageStore),
            "Clear all rules?"
        )
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deleteMessage(for: item, appLanguageStore: languageStore),
            "This will remove all 2 rules."
        )
    }

    func testDeferredNoticeTracksSessionMarkerWithoutChangingPresentationItem() throws {
        let fixture = try AdapterFixture(rules: [])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.addRulesInBulk, to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .bulk(initialItem)? = relay.item else {
            return XCTFail("Expected bulk item")
        }
        XCTAssertNil(
            DomainRuleSettingsAdapter.deferredChooserNotice(
                isDeferred: fixture.session.state.hasDeferredChooserRequest,
                appLanguageStore: fixture.languageStore
            )
        )

        _ = fixture.session.send(
            .requestRuleFromChooser(host: "waiting.example.com", destinationID: adapterDestination)
        )
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .bulk(sameItem)? = relay.item else {
            return XCTFail("Expected the same bulk item")
        }
        XCTAssertEqual(sameItem.id, initialItem.id)
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deferredChooserNotice(
                isDeferred: fixture.session.state.hasDeferredChooserRequest,
                appLanguageStore: fixture.languageStore
            ),
            "Another Domain Rule request is waiting and will open after this editor closes."
        )
        XCTAssertNil(
            DomainRuleSettingsAdapter.deferredChooserNotice(
                isDeferred: false,
                appLanguageStore: fixture.languageStore
            )
        )
    }

    func testSingleDeferredNoticeDoesNotResetDraft() throws {
        let fixture = try AdapterFixture(rules: [])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.addRule, to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .single(initialItem)? = relay.item else {
            return XCTFail("Expected single item")
        }

        _ = fixture.session.send(
            .requestRuleFromChooser(host: "waiting-single.example.com", destinationID: adapterDestination)
        )
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .single(sameItem)? = relay.item else {
            return XCTFail("Expected same single item")
        }
        XCTAssertEqual(sameItem.id, initialItem.id)
        XCTAssertEqual(sameItem.draft.id, initialItem.draft.id)
        XCTAssertEqual(
            DomainRuleSettingsAdapter.deferredChooserNotice(
                isDeferred: fixture.session.state.hasDeferredChooserRequest,
                appLanguageStore: fixture.languageStore
            ),
            "Another Domain Rule request is waiting and will open after this editor closes."
        )
    }

    func testFailedCommitKeepsPresentationAndThrowsSemanticDisplayError() throws {
        let fixture = try AdapterFixture(rules: [])
        defer { fixture.cleanup() }
        var relay = DomainRuleSettingsPresentationRelay()
        DomainRuleSettingsAdapter.send(.addRule, to: fixture.session)
        _ = relay.synchronize(
            with: fixture.session.state.presentation,
            rules: [],
            destinations: []
        )
        guard case let .single(item)? = relay.item else {
            return XCTFail("Expected create item")
        }
        fixture.languageStore.select(.simplifiedChinese)

        XCTAssertThrowsError(
            try DomainRuleSettingsAdapter.commitSingle(
                item: item,
                draft: RuleEditorDraft(
                    destinationID: nil,
                    host: "failed.example.com"
                ),
                session: fixture.session
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsDisplayError,
                DomainRuleSettingsDisplayError(messageKey: "Choose an enabled Open Destination before saving this rule.")
            )
            XCTAssertEqual((error as? DomainRuleSettingsDisplayError)?.text(using: fixture.languageStore),
                           "保存此规则前请选择一个已启用的打开目标。")
        }
        XCTAssertEqual(fixture.session.state.presentation?.id, item.id)
        XCTAssertEqual(fixture.store.settings.rules, [])
    }

    func testTypedRulesActionsMapToSessionIntents() throws {
        let firstRule = try makeRule(host: "first.example.com")
        let secondRule = try makeRule(host: "second.example.com")
        let fixture = try AdapterFixture(rules: [firstRule, secondRule])
        defer { fixture.cleanup() }

        DomainRuleSettingsAdapter.send(.addRule, to: fixture.session)
        guard case let .singleRuleCreate(createID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected single create")
        }
        _ = fixture.session.send(.presentationEnded(id: createID))

        DomainRuleSettingsAdapter.send(.addRulesInBulk, to: fixture.session)
        guard case let .bulkRuleCreate(bulkID)? = fixture.session.state.presentation else {
            return XCTFail("Expected bulk create")
        }
        _ = fixture.session.send(.presentationEnded(id: bulkID))

        DomainRuleSettingsAdapter.send(
            .setRuleSelection(ruleID: firstRule.id, isSelected: true),
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [firstRule.id])

        DomainRuleSettingsAdapter.send(.requestDeleteSelectedRules, to: fixture.session)
        guard case let .deleteConfirmation(selectedID, selectedTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected selected delete")
        }
        XCTAssertEqual(selectedTarget, .selected(ruleIDs: [firstRule.id]))
        _ = fixture.session.send(.presentationEnded(id: selectedID))

        DomainRuleSettingsAdapter.send(.requestClearAllRules, to: fixture.session)
        guard case let .deleteConfirmation(allID, allTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected all delete")
        }
        XCTAssertEqual(allTarget, .all(ruleIDs: [firstRule.id, secondRule.id]))
        _ = fixture.session.send(.presentationEnded(id: allID))

        DomainRuleSettingsAdapter.send(.editRule(ruleID: secondRule.id), to: fixture.session)
        guard case let .singleRuleEdit(editID, ruleID)? = fixture.session.state.presentation else {
            return XCTFail("Expected edit")
        }
        XCTAssertEqual(ruleID, secondRule.id)
        _ = fixture.session.send(.presentationEnded(id: editID))

        DomainRuleSettingsAdapter.send(.requestDeleteRule(ruleID: secondRule.id), to: fixture.session)
        guard case let .deleteConfirmation(_, rowTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected row delete")
        }
        XCTAssertEqual(rowTarget, .row(ruleID: secondRule.id))
    }

    func testAddToScopeActionUsesSession() throws {
        let rule = try makeRule(host: "scope.example.com")
        let fixture = try AdapterFixture(rules: [rule], onlyTheseScope: true)
        defer { fixture.cleanup() }

        DomainRuleSettingsAdapter.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id),
            to: fixture.session
        )
        guard case let .onlyThese(scopeMatchers, _) = fixture.store.settings.scope else {
            return XCTFail("Expected an only-these routing scope")
        }
        XCTAssertEqual(scopeMatchers, [rule.matcher])
    }

    func testSynchronizeImmediatelyAfterCompletedDismissalDefersRepresentation() {
        var relay = DomainRuleSettingsPresentationRelay()
        let firstID = DomainRuleSettingsSession.PresentationID()

        XCTAssertFalse(relay.synchronize(
            with: .singleRuleCreate(id: firstID, prefill: nil),
            rules: [],
            destinations: []
        ))
        XCTAssertEqual(relay.item?.id, firstID)

        // Complete the dismissal of the first sheet.
        relay.presentationWillDismiss()
        XCTAssertNil(relay.item)
        XCTAssertEqual(relay.presentationDidDismiss(), firstID)

        // A promoted presentation must not be re-presented synchronously inside the dismissal
        // chain: SwiftUI would stack a sheet detached from its binding. The relay asks the caller
        // to defer one runloop turn.
        let promotedID = DomainRuleSettingsSession.PresentationID()
        XCTAssertTrue(relay.synchronize(
            with: .singleRuleCreate(id: promotedID, prefill: nil),
            rules: [],
            destinations: []
        ))
        XCTAssertNil(relay.item)

        // The deferred retry performs the presentation.
        XCTAssertFalse(relay.synchronize(
            with: .singleRuleCreate(id: promotedID, prefill: nil),
            rules: [],
            destinations: []
        ))
        XCTAssertEqual(relay.item?.id, promotedID)
    }

    func testDismissalWithoutNewPresentationDoesNotDeferAndConsumesMarker() {
        var relay = DomainRuleSettingsPresentationRelay()
        let firstID = DomainRuleSettingsSession.PresentationID()

        XCTAssertFalse(relay.synchronize(
            with: .singleRuleCreate(id: firstID, prefill: nil),
            rules: [],
            destinations: []
        ))
        relay.presentationWillDismiss()
        XCTAssertEqual(relay.presentationDidDismiss(), firstID)

        // Nothing new to present: no defer request, and the marker is consumed so a later
        // fresh presentation is still shown immediately.
        XCTAssertFalse(relay.synchronize(with: nil, rules: [], destinations: []))
        XCTAssertNil(relay.item)

        let nextID = DomainRuleSettingsSession.PresentationID()
        XCTAssertFalse(relay.synchronize(
            with: .singleRuleCreate(id: nextID, prefill: nil),
            rules: [],
            destinations: []
        ))
        XCTAssertEqual(relay.item?.id, nextID)
    }
}

@MainActor
private final class AdapterFixture {
    let session: DomainRuleSettingsSession
    let store: RoutingPreferencesStore
    let languageStore: AppLanguageStore
    private let defaults: UserDefaults
    private let suiteName: String

    init(rules: [DomainRule], onlyTheseScope: Bool = false) throws {
        suiteName = "EligoTests.DomainRuleSettingsAdapter.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        languageStore = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store = RoutingPreferencesStore(userDefaults: defaults)
        let scope: RoutingScope = onlyTheseScope
            ? .onlyThese(matchers: [], bypassDestinationID: adapterDestination)
            : .allDomains
        try store.replace(with: RoutingSettings(scope: scope, rules: rules, alwaysShowChooser: false))
        session = DomainRuleSettingsSession(store: store)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeRule(
    host: String,
    destinationID: OpenDestinationID = adapterDestination
) throws -> DomainRule {
    DomainRule(
        matcher: try DomainMatcher(host: host, includesSubdomains: false),
        destinationID: destinationID
    )
}

private let adapterDestination = OpenDestinationID(
    browserID: "com.example.AdapterBrowser",
    mode: .normal
)
