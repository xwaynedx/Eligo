import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ChooserAccessibilityTests: XCTestCase {
    func testNavigableRowsAnnounceLocalizedShortcutsWithoutExtraNavigationStops() throws {
        let browsers = [makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")]
            + (1..<11).map { makeBrowser(name: "Browser \($0)", bundleIdentifier: "test.shortcut.\($0)") }
        for language in [AppLanguage.english, .simplifiedChinese] {
            let view = ChooserView(
                link: IncomingLink(url: URL(string: "https://example.com")!),
                destinations: DestinationCatalog(enabledBrowsers: browsers).destinations,
                recentBrowserID: nil, language: language
            )
            let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            let actions = try XCTUnwrap(document.accessibilityChildrenInNavigationOrder() as? [NSView])
            XCTAssertEqual(actions.count, 12, "Eleven Normal actions plus one Private action; badges are not extra stops")
            let normalActions = actions.filter { $0.accessibilityIdentifier() != "chooser.private" }
            XCTAssertEqual(normalActions.count, 11)
            for (index, action) in normalActions.enumerated() {
                let normal = language == .english
                    ? "Open \(browsers[index].name) normally" : "以普通模式打开 \(browsers[index].name)"
                let shortcut = index == 9 ? "0" : String(index + 1)
                let suffix = index < 10
                    ? (language == .english ? ", Chooser shortcut \(shortcut)" : ", 选择器快捷键 \(shortcut)") : ""
                XCTAssertEqual(action.accessibilityLabel(), normal + suffix)
                XCTAssertTrue(action.accessibilityChildren()?.isEmpty ?? false)
            }
        }
    }

    func testDisabledChooserRejectsSelectionCommandsWithoutChangingItsSelection() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let commands: [(ChooserView) -> Void] = [
            { XCTAssertFalse($0.selectNormalDestination(at: 0)) },
            { $0.selectPrivateDestination(at: 0) },
            { XCTAssertFalse($0.handleKeyDown(chooserKeyEvent(keyCode: 18, characters: "1"))) },
            { XCTAssertFalse($0.handleKeyDown(chooserKeyEvent(keyCode: 126, characters: "\u{F700}"))) },
            { XCTAssertFalse($0.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r"))) },
            { XCTAssertFalse($0.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r", modifiers: .shift))) }
        ]
        for command in commands {
            let view = ChooserView(
                link: IncomingLink(url: URL(string: "https://example.com")!),
                destinations: DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations,
                recentBrowserID: safari.id
            )
            command(view)
            var selected: [OpenDestinationID] = []
            view.onSelect = { selected.append($0.id) }
            XCTAssertTrue(view.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r")))
            XCTAssertEqual(selected, [OpenDestinationID(browserID: safari.id, mode: .normal)])
        }
    }

    func testNormalMouseClickOverridesPrivateSelection() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }
        view.selectPrivateDestination(at: 0)
        selected.removeAll()
        let row = try XCTUnwrap(browserChooserRows(in: view).first)

        row.mouseDown(with: chooserMouseEvent(location: row.convert(NSPoint(x: 3, y: 20), to: nil)))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: chrome.id, mode: .normal)])
    }

    func testCompletedPresentationDisablesRetainedAccessibilityControls() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        var panel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { panel = $0 }, mouseEvents: ChooserMouseEventSource().events
        )
        var selected: [OpenDestinationID] = []
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        ) { if let destination = $0 { selected.append(destination.id) } }
        let view = try XCTUnwrap(browserChooserView(in: panel?.contentView))
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: row))
        panel?.contentView?.addSubview(NSView(), positioned: .below, relativeTo: view)

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertFalse(row.accessibilityPerformPress())
        XCTAssertFalse(privateButton.accessibilityPerformPress())
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(selected, [OpenDestinationID(browserID: chrome.id, mode: .normal)])
        withExtendedLifetime(controller) {}
    }

    func testAccessibilityNavigationListsNormalAndPrivateActionsInRowOrder() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: [
                OpenDestination(browser: chrome, mode: .normal),
                OpenDestination(browser: chrome, mode: .privateBrowsing),
                OpenDestination(browser: safari, mode: .normal)
            ],
            recentBrowserID: nil,
            language: .simplifiedChinese
        )
        let rows = browserChooserRows(in: view)
        let document = try XCTUnwrap(rows.first?.superview)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: rows[0]))
        let expected: [NSView] = [rows[0], privateButton, rows[1]]
        let children = try XCTUnwrap(document.accessibilityChildren() as? [NSView])
        let navigationOrder = document.accessibilityChildrenInNavigationOrder()?.compactMap { $0 as? NSView }

        XCTAssertEqual(children.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
        XCTAssertEqual(navigationOrder?.map(ObjectIdentifier.init), expected.map(ObjectIdentifier.init))
        XCTAssertTrue(children.allSatisfy { ($0.accessibilityParent() as? NSView) === document })
        XCTAssertTrue(rows[0].accessibilityChildren()?.isEmpty ?? false)
        XCTAssertEqual(rows[0].accessibilityLabel(), "以普通模式打开 Google Chrome, 选择器快捷键 1")
        XCTAssertEqual(privateButton.accessibilityLabel(), "以隐私模式打开 Google Chrome")
    }

    func testProductionNormalRowAccessibilityPressChoosesNormalExactlyOnce() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }
        let row = try XCTUnwrap(browserChooserRows(in: view).first)

        XCTAssertTrue(row.accessibilityPerformPress())

        XCTAssertEqual(selected, [OpenDestinationID(browserID: chrome.id, mode: .normal)])
    }

    func testRowsWithoutASelectionHandlerAreDisabledAndRejectAccessibilityPress() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: row))

        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(row.isAccessibilityEnabled())
        XCTAssertFalse(privateButton.isEnabled)
        XCTAssertFalse(row.accessibilityPerformPress())

        view.onSelect = { _ in }
        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(privateButton.isEnabled)
        view.onSelect = nil
        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(privateButton.isEnabled)
        XCTAssertFalse(row.accessibilityPerformPress())
    }

    func testNormalAccessibilityPressOverridesPrivateSelectionAndPrivateButtonKeepsItsOwnAction() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: row))
        view.selectPrivateDestination(at: 0)
        selected.removeAll()

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(privateButton.accessibilityPerformPress())

        XCTAssertEqual(selected, [
            OpenDestinationID(browserID: chrome.id, mode: .normal),
            OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing)
        ])
        XCTAssertEqual(row.accessibilityLabel(), "Open Google Chrome normally, Chooser shortcut 1")
        XCTAssertEqual(privateButton.accessibilityLabel(), "Open Google Chrome in Private mode")
    }

    func testDisabledNormalRowRejectsAccessibilityAndMouseSelection() throws {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        row.isEnabled = false

        XCTAssertFalse(row.accessibilityPerformPress())
        row.mouseDown(with: chooserMouseEvent())

        XCTAssertTrue(selected.isEmpty)
    }
}
