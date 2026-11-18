import Combine
import XCTest
@testable import Eligo

@MainActor
final class DomainRuleSettingsSessionTests: XCTestCase {
    func testDeferredChooserCompletionWaitsForItsOwnEditorAndWindowCloseReturnsCancelOnce() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let session = fixture.session
        var results: [OpenDestinationID?] = []
        session.onChooserRuleFinished = { results.append($0) }
        _ = session.send(.presentSingleRuleCreate)
        let originalID = try XCTUnwrap(session.state.presentation?.id)
        _ = session.send(.requestRuleFromChooser(host: "example.com", destinationID: chromeOpenDestination))
        XCTAssertFalse(session.state.isEditingPendingLink)
        _ = session.send(.presentationEnded(id: originalID))
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(session.state.isEditingPendingLink)
        let chooserID = try XCTUnwrap(session.state.presentation?.id)
        XCTAssertThrowsError(try session.commit(.singleRule(presentationID: chooserID, host: "example.com",
            includesSubdomains: false, destinationID: nil)))
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(session.state.presentation?.id, chooserID)
        _ = session.send(.windowClosed)
        _ = session.send(.presentationEnded(id: chooserID))
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        XCTAssertTrue(fixture.store.settings.rules.isEmpty)
    }

    func testInlineDestinationChangePreservesIdentityMatcherSelectionAndPersists() throws {
        let rule = try makeDomainRule(host: "example.com", includesSubdomains: true)
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [rule]))
        defer { fixture.cleanup() }
        _ = fixture.session.send(.setRuleSelection(id: rule.id, isSelected: true))
        let destination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)
        DomainRuleSettingsAdapter.send(.setRuleDestination(ruleID: rule.id, destinationID: destination), to: fixture.session)
        let saved = try XCTUnwrap(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings.rules.first)
        XCTAssertEqual(saved.id, rule.id)
        XCTAssertEqual(saved.matcher, rule.matcher)
        XCTAssertEqual(saved.destinationID, destination)
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [rule.id])
        XCTAssertNil(fixture.session.state.presentation)
    }

    func testChooserRequestWhileIdleOpensExactCreateWithPrefillAndRevealEffect() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let destination = OpenDestinationID(
            browserID: "com.example.PrivateChooserBrowser",
            mode: .privateBrowsing
        )

        let effect = fixture.session.send(
            .requestRuleFromChooser(
                host: "  WWW.Example.COM. ",
                destinationID: destination
            )
        )

        XCTAssertEqual(effect, .revealRules)
        guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        XCTAssertEqual(
            prefill,
            .init(
                matcher: try DomainMatcher(
                    host: "www.example.com",
                    includesSubdomains: false
                ),
                destinationID: destination
            )
        )
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertEqual(fixture.store.settings, .default)
    }

    func testChooserRequestWhileIdleKeepsCreateIntentForExactDuplicate() throws {
        let existingDestination = OpenDestinationID(
            browserID: "com.example.ExistingBrowser",
            mode: .normal
        )
        let chooserDestination = OpenDestinationID(
            browserID: "com.example.ChooserBrowser",
            mode: .privateBrowsing
        )
        let existingRule = try makeDomainRule(
            host: "existing.example.com",
            destinationID: existingDestination
        )
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [existingRule])
        )
        defer { fixture.cleanup() }

        let effect = fixture.session.send(
            .requestRuleFromChooser(
                host: " EXISTING.EXAMPLE.COM. ",
                destinationID: chooserDestination
            )
        )

        XCTAssertEqual(effect, .revealRules)
        guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
            return XCTFail("创建入口应保留创建意图，不预先绑定旧规则")
        }
        XCTAssertEqual(
            prefill,
            .init(
                matcher: existingRule.matcher,
                destinationID: chooserDestination
            )
        )
        XCTAssertEqual(fixture.store.settings.rules, [existingRule])
    }

    func testChooserRequestDoesNotTreatOverlappingMatchersAsExactDuplicates() throws {
        func assertCreatesExactRule(
            existingRules: [DomainRule],
            host: String
        ) throws {
            let destination = OpenDestinationID(
                browserID: "com.example.OverlapBrowser",
                mode: .normal
            )
            let fixture = try DomainRuleSettingsSessionFixture(
                settings: makeSettings(rules: existingRules)
            )
            defer { fixture.cleanup() }

            XCTAssertEqual(
                fixture.session.send(
                    .requestRuleFromChooser(
                        host: host,
                        destinationID: destination
                    )
                ),
                .revealRules
            )
            guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
                return XCTFail("Expected an exact-rule create presentation")
            }
            XCTAssertEqual(
                prefill,
                .init(
                    matcher: try DomainMatcher(
                        host: host,
                        includesSubdomains: false
                    ),
                    destinationID: destination
                )
            )
        }

        try assertCreatesExactRule(
            existingRules: [
                try makeDomainRule(
                    host: "example.com",
                    includesSubdomains: true
                )
            ],
            host: "sub.example.com"
        )
        try assertCreatesExactRule(
            existingRules: [
                try makeDomainRule(
                    host: "example.com",
                    includesSubdomains: true
                )
            ],
            host: "example.com"
        )
        try assertCreatesExactRule(
            existingRules: [
                try makeDomainRule(host: "sub.example.com")
            ],
            host: "example.com"
        )
    }

    func testInvalidIdleChooserRequestIsFailSoftAndDoesNotChangeState() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let stateBefore = fixture.session.state

        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "https://invalid.example.com/path",
                    destinationID: chromeOpenDestination
                )
            )
        )
        XCTAssertEqual(fixture.session.state, stateBefore)
        XCTAssertEqual(fixture.store.settings, .default)
    }

    func testBusyChooserRequestsKeepCurrentPresentationAndPromoteOnlyLatest() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let firstDestination = OpenDestinationID(
            browserID: "com.example.FirstChooserBrowser",
            mode: .normal
        )
        let secondDestination = OpenDestinationID(
            browserID: "com.example.SecondChooserBrowser",
            mode: .privateBrowsing
        )
        let lastDestination = OpenDestinationID(
            browserID: "com.example.LastChooserBrowser",
            mode: .normal
        )

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(currentID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected the current presentation")
        }
        let currentPresentation = fixture.session.state.presentation

        var published: [DomainRuleSettingsSession.State] = []
        let subscription = fixture.session.$state.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "first.example.com",
                    destinationID: firstDestination
                )
            )
        )
        let firstState = fixture.session.state
        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "second.example.com",
                    destinationID: firstDestination
                )
            )
        )
        let hostReplacementState = fixture.session.state
        XCTAssertNotEqual(firstState, hostReplacementState)

        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "second.example.com",
                    destinationID: secondDestination
                )
            )
        )
        let secondState = fixture.session.state
        XCTAssertNotEqual(hostReplacementState, secondState)

        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "last.example.com",
                    destinationID: lastDestination
                )
            )
        )
        let lastState = fixture.session.state
        XCTAssertEqual(published, [firstState, hostReplacementState, secondState, lastState])
        for snapshot in published {
            XCTAssertEqual(snapshot.presentation, currentPresentation)
            XCTAssertTrue(snapshot.hasDeferredChooserRequest)
        }
        XCTAssertEqual(fixture.session.state.presentation, currentPresentation)
        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertEqual(fixture.store.settings, .default)

        published.removeAll()
        XCTAssertEqual(
            fixture.session.send(.presentationEnded(id: currentID)),
            .revealRules
        )
        guard case let .singleRuleCreate(promotedID, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected the latest deferred request to be promoted")
        }
        XCTAssertNotEqual(promotedID, currentID)
        XCTAssertEqual(
            prefill,
            .init(
                matcher: try DomainMatcher(
                    host: "last.example.com",
                    includesSubdomains: false
                ),
                destinationID: lastDestination
            )
        )
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertEqual(published, [fixture.session.state])
        XCTAssertTrue(lastState.hasDeferredChooserRequest)
        XCTAssertEqual(lastState.presentation, currentPresentation)

        published.removeAll()
        XCTAssertNil(fixture.session.send(.presentationEnded(id: currentID)))
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: promotedID, prefill: prefill)
        )
        XCTAssertTrue(published.isEmpty)
    }

    func testLatestDeferredInvalidChooserRequestDiscardsEarlierValidRequest() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let destination = OpenDestinationID(
            browserID: "com.example.ValidChooserBrowser",
            mode: .normal
        )

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(currentID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected the current presentation")
        }
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "valid.example.com",
                destinationID: destination
            )
        )
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "https://invalid.example.com/path",
                destinationID: destination
            )
        )

        let deferredState = fixture.session.state
        var published: [DomainRuleSettingsSession.State] = []
        let subscription = fixture.session.$state.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertNil(fixture.session.send(.presentationEnded(id: currentID)))
        XCTAssertNil(fixture.session.state.presentation)
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertEqual(published, [fixture.session.state])
        XCTAssertTrue(deferredState.hasDeferredChooserRequest)
        XCTAssertEqual(deferredState.presentation?.id, currentID)

        published.removeAll()
        XCTAssertNil(fixture.session.send(.presentationEnded(id: currentID)))
        XCTAssertTrue(published.isEmpty)
    }

    func testChooserRequestDefersForBulkAndDeletePresentations() throws {
        do {
            let fixture = try DomainRuleSettingsSessionFixture()
            defer { fixture.cleanup() }
            _ = fixture.session.send(.presentBulkRuleCreate)
            guard case let .bulkRuleCreate(presentationID)? = fixture.session.state.presentation else {
                return XCTFail("Expected a bulk-rule presentation")
            }
            let currentPresentation = fixture.session.state.presentation

            XCTAssertNil(
                fixture.session.send(
                    .requestRuleFromChooser(
                        host: "bulk.example.com",
                        destinationID: chromeOpenDestination
                    )
                )
            )
            XCTAssertEqual(fixture.session.state.presentation, currentPresentation)
            XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
            XCTAssertEqual(fixture.store.settings, .default)
            _ = fixture.session.send(.presentationEnded(id: presentationID))
        }

        do {
            let rule = try makeDomainRule(host: "delete.example.com")
            let fixture = try DomainRuleSettingsSessionFixture(
                settings: makeSettings(rules: [rule])
            )
            defer { fixture.cleanup() }
            _ = fixture.session.send(
                .presentDeleteConfirmation(target: .row(ruleID: rule.id))
            )
            guard case let .deleteConfirmation(presentationID, _)? = fixture.session.state.presentation else {
                return XCTFail("Expected a delete confirmation presentation")
            }
            let currentPresentation = fixture.session.state.presentation

            XCTAssertNil(
                fixture.session.send(
                    .requestRuleFromChooser(
                        host: "delete.example.com",
                        destinationID: chromeOpenDestination
                    )
                )
            )
            XCTAssertEqual(fixture.session.state.presentation, currentPresentation)
            XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
            XCTAssertEqual(fixture.store.settings.rules, [rule])
            _ = fixture.session.send(.presentationEnded(id: presentationID))
            guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
                return XCTFail("Expected promotion after delete presentation ended")
            }
            XCTAssertEqual(prefill?.matcher, rule.matcher)
            XCTAssertEqual(fixture.store.settings.rules, [rule])
        }
    }

    func testSuccessfulSaveDoesNotPromotePendingChooserRequestUntilPresentationEnds() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let destination = OpenDestinationID(
            browserID: "com.example.PendingChooserBrowser",
            mode: .normal
        )

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }
        let submission = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "saved.example.com",
            includesSubdomains: false,
            destinationID: chromeOpenDestination
        )
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "pending.example.com",
                destinationID: destination
            )
        )

        try fixture.session.commit(submission)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: presentationID, prefill: nil)
        )
        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)
        XCTAssertEqual(
            fixture.store.settings.rules.map(\.matcher.normalizedHost),
            ["saved.example.com"]
        )
        XCTAssertThrowsError(try fixture.session.commit(submission)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .alreadyCommitted
            )
        }
        XCTAssertEqual(fixture.store.settings.rules.count, 1)

        XCTAssertEqual(
            fixture.session.send(.presentationEnded(id: presentationID)),
            .revealRules
        )
        guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected pending request promotion")
        }
        XCTAssertEqual(prefill?.destinationID, destination)
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
    }

    func testFailedSaveKeepsPresentationAndPendingChooserRequestForRetry() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "retry-pending.example.com",
                destinationID: safariOpenDestination
            )
        )
        let stateBeforeFailedCommit = fixture.session.state
        let failingSubmission = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "retry-save.example.com",
            includesSubdomains: false,
            destinationID: nil
        )

        XCTAssertThrowsError(try fixture.session.commit(failingSubmission)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .destinationRequired
            )
        }
        XCTAssertEqual(fixture.session.state, stateBeforeFailedCommit)
        XCTAssertEqual(fixture.store.settings, .default)

        try fixture.session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "retry-save.example.com",
                includesSubdomains: false,
                destinationID: chromeOpenDestination
            )
        )
        XCTAssertEqual(fixture.session.state, stateBeforeFailedCommit)
        XCTAssertEqual(
            fixture.store.settings.rules.map(\.matcher.normalizedHost),
            ["retry-save.example.com"]
        )
        XCTAssertEqual(
            fixture.session.send(.presentationEnded(id: presentationID)),
            .revealRules
        )
        guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected pending request promotion after retry")
        }
        XCTAssertEqual(prefill?.matcher.normalizedHost, "retry-pending.example.com")
    }

    func testPromotionUsesJustSavedExactDuplicateAndStillRequiresExplicitSave() throws {
        let savedDestination = OpenDestinationID(
            browserID: "com.example.SavedBrowser",
            mode: .normal
        )
        let chooserDestination = OpenDestinationID(
            browserID: "com.example.ChooserBrowser",
            mode: .privateBrowsing
        )
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "just-saved.example.com",
                destinationID: chooserDestination
            )
        )
        try fixture.session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "just-saved.example.com",
                includesSubdomains: false,
                destinationID: savedDestination
            )
        )
        let savedRule = try XCTUnwrap(fixture.store.settings.rules.first)
        XCTAssertEqual(savedRule.destinationID, savedDestination)

        XCTAssertEqual(
            fixture.session.send(.presentationEnded(id: presentationID)),
            .revealRules
        )
        guard case let .singleRuleCreate(promotedID, prefill)? = fixture.session.state.presentation else {
            return XCTFail("等待中的创建请求不应绑定刚保存的规则")
        }
        XCTAssertEqual(
            prefill,
            .init(
                matcher: savedRule.matcher,
                destinationID: chooserDestination
            )
        )
        XCTAssertEqual(fixture.store.settings.rules, [savedRule])

        try fixture.session.commit(
            .singleRule(
                presentationID: promotedID,
                host: "just-saved.example.com",
                includesSubdomains: false,
                destinationID: chooserDestination
            )
        )
        XCTAssertEqual(
            fixture.store.settings.rules.first?.destinationID,
            chooserDestination
        )
        XCTAssertEqual(fixture.store.settings.rules.map(\.id), [savedRule.id])
    }

    func testPromotionReevaluatesLatestSnapshotAfterRulesAreAddedDeletedOrChanged() throws {
        do {
            let fixture = try DomainRuleSettingsSessionFixture()
            defer { fixture.cleanup() }
            _ = fixture.session.send(.presentSingleRuleCreate)
            guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
                return XCTFail("Expected a single-rule presentation")
            }
            _ = fixture.session.send(
                .requestRuleFromChooser(
                    host: "added-while-pending.example.com",
                    destinationID: chromeOpenDestination
                )
            )
            let addedRule = try makeDomainRule(host: "added-while-pending.example.com")
            try fixture.store.replace(with: makeSettings(rules: [addedRule]))

            XCTAssertEqual(
                fixture.session.send(.presentationEnded(id: presentationID)),
                .revealRules
            )
            guard case let .singleRuleCreate(promotedID, prefill)? = fixture.session.state.presentation else {
                return XCTFail("创建请求应使用最新快照判断保存动作")
            }
            XCTAssertEqual(prefill?.matcher, addedRule.matcher)
            try fixture.session.commit(.singleRule(
                presentationID: promotedID, host: addedRule.matcher.normalizedHost,
                includesSubdomains: false, destinationID: chromeOpenDestination
            ))
            XCTAssertEqual(fixture.store.settings.rules.map(\.id), [addedRule.id])
            XCTAssertEqual(fixture.store.settings.rules.first?.destinationID, chromeOpenDestination)
        }

        do {
            let existingRule = try makeDomainRule(host: "deleted-while-pending.example.com")
            let fixture = try DomainRuleSettingsSessionFixture(
                settings: makeSettings(rules: [existingRule])
            )
            defer { fixture.cleanup() }
            _ = fixture.session.send(.presentSingleRuleCreate)
            guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
                return XCTFail("Expected a single-rule presentation")
            }
            _ = fixture.session.send(
                .requestRuleFromChooser(
                    host: "deleted-while-pending.example.com",
                    destinationID: safariOpenDestination
                )
            )
            try fixture.store.replace(with: .default)

            XCTAssertEqual(
                fixture.session.send(.presentationEnded(id: presentationID)),
                .revealRules
            )
            guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
                return XCTFail("Expected a create after the matching rule was deleted")
            }
            XCTAssertEqual(
                prefill?.matcher,
                try DomainMatcher(
                    host: "deleted-while-pending.example.com",
                    includesSubdomains: false
                )
            )
        }

        do {
            let existingRule = try makeDomainRule(host: "changed-while-pending.example.com")
            let changedRule = DomainRule(
                id: existingRule.id,
                matcher: try DomainMatcher(
                    host: "other.example.com",
                    includesSubdomains: false
                ),
                destinationID: existingRule.destinationID
            )
            let fixture = try DomainRuleSettingsSessionFixture(
                settings: makeSettings(rules: [existingRule])
            )
            defer { fixture.cleanup() }
            _ = fixture.session.send(.presentSingleRuleCreate)
            guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
                return XCTFail("Expected a single-rule presentation")
            }
            _ = fixture.session.send(
                .requestRuleFromChooser(
                    host: "changed-while-pending.example.com",
                    destinationID: chromeOpenDestination
                )
            )
            try fixture.store.replace(with: makeSettings(rules: [changedRule]))

            XCTAssertEqual(
                fixture.session.send(.presentationEnded(id: presentationID)),
                .revealRules
            )
            guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
                return XCTFail("Expected a create after the matching rule changed")
            }
            XCTAssertEqual(prefill?.matcher.normalizedHost, "changed-while-pending.example.com")
        }
    }

    func testChooserRevealEffectIsNotReplayedByStateReadsOrStaleEvents() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "effect.example.com",
                    destinationID: chromeOpenDestination
                )
            ),
            .revealRules
        )
        _ = fixture.session.state
        XCTAssertNil(fixture.session.send(.clearSelection))
        XCTAssertNil(
            fixture.session.send(
                .presentationEnded(id: DomainRuleSettingsSession.PresentationID())
            )
        )
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected the presentation to remain active")
        }
        XCTAssertNil(fixture.session.send(.presentationEnded(id: presentationID)))
        XCTAssertNil(fixture.session.send(.presentationEnded(id: presentationID)))
    }

    func testWindowClosedDiscardsPendingChooserRequestAndMakesOldEndedEventStale() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }
        _ = fixture.session.send(
            .requestRuleFromChooser(
                host: "discarded.example.com",
                destinationID: chromeOpenDestination
            )
        )

        let deferredState = fixture.session.state
        XCTAssertNil(fixture.session.send(.windowClosed))
        XCTAssertEqual(fixture.session.state, .init())
        XCTAssertTrue(deferredState.hasDeferredChooserRequest)
        XCTAssertEqual(deferredState.presentation?.id, presentationID)
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertNil(fixture.session.send(.presentationEnded(id: presentationID)))
        XCTAssertEqual(fixture.session.state, .init())
    }

    func testInitialStateExposesOnlyNeutralTransientState() throws {
        let rule = try makeDomainRule(host: "persisted.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [rule]))
        defer { fixture.cleanup() }

        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [])
        XCTAssertNil(fixture.session.state.presentation)
        XCTAssertNil(fixture.session.state.pageFailure)
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
    }

    func testSingleCreateCommitUsesOneMutationAndWaitsForPresentationEnd() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }

        XCTAssertEqual(fixture.store.settings, .default)
        try fixture.session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "created.example.com",
                includesSubdomains: true,
                destinationID: chromeOpenDestination
            )
        )

        let createdRule = try XCTUnwrap(fixture.store.settings.rules.first)
        XCTAssertEqual(fixture.store.settings.rules.count, 1)
        XCTAssertEqual(
            createdRule.matcher,
            try DomainMatcher(host: "created.example.com", includesSubdomains: true)
        )
        XCTAssertEqual(createdRule.destinationID, chromeOpenDestination)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: presentationID, prefill: nil)
        )

        XCTAssertThrowsError(
            try fixture.session.commit(
                .singleRule(
                    presentationID: presentationID,
                    host: "created-again.example.com",
                    includesSubdomains: false,
                    destinationID: chromeOpenDestination
                )
            )
        ) { error in
            XCTAssertEqual(error as? DomainRuleSettingsSession.CommitError, .alreadyCommitted)
        }
        XCTAssertEqual(fixture.store.settings.rules.count, 1)

        _ = fixture.session.send(.presentationEnded(id: presentationID))
        XCTAssertNil(fixture.session.state.presentation)
    }

    func testSingleEditCommitDerivesExistingRuleIDFromPresentation() throws {
        let rule = try makeDomainRule(host: "edited.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [rule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        guard case let .singleRuleEdit(presentationID, ruleID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule edit presentation")
        }
        XCTAssertEqual(ruleID, rule.id)

        try fixture.session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "edited-again.example.com",
                includesSubdomains: false,
                destinationID: safariOpenDestination
            )
        )

        let editedRule = try XCTUnwrap(
            fixture.store.settings.rules.first(where: { $0.id == rule.id })
        )
        XCTAssertEqual(fixture.store.settings.rules.count, 1)
        XCTAssertEqual(editedRule.matcher.normalizedHost, "edited-again.example.com")
        XCTAssertFalse(editedRule.matcher.includesSubdomains)
        XCTAssertEqual(editedRule.destinationID, safariOpenDestination)
    }

    func testBulkCommitUsesOneMutationWithoutSelection() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let matchers = try [
            DomainMatcher(host: "docs.example.com", includesSubdomains: false),
            DomainMatcher(host: "support.example.com", includesSubdomains: true)
        ]

        _ = fixture.session.send(.presentBulkRuleCreate)
        guard case let .bulkRuleCreate(presentationID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a bulk-rule create presentation")
        }
        XCTAssertTrue(fixture.session.state.selectedRuleIDs.isEmpty)

        try fixture.session.commit(
            .bulkRule(
                presentationID: presentationID,
                matchers: matchers,
                destinationID: chromeOpenDestination,
                replaceExisting: true
            )
        )

        XCTAssertEqual(
            Set(fixture.store.settings.rules.map(\.matcher)),
            Set(matchers)
        )
        XCTAssertTrue(
            fixture.store.settings.rules.allSatisfy {
                $0.destinationID == chromeOpenDestination
            }
        )
        XCTAssertEqual(
            fixture.session.state.presentation,
            .bulkRuleCreate(id: presentationID)
        )
    }

    func testBulkIPAndDNSPreviewMatchesTheRulesActuallyPersisted() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let preview = DomainListParser().parse("example.com 127.0.0.1 https://[::1]/path", includesSubdomains: true)
        XCTAssertTrue(preview.invalidInputs.isEmpty)
        _ = fixture.session.send(.presentBulkRuleCreate)
        guard case let .bulkRuleCreate(presentationID)? = fixture.session.state.presentation else {
            return XCTFail("Expected bulk rule creation")
        }
        try fixture.session.commit(.bulkRule(
            presentationID: presentationID, matchers: preview.matchers,
            destinationID: safariOpenDestination, replaceExisting: false
        ))
        XCTAssertEqual(fixture.store.settings.rules.map(\.matcher), preview.matchers)
        XCTAssertEqual(fixture.store.settings.rules.map(\.matcher.includesSubdomains), [true, false, false])
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, fixture.store.settings)
    }

    func testBulkURLBoundaryPreviewMatchesPersistedRulesInOrder() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let preview = DomainListParser().parse(
            "https://a.example/path,ignored.example;https://b.example/?nested=one,https://c.example https://a.example./other",
            includesSubdomains: true
        )
        XCTAssertEqual(preview.matchers.map(\.normalizedHost), ["a.example", "b.example", "c.example"])
        XCTAssertEqual(preview.duplicateInputs, ["https://a.example./other"])
        XCTAssertEqual(preview.invalidInputs, [])
        _ = fixture.session.send(.presentBulkRuleCreate)
        let presentationID = try XCTUnwrap(fixture.session.state.presentation?.id)
        try fixture.session.commit(.bulkRule(
            presentationID: presentationID, matchers: preview.matchers,
            destinationID: safariOpenDestination, replaceExisting: false
        ))
        XCTAssertEqual(fixture.store.settings.rules.map(\.matcher), preview.matchers)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, fixture.store.settings)
        XCTAssertEqual(fixture.store.settings.scope, .allDomains)
    }

    func testClosingAnIPRuleDraftKeepsTheSavedRuleAndReopeningUsesTheSavedHost() throws {
        let rule = try makeDomainRule(host: "example.com", includesSubdomains: true)
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [rule]))
        defer { fixture.cleanup() }
        let savedSettings = fixture.store.settings
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        var relay = DomainRuleSettingsPresentationRelay()
        _ = relay.synchronize(with: fixture.session.state.presentation, rules: fixture.store.settings.rules, destinations: [])
        guard case let .single(initial)? = relay.item else { return XCTFail("Expected initial rule draft") }
        var draft = initial.draft
        draft.host = "https://[::1]/path"
        XCTAssertFalse(draft.includesSubdomains)
        _ = fixture.session.send(.windowClosed)
        _ = relay.synchronize(with: fixture.session.state.presentation, rules: fixture.store.settings.rules, destinations: [])
        XCTAssertEqual(fixture.store.settings, savedSettings)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings, savedSettings)
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        _ = relay.synchronize(with: fixture.session.state.presentation, rules: fixture.store.settings.rules, destinations: [])
        guard case let .single(reopened)? = relay.item else { return XCTFail("Expected reopened rule draft") }
        XCTAssertEqual(reopened.draft.host, "example.com")
        XCTAssertTrue(reopened.draft.includesSubdomains)
        XCTAssertEqual(reopened.draft.existingRuleID, rule.id)
        XCTAssertEqual(reopened.draft.destinationID, rule.destinationID)
    }

    func testFailedSaveKeepsPresentationAndAllowsRetry() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        let failingSubmission = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "retry.example.com",
            includesSubdomains: false,
            destinationID: nil
        )

        XCTAssertThrowsError(try fixture.session.commit(failingSubmission)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .destinationRequired
            )
        }
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: presentationID, prefill: nil)
        )

        try fixture.session.commit(
            .singleRule(
                presentationID: presentationID,
                host: "retry.example.com",
                includesSubdomains: false,
                destinationID: safariOpenDestination
            )
        )
        XCTAssertEqual(
            fixture.store.settings.rules.map(\.matcher.normalizedHost),
            ["retry.example.com"]
        )
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: presentationID, prefill: nil)
        )
    }

    func testStaleSubmissionAndWrongPresentationKindDoNotWrite() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }

        XCTAssertThrowsError(
            try fixture.session.commit(
                .singleRule(
                    presentationID: DomainRuleSettingsSession.PresentationID(),
                    host: "stale.example.com",
                    includesSubdomains: false,
                    destinationID: safariOpenDestination
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .stalePresentation
            )
        }
        XCTAssertThrowsError(
            try fixture.session.commit(
                .bulkRule(
                    presentationID: presentationID,
                    matchers: [
                        try DomainMatcher(host: "wrong-kind.example.com", includesSubdomains: false)
                    ],
                    destinationID: safariOpenDestination,
                    replaceExisting: false
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .wrongPresentationKind
            )
        }
        XCTAssertEqual(fixture.store.settings, .default)
    }

    func testSingleCommitPreflightPreservesDestinationMatcherDuplicateAndRuleNotFoundPriority() throws {
        let existingRule = try makeDomainRule(host: "existing.example.com")
        let editedRule = try makeDomainRule(host: "edited.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [existingRule, editedRule])
        )
        defer { fixture.cleanup() }
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: editedRule.id))
        guard case let .singleRuleEdit(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule edit presentation")
        }
        try fixture.store.replace(with: makeSettings(rules: [existingRule]))

        let destinationMissing = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "https://invalid.example.com/path",
            includesSubdomains: false,
            destinationID: nil
        )
        XCTAssertThrowsError(try fixture.session.commit(destinationMissing)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .destinationRequired
            )
        }

        let invalidMatcher = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "https://invalid.example.com/path",
            includesSubdomains: false,
            destinationID: safariOpenDestination
        )
        XCTAssertThrowsError(try fixture.session.commit(invalidMatcher)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .invalidMatcher(.invalidHost)
            )
        }

        let invalidIPAddressMatcher = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "192.0.2.1",
            includesSubdomains: true,
            destinationID: safariOpenDestination
        )
        XCTAssertThrowsError(try fixture.session.commit(invalidIPAddressMatcher)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .invalidMatcher(.ipAddressesCannotIncludeSubdomains)
            )
        }

        let duplicateMatcher = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: existingRule.matcher.normalizedHost,
            includesSubdomains: existingRule.matcher.includesSubdomains,
            destinationID: safariOpenDestination
        )
        XCTAssertThrowsError(try fixture.session.commit(duplicateMatcher)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .duplicateRuleMatcher
            )
        }

        let staleEdit = DomainRuleSettingsSession.Submission.singleRule(
            presentationID: presentationID,
            host: "new.example.com",
            includesSubdomains: false,
            destinationID: safariOpenDestination
        )
        XCTAssertThrowsError(try fixture.session.commit(staleEdit)) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .ruleNotFound
            )
        }
        XCTAssertEqual(fixture.store.settings.rules, [existingRule])
    }

    func testEmptyBulkSubmissionIsRejectedBeforeWriting() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        _ = fixture.session.send(.presentBulkRuleCreate)
        guard case let .bulkRuleCreate(presentationID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a bulk-rule create presentation")
        }

        XCTAssertThrowsError(
            try fixture.session.commit(
                .bulkRule(
                    presentationID: presentationID,
                    matchers: [],
                    destinationID: safariOpenDestination,
                    replaceExisting: false
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .emptyBulkSubmission
            )
        }
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .bulkRuleCreate(id: presentationID)
        )
    }

    func testCommitDoesNotCheckDestinationCatalogOrRejectPrivateDestination() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let unavailableDestination = OpenDestinationID(
            browserID: "com.example.NotInstalled",
            mode: .normal
        )
        let privateDestination = OpenDestinationID(
            browserID: "com.example.NotInstalled",
            mode: .privateBrowsing
        )

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(firstID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        try fixture.session.commit(
            .singleRule(
                presentationID: firstID,
                host: "unavailable.example.com",
                includesSubdomains: false,
                destinationID: unavailableDestination
            )
        )
        _ = fixture.session.send(.presentationEnded(id: firstID))

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(secondID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a second single-rule create presentation")
        }
        try fixture.session.commit(
            .singleRule(
                presentationID: secondID,
                host: "private.example.com",
                includesSubdomains: false,
                destinationID: privateDestination
            )
        )

        XCTAssertEqual(
            fixture.store.settings.rules.map(\.matcher.normalizedHost),
            ["unavailable.example.com", "private.example.com"]
        )
        XCTAssertEqual(
            fixture.store.settings.rules.map(\.destinationID),
            [unavailableDestination, privateDestination]
        )
    }

    func testProductionSaveDeleteAndAddToScopePersistThroughEditor() throws {
        let scopeMatcher = try DomainMatcher(
            host: "scope.example.com",
            includesSubdomains: false
        )
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [scopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [],
            alwaysShowChooser: false
        )
        let fixture = try DomainRuleSettingsSessionFixture(settings: settings)
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(singleID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        try fixture.session.commit(
            .singleRule(
                presentationID: singleID,
                host: "single.example.com",
                includesSubdomains: false,
                destinationID: chromeOpenDestination
            )
        )
        _ = fixture.session.send(.presentationEnded(id: singleID))

        _ = fixture.session.send(.presentBulkRuleCreate)
        guard case let .bulkRuleCreate(bulkID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a bulk-rule create presentation")
        }
        let bulkMatcher = try DomainMatcher(
            host: "bulk.example.com",
            includesSubdomains: true
        )
        try fixture.session.commit(
            .bulkRule(
                presentationID: bulkID,
                matchers: [bulkMatcher],
                destinationID: safariOpenDestination,
                replaceExisting: false
            )
        )
        _ = fixture.session.send(.presentationEnded(id: bulkID))

        let singleRule = try XCTUnwrap(
            fixture.store.settings.rules.first(where: {
                $0.matcher.normalizedHost == "single.example.com"
            })
        )
        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: singleRule.id)
        )
        guard case let .onlyThese(scopeMatchers, _) = fixture.store.settings.scope else {
            return XCTFail("Expected an only-these routing scope")
        }
        XCTAssertTrue(scopeMatchers.contains(singleRule.matcher))

        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: singleRule.id))
        )
        guard case let .deleteConfirmation(deleteID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a row delete confirmation presentation")
        }
        _ = fixture.session.send(.confirmDelete(presentationID: deleteID))
        XCTAssertFalse(fixture.store.settings.rules.contains { $0.id == singleRule.id })
    }

    func testProductionEditCommitPropagatesDuplicateErrorWithoutSwallowing() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let languageStore = AppLanguageStore(userDefaults: fixture.userDefaults, systemPreferredLanguages: ["en-US"])

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(firstID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        try fixture.session.commit(
            .singleRule(
                presentationID: firstID,
                host: "dup.example.com",
                includesSubdomains: false,
                destinationID: safariOpenDestination
            )
        )
        _ = fixture.session.send(.presentationEnded(id: firstID))
        XCTAssertEqual(fixture.store.settings.rules.count, 1)

        let editedRule = try makeDomainRule(host: "other.example.com")
        try fixture.store.replace(with: fixture.store.settings.replacing(rules: fixture.store.settings.rules + [editedRule]))
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: editedRule.id))
        guard case let .singleRuleEdit(secondID, _)? = fixture.session.state.presentation else {
            return XCTFail("应打开指定规则的编辑表单")
        }

        XCTAssertThrowsError(
            try fixture.session.commit(
                .singleRule(
                    presentationID: secondID,
                    host: "dup.example.com",
                    includesSubdomains: false,
                    destinationID: chromeOpenDestination
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .duplicateRuleMatcher
            )
        }

        let draft = RuleEditorDraft(
            destinationID: chromeOpenDestination,
            host: "dup.example.com",
            includesSubdomains: false
        )
        let item = DomainRuleSettingsPresentationRelay.SingleItem(id: secondID, draft: draft)
        XCTAssertThrowsError(
            try DomainRuleSettingsAdapter.commitSingle(
                item: item,
                draft: draft,
                session: fixture.session
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsDisplayError,
                DomainRuleSettingsDisplayError(
                    messageKey: "A rule with this domain and subdomain setting already exists."
                )
            )
            XCTAssertEqual((error as? DomainRuleSettingsDisplayError)?.text(using: languageStore),
                           "A rule with this domain and subdomain setting already exists.")
        }

        XCTAssertEqual(fixture.session.state.presentation?.id, secondID)
        XCTAssertEqual(fixture.store.settings.rules.count, 2)
        XCTAssertEqual(fixture.store.settings.rules.last, editedRule)
    }

    func testCommitOnDeletePresentationIsWrongKindWithoutWriting() throws {
        let rule = try makeDomainRule(host: "delete.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [rule])
        )
        defer { fixture.cleanup() }
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: rule.id))
        )
        guard case let .deleteConfirmation(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }

        XCTAssertThrowsError(
            try fixture.session.commit(
                .bulkRule(
                    presentationID: presentationID,
                    matchers: [
                        try DomainMatcher(host: "wrong.example.com", includesSubdomains: false)
                    ],
                    destinationID: safariOpenDestination,
                    replaceExisting: false
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainRuleSettingsSession.CommitError,
                .wrongPresentationKind
            )
        }
        XCTAssertEqual(fixture.store.settings.rules, [rule])
    }

    func testSelectionCanSetToggleSelectAllAndClearCurrentRuleIDs() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [firstRule, secondRule]))
        defer { fixture.cleanup() }

        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [firstRule.id])

        _ = fixture.session.send(.toggleRuleSelection(id: firstRule.id))
        XCTAssertTrue(fixture.session.state.selectedRuleIDs.isEmpty)

        _ = fixture.session.send(.toggleRuleSelection(id: secondRule.id))
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [secondRule.id])

        _ = fixture.session.send(.selectAllRules)
        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [firstRule.id, secondRule.id])

        _ = fixture.session.send(.clearSelection)
        XCTAssertTrue(fixture.session.state.selectedRuleIDs.isEmpty)
    }

    func testSnapshotReconciliationPrunesDeletedIDsWithoutSelectingNewRules() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let newRule = try makeDomainRule(host: "new.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [firstRule, secondRule]))
        defer { fixture.cleanup() }

        _ = fixture.session.send(.selectAllRules)
        _ = fixture.session.send(.presentBulkRuleCreate)
        let currentPresentation = try XCTUnwrap(fixture.session.state.presentation)
        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(
                    host: "pending.example.com",
                    destinationID: chromeOpenDestination
                )
            )
        )
        try fixture.store.replace(
            with: makeSettings(rules: [secondRule, newRule])
        )

        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [secondRule.id])
        XCTAssertFalse(fixture.session.state.selectedRuleIDs.contains(newRule.id))
        XCTAssertEqual(fixture.session.state.presentation, currentPresentation)
        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)

        XCTAssertEqual(
            fixture.session.send(.presentationEnded(id: currentPresentation.id)),
            .revealRules
        )
        guard case let .singleRuleCreate(_, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected the pending request to survive selection reconciliation")
        }
        XCTAssertEqual(
            prefill,
            .init(
                matcher: try DomainMatcher(host: "pending.example.com", includesSubdomains: false),
                destinationID: chromeOpenDestination
            )
        )
        XCTAssertFalse(fixture.session.state.hasDeferredChooserRequest)
    }

    func testResetReconcilesSelectionToAnEmptySnapshot() throws {
        let rule = try makeDomainRule(host: "example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [rule]))
        defer { fixture.cleanup() }

        _ = fixture.session.send(.setRuleSelection(id: rule.id, isSelected: true))
        fixture.store.reset()

        XCTAssertTrue(fixture.session.state.selectedRuleIDs.isEmpty)
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            .default
        )

        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        XCTAssertNil(fixture.session.state.presentation)
    }

    func testStaleRuleSelectionAndPresentationIntentsAreNoOps() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let staleRuleID = UUID()

        _ = fixture.session.send(.setRuleSelection(id: staleRuleID, isSelected: true))
        _ = fixture.session.send(.toggleRuleSelection(id: staleRuleID))
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: staleRuleID))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: staleRuleID))
        )

        XCTAssertEqual(fixture.session.state, .init())
    }

    func testBulkCreateDoesNotDependOnSelectionAndEmptySelectedDeleteDoesNotPresent() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentBulkRuleCreate)

        guard case .bulkRuleCreate? = fixture.session.state.presentation else {
            return XCTFail("Expected a bulk-create presentation without selected rules")
        }

        guard let bulkPresentationID = fixture.session.state.presentation?.id else {
            return XCTFail("Expected a bulk-create presentation identity")
        }
        _ = fixture.session.send(.presentationEnded(id: bulkPresentationID))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .selected)
        )

        XCTAssertNil(fixture.session.state.presentation, "Empty selected deletion should be a no-op")

        _ = fixture.session.send(.presentDeleteConfirmation(target: .all))
        XCTAssertNil(fixture.session.state.presentation, "Empty all-rules deletion should be a no-op")
    }

    func testEmptyDeleteConfirmationDoesNotWrite() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentDeleteConfirmation(target: .selected))
        _ = fixture.session.send(.presentDeleteConfirmation(target: .all))

        XCTAssertNil(fixture.session.state.presentation)
        XCTAssertEqual(fixture.store.settings, .default)
    }

    func testSingleCreateEditBulkAndDeletePresentationsShareOneUniqueIdentityAtATime() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [firstRule, secondRule]))
        defer { fixture.cleanup() }
        _ = fixture.session.send(.selectAllRules)

        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(createPresentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule create presentation")
        }
        _ = fixture.session.send(.presentationEnded(id: createPresentationID))

        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: firstRule.id))
        guard case let .singleRuleEdit(editPresentationID, firstRuleID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }
        XCTAssertEqual(firstRuleID, firstRule.id)
        XCTAssertNotEqual(editPresentationID, createPresentationID)

        _ = fixture.session.send(.presentBulkRuleCreate)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleEdit(id: editPresentationID, ruleID: firstRule.id)
        )

        _ = fixture.session.send(.presentationEnded(id: editPresentationID))
        _ = fixture.session.send(.presentBulkRuleCreate)
        guard case let .bulkRuleCreate(secondPresentationID)? = fixture.session.state.presentation else {
            return XCTFail("Expected a bulk-create presentation")
        }
        XCTAssertNotEqual(secondPresentationID, editPresentationID)

        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .selected)
        )
        XCTAssertEqual(
            fixture.session.state.presentation,
            .bulkRuleCreate(id: secondPresentationID)
        )

        _ = fixture.session.send(.presentationEnded(id: secondPresentationID))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .selected)
        )
        guard case let .deleteConfirmation(thirdPresentationID, target)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }
        XCTAssertNotEqual(thirdPresentationID, secondPresentationID)
        XCTAssertNotEqual(thirdPresentationID, editPresentationID)
        XCTAssertEqual(target, .selected(ruleIDs: [firstRule.id, secondRule.id]))
    }

    func testDeleteConfirmationFreezesTargetsWhenSelectionChanges() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let thirdRule = try makeDomainRule(host: "third.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [firstRule, secondRule, thirdRule])
        )
        defer { fixture.cleanup() }
        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        _ = fixture.session.send(.setRuleSelection(id: secondRule.id, isSelected: true))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .selected)
        )

        guard case let .deleteConfirmation(presentationID, target)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }
        guard case let .selected(frozenRuleIDs) = target else {
            return XCTFail("Expected selected delete targets")
        }

        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: false))
        _ = fixture.session.send(.setRuleSelection(id: thirdRule.id, isSelected: true))

        XCTAssertEqual(fixture.session.state.selectedRuleIDs, [secondRule.id, thirdRule.id])
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(
                id: presentationID,
                target: .selected(ruleIDs: [firstRule.id, secondRule.id])
            )
        )
        XCTAssertEqual(frozenRuleIDs, [firstRule.id, secondRule.id])
    }

    func testRowAndAllDeletePresentationsFreezeExplicitTargets() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [firstRule, secondRule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: firstRule.id))
        )
        guard case let .deleteConfirmation(rowPresentationID, rowTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected a row delete confirmation")
        }
        XCTAssertEqual(rowTarget, .row(ruleID: firstRule.id))

        _ = fixture.session.send(.setRuleSelection(id: secondRule.id, isSelected: true))
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(
                id: rowPresentationID,
                target: .row(ruleID: firstRule.id)
            )
        )

        _ = fixture.session.send(.presentationEnded(id: rowPresentationID))
        _ = fixture.session.send(.presentDeleteConfirmation(target: .all))
        guard case let .deleteConfirmation(allPresentationID, allTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected an all-rules delete confirmation")
        }
        XCTAssertEqual(allTarget, .all(ruleIDs: [firstRule.id, secondRule.id]))

        _ = fixture.session.send(.clearSelection)
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(
                id: allPresentationID,
                target: .all(ruleIDs: [firstRule.id, secondRule.id])
            )
        )
    }

    func testStalePresentationEndedEventsDoNotDismissCurrentOrNewPresentation() throws {
        let rule = try makeDomainRule(host: "example.com")
        let fixture = try DomainRuleSettingsSessionFixture(settings: makeSettings(rules: [rule]))
        defer { fixture.cleanup() }

        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        guard case let .singleRuleEdit(firstPresentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected the first presentation")
        }

        let stalePresentationID = DomainRuleSettingsSession.PresentationID()
        XCTAssertNotEqual(stalePresentationID, firstPresentationID)
        _ = fixture.session.send(.presentationEnded(id: stalePresentationID))
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleEdit(id: firstPresentationID, ruleID: rule.id)
        )

        _ = fixture.session.send(.presentationEnded(id: firstPresentationID))
        XCTAssertNil(fixture.session.state.presentation)

        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: rule.id))
        guard case let .singleRuleEdit(secondPresentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected the second presentation")
        }
        XCTAssertNotEqual(secondPresentationID, firstPresentationID)

        _ = fixture.session.send(.presentationEnded(id: firstPresentationID))
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleEdit(id: secondPresentationID, ruleID: rule.id)
        )

        _ = fixture.session.send(.presentationEnded(id: secondPresentationID))
        _ = fixture.session.send(.presentationEnded(id: secondPresentationID))
        XCTAssertNil(fixture.session.state.presentation)
    }

    func testWindowClosedClearsTransientStateWithoutChangingPersistentSnapshot() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let settings = try makeSettings(rules: [firstRule, secondRule])
        let fixture = try DomainRuleSettingsSessionFixture(settings: settings)
        defer { fixture.cleanup() }
        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        _ = fixture.session.send(.presentSingleRuleEdit(ruleID: firstRule.id))
        let storedDataBefore = fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey)

        XCTAssertNil(fixture.session.send(.windowClosed))
        XCTAssertEqual(fixture.session.state, .init())
        XCTAssertEqual(fixture.store.settings, settings)
        XCTAssertEqual(
            fixture.userDefaults.data(forKey: RoutingPreferencesStore.storageKey),
            storedDataBefore
        )
        XCTAssertEqual(
            RoutingPreferencesStore(userDefaults: fixture.userDefaults).settings,
            settings
        )
    }

    func testDeleteConfirmationUsesFrozenIDsAfterSelectionChanges() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let thirdRule = try makeDomainRule(host: "third.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [firstRule, secondRule, thirdRule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        _ = fixture.session.send(.setRuleSelection(id: secondRule.id, isSelected: true))
        _ = fixture.session.send(.presentDeleteConfirmation(target: .selected))
        guard case let .deleteConfirmation(presentationID, target)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }
        XCTAssertEqual(
            target,
            .selected(ruleIDs: [firstRule.id, secondRule.id])
        )

        _ = fixture.session.send(.clearSelection)
        _ = fixture.session.send(.setRuleSelection(id: thirdRule.id, isSelected: true))
        _ = fixture.session.send(.confirmDelete(presentationID: presentationID))

        XCTAssertEqual(fixture.store.settings.rules, [thirdRule])
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(
                id: presentationID,
                target: .selected(ruleIDs: [firstRule.id, secondRule.id])
            )
        )
    }

    func testStaleDeleteConfirmationDoesNotShrinkTargetsOrWrite() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let thirdRule = try makeDomainRule(host: "third.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [firstRule, secondRule, thirdRule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        _ = fixture.session.send(.setRuleSelection(id: secondRule.id, isSelected: true))
        _ = fixture.session.send(.presentDeleteConfirmation(target: .selected))
        guard case let .deleteConfirmation(presentationID, target)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }
        try fixture.store.replace(with: makeSettings(rules: [firstRule, thirdRule]))

        _ = fixture.session.send(.confirmDelete(presentationID: presentationID))
        XCTAssertEqual(fixture.store.settings.rules, [firstRule, thirdRule])
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(id: presentationID, target: target)
        )

        _ = fixture.session.send(.presentationEnded(id: presentationID))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: firstRule.id))
        )
        guard case let .deleteConfirmation(rowPresentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a row delete confirmation presentation")
        }
        try fixture.store.replace(with: makeSettings(rules: [thirdRule]))

        _ = fixture.session.send(.confirmDelete(presentationID: rowPresentationID))
        XCTAssertEqual(fixture.store.settings.rules, [thirdRule])
    }

    func testDeleteConfirmationRejectsStaleAndWrongKindWithoutWriting() throws {
        let rule = try makeDomainRule(host: "example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [rule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: rule.id))
        )
        guard case let .deleteConfirmation(deleteID, deleteTarget)? = fixture.session.state.presentation else {
            return XCTFail("Expected a delete confirmation presentation")
        }

        _ = fixture.session.send(
            .confirmDelete(presentationID: DomainRuleSettingsSession.PresentationID())
        )
        XCTAssertEqual(fixture.store.settings.rules, [rule])
        XCTAssertEqual(
            fixture.session.state.presentation,
            .deleteConfirmation(id: deleteID, target: deleteTarget)
        )

        _ = fixture.session.send(.presentationEnded(id: deleteID))
        _ = fixture.session.send(.presentSingleRuleCreate)
        guard case let .singleRuleCreate(singleRuleID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a single-rule presentation")
        }

        _ = fixture.session.send(.confirmDelete(presentationID: singleRuleID))
        XCTAssertEqual(fixture.store.settings.rules, [rule])
        XCTAssertEqual(
            fixture.session.state.presentation,
            .singleRuleCreate(id: singleRuleID, prefill: nil)
        )
    }

    func testProductionDeleteContinuesSelectionReconciliation() throws {
        let firstRule = try makeDomainRule(host: "first.example.com")
        let secondRule = try makeDomainRule(host: "second.example.com")
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: makeSettings(rules: [firstRule, secondRule])
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(.setRuleSelection(id: firstRule.id, isSelected: true))
        _ = fixture.session.send(
            .presentDeleteConfirmation(target: .row(ruleID: firstRule.id))
        )
        guard case let .deleteConfirmation(presentationID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected a row delete confirmation presentation")
        }
        _ = fixture.session.send(.confirmDelete(presentationID: presentationID))

        XCTAssertEqual(fixture.store.settings.rules, [secondRule])
        XCTAssertTrue(fixture.session.state.selectedRuleIDs.isEmpty)
        _ = fixture.session.send(.presentationEnded(id: presentationID))
    }

    func testAddRuleMatcherToScopeUsesLatestRuleSnapshot() throws {
        let scopeMatcher = try DomainMatcher(
            host: "scope.example.com",
            includesSubdomains: false
        )
        let rule = try makeDomainRule(host: "rule.example.com")
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [scopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: settings
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id)
        )
        guard case let .onlyThese(scopeMatchers, _) = fixture.store.settings.scope else {
            return XCTFail("Expected an only-these routing scope")
        }
        XCTAssertEqual(scopeMatchers, [scopeMatcher, rule.matcher])
        XCTAssertNil(fixture.session.state.pageFailure)
    }

    func testAddRuleMatcherToScopeNoOpsWhenBroaderScopeMatcherContainsRule() throws {
        let scopeMatcher = try DomainMatcher(
            host: "example.com",
            includesSubdomains: true
        )
        let rule = try makeDomainRule(host: "sub.example.com")
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [scopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: settings
        )
        defer { fixture.cleanup() }

        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id)
        )

        XCTAssertEqual(fixture.store.settings, settings)
    }

    func testAddRuleMatcherToScopeAddsSubdomainRuleWhenScopeOnlyCoversBaseExactly() throws {
        let scopeMatcher = try DomainMatcher(
            host: "example.com",
            includesSubdomains: false
        )
        let rule = try makeDomainRule(
            host: "example.com",
            includesSubdomains: true
        )
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [scopeMatcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: settings
        )
        defer { fixture.cleanup() }

        XCTAssertEqual(fixture.store.settings.scope.coverage(of: rule.matcher), .partial)
        XCTAssertFalse(fixture.store.settings.scope.contains(rule.matcher))
        XCTAssertEqual(fixture.store.settings, settings, "Partial coverage must not implicitly expand Scope")

        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id)
        )

        guard case let .onlyThese(scopeMatchers, _) = fixture.store.settings.scope else {
            return XCTFail("Expected an only-these routing scope")
        }
        XCTAssertEqual(scopeMatchers, [scopeMatcher, rule.matcher])
        XCTAssertEqual(fixture.store.settings.scope.coverage(of: rule.matcher), .full)
        XCTAssertEqual(fixture.store.settings.rules, [rule])
    }

    func testAddRuleMatcherToScopeIsNoOpForStaleRulesAndUnsupportedScopes() throws {
        let rule = try makeDomainRule(host: "rule.example.com")
        let onlyTheseSettings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        let fixture = try DomainRuleSettingsSessionFixture(
            settings: onlyTheseSettings
        )
        defer { fixture.cleanup() }

        let allDomainsSettings = try RoutingSettings(
            scope: .allDomains,
            rules: [rule],
            alwaysShowChooser: false
        )
        try fixture.store.replace(with: allDomainsSettings)
        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id)
        )
        XCTAssertEqual(fixture.store.settings, allDomainsSettings)

        try fixture.store.replace(with: onlyTheseSettings)
        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: UUID())
        )
        XCTAssertEqual(fixture.store.settings, onlyTheseSettings)

        let alreadyCoveredSettings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [rule.matcher],
                bypassDestinationID: safariOpenDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        try fixture.store.replace(with: alreadyCoveredSettings)
        _ = fixture.session.send(
            .addRuleMatcherToRoutingScope(ruleID: rule.id)
        )
        XCTAssertEqual(fixture.store.settings, alreadyCoveredSettings)
    }

    func testPromotedSheetRepresentationDefersThenCommitsAndClosesCleanly() throws {
        let fixture = try DomainRuleSettingsSessionFixture()
        defer { fixture.cleanup() }
        let destination = OpenDestinationID(
            browserID: "com.example.PromotedBrowser",
            mode: .normal
        )
        var relay = DomainRuleSettingsPresentationRelay()

        // Sheet 1 presented from an idle chooser request.
        XCTAssertEqual(
            fixture.session.send(
                .requestRuleFromChooser(host: "first.example.com", destinationID: destination)
            ),
            .revealRules
        )
        guard case let .singleRuleCreate(firstID, _)? = fixture.session.state.presentation else {
            return XCTFail("Expected immediate chooser presentation")
        }
        XCTAssertFalse(relay.synchronize(
            with: fixture.session.state.presentation,
            rules: fixture.store.settings.rules,
            destinations: []
        ))
        XCTAssertEqual(relay.item?.id, firstID)

        // A chooser request while busy is deferred.
        XCTAssertNil(
            fixture.session.send(
                .requestRuleFromChooser(host: "zed.dev", destinationID: destination)
            )
        )
        XCTAssertTrue(fixture.session.state.hasDeferredChooserRequest)

        // Sheet 1 Cancel: relay dismissal chain, then the session promotes the deferred request.
        relay.presentationWillDismiss()
        XCTAssertEqual(relay.presentationDidDismiss(), firstID)
        XCTAssertEqual(fixture.session.send(.presentationEnded(id: firstID)), .revealRules)
        guard case let .singleRuleCreate(promotedID, prefill)? = fixture.session.state.presentation else {
            return XCTFail("Expected promotion after dismissal")
        }
        XCTAssertEqual(prefill?.matcher.normalizedHost, "zed.dev")

        // Regression (settings-sheet-zombie/01): the first sync inside the dismissal chain must
        // defer instead of handing the view a new sheet item synchronously.
        XCTAssertTrue(relay.synchronize(
            with: fixture.session.state.presentation,
            rules: fixture.store.settings.rules,
            destinations: []
        ))
        XCTAssertNil(relay.item)

        // The deferred retry (next runloop turn in production) presents the promoted sheet.
        XCTAssertFalse(relay.synchronize(
            with: fixture.session.state.presentation,
            rules: fixture.store.settings.rules,
            destinations: []
        ))
        XCTAssertEqual(relay.item?.id, promotedID)

        // Save on the promoted sheet persists through the editor (the zombie-sheet bug
        // surfaced here as CommitError.stalePresentation before anything was saved).
        try fixture.session.commit(
            .singleRule(
                presentationID: promotedID,
                host: "zed.dev",
                includesSubdomains: false,
                destinationID: destination
            )
        )
        let savedRule = try XCTUnwrap(fixture.store.settings.rules.first)
        XCTAssertEqual(fixture.store.settings.rules.count, 1)
        XCTAssertEqual(savedRule.matcher.normalizedHost, "zed.dev")
        XCTAssertEqual(savedRule.destinationID, destination)

        // Dismissing the promoted sheet ends the two-phase lifecycle cleanly.
        relay.presentationWillDismiss()
        XCTAssertEqual(relay.presentationDidDismiss(), promotedID)
        XCTAssertNil(fixture.session.send(.presentationEnded(id: promotedID)))
        XCTAssertNil(fixture.session.state.presentation)
        XCTAssertFalse(relay.synchronize(
            with: fixture.session.state.presentation,
            rules: fixture.store.settings.rules,
            destinations: []
        ))
        XCTAssertNil(relay.item)

        // A later fresh chooser request presents immediately (defer marker fully consumed).
        XCTAssertEqual(
            fixture.session.send(
                .requestRuleFromChooser(host: "fresh.example.com", destinationID: destination)
            ),
            .revealRules
        )
        XCTAssertFalse(relay.synchronize(
            with: fixture.session.state.presentation,
            rules: fixture.store.settings.rules,
            destinations: []
        ))
        XCTAssertNotNil(relay.item)
    }

}

