import XCTest
@testable import Eligo

final class DomainListParserTests: XCTestCase {
    func testBulkHostDisplayIdentitiesAreUniqueAndStableAcrossSubdomainChanges() {
        let input = "https://BÜCHER.example./path xn--bcher-kva.example a.example A.EXAMPLE. 127.0.0.1 http://127.0.0.1/ [::1] 0:0:0:0:0:0:0:1 bad/path"
        let exact = DomainListParser().parse(input, includesSubdomains: false)
        let subdomains = DomainListParser().parse(input, includesSubdomains: true)
        let hosts = ["xn--bcher-kva.example", "a.example", "127.0.0.1", "::1"]
        for result in [exact, subdomains] {
            XCTAssertEqual(result.matchers.map(\.normalizedHost), hosts)
            XCTAssertEqual(Set(result.matchers.map(\.normalizedHost)).count, result.matchers.count)
            XCTAssertEqual(result.invalidInputs, ["bad/path"])
            XCTAssertEqual(result.duplicateInputs, ["xn--bcher-kva.example", "A.EXAMPLE.", "http://127.0.0.1/", "0:0:0:0:0:0:0:1"])
        }
        XCTAssertEqual(exact.matchers.map(\.includesSubdomains), [false, false, false, false])
        XCTAssertEqual(subdomains.matchers.map(\.includesSubdomains), [true, true, false, false])
        XCTAssertNotEqual(exact.matchers, subdomains.matchers, "Display identity must not replace complete business identity")
    }

    func testAcceptedBulkURLDecisionTable() {
        let cases: [(String, [String])] = [
            ("a.example,b.example;c.example", ["a.example", "b.example", "c.example"]),
            ("https://a.example,https://b.example", ["a.example", "b.example"]),
            ("https://a.example, https://b.example", ["a.example", "b.example"]),
            ("https://a.example/x,https://b.example", ["a.example", "b.example"]),
            ("https://a.example/x,b.example", ["a.example"]),
            ("https://a.example/?q=one;two#x,y", ["a.example"]),
            ("https://a.example/?next=https://b.example&tag=x,y", ["a.example"]),
            ("https://a.example https://b.example", ["a.example", "b.example"]),
            ("https://a.example\nhttps://b.example", ["a.example", "b.example"]),
            ("http://a.example;HTTPS://b.example;", ["a.example", "b.example"]),
            ("a.example;https://b.example, c.example", ["a.example", "b.example", "c.example"])
        ]
        for (input, hosts) in cases {
            let result = DomainListParser().parse(input, includesSubdomains: true)
            XCTAssertEqual(result.matchers.map(\.normalizedHost), hosts, input)
            XCTAssertTrue(result.matchers.allSatisfy(\.includesSubdomains), input)
            XCTAssertEqual(result.invalidInputs, [], input)
            XCTAssertEqual(result.duplicateInputs, [], input)
        }
    }

    func testSchemeBoundariesInsideURLsRemainVisibleAsAcceptedAdditionalEntries() {
        for suffix in ["/path,https://b.example", "/?next=one;http://b.example", "/#one,https://b.example"] {
            let result = DomainListParser().parse("https://a.example" + suffix, includesSubdomains: false)
            XCTAssertEqual(result.matchers.map(\.normalizedHost), ["a.example", "b.example"], suffix)
            XCTAssertEqual(result.invalidInputs, [], suffix)
        }
    }

    func testEncodedURLSeparatorsPortsAndTrailingDotsKeepCanonicalOrderAndDuplicates() {
        let input = "b.example;a.example;https://B.example.:443/p%2Cpart%3Bmore,HTTPS://c.example:65535/x;http://d.example:0?q=x%2Cy%3Bz\nhttps://a.example./#x%2Cy%3Bz"
        let result = DomainListParser().parse(input, includesSubdomains: false)
        XCTAssertEqual(result.matchers.map(\.normalizedHost), ["b.example", "a.example", "c.example", "d.example"])
        XCTAssertEqual(result.duplicateInputs, [
            "https://B.example.:443/p%2Cpart%3Bmore", "https://a.example./#x%2Cy%3Bz"
        ])
        XCTAssertEqual(result.invalidInputs, [])
        for input in ["https://a.example/x%2Chttps://b.example", "https://a.example/?x=%3Bhttps://b.example", "https://a.example/#x%2Chttps://b.example"] {
            XCTAssertEqual(DomainListParser().parse(input, includesSubdomains: false).matchers.map(\.normalizedHost), ["a.example"], input)
        }
    }

