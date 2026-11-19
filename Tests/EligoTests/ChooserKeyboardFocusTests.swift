import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ChooserKeyboardFocusTests: XCTestCase {
    func testCommandReturnAndVisibleRuleButtonUseCurrentSelection() throws {
        let browsers = makeBrowsers()
        for keyCode: UInt16 in [36, 76] {
            let presentation = try makePresentation(browsers: browsers) { _ in XCTFail("创建规则不能取消或打开链接") }
            defer { presentation.pasteboard.releaseGlobally() }
            defer { presentation.view.onCancel = nil }
            var requests: [OpenDestinationID] = []
            presentation.view.onCreateRule = { host, destination in
                XCTAssertEqual(host, "example.com")
                requests.append(destination.id)
            }
            let rows = browserChooserRows(in: presentation.view)
            let safari = try XCTUnwrap(rows.first)
            let chrome = try XCTUnwrap(rows.dropFirst().first)
            XCTAssertTrue(presentation.panel.makeFirstResponder(try XCTUnwrap(browserChooserPrivateButton(in: chrome))))
            safari.mouseEntered(with: chooserMouseEvent(
                location: safari.convert(NSPoint(x: 10, y: 20), to: nil), windowNumber: presentation.panel.windowNumber
            ))
            XCTAssertTrue(presentation.panel.performKeyEquivalent(with: chooserKeyEvent(
                keyCode: keyCode, characters: "\r", modifiers: .command, windowNumber: presentation.panel.windowNumber
            )))
            let button = try XCTUnwrap(presentation.view.subviews.compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == "chooser.createRule"
            })
            XCTAssertTrue(presentation.panel.makeFirstResponder(button))
            presentation.panel.sendEvent(chooserKeyEvent(keyCode: 36, characters: "\r", windowNumber: presentation.panel.windowNumber))
            XCTAssertEqual(requests, Array(repeating: OpenDestinationID(browserID: browsers[0].id, mode: .normal), count: 2))
        }
    }

    func testRoutingHintMarksExactModeWithoutChangingRecentSelection() throws {
        _ = NSApplication.shared
        let browsers = [
            Browser(name: "Safari", bundleIdentifier: "com.apple.Safari", appURL: URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"), priority: 1, isCustom: false),
            Browser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"), priority: 2, isCustom: false),
            Browser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox", appURL: URL(fileURLWithPath: "/Applications/Firefox.app"), priority: 3, isCustom: false)
        ]
        let cases: [(OpeningMode, String?, String)] = [
            (.normal, "github.com", "规则目标：github.com → Google Chrome（普通）"),
            (.privateBrowsing, "github.com", "规则目标：github.com → Google Chrome（隐私）"),
            (.normal, nil, "范围外默认目标：Google Chrome（普通）")
        ]
        for (mode, matchedDomain, tooltip) in cases {
            let hint = ChooserRoutingHint(destinationID: .init(browserID: browsers[1].id, mode: mode), matchedDomain: matchedDomain)
            let view = ChooserView(link: IncomingLink(url: URL(string: "https://github.com/openai/codex/pull/42?tab=files#discussion")!),
                destinations: DestinationCatalog(enabledBrowsers: browsers).destinations, recentBrowserID: browsers[0].id,
                routingHint: hint, language: .simplifiedChinese)
            view.onSelect = { _ in }
            view.onCreateRule = { _, _ in }
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            let rows = browserChooserRows(in: view)
            XCTAssertEqual(rows[0].accessibilityValue() as? String, "已选择")
            let markers = rows.flatMap(\.subviews).filter { $0.accessibilityIdentifier() == "chooser.routingHint" }
            XCTAssertEqual(markers.count, 1)
            XCTAssertTrue(markers[0].superview === rows[1])
            XCTAssertEqual(markers[0].toolTip, tooltip)
            var selected: OpenDestinationID?
            view.onSelect = { selected = $0.id }
            _ = view.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r"))
            XCTAssertEqual(selected, OpenDestinationID(browserID: browsers[0].id, mode: .normal))
            if matchedDomain != nil, let directory = ProcessInfo.processInfo.environment["ELIGO_UX_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rule-\(mode.rawValue).png"))
            }
        }
    }

    func testPanelDigitShortcutsOpenOnlyTheRequestedMode() throws {
        let browsers = makeBrowsers()
        let cases: [(NSEvent.ModifierFlags, String, OpeningMode)] = [([], "2", .normal), (.shift, "@", .privateBrowsing)]
        for (modifiers, characters, mode) in cases {
            var opened: [OpenDestinationID?] = []
            let presentation = try makePresentation(browsers: browsers) { opened.append($0?.id) }
            defer { presentation.pasteboard.releaseGlobally() }
            let panel = presentation.panel
            panel.sendEvent(chooserKeyEvent(keyCode: 18, characters: "!", modifiers: .shift, windowNumber: panel.windowNumber))
            panel.sendEvent(chooserKeyEvent(keyCode: 19, characters: "2", modifiers: .command, windowNumber: panel.windowNumber))
            XCTAssertTrue(opened.isEmpty)
            panel.sendEvent(chooserKeyEvent(keyCode: 19, characters: characters, modifiers: modifiers, windowNumber: panel.windowNumber))
            XCTAssertEqual(opened, [OpenDestinationID(browserID: browsers[1].id, mode: mode)])
            withExtendedLifetime(presentation.controller) {}
        }
    }

    func testTabToNormalRowHighlightsAndActivatesThatBrowser() throws {
        let browsers = makeBrowsers()
        for (keyCode, characters) in [(UInt16(36), "\r"), (76, "\u{3}"), (49, " ")] {
            var completions: [OpenDestinationID?] = []
            let presentation = try makePresentation(browsers: browsers) {
                completions.append($0?.id)
            }
            defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
            defer { presentation.pasteboard.releaseGlobally() }
            let changeCount = presentation.pasteboard.changeCount
            let rows = browserChooserRows(in: presentation.view)
            let safari = try XCTUnwrap(rows.first)
            let chrome = try XCTUnwrap(rows.dropFirst().first)
            XCTAssertEqual(safari.accessibilityValue() as? String, "Selected")
            XCTAssertTrue(presentation.panel.firstResponder === presentation.view)
            XCTAssertFalse(presentation.panel.autorecalculatesKeyViewLoop)

            sendTab(to: presentation.panel)
            XCTAssertEqual((presentation.panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.copyLink")
            sendTab(to: presentation.panel)
            XCTAssertEqual((presentation.panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.expandLink")
            sendTab(to: presentation.panel)
            XCTAssertTrue(presentation.panel.firstResponder === safari)
            sendTab(to: presentation.panel)
            assertFocused(chrome, in: presentation.panel)
            XCTAssertEqual(safari.accessibilityValue() as? String, "Not selected")
            XCTAssertTrue(completions.isEmpty, "Tab must only focus and highlight, never open")

            try pressActivationKey(keyCode, characters: characters, in: presentation.panel)
            XCTAssertEqual(completions, [OpenDestinationID(browserID: browsers[1].id, mode: .normal)])
            XCTAssertEqual(presentation.pasteboard.changeCount, changeCount)
            XCTAssertFalse(chrome.isEnabled, "Completed controls must not remain actionable")
        }
    }

    func testTabbedPrivateButtonOpensItsBrowserWhenAnotherRowIsHighlighted() throws {
        let browsers = Array(makeBrowsers().prefix(2))
        for backwards in [false, true] {
            for (keyCode, characters) in [(UInt16(36), "\r"), (76, "\u{3}"), (49, " ")] {
                var opened: [OpenDestinationID?] = []
                let presentation = try makePresentation(browsers: browsers, onCreateRule: { _, _ in
                    XCTFail("键盘只应触发聚焦的隐私按钮")
                }) { opened.append($0?.id) }
                defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
                defer { presentation.pasteboard.releaseGlobally() }
                let panel = presentation.panel
                let rows = browserChooserRows(in: presentation.view)
                let safari = try XCTUnwrap(rows.first)
                let chrome = try XCTUnwrap(rows.last)
                let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: chrome))

                if backwards {
                    sendTab(to: panel, backwards: true)
                    XCTAssertEqual((panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.createRule")
                    sendTab(to: panel, backwards: true)
                } else {
                    for _ in 0..<5 { sendTab(to: panel) }
                }
                safari.mouseEntered(with: chooserMouseEvent(
                    location: safari.convert(NSPoint(x: 10, y: 20), to: nil), windowNumber: panel.windowNumber
                ))
                XCTAssertTrue(panel.firstResponder === privateButton)
                XCTAssertEqual(safari.accessibilityValue() as? String, "Selected")
                XCTAssertTrue(opened.isEmpty)

                try pressActivationKey(keyCode, characters: characters, in: panel)
                XCTAssertEqual(opened, [OpenDestinationID(browserID: browsers[1].id, mode: .privateBrowsing)])
            }
        }
    }

    func testTabSkipsHiddenAndDisabledRowActionsUntilTheyAreAvailableAgain() throws {
        let presentation = try makePresentation(browsers: makeBrowsers()) { destination in XCTAssertNil(destination) }
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        defer { presentation.pasteboard.releaseGlobally() }
        let panel = presentation.panel
        let rows = browserChooserRows(in: presentation.view)
        let safari = try XCTUnwrap(rows.first)
        let chrome = try XCTUnwrap(rows.dropFirst().first)
        let chromePrivate = try XCTUnwrap(browserChooserPrivateButton(in: chrome))
        let zen = try XCTUnwrap(rows.last)

        XCTAssertTrue(panel.makeFirstResponder(chrome))
        chromePrivate.isHidden = true
        sendTab(to: panel)
        XCTAssertTrue(panel.firstResponder === zen)
        chromePrivate.isHidden = false
        sendTab(to: panel, backwards: true)
        XCTAssertTrue(panel.firstResponder === chromePrivate)

        XCTAssertTrue(panel.makeFirstResponder(zen))
        chrome.isHidden = true
        sendTab(to: panel, backwards: true)
        XCTAssertTrue(panel.firstResponder === safari)
        chrome.isHidden = false
        chrome.isEnabled = false
        sendTab(to: panel)
        XCTAssertTrue(panel.firstResponder === zen)
        chrome.isEnabled = true
        sendTab(to: panel, backwards: true)
        XCTAssertTrue(panel.firstResponder === chromePrivate)
    }

    func testReverseTabToZenNormalHighlightsAndActivatesZen() throws {
        let browsers = makeBrowsers()
        var completions: [OpenDestinationID?] = []
        let presentation = try makePresentation(browsers: browsers) { completions.append($0?.id) }
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        defer { presentation.pasteboard.releaseGlobally() }
        let rows = browserChooserRows(in: presentation.view)
        let zen = try XCTUnwrap(rows.last)
        let zenPrivate = try XCTUnwrap(browserChooserPrivateButton(in: zen))

        sendTab(to: presentation.panel, backwards: true)
        XCTAssertTrue(presentation.panel.firstResponder === zenPrivate)
        sendTab(to: presentation.panel, backwards: true)
        assertFocused(zen, in: presentation.panel)
        XCTAssertEqual(rows.first?.accessibilityValue() as? String, "Not selected")
        XCTAssertTrue(completions.isEmpty)
        presentation.panel.sendEvent(chooserKeyEvent(
            keyCode: 36, characters: "\r", windowNumber: presentation.panel.windowNumber
        ))
        XCTAssertEqual(completions, [OpenDestinationID(browserID: browsers[2].id, mode: .normal)])
    }

    func testFocusedNormalActionWinsOverSubsequentMouseHover() throws {
        let browsers = makeBrowsers()
        var completions: [OpenDestinationID?] = []
        let presentation = try makePresentation(browsers: browsers) { completions.append($0?.id) }
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        defer { presentation.pasteboard.releaseGlobally() }
        let rows = browserChooserRows(in: presentation.view)
        let safari = try XCTUnwrap(rows.first)
        let chrome = try XCTUnwrap(rows.dropFirst().first)
        for _ in 0..<4 { sendTab(to: presentation.panel) }
        assertFocused(chrome, in: presentation.panel)

        safari.mouseEntered(with: chooserMouseEvent(
            location: safari.convert(NSPoint(x: 10, y: 20), to: nil),
            windowNumber: presentation.panel.windowNumber
        ))
        XCTAssertEqual(safari.accessibilityValue() as? String, "Selected")
        XCTAssertTrue(presentation.panel.firstResponder === chrome)
        XCTAssertTrue(chrome.isAccessibilityFocused())
        presentation.panel.sendEvent(chooserKeyEvent(
            keyCode: 36, characters: "\r", windowNumber: presentation.panel.windowNumber
        ))
        XCTAssertEqual(completions, [OpenDestinationID(browserID: browsers[1].id, mode: .normal)])
    }

    func testShiftEnterFromTabbedNormalRowPreservesPrivateContract() throws {
        let browsers = makeBrowsers()
        for browserIndex in [0, 1] {
            for keyCode: UInt16 in [36, 76] {
                var completions: [OpenDestinationID?] = []
                let presentation = try makePresentation(browsers: browsers) { completions.append($0?.id) }
                defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
                defer { presentation.pasteboard.releaseGlobally() }
                let changeCount = presentation.pasteboard.changeCount
                let row = try XCTUnwrap(browserChooserRows(in: presentation.view).dropFirst(browserIndex).first)
                for _ in 0..<(browserIndex + 3) { sendTab(to: presentation.panel) }
                assertFocused(row, in: presentation.panel)
                presentation.panel.sendEvent(chooserKeyEvent(
                    keyCode: keyCode, characters: keyCode == 36 ? "\r" : "\u{3}",
                    modifiers: .shift, windowNumber: presentation.panel.windowNumber
                ))
                if browserIndex == 1 {
                    XCTAssertEqual(completions, [OpenDestinationID(browserID: browsers[1].id, mode: .privateBrowsing)])
                } else {
                    XCTAssertTrue(completions.isEmpty)
                    assertFocused(row, in: presentation.panel)
                }
                XCTAssertEqual(presentation.pasteboard.changeCount, changeCount)
            }
        }
    }

    func testShiftEnterOnFocusedPrivateButtonUsesTheHighlightedBrowser() throws {
        let browsers = makeBrowsers()
        for (keyCode, characters) in [(UInt16(36), "\r"), (76, "\u{3}")] {
            var opened: [OpenDestinationID?] = []
            let presentation = try makePresentation(browsers: browsers, showPanel: true) { opened.append($0?.id) }
            defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
            defer { presentation.pasteboard.releaseGlobally() }
            let panel = presentation.panel
            let rows = browserChooserRows(in: presentation.view)
            let safari = try XCTUnwrap(rows.first)
            let chrome = try XCTUnwrap(rows.dropFirst().first)
            let zen = try XCTUnwrap(rows.last)
            let chromePrivate = try XCTUnwrap(browserChooserPrivateButton(in: chrome))
            XCTAssertTrue(panel.makeFirstResponder(chromePrivate))

            func hover(_ row: NSControl) {
                row.mouseEntered(with: chooserMouseEvent(
                    location: row.convert(NSPoint(x: 10, y: 20), to: nil), windowNumber: panel.windowNumber
                ))
                XCTAssertEqual(row.accessibilityValue() as? String, "Selected")
                XCTAssertTrue(panel.firstResponder === chromePrivate)
            }

            hover(safari)
            XCTAssertTrue(panel.isVisible)
            try pressActivationKey(keyCode, characters: characters, modifiers: .shift, in: panel)
            XCTAssertTrue(panel.isVisible, "Safari 不支持隐私模式，按键后选择器应保持可见")
            XCTAssertTrue(opened.isEmpty)
            XCTAssertTrue(panel.firstResponder === chromePrivate)
            XCTAssertTrue(chromePrivate.isEnabled)

            hover(zen)
            try pressActivationKey(keyCode, characters: characters, modifiers: .shift, in: panel)
            XCTAssertEqual(opened, [OpenDestinationID(browserID: browsers[2].id, mode: .privateBrowsing)])
        }
    }

    func testReopenedForegroundPanelStartsAtChooserAndTabsToCopy() throws {
        let app = NSApplication.shared
        try XCTSkipUnless(app.isRunning && app.activationPolicy() != .prohibited,
                          "此用例需要运行 AppKit 事件循环且可激活的应用宿主")
        let board = NSPasteboard(name: .init("EligoTests.Reopen.\(UUID())"))
        defer { board.releaseGlobally() }
        let controller = ChooserWindowController(appLanguageStore: makeEnglishAppLanguageStore(),
            mouseEvents: ChooserMouseEventSource().events, pasteboard: board)
        var completed: [OpenDestinationID?] = []
        func present(_ browsers: [Browser]) throws -> (panel: NSPanel, view: ChooserView) {
            controller.present(
                link: IncomingLink(url: URL(string: "https://example.com/reopen")!),
                destinations: DestinationCatalog(enabledBrowsers: browsers).destinations,
                recentBrowserID: browsers.last?.id
            ) { completed.append($0?.id) }
            let panel = try XCTUnwrap(app.windows.compactMap { $0 as? NSPanel }.first { $0.delegate === controller })
            let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
            let deadline = Date(timeIntervalSinceNow: 3)
            while (!app.isActive || !panel.isKeyWindow) && Date() < deadline {
                if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                             inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
            XCTAssertTrue(app.isActive)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(app.keyWindow === panel)
            return (panel, view)
        }

        let browsers = (0..<30).map { makeBrowser(name: "Browser \($0)", bundleIdentifier: "test.reopen.\($0)") }
        let first = try present(browsers)
        defer { first.view.onCancel?() }
        let lastRow = try XCTUnwrap(browserChooserRows(in: first.view).last)
        XCTAssertTrue(first.panel.makeFirstResponder(lastRow))
        XCTAssertTrue(first.panel.firstResponder === lastRow)
        first.panel.sendEvent(chooserKeyEvent(keyCode: 53, characters: "\u{1B}", windowNumber: first.panel.windowNumber))
        XCTAssertEqual(completed, [nil])
        XCTAssertFalse(first.panel.isVisible)

        let reopened = try present([browsers[29], browsers[0]])
        defer { reopened.view.onCancel?() }
        XCTAssertFalse(reopened.panel === first.panel)
        XCTAssertTrue(reopened.panel.firstResponder === reopened.view)
        sendTab(to: reopened.panel)
        XCTAssertEqual((reopened.panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.copyLink")
        XCTAssertEqual(completed, [nil])
    }

    func testTabFocusRevealsOffscreenNormalRowAndArrowNavigationResumesSelection() throws {
        let browsers = (0..<30).map { makeBrowser(name: "Browser \($0)", bundleIdentifier: "test.focus.\($0)") }
        var completions: [OpenDestinationID?] = []
        let presentation = try makePresentation(browsers: browsers) { completions.append($0?.id) }
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        defer { presentation.pasteboard.releaseGlobally() }
        let rows = browserChooserRows(in: presentation.view)
        let last = try XCTUnwrap(rows.last)
        // Copy, then all thirty Normal actions (these browsers have no Private action).
        for _ in 0...(browsers.count + 1) { sendTab(to: presentation.panel) }
        assertFocused(last, in: presentation.panel)
        XCTAssertTrue(last.visibleRect.contains(last.bounds))
        presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
        presentation.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(last.visibleRect.contains(last.bounds))

        presentation.panel.sendEvent(chooserKeyEvent(
            keyCode: 126, characters: "\u{F700}", windowNumber: presentation.panel.windowNumber
        ))
        XCTAssertTrue(presentation.panel.firstResponder === presentation.view)
        XCTAssertFalse(last.isAccessibilityFocused())
        let previous = try XCTUnwrap(rows.dropLast().last)
        XCTAssertEqual(previous.accessibilityValue() as? String, "Selected")
        XCTAssertTrue(previous.visibleRect.contains(previous.bounds))
        presentation.panel.sendEvent(chooserKeyEvent(
            keyCode: 36, characters: "\r", windowNumber: presentation.panel.windowNumber
        ))
        XCTAssertEqual(completions, [OpenDestinationID(browserID: browsers[28].id, mode: .normal)])
    }

    private func pressActivationKey(
        _ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in panel: NSPanel
    ) throws {
        panel.sendEvent(chooserKeyEvent(
            keyCode: keyCode, characters: characters, modifiers: modifiers, windowNumber: panel.windowNumber
        ))
        panel.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )))
    }

    private func sendTab(to panel: NSPanel, backwards: Bool = false) {
        panel.sendEvent(chooserKeyEvent(
            keyCode: 48, characters: backwards ? "\u{19}" : "\t", modifiers: backwards ? .shift : [],
            windowNumber: panel.windowNumber
        ))
    }

    private func assertFocused(_ row: NSControl, in panel: NSPanel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(panel.firstResponder === row, file: file, line: line)
        XCTAssertTrue(row.isAccessibilityFocused(), file: file, line: line)
        XCTAssertEqual(row.accessibilityValue() as? String, "Selected", file: file, line: line)
        XCTAssertEqual(row.focusRingType, .exterior, file: file, line: line)
        XCTAssertFalse(row.focusRingMaskBounds.isEmpty, file: file, line: line)
    }

    private func makeBrowsers() -> [Browser] {
        [
            makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen")
        ]
    }

    private func makePresentation(
        browsers: [Browser], onCreateRule: ((String, OpenDestination) -> Void)? = nil,
        showPanel: Bool = false,
        completion: @escaping (OpenDestination?) -> Void
    ) throws -> (controller: ChooserWindowController, panel: NSPanel, view: ChooserView, pasteboard: NSPasteboard) {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("EligoTests.Focus.\(UUID())"))
        board.setString("keep clipboard", forType: .string)
        var displayedPanel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panel in
                displayedPanel = panel
                if showPanel { panel.orderFront(nil) }
            },
            screenGeometry: { (NSRect(x: 0, y: 0, width: 1280, height: 720), NSPoint(x: 640, y: 360)) },
            mouseEvents: ChooserMouseEventSource().events, pasteboard: board
        )
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com/focus")!),
            destinations: DestinationCatalog(enabledBrowsers: browsers).destinations,
            recentBrowserID: browsers.first?.id, onCreateRule: onCreateRule, completion: completion
        )
        let panel = try XCTUnwrap(displayedPanel)
        let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
        panel.contentView?.layoutSubtreeIfNeeded()
        return (controller, panel, view, board)
    }
}