@MainActor
private final class DomainRuleSettingsSessionFixture {
    let userDefaults: UserDefaults
    let store: RoutingPreferencesStore
    let session: DomainRuleSettingsSession

    private let suiteName: String

    init(
        settings: RoutingSettings = .default
    ) throws {
        let suiteName = "EligoTests.DomainRuleSettingsSession.\(UUID().uuidString)"
        self.suiteName = suiteName
        userDefaults = UserDefaults(suiteName: suiteName)!
        store = RoutingPreferencesStore(userDefaults: userDefaults)
        try store.replace(with: settings)
        session = DomainRuleSettingsSession(store: store)
    }

    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeDomainRule(
    host: String,
    includesSubdomains: Bool = false,
    destinationID: OpenDestinationID = OpenDestinationID(
        browserID: "com.example.Browser",
        mode: .normal
    )
) throws -> DomainRule {
    DomainRule(
        matcher: try DomainMatcher(host: host, includesSubdomains: includesSubdomains),
        destinationID: destinationID
    )
}

private func makeSettings(rules: [DomainRule]) throws -> RoutingSettings {
    try RoutingSettings(scope: .allDomains, rules: rules, alwaysShowChooser: false)
}

private let safariOpenDestination = OpenDestinationID(
    browserID: "com.apple.Safari",
    mode: .normal
)

private let chromeOpenDestination = OpenDestinationID(
    browserID: "com.google.Chrome",
    mode: .normal
)