    func testBareIPv6ListsAndURLIPEntriesRetainExactMatching() {
        let bareList = DomainListParser().parse("abcd:1::1,b.example", includesSubdomains: true)
        XCTAssertEqual(bareList.matchers.map(\.normalizedHost), ["abcd:1::1", "b.example"])
        XCTAssertEqual(bareList.matchers.map(\.includesSubdomains), [false, true])
        XCTAssertEqual(bareList.invalidInputs, [])
        let result = DomainListParser().parse("abcd:1::1,127.0.0.1;https://[2001:DB8::1]:8080/path;http://bücher.example./路径", includesSubdomains: true)
        XCTAssertEqual(result.matchers.map(\.normalizedHost), ["abcd:1::1", "127.0.0.1", "2001:db8::1", "xn--bcher-kva.example"])
        XCTAssertEqual(result.matchers.map(\.includesSubdomains), [false, false, false, true])
        XCTAssertEqual(result.invalidInputs, [])
    }

    func testStripsAtMostOneTrailingURLSeparator() {
        let result = DomainListParser().parse("https://a.example, https://b.example; https://c.example,, https://d.example;;", includesSubdomains: false)
        XCTAssertEqual(result.matchers.map(\.normalizedHost), ["a.example", "b.example"])
        XCTAssertEqual(result.invalidInputs, ["https://c.example,", "https://d.example;"])
    }

    func testURLPathQueryAndFragmentSeparatorsDoNotCreateDomainEntries() {
        for input in [
            "https://example.com/path,cdn.example.net",
            "https://example.com/path;cdn.example.net",
            "https://example.com/?q=one;two#x,y",
            "https://example.com/?next=https://other.example&tag=x,y",
            "https://example.com/#one;two.example,three.example"
        ] {
            let result = DomainListParser().parse(input, includesSubdomains: false)
            XCTAssertEqual(result.matchers.map(\.normalizedHost), ["example.com"], input)
            XCTAssertEqual(result.invalidInputs, [], input)
            XCTAssertEqual(result.duplicateInputs, [], input)
        }
    }

    func testInvalidURLPiecesAreRejectedWithoutSalvagingDomainFragments() {
        for input in [
            "https://user:password@a.example/path,b.example",
            "https://user@a.example/path;b.example",
            "https:///a.example,b.example",
            "https://[not-an-ip]/path,b.example",
            "https://a.example:bad/path,b.example",
            "https://a.example:65536/path,b.example",
            "https://a.example:999999999999999999999/path,b.example",
            "https://a.example,b.example/path",
            "https://a.example;b.example/path",
            "https://a.example%2C/path,b.example",
            "https://a.example%3B/path,b.example",
            "ftp://a.example/path,b.example",
            "a.example,ftp://b.example",
            "localhost:8080,b.example",
            "mailto:user@a.example,b.example",
            "javascript:alert(1),b.example",
            "https:/a.example,b.example"
        ] {
            let result = DomainListParser().parse(input, includesSubdomains: false)
            XCTAssertEqual(result.matchers, [], input)
            XCTAssertEqual(result.invalidInputs, [input], input)
            XCTAssertEqual(result.duplicateInputs, [], input)
        }
    }

    func testParsesDomainsURLsAndCommonSeparators() throws {
        let result = DomainListParser().parse(
            "github.com, https://Example.com/path\ndocs.example.net; localhost",
            includesSubdomains: true
        )

        XCTAssertEqual(result.matchers, [
            try DomainMatcher(host: "github.com", includesSubdomains: true),
            try DomainMatcher(host: "example.com", includesSubdomains: true),
            try DomainMatcher(host: "docs.example.net", includesSubdomains: true),
            try DomainMatcher(host: "localhost", includesSubdomains: true)
        ])
        XCTAssertTrue(result.invalidInputs.isEmpty)
    }

