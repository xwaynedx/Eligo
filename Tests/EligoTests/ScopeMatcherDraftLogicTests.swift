import XCTest
@testable import Eligo

final class ScopeMatcherDraftLogicTests: XCTestCase {
    func testValidationResolvesEachRowOnceAndReadsDoNotResolveAgain() {
        for count in [100, 300, 1_000] {
            let drafts = (0..<count).map {
                ScopeMatcherDraft(host: "host\($0).example.com", includesSubdomains: true)
            }
            var resolutionCount = 0
            let validation = ScopeMatcherDraftLogic.validation(for: drafts) { draft in
                resolutionCount += 1
                return try ScopeMatcherDraftLogic.matcher(for: draft)
            }
            XCTAssertEqual(resolutionCount, count)

            for _ in 0..<10 {
                XCTAssertTrue(validation.invalidDraftIDs.isEmpty)
                for draft in drafts {
                    XCTAssertNil(validation.issue(for: draft.id))
                    XCTAssertTrue(validation.supportsSubdomains(for: draft.id))
                }
                XCTAssertEqual(validation.validatedMatchers(for: drafts)?.count, count)
            }
            XCTAssertEqual(resolutionCount, count, "Consumers must reuse the snapshot")
        }
    }

    // MARK: - validation(for:)

    func testValidationSnapshotCoversEveryDraftContract() throws {
        let empty = ScopeMatcherDraft(host: "   ", includesSubdomains: true)
        let invalid = ScopeMatcherDraft(host: "foo/bar", includesSubdomains: true)
        let duplicateA = ScopeMatcherDraft(host: "Example.com.", includesSubdomains: true)
        let duplicateB = ScopeMatcherDraft(
            host: "https://example.com/path",
            includesSubdomains: true
        )
        let sameHostDifferentFlag = ScopeMatcherDraft(
            host: "example.com",
            includesSubdomains: false
        )
        let unique = ScopeMatcherDraft(host: "unique.example", includesSubdomains: false)
        let drafts = [empty, invalid, duplicateA, duplicateB, sameHostDifferentFlag, unique]

        let validation = ScopeMatcherDraftLogic.validation(for: drafts)

        XCTAssertNil(validation.issue(for: empty.id))
        XCTAssertEqual(validation.issue(for: invalid.id), .invalidHost)
        XCTAssertEqual(validation.issue(for: duplicateA.id), .duplicate)
        XCTAssertEqual(validation.issue(for: duplicateB.id), .duplicate)
        XCTAssertNil(validation.issue(for: sameHostDifferentFlag.id))
        XCTAssertNil(validation.issue(for: unique.id))
        XCTAssertEqual(validation.invalidDraftIDs, [invalid.id, duplicateA.id, duplicateB.id])
        XCTAssertNil(validation.validatedMatchers(for: drafts))
    }

    func testValidationRefreshesAfterBatchAppendAndRemoval() throws {
        let existing = ScopeMatcherDraft(host: "existing.example", includesSubdomains: false)
        let duplicate = try DomainMatcher(host: "existing.example", includesSubdomains: false)
        let added = try DomainMatcher(host: "added.example", includesSubdomains: true)

        let append = ScopeMatcherDraftLogic.validation(for: [existing]).appending([duplicate, added])
        let appendedValidation = ScopeMatcherDraftLogic.validation(for: append.drafts)

        XCTAssertTrue(appendedValidation.invalidDraftIDs.isEmpty)
        XCTAssertEqual(appendedValidation.validatedMatchers(for: append.drafts), [duplicate, added])

        let remaining = Array(append.drafts.dropFirst())
        let removedValidation = ScopeMatcherDraftLogic.validation(for: remaining)

        XCTAssertTrue(removedValidation.invalidDraftIDs.isEmpty)
        XCTAssertEqual(removedValidation.validatedMatchers(for: remaining), [added])
    }

