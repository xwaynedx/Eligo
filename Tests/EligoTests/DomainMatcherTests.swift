import Foundation
import XCTest
@testable import Eligo

final class DomainMatcherTests: XCTestCase {
    func testEquivalentIPv6SpellingsHaveOneMatcherIdentity() throws {
        let groups: [(canonical: String, spellings: [String])] = [
            ("::1", ["::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001"]),
            ("::", ["::", "0:0:0:0:0:0:0:0"]),
            ("2001:db8::a:b", ["2001:DB8::000A:000b", "2001:0db8:0000:0:0:0:a:B"]),
            ("ff02::1", ["FF02:0:0:0:0:0:0:1", "ff02::0001"]),
            ("::ffff:192.0.2.1", ["::FFFF:192.0.2.1", "0:0:0:0:0:ffff:c000:0201"])
        ]
        for (canonical, spellings) in groups {
            let expected = try DomainMatcher(host: canonical, includesSubdomains: false)
            var identities = Set<DomainMatcher>()
            for spelling in spellings {
                for input in [spelling, "[\(spelling)]"] {
                    let matcher = try DomainMatcher(host: input, includesSubdomains: false)
                    XCTAssertEqual(matcher.normalizedHost, canonical, input)
                    XCTAssertEqual(matcher, expected, input)
                    XCTAssertTrue(matcher.isIPAddress, input)
                    XCTAssertTrue(expected.matches(host: input), input)
                    XCTAssertTrue(expected.covers(matcher), input)
                    XCTAssertEqual(try DomainMatcher.normalizedHost(from: matcher.normalizedHost), canonical)
                    let raw = try JSONSerialization.data(withJSONObject: [
                        "normalizedHost": input, "includesSubdomains": false
                    ])
                    XCTAssertEqual(try JSONDecoder().decode(DomainMatcher.self, from: raw), expected, input)
                    identities.insert(matcher)
                }
                let url = try XCTUnwrap(URL(string: "https://[\(spelling)]:8443/path"))
                XCTAssertEqual(DomainMatcher.normalizedHost(from: url), canonical, spelling)
            }
            XCTAssertEqual(identities, [expected])
        }
        XCTAssertEqual(Set(try groups.map { try DomainMatcher(host: $0.canonical, includesSubdomains: false) }).count,
                       groups.count)
    }

    func testIPv6CanonicalizationKeepsDifferentAddressesDistinct() throws {
        let hosts = ["::", "::1", "::2", "2001:db8::1", "2001:db8::2", "::ffff:192.0.2.1", "192.0.2.1"]
        let matchers = try hosts.map { try DomainMatcher(host: $0, includesSubdomains: false) }
        XCTAssertEqual(Set(matchers).count, hosts.count)
        for (index, matcher) in matchers.enumerated() {
            for (otherIndex, host) in hosts.enumerated() {
                XCTAssertEqual(matcher.matches(host: host), index == otherIndex, "\(matcher.normalizedHost) vs \(host)")
            }
        }
    }

