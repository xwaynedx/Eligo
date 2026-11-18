import Combine
import Foundation
import XCTest
@testable import Eligo

@MainActor
final class ScopeEditorSessionTests: XCTestCase {
    func testPasteAppendReusesSnapshotAndValidatesChangedDraftsOnce() throws {
        let initial = try (0..<1_000).map { try DomainMatcher(host: "host\($0).example", includesSubdomains: true) }
        var resolutions = 0
        let fixture = try ScopeSessionFixture(matchers: initial) { draft in
            resolutions += 1
            return try ScopeMatcherDraftLogic.matcher(for: draft)
        }
        defer { fixture.cleanup() }
        let session = fixture.session
        let initialDrafts = session.validation.drafts
        XCTAssertEqual(resolutions, 1_000)

        resolutions = 0
        let pasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "host0.example added.example added.example")
        XCTAssertEqual(session.pasteDraft?.preview.duplicateInputs, ["added.example"])
        XCTAssertTrue(session.confirmPaste(pasteID: pasteID))
        XCTAssertEqual(session.feedback?.message, .pasteResult(added: 1, skippedDuplicates: 1))
        XCTAssertEqual(resolutions, 1_001)
        XCTAssertEqual(Array(session.validation.drafts.prefix(initialDrafts.count)), initialDrafts)
        XCTAssertNotNil(session.validation.validatedMatchers(for: session.validation.drafts))