    func testValidationSnapshotCannotApproveNewerInvalidInput() throws {
        let original = [ScopeMatcherDraft(host: "example.com", includesSubdomains: true)]
        let originalMatcher = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let originalValidation = ScopeMatcherDraftLogic.validation(for: original)
        XCTAssertEqual(originalValidation.validatedMatchers(for: original), [originalMatcher])

        var edited = original
        edited[0].host = "foo/bar"

        XCTAssertNil(originalValidation.validatedMatchers(for: edited))
        XCTAssertNil(ScopeMatcherDraftLogic.validation(for: edited).validatedMatchers(for: edited))
    }

    // MARK: - normalizedHostInput

    func testNormalizedHostInputTrimsAndLowercasesBareHosts() {
        XCTAssertEqual(ScopeMatcherDraftLogic.normalizedHostInput("  Example.COM  "), "example.com")
        XCTAssertEqual(ScopeMatcherDraftLogic.normalizedHostInput("example.com."), "example.com")
    }

    func testNormalizedHostInputExtractsHostFromURL() {
        XCTAssertEqual(
            ScopeMatcherDraftLogic.normalizedHostInput("https://Example.com/some/path?query=1"),
            "example.com"
        )
    }

    func testNormalizedHostInputRejectsUnusableInput() {
        XCTAssertNil(ScopeMatcherDraftLogic.normalizedHostInput("foo/bar"))
        XCTAssertNil(ScopeMatcherDraftLogic.normalizedHostInput("not a host"))
        XCTAssertNil(ScopeMatcherDraftLogic.normalizedHostInput(""))
    }

    // MARK: - Snapshot issues

    func testIssueIsNilForEmptyDraft() {
        let drafts = [ScopeMatcherDraft(host: "", includesSubdomains: true)]
        XCTAssertNil(issue(for: drafts[0], in: drafts))
    }

    func testIssueIsNilForValidUniqueDraft() throws {
        let drafts = [ScopeMatcherDraft(host: "example.com", includesSubdomains: true)]
        XCTAssertNil(issue(for: drafts[0], in: drafts))
    }

    func testIssueIsInvalidHostForMalformedDraft() {
        let drafts = [ScopeMatcherDraft(host: "foo/bar", includesSubdomains: true)]
        XCTAssertEqual(issue(for: drafts[0], in: drafts), .invalidHost)
    }

    func testIssueExplainsIPAddressWithSubdomainsAndClearsWhenUnchecked() {
        let drafts = [ScopeMatcherDraft(host: "192.168.0.1", includesSubdomains: true)]
        XCTAssertEqual(issue(for: drafts[0], in: drafts), .ipAddressesCannotIncludeSubdomains)
        let precise = ScopeMatcherDraft(host: drafts[0].host, includesSubdomains: false)
        XCTAssertNil(issue(for: precise, in: [precise]))
    }

    func testIssueIsDuplicateForSameHostAndSubdomainFlag() {
        let first = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let second = ScopeMatcherDraft(host: "https://example.com/path", includesSubdomains: true)
        let drafts = [first, second]

        let validation = ScopeMatcherDraftLogic.validation(for: drafts)
        XCTAssertEqual(validation.issue(for: second.id), .duplicate)
        XCTAssertEqual(validation.issue(for: first.id), .duplicate)
    }

    func testIssueIsNilWhenSubdomainFlagDiffers() {
        let first = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let second = ScopeMatcherDraft(host: "example.com", includesSubdomains: false)

        XCTAssertNil(issue(for: second, in: [first, second]))
    }

    func testIssueIgnoresInvalidRowsWhenCheckingDuplicates() {
        let valid = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let invalid = ScopeMatcherDraft(host: "example.com/path", includesSubdomains: true)

        let validation = ScopeMatcherDraftLogic.validation(for: [valid, invalid])
        XCTAssertNil(validation.issue(for: valid.id))
        XCTAssertEqual(validation.issue(for: invalid.id), .invalidHost)
    }

