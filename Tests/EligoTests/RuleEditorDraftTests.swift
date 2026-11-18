import XCTest
@testable import Eligo

final class RuleEditorDraftTests: XCTestCase {
    func testCanonicalizingAResidualInvalidDraftDoesNotSilentlyRepairItsSubdomainFlag() throws {
        let destination = OpenDestinationID(browserID: "test.rule", mode: .normal)
        let draft = RuleEditorDraft(destinationID: destination, host: "[::1]", includesSubdomains: true)
        XCTAssertEqual(DomainRuleFormValidation.validate(
            host: draft.host, includesSubdomains: draft.includesSubdomains, destinationID: destination
        ), .ipAddressesCannotIncludeSubdomains)
        let submission = draft.normalizedForSaving()
        XCTAssertEqual(submission.host, "::1")
        XCTAssertTrue(submission.includesSubdomains, "Normalization must preserve the explicit submission for model validation")
        XCTAssertThrowsError(try DomainRuleSavePreflight.plan(
            settings: .default, existingRuleID: nil, host: submission.host,
            includesSubdomains: submission.includesSubdomains, destinationID: destination
        )) {
            XCTAssertEqual($0 as? DomainMatcherValidationError, .ipAddressesCannotIncludeSubdomains)
        }
    }

    func testEditingADNSRuleToIPAddressClearsSubdomainsWithoutChangingTheSavedRule() throws {
        let destination = OpenDestinationID(browserID: "test.rule", mode: .normal)
        let rule = DomainRule(
            matcher: try DomainMatcher(host: "example.com", includesSubdomains: true), destinationID: destination
        )
        for input in ["127.0.0.1", "2001:db8::1", "[2001:DB8::1]", "https://127.0.0.1:8080/path", "https://[::1]/path"] {
            var draft = RuleEditorDraft(rule: rule)
            draft.host = input
            XCTAssertFalse(draft.includesSubdomains, input)
            XCTAssertFalse(draft.supportsSubdomains, input)
            XCTAssertEqual(DomainRuleFormValidation.validate(
                host: draft.host, includesSubdomains: draft.includesSubdomains, destinationID: draft.destinationID
            ), .valid, input)
            let submission = draft.normalizedForSaving()
            let planned = try DomainRuleSavePreflight.plan(
                settings: try RoutingSettings(scope: .allDomains, rules: [rule], alwaysShowChooser: false),
                existingRuleID: submission.existingRuleID, host: submission.host,
                includesSubdomains: submission.includesSubdomains, destinationID: submission.destinationID
            )
            XCTAssertTrue(planned.matcher.isIPAddress, input)
            XCTAssertFalse(planned.matcher.includesSubdomains, input)
            draft.host = "other.example"
            XCTAssertFalse(draft.includesSubdomains, "IP to DNS must retain the user's unchecked state")
            XCTAssertTrue(draft.supportsSubdomains)
            XCTAssertEqual(draft.existingRuleID, rule.id)
            XCTAssertEqual(draft.destinationID, destination)
        }
        XCTAssertEqual(rule.matcher.normalizedHost, "example.com")
        XCTAssertTrue(rule.matcher.includesSubdomains)
    }
}
