import XCTest
@testable import Eligo

final class BatchRuleDraftTests: XCTestCase {
    func testDraftOwnsExactInputAndPreviewForEachSubdomainOption() throws {
        let text = "https://Example.com/path 127.0.0.1"
        let draft = BatchRuleDraft(text: text, includesSubdomains: true)
        XCTAssertEqual(draft.text, text)
        XCTAssertTrue(draft.includesSubdomains)
        XCTAssertEqual(draft.preview, DomainListParseResult(matchers: [
            try DomainMatcher(host: "example.com", includesSubdomains: true),
            try DomainMatcher(host: "127.0.0.1", includesSubdomains: false)
        ], duplicateInputs: [], invalidInputs: []))
        let exact = BatchRuleDraft(text: text, includesSubdomains: false)
        XCTAssertEqual(exact.text, text)
        XCTAssertFalse(exact.includesSubdomains)
        XCTAssertEqual(exact.preview.matchers, [
            try DomainMatcher(host: "example.com", includesSubdomains: false),
            try DomainMatcher(host: "127.0.0.1", includesSubdomains: false)
        ])
    }

    func testMixedInputRetainsEveryIssueDuplicateAndOrderedMatcher() throws {
        let text = "Example.com https://EXAMPLE.com/a 127.0.0.1 https://[2001:db8::1]:8443/p?q=a,b docs.example bad/path ftp://bad.example/a"
        let preview = BatchRuleDraft(text: text, includesSubdomains: true)
        XCTAssertEqual(preview.preview, DomainListParseResult(matchers: [
            try DomainMatcher(host: "example.com", includesSubdomains: true),
            try DomainMatcher(host: "127.0.0.1", includesSubdomains: false),
            try DomainMatcher(host: "2001:db8::1", includesSubdomains: false),
            try DomainMatcher(host: "docs.example", includesSubdomains: true)
        ], duplicateInputs: ["https://EXAMPLE.com/a"], invalidInputs: ["bad/path", "ftp://bad.example/a"]))
    }

    func testInitialAndWhitespacePreviewsAreEmptyAndAllInvalidInputKeepsAllErrors() {
        let empty = DomainListParseResult(matchers: [], duplicateInputs: [], invalidInputs: [])
        XCTAssertEqual(BatchRuleDraft.empty.preview, empty)
        XCTAssertEqual(BatchRuleDraft.empty.preview, BatchRuleDraft(text: "", includesSubdomains: true).preview)
        XCTAssertEqual(BatchRuleDraft.empty.text, "")
        XCTAssertTrue(BatchRuleDraft.empty.includesSubdomains)
        let whitespace = " \n\t"
        XCTAssertEqual(BatchRuleDraft(text: whitespace, includesSubdomains: false)
            .preview, empty)
        let invalid = "bad/path ftp://bad.example/a"
        XCTAssertEqual(BatchRuleDraft(text: invalid, includesSubdomains: true)
            .preview,
            DomainListParseResult(matchers: [], duplicateInputs: [], invalidInputs: ["bad/path", "ftp://bad.example/a"]))
    }
}
