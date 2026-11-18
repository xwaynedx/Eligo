import Foundation
import XCTest
@testable import Eligo

final class ChooserDisplayURLTests: XCTestCase {
    func testShowsNonDefaultPortsInTheTitle() throws {
        let cases = [
            "http://127.0.0.1:3000": "http://127.0.0.1:3000",
            "https://example.com:8443/path?q=1": "https://example.com:8443",
            "http://example.com:443/": "http://example.com:443"
        ]
        for (string, expected) in cases {
            try assertDisplayURL(string, equals: expected)
        }
    }

    func testHidesDefaultPorts() throws {
        let cases = [
            "http://example.com:80/": "http://example.com",
            "https://example.com:443/": "https://example.com"
        ]
        for (string, expected) in cases {
            try assertDisplayURL(string, equals: expected)
        }
    }

    func testOmitsPortWhenTheLinkCarriesNone() throws {
        try assertDisplayURL("https://example.com/path", equals: "https://example.com")
    }

    func testBracketsIPv6HostsSoTheTitleStaysAValidAuthority() throws {
        let cases = [
            "http://[::1]:8080/": "http://[::1]:8080",
            "http://[::1]:80/": "http://[::1]",
            "http://[::1]/": "http://[::1]"
        ]
        for (string, expected) in cases {
            try assertDisplayURL(string, equals: expected)
        }
    }

    func testFileAndHostlessLinksKeepTheirExistingDisplay() throws {
        try assertDisplayURL("file:///tmp/note.html", equals: "file://note.html")
        try assertDisplayURL("mailto:a@b.c", equals: "Unknown URL")
    }

    private func assertDisplayURL(
        _ string: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try XCTUnwrap(URL(string: string), file: file, line: line)
        XCTAssertEqual(ChooserView.displayURL(for: url), expected, "Wrong display URL for \(string)", file: file, line: line)
    }
}