        resolutions = 0
        let secondPasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: secondPasteID, text: "added.example")
        XCTAssertTrue(session.confirmPaste(pasteID: secondPasteID))
        XCTAssertEqual(session.feedback?.message, .pasteResult(added: 0, skippedDuplicates: 1))
        XCTAssertEqual(resolutions, 0, "Duplicate-only append must reuse the complete validation snapshot")
    }

    func testCapturedAddRulesActionPreservesLatestInvalidDraft() throws {
        let fixture = try ScopeSessionFixture(
            matchers: [try matcher("old.example")], rules: [try matcher("added.example", subdomains: false)]
        )
        defer { fixture.cleanup() }
        let session = fixture.session
        let append = session.addAllRuleDomains
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        session.editHost(rowID: rowID, text: "foo/bar")
        let edited = try XCTUnwrap(session.validation.drafts.first)

        append()

        XCTAssertEqual(session.validation.drafts.first, edited)
        XCTAssertEqual(session.validation.issue(for: rowID), .invalidHost)
        XCTAssertNil(session.validation.validatedMatchers(for: session.validation.drafts))
        XCTAssertEqual(session.validation.drafts.last?.host, "added.example")
    }

    func testIPHostEditsClearSubdomainsAndDNSDoesNotReenableIt() throws {
        for input in ["192.168.0.1", "::1", "[::1]", "https://[::1]/path", "https://127.0.0.1/path"] {
            let fixture = try ScopeSessionFixture(matchers: [try matcher("example.com")])
            defer { fixture.cleanup() }
            let session = fixture.session
            let rowID = try XCTUnwrap(session.validation.drafts.first?.id)

            session.editHost(rowID: rowID, text: input)
            XCTAssertFalse(try XCTUnwrap(session.validation.drafts.first).includesSubdomains, input)
            XCTAssertNil(session.validation.issue(for: rowID), input)
            XCTAssertFalse(session.validation.supportsSubdomains(for: rowID), input)
            let matchers = try XCTUnwrap(session.validation.validatedMatchers(for: session.validation.drafts))
            XCTAssertEqual(matchers.count, 1)
            XCTAssertFalse(matchers[0].includesSubdomains)

            session.editHost(rowID: rowID, text: "example.com")
            XCTAssertFalse(try XCTUnwrap(session.validation.drafts.first).includesSubdomains,
                           "Returning to DNS must not silently check the option")
            XCTAssertTrue(session.validation.supportsSubdomains(for: rowID))
            session.setIncludesSubdomains(rowID: rowID, enabled: true)
            session.editHost(rowID: rowID, text: input)
            XCTAssertTrue(session.save(), input)
            XCTAssertEqual(fixture.store.settings.scope,
                           .onlyThese(matchers: matchers, bypassDestinationID: fixture.destination.destinationID))
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.defaults).settings, fixture.store.settings)
        }
    }

    func testForcedIPSubdomainsHasDedicatedErrorAndDirectSaveCannotWrite() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("127.0.0.1", subdomains: false)])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        let bytes = fixture.routingBytes
        session.setIncludesSubdomains(rowID: rowID, enabled: true)

        XCTAssertEqual(session.validation.issue(for: rowID), .ipAddressesCannotIncludeSubdomains)
        XCTAssertTrue(session.validation.supportsSubdomains(for: rowID), "The residual invalid option must remain repairable")
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.save())
        XCTAssertEqual(fixture.successfulWrites, 0)
        XCTAssertEqual(fixture.routingBytes, bytes)
        let language = AppLanguageStore(userDefaults: fixture.defaults, systemPreferredLanguages: ["en-US"])
        language.select(.simplifiedChinese)
        XCTAssertEqual(language.text(ScopeMatcherDraftIssue.ipAddressesCannotIncludeSubdomains.message),
                       "IP 地址不支持子域名，请关闭“包含子域名”。")
        session.setIncludesSubdomains(rowID: rowID, enabled: false)
        XCTAssertTrue(session.save())
    }

    func testRowActionsKeepDuplicateValidationAndSaveSynchronized() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("example.com"), try matcher("other.example", subdomains: false)])
        defer { fixture.cleanup() }
        let session = fixture.session
        let first = session.validation.drafts[0].id
        let second = session.validation.drafts[1].id
        let bytes = fixture.routingBytes

        session.editHost(rowID: second, text: "https://EXAMPLE.com./path")
        XCTAssertTrue(session.validation.invalidDraftIDs.isEmpty)
        XCTAssertEqual(try XCTUnwrap(session.validation.validatedMatchers(for: session.validation.drafts)).count, 2)
        session.setIncludesSubdomains(rowID: second, enabled: true)
        XCTAssertEqual(session.validation.invalidDraftIDs, [first, second])
        XCTAssertEqual(session.validation.issue(for: first), .duplicate)
        XCTAssertEqual(session.validation.issue(for: second), .duplicate)
        XCTAssertFalse(session.save(), "Calling Save directly must reject duplicates")
        XCTAssertEqual(fixture.routingBytes, bytes)

        session.editHost(rowID: second, text: "foo/bar")
        XCTAssertEqual(session.validation.invalidDraftIDs, [second])
        XCTAssertEqual(session.validation.issue(for: second), .invalidHost)
        XCTAssertFalse(session.save(), "A former valid snapshot must not be submitted")
        XCTAssertEqual(fixture.successfulWrites, 0)

        session.editHost(rowID: second, text: "fixed.example")
        let matchers = try XCTUnwrap(session.validation.validatedMatchers(for: session.validation.drafts))
        XCTAssertEqual(matchers.map(\.normalizedHost), ["example.com", "fixed.example"])
        XCTAssertEqual(matchers.map(\.includesSubdomains), [true, true])
        XCTAssertTrue(session.save())
        XCTAssertEqual(fixture.successfulWrites, 1)
    }

    func testAppendRemoveClearAndUndoPreserveInvalidAndEmptyRows() throws {
        let fixture = try ScopeSessionFixture()
        defer { fixture.cleanup() }
        let session = fixture.session
        let invalidID = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: invalidID, text: "foo/bar")
        session.finishRowEditing(rowID: invalidID)
        let emptyID = try XCTUnwrap(session.addDomain())
        let originalRows = session.validation.drafts
        let pasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "added.example added.example")
        XCTAssertTrue(session.confirmPaste(pasteID: pasteID))
        XCTAssertEqual(Array(session.validation.drafts.prefix(2)), originalRows)
        XCTAssertEqual(session.validation.invalidDraftIDs, [invalidID])
        XCTAssertEqual(session.touchedRowIDs, [invalidID])
        XCTAssertEqual(session.validation.drafts.count, 3)

        session.removeDomain(rowID: invalidID)
        let removalID = try XCTUnwrap(session.feedback?.id)
        XCTAssertTrue(session.validation.invalidDraftIDs.isEmpty)
        XCTAssertEqual(session.validation.validatedMatchers(for: session.validation.drafts), [try matcher("added.example")])
        session.undo(feedbackID: removalID)
        XCTAssertEqual(session.validation.invalidDraftIDs, [invalidID])
        XCTAssertEqual(session.touchedRowIDs, [invalidID])
        XCTAssertTrue(session.validation.drafts.contains { $0.id == emptyID && $0.host.isEmpty })

        let beforeClear = session.validation.drafts
        session.clearDomains()
        let clearID = try XCTUnwrap(session.feedback?.id)
        XCTAssertEqual(session.validation.validatedMatchers(for: session.validation.drafts), [])
        XCTAssertTrue(session.touchedRowIDs.isEmpty)
        session.undo(feedbackID: clearID)
        XCTAssertEqual(session.validation.drafts, beforeClear)
        XCTAssertEqual(session.validation.invalidDraftIDs, [invalidID])
        XCTAssertEqual(session.touchedRowIDs, [invalidID])
    }

    func testUnchangedActionsAndDerivedReadsDoNotPublishOrReparseDrafts() throws {
        var resolutions = 0
        let fixture = try ScopeSessionFixture(matchers: [try matcher("example.com")]) { draft in
            resolutions += 1
            return try ScopeMatcherDraftLogic.matcher(for: draft)
        }
        defer { fixture.cleanup() }
        let session = fixture.session
        let row = try XCTUnwrap(session.validation.drafts.first)
        var snapshots: [ScopeMatcherDraftValidation] = []
        var repositoryChanges = 0
        let validationSubscription = session.$validation.dropFirst().sink { snapshots.append($0) }
        let repositorySubscription = fixture.destination.repository.objectWillChange.sink { repositoryChanges += 1 }
        defer { validationSubscription.cancel(); repositorySubscription.cancel() }
        resolutions = 0

        session.editHost(rowID: row.id, text: row.host)
        session.setIncludesSubdomains(rowID: row.id, enabled: row.includesSubdomains)
        session.setMode(session.mode)
        session.selectBypassDestination(session.bypassDestinationID)
        session.finishRowEditing(rowID: row.id)
        session.finishRowEditing(rowID: row.id)
        let language = AppLanguageStore(userDefaults: fixture.defaults, systemPreferredLanguages: ["en-US"])
        language.select(.simplifiedChinese)
        for _ in 0..<100 {
            XCTAssertNil(session.validation.issue(for: row.id))
            XCTAssertTrue(session.validation.invalidDraftIDs.isEmpty)
            XCTAssertNotNil(session.validation.validatedMatchers(for: session.validation.drafts))
            XCTAssertTrue(session.canSave)
            _ = session.normalDestinations
            _ = session.destinationIssue
            _ = session.ruleMatchers
        }
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(repositoryChanges, 0, "Display reads must not call the publishing commit-time destination lookup")

        session.editHost(rowID: row.id, text: "foo/bar")
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(snapshots[0].drafts, session.validation.drafts)
        XCTAssertEqual(snapshots[0].invalidDraftIDs, [row.id])
        XCTAssertNil(snapshots[0].validatedMatchers(for: snapshots[0].drafts))
    }

    func testAddDomainInsertsAtTopAndReusesPendingEmptyRow() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("first.example"), try matcher("second.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let original = session.validation.drafts
        let newID = try XCTUnwrap(session.addDomain())
        XCTAssertEqual(session.validation.drafts.first?.id, newID)
        XCTAssertEqual(Array(session.validation.drafts.dropFirst()), original)
        XCTAssertFalse(session.touchedRowIDs.contains(newID))
        XCTAssertEqual(session.addDomain(), newID)
        XCTAssertEqual(session.validation.drafts.count, 3)
        session.editHost(rowID: newID, text: " \n ")
        XCTAssertEqual(session.addDomain(), newID)
        XCTAssertTrue(session.canSave)
        XCTAssertTrue(session.save())
        XCTAssertEqual(fixture.store.settings.scope,
                       .onlyThese(matchers: [try matcher("first.example"), try matcher("second.example")],
                                  bypassDestinationID: fixture.destination.destinationID))
    }

    func testFinishEditingNormalizesCurrentRowAndUnknownRowActionsDoNothing() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("initial.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        session.editHost(rowID: rowID, text: " https://EXAMPLE.com./path?query=1 ")
        session.finishRowEditing(rowID: rowID)
        XCTAssertEqual(session.validation.drafts.first?.host, "example.com")
        XCTAssertEqual(session.touchedRowIDs, [rowID])
        XCTAssertTrue(session.isActive, "Finishing a row must leave the editor open")
        XCTAssertEqual(fixture.successfulWrites, 0)
        let validation = session.validation
        let unknown = UUID()
        session.editHost(rowID: unknown, text: "foo/bar")
        session.setIncludesSubdomains(rowID: unknown, enabled: false)
        session.finishRowEditing(rowID: unknown)
        session.removeDomain(rowID: unknown)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(session.touchedRowIDs, [rowID])
        XCTAssertNil(session.feedback)
    }

    func testTrailingDotNormalizationAndRejectionUseTheCurrentSavePath() throws {
        for input in ["EXAMPLE.com.", "https://EXAMPLE.com./path", "example.com..", "https://example.com../path"] {
            let fixture = try ScopeSessionFixture()
            defer { fixture.cleanup() }
            let session = fixture.session
            let rowID = try XCTUnwrap(session.addDomain())
            let bytes = fixture.routingBytes
            session.editHost(rowID: rowID, text: input)
            let isValid = !input.contains("..")
            XCTAssertEqual(session.save(), isValid, input)
            if isValid {
                XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.defaults).settings.scope,
                               .onlyThese(matchers: [try matcher("example.com")],
                                          bypassDestinationID: fixture.destination.destinationID))
            } else {
                XCTAssertEqual(session.validation.issue(for: rowID), .invalidHost, input)
                XCTAssertEqual(fixture.routingBytes, bytes)
                XCTAssertEqual(fixture.successfulWrites, 0)
            }
        }
    }

    func testSingleRowUndoRestoresIdentityPositionAndTouchedWithoutOverwritingOtherEdits() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("first.example"), try matcher("second.example", subdomains: false)])
        defer { fixture.cleanup() }
        let session = fixture.session
        let first = session.validation.drafts[0]
        let second = session.validation.drafts[1]
        session.finishRowEditing(rowID: second.id)
        session.removeDomain(rowID: second.id)
        let feedbackID = try XCTUnwrap(session.feedback?.id)
        XCTAssertTrue(session.touchedRowIDs.isEmpty)
        session.editHost(rowID: first.id, text: "edited.example")
        let newID = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: newID, text: "new.example")

        session.undo(feedbackID: feedbackID)

        XCTAssertEqual(session.validation.drafts.map(\.id), [newID, second.id, first.id])
        XCTAssertEqual(session.validation.drafts[1], second)
        XCTAssertEqual(session.validation.drafts[2].host, "edited.example")
        XCTAssertEqual(session.validation.drafts[0].host, "new.example")
        XCTAssertEqual(session.touchedRowIDs, [second.id])
        XCTAssertNil(session.feedback)
    }

    func testClearUndoIsInvalidatedByNewInputAndByAppend() throws {
        for addition in ["row", "paste", "rules"] {
            let fixture = try ScopeSessionFixture(matchers: [try matcher("old.example")], rules: [try matcher("rule.example")])
            defer { fixture.cleanup() }
            let session = fixture.session
            session.clearDomains()
            let oldFeedbackID = try XCTUnwrap(session.feedback?.id)
            switch addition {
            case "row":
                let rowID = try XCTUnwrap(session.addDomain())
                session.editHost(rowID: rowID, text: "new.example")
                XCTAssertNil(session.feedback)
            case "paste":
                let pasteID = try XCTUnwrap(session.beginPaste())
                session.editPasteText(pasteID: pasteID, text: "pasted.example")
                XCTAssertTrue(session.confirmPaste(pasteID: pasteID))
            default: session.addAllRuleDomains()
            }
            let rows = session.validation.drafts
            session.undo(feedbackID: oldFeedbackID)
            XCTAssertEqual(session.validation.drafts, rows, addition)
            XCTAssertEqual(rows.count, 1)
            XCTAssertNotEqual(rows.first?.host, "old.example")
        }
    }

    func testUndoRejectsOldEventAndHonorsCurrentEventAbsoluteDeadline() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("same.example"), try matcher("same.example", subdomains: false)])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rows = session.validation.drafts
        session.removeDomain(rowID: rows[0].id)
        let first = try XCTUnwrap(session.feedback)
        fixture.clock.advance(by: .seconds(5))
        session.removeDomain(rowID: rows[1].id)
        let second = try XCTUnwrap(session.feedback)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.message, second.message)
        XCTAssertEqual(second.expiresAt, fixture.clock.now.advanced(by: .seconds(6)))

        fixture.clock.advance(by: .seconds(1))
        session.undo(feedbackID: first.id)
        XCTAssertEqual(session.feedback, second)
        XCTAssertTrue(session.validation.drafts.isEmpty)
        session.undo(feedbackID: second.id)
        XCTAssertEqual(session.validation.drafts, [rows[1]])
        XCTAssertNil(session.feedback)
        session.undo(feedbackID: first.id)
        XCTAssertEqual(session.validation.drafts, [rows[1]])

        session.removeDomain(rowID: rows[1].id)
        let third = try XCTUnwrap(session.feedback)
        fixture.clock.advance(by: .seconds(6))
        // No task can run between advancing this clock and the synchronous action.
        session.undo(feedbackID: third.id)
        XCTAssertTrue(session.validation.drafts.isEmpty)
        XCTAssertNil(session.feedback, "Deadline rejection must clear both feedback and its Undo snapshot")
        session.undo(feedbackID: third.id)
        XCTAssertTrue(session.validation.drafts.isEmpty)
    }

    func testUndoAfterDifferentHostRemovalAndReplacementFeedbackCannotReviveOldRows() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("first.example"), try matcher("second.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rows = session.validation.drafts
        session.removeDomain(rowID: rows[0].id)
        let firstID = try XCTUnwrap(session.feedback?.id)
        session.undo(feedbackID: firstID)
        XCTAssertEqual(session.validation.drafts, rows)
        session.removeDomain(rowID: rows[1].id)
        let secondID = try XCTUnwrap(session.feedback?.id)
        session.undo(feedbackID: firstID)
        XCTAssertEqual(session.validation.drafts, [rows[0]])
        let pasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "third.example")
        XCTAssertTrue(session.confirmPaste(pasteID: pasteID))
        XCTAssertFalse(try XCTUnwrap(session.feedback).canUndo)
        let afterPaste = session.validation.drafts
        session.undo(feedbackID: secondID)
        XCTAssertEqual(session.validation.drafts, afterPaste)
    }

    func testSameModeKeepsUndoAndActualModeChangeClearsItWithoutLosingInput() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("first.example"), try matcher("second.example", subdomains: false)])
        defer { fixture.cleanup() }
        let session = fixture.session
        let first = session.validation.drafts[0].id
        let second = session.validation.drafts[1].id
        session.editHost(rowID: first, text: "foo/bar")
        session.finishRowEditing(rowID: first)
        session.removeDomain(rowID: second)
        let feedback = try XCTUnwrap(session.feedback)
        session.setMode(.onlyThese)
        XCTAssertEqual(session.feedback, feedback)
        let validation = session.validation
        let destinationID = session.bypassDestinationID

        session.setMode(.allDomains)
        XCTAssertNil(session.feedback)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(session.touchedRowIDs, [first])
        XCTAssertEqual(session.bypassDestinationID, destinationID)
        session.setMode(.allExceptThese)
        session.undo(feedbackID: feedback.id)
        XCTAssertEqual(session.validation, validation)
        XCTAssertFalse(session.canSave)
    }

    func testMixedPastePreviewOptionAndAppendPreserveOriginalRowsAndTouched() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("existing.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let invalidID = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: invalidID, text: "foo/bar")
        session.finishRowEditing(rowID: invalidID)
        let emptyID = try XCTUnwrap(session.addDomain())
        let initial = session.validation.drafts
        let pasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "existing.example new.example https://[::1]/path")
        let firstPreview = try XCTUnwrap(session.pasteDraft?.preview)
        XCTAssertTrue(firstPreview.hasDNSHosts)
        XCTAssertTrue(firstPreview.hasIPAddresses)
        XCTAssertFalse(firstPreview.hasOnlyIPAddresses)
        XCTAssertEqual(firstPreview.matchers.map(\.includesSubdomains), [true, true, false])
        session.setPasteIncludesSubdomains(pasteID: pasteID, enabled: false)
        XCTAssertEqual(session.pasteDraft?.preview.matchers.map(\.includesSubdomains), [false, false, false])
        session.setPasteIncludesSubdomains(pasteID: pasteID, enabled: true)
        XCTAssertTrue(session.confirmPaste(pasteID: pasteID))

        XCTAssertEqual(Array(session.validation.drafts.prefix(initial.count)), initial)
        XCTAssertEqual(session.validation.drafts.suffix(2).map(\.host), ["new.example", "::1"])
        XCTAssertEqual(session.validation.drafts.suffix(2).map(\.includesSubdomains), [true, false])
        XCTAssertEqual(session.validation.invalidDraftIDs, [invalidID])
        XCTAssertEqual(session.touchedRowIDs, [invalidID])
        XCTAssertTrue(session.validation.drafts.contains { $0.id == emptyID })
        XCTAssertEqual(session.feedback?.message, .pasteResult(added: 2, skippedDuplicates: 1))
        XCTAssertNil(session.pasteDraft)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(fixture.successfulWrites, 0)
    }

    func testPasteWithEmptyOrInvalidTokensRejectsEntireSubmission() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("existing.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rows = session.validation.drafts
        let pasteID = try XCTUnwrap(session.beginPaste())
        for text in ["", " \n ", "good.example foo/bar", "good.example https://bad.example:65536/path"] {
            session.editPasteText(pasteID: pasteID, text: text)
            XCTAssertFalse(session.confirmPaste(pasteID: pasteID), text)
            XCTAssertEqual(session.validation.drafts, rows, text)
            XCTAssertEqual(session.pasteDraft?.id, pasteID)
            XCTAssertNil(session.feedback)
        }
        session.cancelPaste(pasteID: pasteID)
        XCTAssertNil(session.pasteDraft)
        XCTAssertEqual(session.validation.drafts, rows)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(fixture.successfulWrites, 0)
    }

    func testReopenedPasteIgnoresEveryCallbackFromPreviousPasteID() throws {
        let fixture = try ScopeSessionFixture()
        defer { fixture.cleanup() }
        let session = fixture.session
        let firstID = try XCTUnwrap(session.beginPaste())
        XCTAssertNil(session.beginPaste(), "A currently open child draft must not be replaced")
        session.editPasteText(pasteID: firstID, text: "discarded.example")
        session.cancelPaste(pasteID: firstID)
        let secondID = try XCTUnwrap(session.beginPaste())
        XCTAssertNotEqual(firstID, secondID)
        session.editPasteText(pasteID: secondID, text: "current.example")
        let currentPreview = try XCTUnwrap(session.pasteDraft?.preview)

        session.editPasteText(pasteID: firstID, text: "stale.example")
        session.setPasteIncludesSubdomains(pasteID: firstID, enabled: false)
        XCTAssertFalse(session.confirmPaste(pasteID: firstID))
        session.cancelPaste(pasteID: firstID)
        XCTAssertEqual(session.pasteDraft?.id, secondID)
        XCTAssertEqual(session.pasteDraft?.text, "current.example")
        XCTAssertEqual(session.pasteDraft?.preview, currentPreview)
        XCTAssertTrue(session.confirmPaste(pasteID: secondID))
        XCTAssertEqual(session.validation.drafts.map(\.host), ["current.example"])
    }

    func testReferenceUpdatesKeepDraftSnapshotAndAddRulesUsesLatestRules() throws {
        var resolutions = 0
        let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")], rules: [try matcher("old-rule.example")]) { draft in
            resolutions += 1
            return try ScopeMatcherDraftLogic.matcher(for: draft)
        }
        defer { fixture.cleanup() }
        let session = fixture.session
        let validation = session.validation
        let capturedAction = session.addAllRuleDomains
        resolutions = 0
        let newMatcher = try matcher("latest-rule.example", subdomains: false)
        let latestRules = [DomainRule(matcher: newMatcher, destinationID: fixture.destination.destinationID)]
        try fixture.store.replace(with: fixture.store.settings.replacing(rules: latestRules))
        _ = try fixture.destination.repository.currentNormalDestination(for: fixture.destination.destinationID)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(session.ruleMatchers, [newMatcher], "Read after publication must see newly assigned reference values")

        capturedAction()
        XCTAssertEqual(session.validation.drafts.map(\.host), ["scope.example", "latest-rule.example"])
        XCTAssertEqual(session.validation.drafts.last?.includesSubdomains, false)
        XCTAssertEqual(session.feedback?.message, .pasteResult(added: 1, skippedDuplicates: 0))
        XCTAssertEqual(resolutions, 2)
    }

    func testDirectSaveRejectsMissingDestinationAndPrivateDestinationWithoutWriting() throws {
        for destinationKind in ["missing", "private"] {
            let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
            defer { fixture.cleanup() }
            let session = fixture.session
            let bytes = fixture.routingBytes
            session.selectBypassDestination(destinationKind == "missing" ? nil : OpenDestinationID(
                browserID: fixture.destination.browser.id, mode: .privateBrowsing
            ))
            XCTAssertFalse(session.canSave)
            XCTAssertFalse(session.save())
            XCTAssertTrue(session.isActive)
            XCTAssertFalse(session.isSaving)
            XCTAssertEqual(fixture.routingBytes, bytes)
            XCTAssertEqual(fixture.successfulWrites, 0)
            switch (destinationKind, session.saveFeedback) {
            case ("missing", .editorValidation(.bypassDestinationRequired)?): break
            case ("private", .destinationValidation(.bypassDestinationUnavailable)?): break
            default: XCTFail("The save feedback must distinguish a missing selection from an invalid target")
            }
        }
    }

    func testSaveChecksLatestTargetInsteadOfCachedAvailabilityAndPreservesDrafts() throws {
        for change in ["disabled", "removed", "uninstalled", "unreadable"] {
            let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
            defer { fixture.cleanup() }
            let session = fixture.session
            let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
            session.editHost(rowID: rowID, text: "latest.example")
            session.finishRowEditing(rowID: rowID)
            let validation = session.validation
            let bytes = fixture.routingBytes
            switch change {
            case "disabled":
                try fixture.destination.preferences.save([ConfiguredBrowser(browser: fixture.destination.browser, isEnabled: false)])
            case "removed":
                try fixture.destination.preferences.saveScannedBrowsers([], at: Date())
            case "uninstalled":
                try FileManager.default.removeItem(at: fixture.destination.browser.appURL)
            default:
                fixture.defaults.set(Data("broken browser settings".utf8), forKey: BrowserPreferences.storageKey)
            }
            XCTAssertTrue(session.canSave, "External bytes have not yet replaced the repository's published cache")
            XCTAssertFalse(session.save(), change)
            XCTAssertEqual(session.validation, validation, change)
            XCTAssertEqual(session.touchedRowIDs, [rowID])
            XCTAssertEqual(session.bypassDestinationID, fixture.destination.destinationID)
            XCTAssertTrue(session.isActive)
            XCTAssertFalse(session.isSaving)
            XCTAssertEqual(fixture.routingBytes, bytes, change)
            XCTAssertEqual(fixture.successfulWrites, 0, change)
            let expected: ScopeSaveError = change == "unreadable" ? .browserConfigurationUnavailable : .bypassDestinationUnavailable
            guard case let .destinationValidation(error)? = session.saveFeedback else {
                XCTFail("Expected semantic destination failure for \(change)")
                continue
            }
            XCTAssertEqual(error, expected)
            if change != "uninstalled" {
                XCTAssertEqual(session.destinationIssue, expected)
                XCTAssertFalse(session.canSave)
            } else {
                guard case .destinationValidation(.bypassDestinationUnavailable)? = session.displayedIssue else {
                    XCTFail("A commit-only missing-app failure must remain visible while the published cache is unchanged")
                    continue
                }
            }
        }
    }

    func testPublishedTargetFaultExplainsFailureAndExplicitSaveSucceedsAfterRecovery() async throws {
        for fault in ["disabled", "unreadable"] {
            let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
            defer { fixture.cleanup() }
            let session = fixture.session
            let rows = session.validation.drafts
            let target = try XCTUnwrap(session.bypassDestinationID)
            if fault == "disabled" {
                try fixture.destination.preferences.save([ConfiguredBrowser(browser: fixture.destination.browser, isEnabled: false)])
                XCTAssertNil(try fixture.destination.repository.currentNormalDestination(for: target))
            } else {
                fixture.defaults.set(Data("corrupt browser bytes".utf8), forKey: BrowserPreferences.storageKey)
                XCTAssertThrowsError(try fixture.destination.repository.currentNormalDestination(for: target))
            }
            XCTAssertEqual(session.destinationIssue,
                           fault == "disabled" ? .bypassDestinationUnavailable : .browserConfigurationUnavailable)
            XCTAssertFalse(session.canSave)
            XCTAssertFalse(session.save())
            XCTAssertEqual(fixture.successfulWrites, 0)
            XCTAssertEqual(session.validation.drafts, rows)
            XCTAssertEqual(session.bypassDestinationID, target)

            // Repository's unreadable state requires its existing explicit recovery entry.
            // Only this isolated fixture is reset; the session never repairs data itself.
            if fault == "unreadable" {
                XCTAssertEqual(fixture.destination.repository.resetPreferences(), .applied)
                let rescanResult = await fixture.destination.repository.rescan().value
                XCTAssertEqual(rescanResult, .applied)
            } else {
                try fixture.destination.preferences.save([ConfiguredBrowser(browser: fixture.destination.browser, isEnabled: true)])
            }
            XCTAssertNotNil(try fixture.destination.repository.currentNormalDestination(for: target))
            XCTAssertNil(session.destinationIssue)
            XCTAssertTrue(session.canSave)
            XCTAssertNil(session.displayedIssue, "The same recovered target must not retain its previous failure")
            XCTAssertEqual(session.validation.drafts, rows)
            XCTAssertTrue(session.save())
            XCTAssertEqual(fixture.successfulWrites, 1)
        }
    }

    func testUnreadableRepositoryExplainsInitialMissingTargetWhenModeBecomesLimited() throws {
        let fixture = try ScopeSessionFixture(mode: .allDomains)
        defer { fixture.cleanup() }
        fixture.defaults.set(Data("unreadable browser settings".utf8), forKey: BrowserPreferences.storageKey)
        XCTAssertThrowsError(try fixture.destination.repository.currentNormalDestination(for: fixture.destination.destinationID))
        let session = ScopeEditorSession(
            store: fixture.store, editor: fixture.editor, browserRepository: fixture.destination.repository
        )
        defer { session.end() }
        let bytes = fixture.routingBytes
        XCTAssertEqual(session.mode, .allDomains)
        XCTAssertNil(session.bypassDestinationID)
        session.setMode(.onlyThese)

        guard case .destinationValidation(.browserConfigurationUnavailable)? = session.displayedIssue else {
            return XCTFail("An unreadable browser configuration must explain the missing destination")
        }
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.save())
        guard case .destinationValidation(.browserConfigurationUnavailable)? = session.displayedIssue else {
            return XCTFail("A direct save attempt must retain the current configuration explanation")
        }
        XCTAssertEqual(fixture.successfulWrites, 0)
        XCTAssertEqual(fixture.routingBytes, bytes)
    }

    func testDisplayedFieldAndTargetErrorsDisappearWhenTheirCurrentCauseIsRepaired() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        let bytes = fixture.routingBytes
        session.editHost(rowID: rowID, text: "foo/bar")
        XCTAssertFalse(session.save())
        guard case .editorValidation(.invalidDomains)? = session.displayedIssue else {
            return XCTFail("The invalid row must be explained before repair")
        }
        session.editHost(rowID: rowID, text: "repaired.example")
        XCTAssertNil(session.displayedIssue, "Repairing the row must not leave the previous field failure visible")
        XCTAssertTrue(session.canSave)

        let staleTarget = OpenDestinationID(browserID: "removed.browser", mode: .normal)
        session.selectBypassDestination(staleTarget)
        XCTAssertFalse(session.save())
        guard case .destinationValidation(.bypassDestinationUnavailable)? = session.displayedIssue else {
            return XCTFail("The failed target must be explained before replacement")
        }
        XCTAssertEqual(session.bypassDestinationID, staleTarget)
        session.selectBypassDestination(fixture.destination.destinationID)
        XCTAssertNil(session.displayedIssue, "Replacing a failed target must clear its previous failure")
        XCTAssertTrue(session.canSave)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.validation.drafts.first?.host, "repaired.example")
        XCTAssertEqual(fixture.successfulWrites, 0)
        XCTAssertEqual(fixture.routingBytes, bytes)
    }

    func testPersistentRoutingFailureRemainsVisibleAfterOrdinaryEditing() throws {
        let original = Data("unreadable routing settings".utf8)
        let fixture = try ScopeSessionFixture(corruptRoutingData: original)
        defer { fixture.cleanup() }
        let session = fixture.session
        XCTAssertFalse(session.save())
        guard case .routingConfigurationUnavailable? = session.displayedIssue else {
            return XCTFail("The real store refusal must be visible")
        }
        session.setMode(.onlyThese)
        session.selectBypassDestination(fixture.destination.destinationID)
        let rowID = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: rowID, text: "changed.example")
        session.setIncludesSubdomains(rowID: rowID, enabled: false)
        session.finishRowEditing(rowID: rowID)

        guard case .routingConfigurationUnavailable? = session.displayedIssue else {
            return XCTFail("Field editing must not dismiss an unresolved persistence failure")
        }
        guard case .routingConfigurationUnavailable? = session.saveFeedback else {
            return XCTFail("The persistence failure must remain semantic state")
        }
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.validation.invalidDraftIDs.isEmpty)
        XCTAssertEqual(fixture.routingBytes, original)
        XCTAssertEqual(fixture.successfulWrites, 0)
    }

    func testAllDomainsSaveIgnoresHiddenInvalidRowsAndUnavailableBypass() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        session.editHost(rowID: rowID, text: "foo/bar")
        session.selectBypassDestination(OpenDestinationID(browserID: "missing.browser", mode: .normal))
        fixture.defaults.set(Data("broken browser bytes".utf8), forKey: BrowserPreferences.storageKey)
        XCTAssertThrowsError(try fixture.destination.repository.currentNormalDestination(for: fixture.destination.destinationID))
        session.setMode(.allDomains)
        let validation = session.validation

        XCTAssertNil(session.destinationIssue)
        XCTAssertTrue(session.canSave)
        XCTAssertTrue(session.save())
        XCTAssertEqual(fixture.store.settings.scope, .allDomains)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), Data("broken browser bytes".utf8))
    }

    func testRealStoreRefusalPreservesBadBytesAndDraftUntilExplicitRetry() throws {
        let original = Data("{ original unreadable routing bytes }".utf8)
        let fixture = try ScopeSessionFixture(corruptRoutingData: original)
        defer { fixture.cleanup() }
        let session = fixture.session
        session.setMode(.onlyThese)
        session.selectBypassDestination(fixture.destination.destinationID)
        let rowID = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: rowID, text: "edited.example")
        session.finishRowEditing(rowID: rowID)
        let validation = session.validation

        XCTAssertFalse(session.save())
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isSaving)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(session.touchedRowIDs, [rowID])
        XCTAssertEqual(fixture.routingBytes, original)
        XCTAssertEqual(fixture.successfulWrites, 0)
        guard case .routingConfigurationUnavailable? = session.saveFeedback else {
            return XCTFail("The actual store's refusal must be visible")
        }
        let language = AppLanguageStore(userDefaults: fixture.defaults, systemPreferredLanguages: ["en-US"])
        let english = try XCTUnwrap(session.saveFeedback).text(using: language)
        language.select(.simplifiedChinese)
        let chinese = try XCTUnwrap(session.saveFeedback).text(using: language)
        XCTAssertNotEqual(english, chinese)
        XCTAssertEqual(session.validation, validation)

        // Explicit fixture recovery enables retry; Save never performs this reset.
        fixture.store.reset()
        let writesBeforeRetry = fixture.successfulWrites
        XCTAssertTrue(session.save())
        XCTAssertEqual(fixture.successfulWrites, writesBeforeRetry + 1)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.saveFeedback)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.defaults).settings.scope,
                       .onlyThese(matchers: [try matcher("edited.example")],
                                  bypassDestinationID: fixture.destination.destinationID))
    }

    func testSavePreservesLatestOtherFieldsAndReplacesOnlyScope() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("initial.example")], rules: [try matcher("initial-rule.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        session.editHost(rowID: rowID, text: "saved.example")
        session.setMode(.allExceptThese)
        try fixture.editor.setAlwaysShowChooser(true)
        try fixture.editor.saveRule(existingRuleID: nil, host: "latest-rule.example", includesSubdomains: false,
                                    destinationID: fixture.destination.destinationID)
        try fixture.editor.saveScope(.allDomains, browserRepository: fixture.destination.repository)
        let latestRules = fixture.store.settings.rules
        let writes = fixture.successfulWrites

        XCTAssertTrue(session.save())

        XCTAssertEqual(fixture.successfulWrites, writes + 1)
        let reloaded = RoutingPreferencesStore(userDefaults: fixture.defaults).settings
        XCTAssertEqual(reloaded.scope,
                       .allExceptThese(matchers: [try matcher("saved.example")],
                                       bypassDestinationID: fixture.destination.destinationID))
        XCTAssertEqual(reloaded.rules, latestRules)
        XCTAssertTrue(reloaded.alwaysShowChooser)
    }

    func testSaveGuardsReentryFromRepositoryAndStorePublicationAndEndsImmediately() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("scope.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rowID = try XCTUnwrap(session.validation.drafts.first?.id)
        let validation = session.validation
        var nestedResults: [Bool] = []
        var savingFlags: [Bool] = []
        let attemptReentry = {
            savingFlags.append(session.isSaving)
            nestedResults.append(session.save())
            session.editHost(rowID: rowID, text: "reentrant.example")
            session.setMode(.allDomains)
            session.selectBypassDestination(nil)
        }
        let repositorySubscription = fixture.destination.repository.objectWillChange.sink { attemptReentry() }
        let storeSubscription = fixture.store.objectWillChange.sink { attemptReentry() }
        defer { repositorySubscription.cancel(); storeSubscription.cancel() }

        XCTAssertTrue(session.save())

        XCTAssertFalse(nestedResults.isEmpty, "The real save path must actually exercise synchronous publications")
        XCTAssertTrue(nestedResults.allSatisfy { !$0 })
        XCTAssertTrue(savingFlags.allSatisfy { $0 })
        XCTAssertEqual(fixture.successfulWrites, 1)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isSaving)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(session.mode, .onlyThese)
        XCTAssertEqual(session.bypassDestinationID, fixture.destination.destinationID)
        XCTAssertFalse(session.save())
        session.end()
        session.end()
        XCTAssertEqual(fixture.successfulWrites, 1)
    }

    func testEndIsIdempotentAndFreezesEveryOldActionWithoutWriting() throws {
        let fixture = try ScopeSessionFixture(matchers: [try matcher("first.example"), try matcher("second.example")])
        defer { fixture.cleanup() }
        let session = fixture.session
        let rows = session.validation.drafts
        session.finishRowEditing(rowID: rows[0].id)
        session.removeDomain(rowID: rows[1].id)
        let feedbackID = try XCTUnwrap(session.feedback?.id)
        let pasteID = try XCTUnwrap(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "stale.example")
        session.end()
        let validation = session.validation
        let touched = session.touchedRowIDs
        let bytes = fixture.routingBytes

        session.setMode(.allDomains)
        session.selectBypassDestination(nil)
        XCTAssertNil(session.addDomain())
        session.editHost(rowID: rows[0].id, text: "late.example")
        session.setIncludesSubdomains(rowID: rows[0].id, enabled: false)
        session.finishRowEditing(rowID: rows[0].id)
        session.removeDomain(rowID: rows[0].id)
        session.clearDomains()
        session.undo(feedbackID: feedbackID)
        session.addAllRuleDomains()
        XCTAssertNil(session.beginPaste())
        session.editPasteText(pasteID: pasteID, text: "late-paste.example")
        session.setPasteIncludesSubdomains(pasteID: pasteID, enabled: false)
        XCTAssertFalse(session.confirmPaste(pasteID: pasteID))
        session.cancelPaste(pasteID: pasteID)
        XCTAssertFalse(session.save())
        session.end()

        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.canSave)
        XCTAssertEqual(session.validation, validation)
        XCTAssertEqual(session.touchedRowIDs, touched)
        XCTAssertEqual(session.mode, .onlyThese)
        XCTAssertEqual(session.bypassDestinationID, fixture.destination.destinationID)
        XCTAssertNil(session.feedback)
        XCTAssertNil(session.pasteDraft)
        XCTAssertEqual(fixture.routingBytes, bytes)
        XCTAssertEqual(fixture.successfulWrites, 0)
    }

    private func matcher(_ host: String, subdomains: Bool = true) throws -> DomainMatcher {
        try DomainMatcher(host: host, includesSubdomains: subdomains)
    }
}

