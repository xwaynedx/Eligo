import XCTest
@testable import Eligo

@MainActor
final class ChooserSelectionTests: XCTestCase {
    func testRecentBrowserDefaultsToNormalDestinationForEnterAndItsOwnNumberShortcut() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let destinations = DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: chrome.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r"))
        _ = view.handleKeyDown(makeKeyEvent(keyCode: 18, characters: "1"))

        let normalID = OpenDestinationID(browserID: chrome.id, mode: .normal)
        XCTAssertEqual(selected.first, normalID)
        XCTAssertEqual(selected.last, normalID)
    }

    func testUnavailableRecentBrowserFallsBackToFirstBrowser() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: "com.example.missing"
        )
        var selected: OpenDestinationID?
        view.onSelect = { selected = $0.id }

        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r"))

        XCTAssertEqual(selected, OpenDestinationID(browserID: safari.id, mode: .normal))
    }

    func testShiftEnterOnUnsupportedBrowserDoesNotOpenNormalDestination() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r", modifierFlags: .shift))

        XCTAssertTrue(selected.isEmpty)
    }

    func testNormalRowAndPlainEnterOpenNormalDestination() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        view.selectNormalDestination(at: 1)
        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r"))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: safari.id, mode: .normal), OpenDestinationID(browserID: safari.id, mode: .normal)])
    }

    func testPrivateActionAndShiftEnterOpenPrivateDestination() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        view.selectPrivateDestination(at: 0)
        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r", modifierFlags: .shift))

        XCTAssertEqual(selected, [
            OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing),
            OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing)
        ])
    }

    func testNumberShortcutUsesNormalModeAfterPrivateAction() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations,
            recentBrowserID: chrome.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        view.selectPrivateDestination(at: 0)
        _ = view.handleKeyDown(makeKeyEvent(keyCode: 19, characters: "2"))

        XCTAssertEqual(selected, [
            OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing),
            OpenDestinationID(browserID: safari.id, mode: .normal)
        ])
    }

    func testEscapeKeyCancelsChooser() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var cancelled = false
        view.onCancel = { cancelled = true }

        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 53, characters: "\u{1B}")))

        XCTAssertTrue(cancelled)
    }

    func testDownArrowMovesSelectionWithoutWrappingPastLastRow() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let destinations = DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: chrome.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        // Down to Safari, down again clamps at last row, Return selects Safari (no wrap back to Chrome).
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 125, characters: "\u{F701}")))
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 125, characters: "\u{F701}")))
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: safari.id, mode: .normal)])
    }

    func testUpArrowMovesSelectionWithoutWrappingPastFirstRow() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let destinations = DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations
        // Selection starts at chrome (index 0) via recentBrowserID; up clamps at first row.
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: chrome.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 126, characters: "\u{F700}")))
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: chrome.id, mode: .normal)])
    }

    func testPlainEnterChoosesCurrentlyPrivateSelectedRow() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        view.selectPrivateDestination(at: 0)
        // Plain Enter (no shift) on a private-selected row chooses the private destination.
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))

        XCTAssertEqual(selected.last, OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing))
    }

    func testLetterKeySelectsNextRowWithMatchingPrefix() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 30)
        let chromium = makeBrowser(name: "Chromium", bundleIdentifier: "org.chromium.Chromium", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let destinations = DestinationCatalog(enabledBrowsers: [chrome, chromium, safari]).destinations
        // Selection starts at chrome (index 0); "c" advances to the next "C"-prefixed row (Chromium).
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: chrome.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 8, characters: "c")))
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: chromium.id, mode: .normal)])
    }

    func testLetterKeyWrapsToEarlierMatchingRow() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 30)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let destinations = DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations
        // Selection starts at safari (last row); "g" matches "Google Chrome" only by wrapping back to row 0.
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: safari.id
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 5, characters: "g")))
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r")))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: chrome.id, mode: .normal)])
    }

    func testLetterWithNoMatchingRowIsUnhandledAndDoesNotSelect() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        XCTAssertFalse(view.handleKeyDown(makeKeyEvent(keyCode: 122, characters: "z")))

        XCTAssertTrue(selected.isEmpty)
    }

    func testNumberShortcutBeyondRowCountIsUnhandledAndDoesNotSelect() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        // "2" maps to index 1, which does not exist with a single browser.
        XCTAssertFalse(view.handleKeyDown(makeKeyEvent(keyCode: 19, characters: "2")))

        XCTAssertTrue(selected.isEmpty)
    }

    func testShiftEnterOnRowWithoutPrivateDestinationBeepsAndSelectsNothing() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        // Shift+Enter handled (returns true) but selects nothing because Safari has no private adapter.
        XCTAssertTrue(view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r", modifierFlags: .shift)))

        XCTAssertTrue(selected.isEmpty)
    }

    func testTabIsLeftToTheKeyViewLoopForKeyboardAccessibility() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
            recentBrowserID: nil
        )

        XCTAssertFalse(view.handleKeyDown(makeKeyEvent(keyCode: 48, characters: "\t")))
        XCTAssertFalse(
            view.handleKeyDown(makeKeyEvent(keyCode: 48, characters: "\t", modifierFlags: .shift))
        )
        let copy = try XCTUnwrap(view.nextKeyView as? NSButton)
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: row))
        XCTAssertEqual(copy.accessibilityIdentifier(), "chooser.copyLink")
        XCTAssertEqual(copy.nextKeyView?.accessibilityIdentifier(), "chooser.expandLink")
        XCTAssertTrue(copy.nextKeyView?.nextKeyView === row)
        XCTAssertTrue(row.nextKeyView === privateButton)
        XCTAssertEqual(privateButton.nextKeyView?.accessibilityIdentifier(), "chooser.createRule")
        XCTAssertTrue(privateButton.nextKeyView?.nextKeyView === view)
    }

    func testPrivateSelectionOnUnsupportedRowKeepsNormalSelectionForEnter() {
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil
        )
        var selected: [OpenDestinationID] = []
        view.onSelect = { selected.append($0.id) }

        // Safari has no Private adapter: the call beeps and leaves the cursor untouched.
        view.selectPrivateDestination(at: 0)
        _ = view.handleKeyDown(makeKeyEvent(keyCode: 36, characters: "\r"))

        XCTAssertEqual(selected, [OpenDestinationID(browserID: safari.id, mode: .normal)])
    }

    func testCreateRuleMenuCallbacksPairHostWithRowDestinations() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", priority: 20)
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari", priority: 10)
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com/articles/1")!),
            destinations: DestinationCatalog(enabledBrowsers: [chrome, safari]).destinations,
            recentBrowserID: nil
        )
        var requests: [(host: String, destination: OpenDestinationID)] = []
        view.onCreateRule = { host, destination in requests.append((host, destination.id)) }

        let rows = browserChooserRows(in: view)
        XCTAssertEqual(rows.count, 2)
        let event = makeMenuEvent()

        // Row context menus pair the rule host with each row's Normal destination.
        invokeMenuItem(rows[0].menu(for: event)?.items.first)
        invokeMenuItem(rows[1].menu(for: event)?.items.first)
        // The Private button menu pairs the same host with that row's Private destination.
        // Safari's row has no Private adapter and therefore no Private button at all.
        let chromePrivateButton = browserChooserPrivateButton(in: rows[0])
        XCTAssertNotNil(chromePrivateButton)
        XCTAssertNil(browserChooserPrivateButton(in: rows[1]))
        invokeMenuItem(chromePrivateButton?.menu?.items.first)

        XCTAssertEqual(requests.map(\.host), ["example.com", "example.com", "example.com"])
        XCTAssertEqual(requests.map(\.destination), [
            OpenDestinationID(browserID: chrome.id, mode: .normal),
            OpenDestinationID(browserID: safari.id, mode: .normal),
            OpenDestinationID(browserID: chrome.id, mode: .privateBrowsing)
        ])
    }

    func testCreateRuleMenuRequiresWebHostAndCallback() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let destinations = DestinationCatalog(enabledBrowsers: [chrome]).destinations
        let event = makeMenuEvent()

        // A file URL has no rule host: no rule menus even when a callback is installed.
        let fileView = ChooserView(
            link: IncomingLink(url: URL(fileURLWithPath: "/tmp/notes.txt")),
            destinations: destinations,
            recentBrowserID: nil
        )
        fileView.onCreateRule = { _, _ in XCTFail("create-rule must not fire for file URLs") }
        let fileRow = browserChooserRows(in: fileView).first
        XCTAssertNil(fileRow?.menu(for: event))
        XCTAssertNil(browserChooserPrivateButton(in: fileRow)?.menu)

        // A web URL without an installed callback exposes no rule menus either.
        let webView = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: destinations,
            recentBrowserID: nil
        )
        let webRow = browserChooserRows(in: webView).first
        XCTAssertNil(webRow?.menu(for: event))
        XCTAssertNil(browserChooserPrivateButton(in: webRow)?.menu)
    }

    private func invokeMenuItem(_ item: NSMenuItem?, file: StaticString = #filePath, line: UInt = #line) {
        guard let item, let action = item.action else {
            XCTFail("expected a rule menu item with an action", file: file, line: line)
            return
        }
        // Dispatch through the same target/action mechanism AppKit uses for a real menu click.
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    private func makeMenuEvent() -> NSEvent {
        // `BrowserRowView.menu(for:)` ignores the event payload; a minimal right-mouse-down
        // event documents the intended trigger.
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
