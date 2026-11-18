import Foundation
import XCTest
@testable import Eligo

final class DestinationCatalogTests: XCTestCase {
    func testEveryEnabledBrowserHasANormalDestination() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let catalog = DestinationCatalog(enabledBrowsers: [safari, chrome])

        XCTAssertEqual(
            catalog.normalDestinations.map(\.id),
            [
                OpenDestinationID(browserID: safari.id, mode: .normal),
                OpenDestinationID(browserID: chrome.id, mode: .normal)
            ]
        )
    }

    func testRegisteredBrowsersHavePrivateDestinations() {
        let supportedBrowsers = [
            makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            makeBrowser(name: "Brave Browser", bundleIdentifier: "com.brave.Browser"),
            makeBrowser(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
            makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
            makeBrowser(name: "Firefox Nightly", bundleIdentifier: "org.mozilla.nightly"),
            makeBrowser(name: "Helium", bundleIdentifier: "net.imput.helium"),
            makeBrowser(name: "Zen Browser", bundleIdentifier: "app.zen-browser.zen")
        ]

        let catalog = DestinationCatalog(enabledBrowsers: supportedBrowsers)

        XCTAssertEqual(
            catalog.privateDestinations.map(\.browser.id),
            supportedBrowsers.map(\.id)
        )
    }

    func testRegisteredBrowserDefinitionsExposeVerifiedPrivateDestinations() {
        let registeredBrowsers = BrowserDefinition.all.flatMap { definition in
            definition.bundleIdentifiers.map {
                makeBrowser(name: definition.displayName, bundleIdentifier: $0)
            }
        }
        let catalog = DestinationCatalog(enabledBrowsers: registeredBrowsers)

        XCTAssertEqual(
            Set(catalog.privateDestinations.map(\.browser.id)),
            [
                "com.google.Chrome",
                "com.brave.Browser",
                "com.microsoft.edgemac",
                "org.mozilla.firefox",
                "org.mozilla.nightly",
                "net.imput.helium",
                "app.zen-browser.zen",
                "org.mozilla.zen"
            ]
        )
    }

    func testHeliumPrivateAdapterIsVerifiedChromium() {
        let adapter = BrowserDefinition.definition(for: "net.imput.helium")?.privateLaunchAdapter

        XCTAssertEqual(adapter?.verification, .verified)
        XCTAssertEqual(adapter?.family, .chromium)
        XCTAssertEqual(adapter?.actionTitle(language: .simplifiedChinese), "隐私")
        XCTAssertEqual(adapter?.actionTitle(language: .english), "Private")
        XCTAssertEqual(adapter?.chooserActionTitle(language: .simplifiedChinese), "隐私模式")
        XCTAssertEqual(adapter?.chooserActionTitle(language: .english), "Private mode")
        XCTAssertEqual(adapter?.capabilityLabel(language: .simplifiedChinese), "支持隐私模式")
        XCTAssertEqual(adapter?.toolTip(language: .english), "Open in Private mode")
    }

    func testZenPrivateAdapterUsesVerifiedFirefoxStrategy() {
        for bundleIdentifier in ["app.zen-browser.zen", "org.mozilla.zen"] {
            let adapter = BrowserDefinition.definition(for: bundleIdentifier)?.privateLaunchAdapter

            XCTAssertEqual(adapter?.verification, .verified)
            XCTAssertEqual(adapter?.family, .firefox)
            XCTAssertEqual(adapter?.privateWindowArgument, "--private-window")
            XCTAssertEqual(adapter?.actionTitle(language: .simplifiedChinese), "隐私")
            XCTAssertEqual(adapter?.chooserActionTitle(language: .english), "Private mode")
            XCTAssertEqual(adapter?.capabilityLabel(language: .simplifiedChinese), "支持隐私模式")
        }
    }

    func testExperimentalAdapterCopyIsExplicitlyMarked() {
        let experimental = PrivateLaunchAdapter.experimentalChromium

        XCTAssertEqual(experimental.actionTitle(language: .simplifiedChinese), "隐私（试验）")
        XCTAssertEqual(experimental.actionTitle(language: .english), "Private (Experimental)")
        XCTAssertEqual(experimental.capabilityLabel(language: .simplifiedChinese), "隐私模式（试验）")
        XCTAssertEqual(experimental.capabilityLabel(language: .english), "Privacy mode (Experimental)")
        XCTAssertEqual(
            experimental.accessibilityLabel(browserName: "Chrome", language: .simplifiedChinese),
            "以隐私模式（试验）打开 Chrome"
        )
        XCTAssertEqual(
            experimental.ruleMenuTitle(browserName: "Chrome", language: .english),
            "Add Private (Experimental) Rule for Chrome…"
        )
    }

    func testDiaDoesNotExposePrivateDestination() {
        let dia = makeBrowser(name: "Dia", bundleIdentifier: "company.thebrowser.dia")
        let catalog = DestinationCatalog(enabledBrowsers: [dia])

        XCTAssertNil(BrowserDefinition.definition(for: dia.bundleIdentifier)?.privateLaunchAdapter)
        XCTAssertEqual(catalog.normalDestinations.map(\.browser.id), [dia.id])
        XCTAssertTrue(catalog.privateDestinations.isEmpty)
    }

    func testDisabledBrowsersProduceNoDestinations() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let catalog = DestinationCatalog(enabledBrowsers: [])

        XCTAssertTrue(catalog.destinations.isEmpty)
        XCTAssertNil(catalog.destination(for: OpenDestinationID(browserID: chrome.id, mode: .normal)))
        XCTAssertNil(catalog.destination(for: OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing)))
    }

    func testUnverifiedVariantsDoNotInheritPrivateSupport() {
        let chromeCanary = makeBrowser(
            name: "Chrome Canary",
            bundleIdentifier: "com.google.Chrome.canary"
        )
        let firefoxDeveloperEdition = makeBrowser(
            name: "Firefox Developer Edition",
            bundleIdentifier: "org.mozilla.firefoxdeveloperedition"
        )

        let catalog = DestinationCatalog(enabledBrowsers: [chromeCanary, firefoxDeveloperEdition])

        XCTAssertTrue(catalog.privateDestinations.isEmpty)
    }

    func testDestinationIDRoundTripsThroughCodable() throws {
        let identifier = OpenDestinationID(
            browserID: "com.google.Chrome",
            mode: .privateBrowsing
        )

        let encoded = try JSONEncoder().encode(identifier)
        let decoded = try JSONDecoder().decode(OpenDestinationID.self, from: encoded)

        XCTAssertEqual(decoded, identifier)
    }
}