    func testReportsDuplicatesAndInvalidInputs() throws {
        let result = DomainListParser().parse(
            "example.com https://example.com/path not@@valid",
            includesSubdomains: false
        )

        XCTAssertEqual(result.matchers, [try DomainMatcher(host: "example.com", includesSubdomains: false)])
        XCTAssertEqual(result.duplicateInputs, ["https://example.com/path"])
        XCTAssertEqual(result.invalidInputs, ["not@@valid"])
    }

    func testGlobalSubdomainOptionAppliesOnlyToDNSAndRetainsEveryIPAddress() throws {
        let input = "example.com, 127.0.0.1; https://[2001:DB8::1]:8080/path [::1]"
        for includesSubdomains in [false, true] {
            let result = DomainListParser().parse(input, includesSubdomains: includesSubdomains)
            XCTAssertEqual(result.matchers, [
                try DomainMatcher(host: "example.com", includesSubdomains: includesSubdomains),
                try DomainMatcher(host: "127.0.0.1", includesSubdomains: false),
                try DomainMatcher(host: "2001:db8::1", includesSubdomains: false),
                try DomainMatcher(host: "::1", includesSubdomains: false)
            ])
            XCTAssertTrue(result.invalidInputs.isEmpty)
            XCTAssertTrue(result.hasDNSHosts)
            XCTAssertTrue(result.hasIPAddresses)
            let state = ScopeMatcherDraftLogic.validation(for: result.matchers.map(ScopeMatcherDraft.init))
            XCTAssertEqual(state.validatedMatchers(for: state.drafts), result.matchers,
                           "The shared preview and Scope submission must preserve the same matchers")
        }
    }

    func testPureIPPreviewHasNoApplicableSubdomainOptionAndReportsInvalidInputs() {
        let onlyIPs = DomainListParser().parse("127.0.0.1 https://[::1]/path", includesSubdomains: true)
        XCTAssertFalse(onlyIPs.hasDNSHosts)
        XCTAssertTrue(onlyIPs.hasIPAddresses)
        XCTAssertEqual(onlyIPs.matchers.count, 2)
        let mixed = DomainListParser().parse("example.com 127.0.0.1 not@@valid", includesSubdomains: true)
        XCTAssertEqual(mixed.matchers.map(\.normalizedHost), ["example.com", "127.0.0.1"])
        XCTAssertEqual(mixed.invalidInputs, ["not@@valid"])
        let explanation = "Include subdomains applies only to DNS names. IP addresses always match exactly."
        XCTAssertEqual(AppLanguageStore.localizedText(explanation, for: .english), explanation)
        XCTAssertEqual(AppLanguageStore.localizedText(explanation, for: .simplifiedChinese),
                       "包含子域名仅适用于 DNS 名称。IP 地址始终精确匹配。")
    }

    func testAcceptsOnlyHTTPAndHTTPSAbsoluteURLs() throws {
        let result = DomainListParser().parse(
            "https://example.com/path?query=1 http://docs.example.com:8080/page ftp://files.example.com/archive",
            includesSubdomains: false
        )

        XCTAssertEqual(result.matchers, [
            try DomainMatcher(host: "example.com", includesSubdomains: false),
            try DomainMatcher(host: "docs.example.com", includesSubdomains: false)
        ])
        XCTAssertEqual(result.invalidInputs, ["ftp://files.example.com/archive"])
    }

    func testRejectsAmbiguousSchemelessPathsInsteadOfGuessingAHost() {
        let result = DomainListParser().parse(
            "example.com/path example.com?query=1 example.com#section",
            includesSubdomains: false
        )

        XCTAssertTrue(result.matchers.isEmpty)
        XCTAssertEqual(result.invalidInputs, [
            "example.com/path",
            "example.com?query=1",
            "example.com#section"
        ])
    }
}
