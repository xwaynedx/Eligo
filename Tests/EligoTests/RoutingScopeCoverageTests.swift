import Foundation
import XCTest
@testable import Eligo

final class RoutingScopeCoverageTests: XCTestCase {
    private let bypass = OpenDestinationID(browserID: "test.bypass", mode: .normal)
    private let destination = OpenDestinationID(browserID: "test.rule", mode: .normal)

    func testCoverageTableAgreesWithBadgesAndRoutingPolicy() throws {
        let exact = try DomainMatcher(host: "example.com", includesSubdomains: false)
        let broad = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let child = try DomainMatcher(host: "sub.example.com", includesSubdomains: false)
        let childTree = try DomainMatcher(host: "sub.example.com", includesSubdomains: true)
        let other = try DomainMatcher(host: "notexample.com", includesSubdomains: true)
        let ip = try DomainMatcher(host: "127.0.0.1", includesSubdomains: false)
        // Literal expectations include both parent/child directions and same-host
        // flag combinations. Sample hosts all match the rule under examination.
        let cases: [(DomainMatcher, [DomainMatcher], RoutingScopeCoverage, RoutingScopeCoverage, [(String, Bool)])] = [
            (exact, [], .none, .full, [("example.com", false)]),
            (exact, [exact], .full, .none, [("example.com", true)]),
            (exact, [broad], .full, .none, [("example.com", true)]),
            (exact, [child], .none, .full, [("example.com", false)]),
            (exact, [childTree], .none, .full, [("example.com", false)]),
            (broad, [exact], .partial, .partial, [("example.com", true), ("www.example.com", false)]),
            (broad, [broad], .full, .none, [("example.com", true), ("www.example.com", true)]),
            (broad, [child], .partial, .partial, [("sub.example.com", true), ("a.sub.example.com", false)]),
            (broad, [childTree], .partial, .partial, [("a.sub.example.com", true), ("example.com", false)]),
            (child, [exact], .none, .full, [("sub.example.com", false)]),
            (child, [broad], .full, .none, [("sub.example.com", true)]),
            (child, [childTree], .full, .none, [("sub.example.com", true)]),
            (childTree, [child], .partial, .partial, [("sub.example.com", true), ("a.sub.example.com", false)]),
            (childTree, [broad], .full, .none, [("sub.example.com", true), ("a.sub.example.com", true)]),
            (broad, [other], .none, .full, [("example.com", false), ("www.example.com", false)]),
            (broad, [exact, childTree], .partial, .partial, [("example.com", true), ("www.example.com", false)]),
            (broad, [child, broad], .full, .none, [("sub.example.com", true), ("www.example.com", true)]),
            (ip, [ip], .full, .none, [("127.0.0.1", true)]),
            (ip, [broad], .none, .full, [("127.0.0.1", false)])
        ]
        for (ruleMatcher, scopeMatchers, onlyCoverage, exceptCoverage, samples) in cases {
            let scopes: [(RoutingScope, RoutingScopeCoverage, Bool)] = [
                (.allDomains, .full, false),
                (.onlyThese(matchers: scopeMatchers, bypassDestinationID: bypass), onlyCoverage, false),
                (.allExceptThese(matchers: scopeMatchers, bypassDestinationID: bypass), exceptCoverage, true)
            ]
            for (scope, expectedCoverage, isExclusion) in scopes {
                let coverage = scope.coverage(of: ruleMatcher)
                let context = "\(scope), rule=\(ruleMatcher)"
                XCTAssertEqual(coverage, expectedCoverage, context)
                XCTAssertEqual(scope.contains(ruleMatcher), expectedCoverage == .full, context)
                switch expectedCoverage {
                case .full: XCTAssertNil(coverage.badge, context)
                case .partial: XCTAssertEqual(coverage.badge?.title, "Partially active", context)
                case .none: XCTAssertEqual(coverage.badge?.title, "Inactive", context)
                }
                let settings = try RoutingSettings(
                    scope: scope, rules: [DomainRule(matcher: ruleMatcher, destinationID: destination)],
                    alwaysShowChooser: false
                )
                for (host, listed) in samples {
                    let inScope = scope == .allDomains || (isExclusion ? !listed : listed)
                    XCTAssertEqual(
                        RoutingPolicy().plan(for: URL(string: "https://\(host)")!, settings: settings),
                        .open(destinationID: inScope ? destination : bypass, reason: inScope ? .domainRule : .bypassed),
                        "\(context), host=\(host)"
                    )
                }
            }
        }
    }

    func testScopeCoverageDoesNotPromisePrecedenceOrDisableAlwaysShowChooser() throws {
        let broad = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let exact = try DomainMatcher(host: "sub.example.com", includesSubdomains: false)
        let scope = RoutingScope.onlyThese(matchers: [exact], bypassDestinationID: bypass)
        let rules = [DomainRule(matcher: broad, destinationID: destination), DomainRule(matcher: exact, destinationID: bypass)]
        let settings = try RoutingSettings(scope: scope, rules: rules, alwaysShowChooser: false)
        XCTAssertEqual(scope.coverage(of: broad), .partial)
        XCTAssertEqual(RoutingPolicy().plan(for: URL(string: "https://sub.example.com")!, settings: settings),
                       .open(destinationID: bypass, reason: .domainRule))
        let paused = try settings.replacing(alwaysShowChooser: true)
        XCTAssertEqual(RoutingPolicy().plan(for: URL(string: "https://sub.example.com")!, settings: paused),
                       .choose(reason: .alwaysShowChooser(base: .domainRule)))
        XCTAssertEqual(RoutingPolicy().plan(for: URL(string: "https://www.example.com")!, settings: paused),
                       .choose(reason: .alwaysShowChooser(base: .bypassed)))
        XCTAssertEqual(paused.scope.coverage(of: broad), .partial)
        for (english, chinese) in [
            ("Partially active", "部分生效"),
            ("Only some matching hosts are within Routing Scope. More specific rules and Always Show Chooser still apply.",
             "仅部分匹配的主机位于路由范围内。更具体的规则和始终显示选择器仍然适用。")
        ] {
            XCTAssertEqual(AppLanguageStore.localizedText(english, for: .english), english)
            XCTAssertEqual(AppLanguageStore.localizedText(english, for: .simplifiedChinese), chinese)
        }
    }

    func testExcludingOneHostLeavesTheBroadRulePartiallyActive() throws {
        let matcher = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let scope = RoutingScope.allExceptThese(
            matchers: [try DomainMatcher(host: "private.example.com", includesSubdomains: false)],
            bypassDestinationID: bypass
        )
        let coverage = scope.coverage(of: matcher)
        XCTAssertEqual(coverage, .partial)
        XCTAssertEqual(coverage.badge?.title, "Partially active")
        XCTAssertFalse(scope.contains(matcher), "Complete coverage remains a separate contract")

        let settings = try RoutingSettings(
            scope: scope, rules: [DomainRule(matcher: matcher, destinationID: destination)], alwaysShowChooser: false
        )
        XCTAssertEqual(RoutingPolicy().plan(for: URL(string: "https://www.example.com")!, settings: settings),
                       .open(destinationID: destination, reason: .domainRule))
        XCTAssertEqual(RoutingPolicy().plan(for: URL(string: "https://private.example.com")!, settings: settings),
                       .open(destinationID: bypass, reason: .bypassed))
    }
}
