import Foundation
import XCTest
@testable import Eligo

final class RoutingPolicyTests: XCTestCase {
    func testChooserHintFollowsScopeBeforeDomainRuleAndRequiresOverride() throws {
        let policy = RoutingPolicy()
        let url = URL(string: "https://docs.example.com/path")!
        let rule = DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: true), destinationID: privateDestination)
        let settings = try RoutingSettings(scope: .allDomains, rules: [rule], alwaysShowChooser: true)
        XCTAssertEqual(policy.chooserHint(for: url, settings: settings), .domainRule(privateDestination, domain: "example.com"))
        let exactRule = DomainRule(matcher: try DomainMatcher(host: "docs.example.com", includesSubdomains: false), destinationID: normalDestination)
        let overlapping = try settings.replacing(rules: [rule, exactRule])
        XCTAssertEqual(policy.chooserHint(for: url, settings: overlapping), .domainRule(normalDestination, domain: "docs.example.com"))
        XCTAssertNil(policy.chooserHint(for: url, settings: try settings.replacing(alwaysShowChooser: false)))
        let bypass = try RoutingSettings(scope: .onlyThese(matchers: [], bypassDestinationID: normalDestination), rules: [rule], alwaysShowChooser: true)
        XCTAssertEqual(policy.chooserHint(for: url, settings: bypass), .bypass(normalDestination))
        XCTAssertNil(policy.chooserHint(for: URL(fileURLWithPath: "/tmp/test.html"), settings: settings))
        XCTAssertNil(policy.chooserHint(for: URL(string: "https://unmatched.test")!, settings: settings))
    }

    private let normalDestination = OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
    private let privateDestination = OpenDestinationID(browserID: "com.google.Chrome", mode: .privateBrowsing)

    func testEquivalentIPv6URLsPreserveRuleScopeAndOverridePrecedence() throws {
        let matcher = try DomainMatcher(host: "::1", includesSubdomains: false)
        let rule = DomainRule(matcher: matcher, destinationID: privateDestination)
        let outside = try XCTUnwrap(URL(string: "http://[::2]/"))
        let scopes: [(scope: RoutingScope, destination: OpenDestinationID, reason: RoutingReason, outsidePlan: RoutingPlan)] = [
            (.onlyThese(matchers: [matcher], bypassDestinationID: normalDestination),
             privateDestination, .domainRule,
             .open(destinationID: normalDestination, reason: .bypassed)),
            (.allDomains, privateDestination, .domainRule,
             .choose(reason: .noMatchingRule)),
            (.allExceptThese(matchers: [matcher], bypassDestinationID: normalDestination),
             normalDestination, .bypassed,
             .choose(reason: .noMatchingRule))
        ]
        let policy = RoutingPolicy()
        for (scope, destination, reason, outsidePlan) in scopes {
            let settings = try RoutingSettings(scope: scope, rules: [rule], alwaysShowChooser: false)
            XCTAssertEqual(policy.plan(for: outside, settings: settings), outsidePlan)
            for host in ["::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001"] {
                let url = try XCTUnwrap(URL(string: "http://[\(host)]/"))
                XCTAssertEqual(policy.plan(for: url, settings: settings), .open(destinationID: destination, reason: reason))
                XCTAssertEqual(policy.plan(for: url, settings: try settings.replacing(alwaysShowChooser: true)),
                               .choose(reason: .alwaysShowChooser(base: reason)))
            }
        }
    }

    func testDefaultSettingsChoose() throws {
        let plan = RoutingPolicy().plan(
            for: URL(string: "https://example.com")!,
            settings: .default
        )

        XCTAssertEqual(plan, .choose(reason: .noMatchingRule))
    }

    func testLocalFileAndMissingHostChoose() throws {
        let policy = RoutingPolicy()

        XCTAssertEqual(
            policy.plan(for: URL(fileURLWithPath: "/tmp/page.html"), settings: .default),
            .choose(reason: .localFile)
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "about:blank")!, settings: .default),
            .choose(reason: .missingHost)
        )
    }

    func testRulesOpenTheirConfiguredDestinations() throws {
        let normalRule = DomainRule(
            matcher: try DomainMatcher(host: "normal.example.com", includesSubdomains: false),
            destinationID: normalDestination
        )
        let privateRule = DomainRule(
            matcher: try DomainMatcher(host: "private.example.com", includesSubdomains: false),
            destinationID: privateDestination
        )
        let settings = try RoutingSettings(
            scope: .allDomains,
            rules: [normalRule, privateRule],
            alwaysShowChooser: false
        )
        let cases: [(url: URL, expected: RoutingPlan)] = [
            (
                URL(string: "https://normal.example.com")!,
                .open(destinationID: normalDestination, reason: .domainRule)
            ),
            (
                URL(string: "https://private.example.com")!,
                .open(destinationID: privateDestination, reason: .domainRule)
            )
        ]

        for testCase in cases {
            XCTAssertEqual(RoutingPolicy().plan(for: testCase.url, settings: settings), testCase.expected)
        }
    }

    func testExactAndLongestSubdomainRulesTakePrecedence() throws {
        let broad = DomainRule(
            matcher: try DomainMatcher(host: "example.com", includesSubdomains: true),
            destinationID: normalDestination
        )
        let narrower = DomainRule(
            matcher: try DomainMatcher(host: "team.example.com", includesSubdomains: true),
            destinationID: privateDestination
        )
        let exact = DomainRule(
            matcher: try DomainMatcher(host: "a.team.example.com", includesSubdomains: false),
            destinationID: normalDestination
        )
        let settings = try RoutingSettings(scope: .allDomains, rules: [broad, narrower, exact], alwaysShowChooser: false)
        let policy = RoutingPolicy()

        XCTAssertEqual(
            policy.plan(for: URL(string: "https://b.team.example.com")!, settings: settings),
            .open(destinationID: privateDestination, reason: .domainRule)
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://a.team.example.com")!, settings: settings),
            .open(destinationID: normalDestination, reason: .domainRule)
        )
    }

    func testOnlyTheseAndAllExceptTheseBypassOutsideScope() throws {
        let scopedMatcher = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let rule = DomainRule(
            matcher: try DomainMatcher(host: "inside.example.com", includesSubdomains: false),
            destinationID: privateDestination
        )
        let policy = RoutingPolicy()

        let onlyThese = try RoutingSettings(
            scope: .onlyThese(matchers: [scopedMatcher], bypassDestinationID: normalDestination),
            rules: [rule],
            alwaysShowChooser: false
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://inside.example.com")!, settings: onlyThese),
            .open(destinationID: privateDestination, reason: .domainRule)
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://outside.example.net")!, settings: onlyThese),
            .open(destinationID: normalDestination, reason: .bypassed)
        )

        let allExceptThese = try RoutingSettings(
            scope: .allExceptThese(
                matchers: [try DomainMatcher(host: "excluded.example.com", includesSubdomains: true)],
                bypassDestinationID: normalDestination
            ),
            rules: [rule],
            alwaysShowChooser: false
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://excluded.example.com")!, settings: allExceptThese),
            .open(destinationID: normalDestination, reason: .bypassed)
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://inside.example.com")!, settings: allExceptThese),
            .open(destinationID: privateDestination, reason: .domainRule)
        )
    }

    func testAlwaysShowChooserConvertsRuleAndBypassedPlansWithoutASelectionHint() throws {
        let rule = DomainRule(
            matcher: try DomainMatcher(host: "example.com", includesSubdomains: false),
            destinationID: privateDestination
        )
        let automaticSettings = try RoutingSettings(scope: .allDomains, rules: [rule], alwaysShowChooser: true)
        let policy = RoutingPolicy()

        XCTAssertEqual(
            policy.plan(for: URL(string: "https://example.com")!, settings: automaticSettings),
            .choose(reason: .alwaysShowChooser(base: .domainRule))
        )

        let bypassSettings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [try DomainMatcher(host: "inside.example.com", includesSubdomains: false)],
                bypassDestinationID: normalDestination
            ),
            rules: [],
            alwaysShowChooser: true
        )
        XCTAssertEqual(
            policy.plan(for: URL(string: "https://outside.example.com")!, settings: bypassSettings),
            .choose(reason: .alwaysShowChooser(base: .bypassed))
        )
    }

    func testLimitedScopeInsideWithoutARuleChoosesNormally() throws {
        let settings = try RoutingSettings(
            scope: .onlyThese(
                matchers: [try DomainMatcher(host: "example.com", includesSubdomains: true)],
                bypassDestinationID: normalDestination
            ),
            rules: [],
            alwaysShowChooser: false
        )

        XCTAssertEqual(
            RoutingPolicy().plan(for: URL(string: "https://inside.example.com")!, settings: settings),
            .choose(reason: .noMatchingRule)
        )
    }

    func testSettingsRejectPrivateBypassDestinationAndDuplicateRuleMatchers() throws {
        XCTAssertThrowsError(
            try RoutingSettings(
                scope: .onlyThese(
                    matchers: [try DomainMatcher(host: "example.com", includesSubdomains: false)],
                    bypassDestinationID: privateDestination
                ),
                rules: [],
                alwaysShowChooser: false
            )
        )

        let matcher = try DomainMatcher(host: "example.com", includesSubdomains: false)
        let first = DomainRule(matcher: matcher, destinationID: normalDestination)
        let duplicate = DomainRule(matcher: matcher, destinationID: privateDestination)
        XCTAssertThrowsError(
            try RoutingSettings(scope: .allDomains, rules: [first, duplicate], alwaysShowChooser: false)
        )
    }
}
