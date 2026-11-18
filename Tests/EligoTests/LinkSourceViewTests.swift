import Foundation
import XCTest
@testable import Eligo

@MainActor
final class LinkSourceViewTests: XCTestCase {
    private let slackSource = LinkSource.app(AppSender(
        name: "Slack",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        appURL: URL(fileURLWithPath: "/Applications/Slack.app", isDirectory: true)
    ))

    func testDisplayTextNamesTheSourceApp() {
        XCTAssertEqual(slackSource.displayText(language: .english), "From Slack")
        XCTAssertEqual(slackSource.displayText(language: .simplifiedChinese), "来自 Slack")
    }

    func testDisplayTextMarksUnresolvableSendersAsUnknown() {
        XCTAssertEqual(LinkSource.unknown.displayText(language: .english), "Unknown source")
        XCTAssertEqual(LinkSource.unknown.displayText(language: .simplifiedChinese), "来源未知")
    }

    func testToolTipPrefersBundleIdentifierAndFallsBackToName() {
        XCTAssertEqual(slackSource.toolTip, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(
            LinkSource.app(AppSender(name: "Helper", bundleIdentifier: nil, appURL: nil)).toolTip,
            "Helper"
        )
        XCTAssertNil(LinkSource.unknown.toolTip)
    }

    func testLogDescriptionIdentifiesAppAndUnknown() {
        XCTAssertEqual(slackSource.logDescription, "Slack (com.tinyspeck.slackmacgap)")
        XCTAssertEqual(LinkSource.unknown.logDescription, "unknown")
    }

    func testChooserGrowsForSourceLineAndStaysCompactWithoutSource() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let destinations = DestinationCatalog(enabledBrowsers: [safari]).destinations
        let url = URL(string: "https://example.com")!

        let withoutSource = ChooserView(link: IncomingLink(url: url), destinations: destinations, recentBrowserID: nil)
        let withSource = ChooserView(
            link: IncomingLink(url: url, source: slackSource),
            destinations: destinations,
            recentBrowserID: nil
        )

        XCTAssertNil(withoutSource.displaySource)
        XCTAssertEqual(withSource.displaySource, "From Slack")
        XCTAssertEqual(
            withSource.preferredSize.height,
            withoutSource.preferredSize.height + 18
        )
    }
}