    func testIPv6CanonicalizationDoesNotAcceptZonesMalformedAddressesOrSubdomains() throws {
        for input in ["2001:::1", "1:2:3:4:5:6:7:8:9", "2001:db8::gg", "::ffff:192.0.2.999",
                      "[::1", "::1]", "fe80::1%en0", "[fe80::1%25en0]"] {
            XCTAssertThrowsError(try DomainMatcher(host: input, includesSubdomains: false), input) {
                XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost)
            }
        }
        for input in ["::1", "0000:0000:0000:0000:0000:0000:0000:0001", "[2001:DB8::1]", "::ffff:c000:201"] {
            XCTAssertThrowsError(try DomainMatcher(host: input, includesSubdomains: true), input) {
                XCTAssertEqual($0 as? DomainMatcherValidationError, .ipAddressesCannotIncludeSubdomains)
            }
        }
    }

    func testContextualIDNJoinersAreValidatedByIDNAInsteadOfRejectedAsControls() throws {
        let cases = [
            ("نامه\u{200C}ای.ir", "xn--mgba3gch31f060k.ir"),
            ("क्\u{200D}ष.com", "xn--11b2ezcw70k.com")
        ]
        for (input, expected) in cases {
            let matcher = try DomainMatcher(host: input, includesSubdomains: false)
            XCTAssertEqual(matcher.normalizedHost, expected)
            XCTAssertEqual(try DomainMatcher(host: expected, includesSubdomains: false), matcher)
            XCTAssertEqual(try JSONDecoder().decode(DomainMatcher.self, from: JSONEncoder().encode(matcher)), matcher)
            let url = try XCTUnwrap(URL(string: "https://\(input)/path"))
            XCTAssertEqual(DomainMatcher.normalizedHost(from: url), expected)
            XCTAssertEqual(DomainListParser().parse(url.absoluteString, includesSubdomains: false).matchers, [matcher])
            XCTAssertEqual(try ScopeMatcherDraftLogic.matcher(for: ScopeMatcherDraft(host: input, includesSubdomains: false)), matcher)
        }
        for forbidden in ["example.com%00", "ex%09ample.com", "ex%0Aample.com", "ex%7Fample.com", "ex\u{202E}ample.com"] {
            XCTAssertThrowsError(try DomainMatcher(host: forbidden, includesSubdomains: false))
        }
    }

    func testCanonicalHostsAreIdempotentAndRoundTrip() throws {
        let cases = [
            ("example.com", "example.com"),
            ("example.com.", "example.com"),
            ("example.com。", "example.com"),
            ("EXAMPLE.COM．", "example.com"),
            ("example.com｡", "example.com"),
            ("example.com%2E", "example.com"),
            ("example.com%E3%80%82", "example.com"),
            ("BÜCHER.example。", "xn--bcher-kva.example"),
            ("xn--bcher-kva.example%2e", "xn--bcher-kva.example"),
            ("[2001:DB8::1]", "2001:db8::1")
        ]
        for (input, expected) in cases {
            let matcher = try DomainMatcher(host: input, includesSubdomains: false)
            XCTAssertEqual(matcher.normalizedHost, expected, input)
            XCTAssertEqual(try DomainMatcher.normalizedHost(from: matcher.normalizedHost), expected, input)
            XCTAssertEqual(try JSONDecoder().decode(DomainMatcher.self, from: JSONEncoder().encode(matcher)), matcher)
        }
    }

    func testInvalidHostsAreRejectedOnEveryAttemptIncludingAfterConversion() {
        let inputs = [
            "example.com..", "example.com...", "example.com。。", "example.com．｡",
            "example.com.%2e", "example.com%2e%2e", "example.com。.",
            "example.com%E3%80%82%2e", ".example.com", "。", "%2e",
            "user%40example.com", "example.com%2Fpath", "example.com%3Fquery",
            "example.com%23fragment", "example.com%3A8080", "example.com%00",
            "example.com%252e", "example.com%", "https://example.com", "example.com/path"
        ]
        for input in inputs {
            for _ in 0..<2 {
                XCTAssertThrowsError(try DomainMatcher(host: input, includesSubdomains: false), input) {
                    XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost, input)
                }
                let data = Data("{\"normalizedHost\":\"\(input)\",\"includesSubdomains\":false}".utf8)
                XCTAssertThrowsError(try JSONDecoder().decode(DomainMatcher.self, from: data), input) {
                    XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost, input)
                }
            }
        }
    }

    func testNormalizesHostsConsistently() throws {
        let cases = [
            (input: " Example.COM. ", expected: "example.com"),
            (input: "bücher.example", expected: "xn--bcher-kva.example"),
            (input: "xn--bcher-kva.example", expected: "xn--bcher-kva.example"),
            (input: "localhost.", expected: "localhost")
        ]

        for testCase in cases {
            XCTAssertEqual(
                try DomainMatcher.normalizedHost(from: testCase.input),
                testCase.expected,
                "Failed to normalize \(testCase.input)"
            )
        }
    }

    func testRejectsAmbiguousHostInput() {
        for input in ["", "https://example.com", "example.com/path", "example.com:8080", "user@example.com"] {
            XCTAssertThrowsError(try DomainMatcher.normalizedHost(from: input), "Expected \(input) to be rejected")
        }
    }

    func testMatchesExactAndDomainWithSubdomains() throws {
        let exact = try DomainMatcher(host: "www.example.com", includesSubdomains: false)
        let includingSubdomains = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let localhost = try DomainMatcher(host: "localhost", includesSubdomains: false)

        XCTAssertTrue(exact.matches(host: "www.example.com"))
        XCTAssertFalse(exact.matches(host: "example.com"))
        XCTAssertTrue(includingSubdomains.matches(host: "example.com"))
        XCTAssertTrue(includingSubdomains.matches(host: "docs.example.com"))
        XCTAssertFalse(includingSubdomains.matches(host: "notexample.com"))
        XCTAssertTrue(localhost.matches(host: "localhost"))
    }

    func testCoveragePreservesIncludesSubdomainsSemantics() throws {
        let exact = try DomainMatcher(host: "example.com", includesSubdomains: false)
        let includingSubdomains = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let nestedExact = try DomainMatcher(host: "sub.example.com", includesSubdomains: false)
        let nestedIncludingSubdomains = try DomainMatcher(
            host: "sub.example.com",
            includesSubdomains: true
        )

        XCTAssertTrue(exact.covers(exact))
        XCTAssertFalse(exact.covers(includingSubdomains))
        XCTAssertFalse(exact.covers(nestedExact))
        XCTAssertTrue(includingSubdomains.covers(exact))
        XCTAssertTrue(includingSubdomains.covers(nestedExact))
        XCTAssertTrue(includingSubdomains.covers(nestedIncludingSubdomains))
        XCTAssertFalse(nestedIncludingSubdomains.covers(includingSubdomains))
    }

    func testRoutingScopeCoverageUsesTheCompleteMatcher() throws {
        let exact = try DomainMatcher(host: "example.com", includesSubdomains: false)
        let includingSubdomains = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let nestedExact = try DomainMatcher(host: "sub.example.com", includesSubdomains: false)
        let exactScope = RoutingScope.onlyThese(
            matchers: [exact],
            bypassDestinationID: OpenDestinationID(browserID: "com.example.Browser", mode: .normal)
        )
        let broadScope = RoutingScope.onlyThese(
            matchers: [includingSubdomains],
            bypassDestinationID: OpenDestinationID(browserID: "com.example.Browser", mode: .normal)
        )
        let exceptNestedHost = RoutingScope.allExceptThese(
            matchers: [nestedExact],
            bypassDestinationID: OpenDestinationID(browserID: "com.example.Browser", mode: .normal)
        )

        XCTAssertTrue(exactScope.contains(exact))
        XCTAssertFalse(exactScope.contains(includingSubdomains))
        XCTAssertTrue(broadScope.contains(nestedExact))
        XCTAssertTrue(exceptNestedHost.contains(exact))
        XCTAssertFalse(exceptNestedHost.contains(includingSubdomains))
    }

    func testIPAddressMatchersAreExactOnly() throws {
        let ipv4 = try DomainMatcher(host: "127.0.0.1", includesSubdomains: false)
        let ipv6 = try DomainMatcher(host: "2001:db8::1", includesSubdomains: false)

        XCTAssertTrue(ipv4.matches(host: "127.0.0.1"))
        XCTAssertTrue(ipv6.matches(host: "2001:db8::1"))
        XCTAssertThrowsError(try DomainMatcher(host: "127.0.0.1", includesSubdomains: true))
        XCTAssertThrowsError(try DomainMatcher(host: "2001:db8::1", includesSubdomains: true))
    }

    func testShortIPv4SpellingKeepsCurrentNonIPHostClassification() throws {
        let matcher = try DomainMatcher(host: "127.1", includesSubdomains: false)
        let url = try XCTUnwrap(URL(string: "http://127.1:8080/path?query=1#fragment"))

        // Pin the current abbreviated-IPv4 compatibility boundary explicitly.
        XCTAssertEqual(matcher.normalizedHost, "127.1")
        XCTAssertFalse(matcher.isIPAddress)
        XCTAssertEqual(DomainMatcher.normalizedHost(from: url), "127.1")
    }

    func testMalformedIPAddressesRemainInvalidAcrossEditorInputs() {
        for host in ["256.0.0.1", "127.0.0.999", "999999999999999999999.0.0.1", "2001:::1", "[2001:db8::gg]"] {
            XCTAssertThrowsError(try DomainMatcher(host: host, includesSubdomains: false), host) {
                XCTAssertEqual($0 as? DomainMatcherValidationError, .invalidHost, host)
            }
            for input in [host, "https://\(host)/path"] {
                let parsed = DomainListParser().parse(input, includesSubdomains: true)
                XCTAssertTrue(parsed.matchers.isEmpty, input)
                XCTAssertEqual(parsed.invalidInputs, [input])
                XCTAssertEqual(DomainRuleFormValidation.validate(
                    host: input, includesSubdomains: false,
                    destinationID: OpenDestinationID(browserID: "test.rule", mode: .normal)
                ), .invalidDomain, input)
            }
        }
    }

    func testURLHostNormalizationIgnoresPorts() throws {
        let url = try XCTUnwrap(URL(string: "https://BÜCHER.example.:8443/path"))

        XCTAssertEqual(DomainMatcher.normalizedHost(from: url), "xn--bcher-kva.example")
    }

    func testDecodingRejectsIPSubdomainMatcher() {
        let data = Data(#"{"normalizedHost":"127.0.0.1","includesSubdomains":true}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(DomainMatcher.self, from: data))
    }
}
