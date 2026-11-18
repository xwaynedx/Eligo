import AppKit
import XCTest
@testable import Eligo

final class ChooserInsecureHTTPWarningTests: XCTestCase {
    func testShortIPv4URLsKeepCurrentCompatibilityWarning() throws {
        for input in ["http://127.1", "http://127.1:8080/path?query=1#fragment"] {
            let url = try XCTUnwrap(URL(string: input))

            XCTAssertEqual(url.host, "127.1", "Foundation host representation changed for \(input)")
            XCTAssertTrue(
                ChooserView.showsInsecureHTTPWarning(for: url),
                "The current short-IPv4 boundary keeps the HTTP warning for \(input)"
            )
        }
    }

    @MainActor
    func testShortIPv4WarningIsConnectedToChooserIcon() throws {
        func descendants(of view: NSView) -> [NSView] {
            // Include hidden arranged views even when NSStackView detaches them.
            let children = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
            return children.flatMap { [$0] + descendants(of: $0) }
        }

        for (string, expectsWarning) in [
            ("http://127.1", true),
            ("http://127.1:8080/path?query=1#fragment", true),
            ("https://127.1", false),
            ("http://127.0.0.1", false)
        ] {
            let url = try XCTUnwrap(URL(string: string))
            let view = ChooserView(
                link: IncomingLink(url: url),
                destinations: [],
                recentBrowserID: nil,
                language: .english
            )
            let warningIcons = descendants(of: view).compactMap { $0 as? NSImageView }.filter {
                $0.image?.accessibilityDescription == "Insecure HTTP"
            }
            XCTAssertEqual(warningIcons.count, 1, "Expected one HTTP warning icon for \(string)")
            let warningIcon = try XCTUnwrap(warningIcons.first)

            XCTAssertEqual(warningIcon.isHidden, !expectsWarning, "Unexpected warning visibility for \(string)")
            if expectsWarning {
                XCTAssertTrue(warningIcon.isDescendant(of: view), "Expected the warning icon in the chooser for \(string)")
                XCTAssertFalse(warningIcon.isHiddenOrHasHiddenAncestor, "Expected a visible warning icon for \(string)")
            }
        }
    }

    func testLoopbackHTTPLinksAreExemptFromTheWarning() throws {
        for string in [
            "http://127.0.0.1",
            "http://127.0.0.1:3000/path",
            "http://127.23.45.67",
            "http://localhost:8080",
            "http://foo.localhost",
            "http://[::1]/"
        ] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(
                ChooserView.showsInsecureHTTPWarning(for: url),
                "Expected \(string) to be exempt from the insecure-HTTP warning"
            )
        }
    }

    func testPublicAndLANHTTPLinksKeepTheWarning() throws {
        for string in ["http://example.com", "http://192.168.1.1", "http://10.0.0.1:8000"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertTrue(
                ChooserView.showsInsecureHTTPWarning(for: url),
                "Expected \(string) to keep the insecure-HTTP warning"
            )
        }
    }

    func testNonHTTPSchemesNeverWarn() throws {
        for string in ["https://example.com", "https://127.0.0.1", "https://127.1", "file:///tmp/note.html"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(
                ChooserView.showsInsecureHTTPWarning(for: url),
                "Expected \(string) to never warn"
            )
        }
    }
}