/// Real preferences, editor and executable fixture bundle, never the host's settings.
@MainActor
final class ScopeSessionFixture {
    let defaults: UserDefaults
    let store: RoutingPreferencesStore
    let editor: RoutingSettingsEditor
    let destination: ScopeDestinationFixture
    let clock = ScopeSessionTestClock()
    let session: ScopeEditorSession
    private(set) var successfulWrites = 0
    private let removeDefaults: () -> Void
    private var writeSubscription: AnyCancellable?

    init(
        matchers: [DomainMatcher] = [],
        rules: [DomainMatcher] = [],
        mode: ScopeEditorKind = .onlyThese,
        corruptRoutingData: Data? = nil,
        resolvingMatcher: @escaping (ScopeMatcherDraft) throws -> DomainMatcher? = ScopeMatcherDraftLogic.matcher(for:)
    ) throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        self.defaults = defaults
        removeDefaults = cleanup
        do {
            destination = try ScopeDestinationFixture(userDefaults: defaults)
        } catch {
            cleanup()
            throw error
        }
        if let corruptRoutingData { defaults.set(corruptRoutingData, forKey: RoutingPreferencesStore.storageKey) }
        store = RoutingPreferencesStore(userDefaults: defaults)
        editor = RoutingSettingsEditor(store: store)
        do {
            if corruptRoutingData == nil {
                let scope: RoutingScope
                let destinationID = destination.destinationID
                switch mode {
                case .allDomains: scope = .allDomains
                case .onlyThese: scope = .onlyThese(matchers: matchers, bypassDestinationID: destinationID)
                case .allExceptThese: scope = .allExceptThese(matchers: matchers, bypassDestinationID: destinationID)
                }
                try store.replace(with: RoutingSettings(
                    scope: scope,
                    rules: rules.map { DomainRule(matcher: $0, destinationID: destinationID) },
                    alwaysShowChooser: false
                ))
            }
        } catch {
            destination.cleanup()
            cleanup()
            throw error
        }
        let clock = clock
        session = ScopeEditorSession(store: store, editor: editor, browserRepository: destination.repository,
                                     now: { clock.now }, resolvingMatcher: resolvingMatcher)
        writeSubscription = store.$settings.dropFirst().sink { [weak self] _ in self?.successfulWrites += 1 }
    }

    var routingBytes: Data? { defaults.data(forKey: RoutingPreferencesStore.storageKey) }

    func cleanup() {
        writeSubscription?.cancel()
        session.end()
        destination.cleanup()
        removeDefaults()
    }
}

@MainActor
final class ScopeSessionTestClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}