    func testInvalidDraftIDsCollectsEveryProblemRow() {
        let invalid = ScopeMatcherDraft(host: "foo/bar", includesSubdomains: true)
        let duplicateA = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let duplicateB = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let fine = ScopeMatcherDraft(host: "fine.com", includesSubdomains: false)
        let empty = ScopeMatcherDraft(host: "", includesSubdomains: true)
        let drafts = [invalid, duplicateA, duplicateB, fine, empty]

        XCTAssertEqual(
            ScopeMatcherDraftLogic.validation(for: drafts).invalidDraftIDs,
            [invalid.id, duplicateA.id, duplicateB.id]
        )
    }

    // MARK: - appending(_:to:)

    func testAppendingPreservesExistingRowsIncludingInvalidAndEmptyOnes() throws {
        let invalid = ScopeMatcherDraft(host: "foo/bar", includesSubdomains: false)
        let empty = ScopeMatcherDraft(host: "", includesSubdomains: true)
        let existing = [invalid, empty]
        let addition = try DomainMatcher(host: "added.com", includesSubdomains: true)

        let result = ScopeMatcherDraftLogic.validation(for: existing).appending([addition])

        XCTAssertEqual(result.drafts.count, 3)
        XCTAssertEqual(result.drafts[0], invalid)
        XCTAssertEqual(result.drafts[1], empty)
        XCTAssertEqual(result.drafts[2].host, addition.normalizedHost)
        XCTAssertEqual(result.drafts[2].includesSubdomains, addition.includesSubdomains)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.skippedDuplicateCount, 0)
    }

    func testAppendingSkipsDuplicatesAgainstExistingValidRows() throws {
        let existingDraft = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let duplicate = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let distinctFlag = try DomainMatcher(host: "example.com", includesSubdomains: false)

        let result = ScopeMatcherDraftLogic.validation(for: [existingDraft]).appending([duplicate, distinctFlag])

        XCTAssertEqual(result.drafts.count, 2)
        XCTAssertEqual(result.drafts[0], existingDraft)
        XCTAssertEqual(result.drafts[1].host, distinctFlag.normalizedHost)
        XCTAssertEqual(result.drafts[1].includesSubdomains, distinctFlag.includesSubdomains)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.skippedDuplicateCount, 1)
    }

    func testAppendingSkipsDuplicatesWithinAdditions() throws {
        let matcher = try DomainMatcher(host: "example.com", includesSubdomains: true)

        let result = ScopeMatcherDraftLogic.validation(for: []).appending([matcher, matcher])

        XCTAssertEqual(result.drafts.count, 1)
        XCTAssertEqual(result.drafts[0].host, matcher.normalizedHost)
        XCTAssertEqual(result.drafts[0].includesSubdomains, matcher.includesSubdomains)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.skippedDuplicateCount, 1)
    }

    func testAppendingKeepsDraftIDsAndFocusStableForExistingRows() throws {
        let editing = ScopeMatcherDraft(host: "partial-typing", includesSubdomains: true)
        let addition = try DomainMatcher(host: "added.com", includesSubdomains: false)

        let result = ScopeMatcherDraftLogic.validation(for: [editing]).appending([addition])

        XCTAssertEqual(result.drafts.first?.id, editing.id)
        XCTAssertEqual(result.drafts.first?.host, "partial-typing")
    }

    // MARK: - validatedMatchers(for:)

    func testSaveableMatchersDropsEmptyRowsAndNormalizes() throws {
        let empty = ScopeMatcherDraft(host: "", includesSubdomains: true)
        let whitespace = ScopeMatcherDraft(host: "   ", includesSubdomains: false)
        let url = ScopeMatcherDraft(host: "https://Example.com/path", includesSubdomains: true)
        let expected = try DomainMatcher(host: "example.com", includesSubdomains: true)

        let drafts = [empty, whitespace, url]
        let validation = ScopeMatcherDraftLogic.validation(for: drafts)
        XCTAssertEqual(validation.validatedMatchers(for: drafts), [expected])
    }

    private func issue(
        for draft: ScopeMatcherDraft,
        in drafts: [ScopeMatcherDraft]
    ) -> ScopeMatcherDraftIssue? {
        ScopeMatcherDraftLogic.validation(for: drafts).issue(for: draft.id)
    }
}
