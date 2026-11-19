import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ChooserViewportTests: XCTestCase {
    func testArrowAndLetterNavigationReturnsKeyboardFocusToTheVisibleSelection() throws {
        for (recentIndex, privateIndex, keyCode, characters, selectedIndex) in [
            (0, 29, UInt16(125), "\u{F701}", 1),
            (29, 0, UInt16(126), "\u{F700}", 28),
            (0, 29, UInt16(11), "b", 1)
        ] {
            let presentation = try makePresentation(rowCount: 30, recentIndex: recentIndex, privateIndex: privateIndex)
            defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
            let rows = browserChooserRows(in: presentation.view)
            let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: rows[privateIndex]))
            XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))
            XCTAssertTrue(rows[privateIndex].visibleRect.contains(rows[privateIndex].bounds))

            presentation.panel.sendEvent(chooserKeyEvent(
                keyCode: keyCode,
                characters: characters,
                windowNumber: presentation.panel.windowNumber
            ))

            XCTAssertTrue(rows[selectedIndex].visibleRect.contains(rows[selectedIndex].bounds))
            XCTAssertTrue(presentation.panel.firstResponder === presentation.view)
            presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
            presentation.panel.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(rows[selectedIndex].visibleRect.contains(rows[selectedIndex].bounds))

            var chosen: OpenDestinationID?
            presentation.view.onSelect = { chosen = $0.id }
            presentation.panel.sendEvent(chooserKeyEvent(
                keyCode: 36,
                characters: "\r",
                windowNumber: presentation.panel.windowNumber
            ))
            XCTAssertEqual(chosen, OpenDestinationID(browserID: "test.browser.\(selectedIndex)", mode: .normal))
        }
    }

    func testRejectedShiftEnterKeepsTheFocusedPrivateRowVisible() throws {
        let presentation = try makePresentation(rowCount: 30, recentIndex: 29, privateIndex: 0)
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        let row = try XCTUnwrap(browserChooserRows(in: presentation.view).first)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: row))
        XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))

        presentation.panel.sendEvent(chooserKeyEvent(
            keyCode: 36, characters: "\r", modifiers: .shift, windowNumber: presentation.panel.windowNumber
        ))

        XCTAssertTrue(presentation.panel.firstResponder === privateButton)
        XCTAssertTrue(row.visibleRect.contains(row.bounds))
        presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
        presentation.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.visibleRect.contains(row.bounds))
    }

    func testResizeKeepsTheMostRecentlyFocusedActionVisibleAcrossFocusKinds() throws {
        let presentation = try makePresentation(rowCount: 30, privateIndex: 0)
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        let rows = browserChooserRows(in: presentation.view)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: rows[0]))
        XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))
        rows[29].setAccessibilityFocused(true)

        presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
        presentation.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))

        XCTAssertTrue(presentation.panel.makeFirstResponder(presentation.view))
        XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))
        presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 500))
        presentation.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(rows[0].visibleRect.contains(rows[0].bounds))
    }

    func testResizingPreservesAccessibilityAndKeyboardFocusedRows() throws {
        for focusKind in 0..<3 {
            let presentation = try makePresentation(rowCount: 30, privateIndex: 29)
            defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
            let lastRow = try XCTUnwrap(browserChooserRows(in: presentation.view).last)
            let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: lastRow))
            switch focusKind {
            case 0: lastRow.setAccessibilityFocused(true)
            case 1: privateButton.setAccessibilityFocused(true)
            default: XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))
            }
            XCTAssertTrue(lastRow.visibleRect.contains(lastRow.bounds))

            presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
            presentation.panel.contentView?.layoutSubtreeIfNeeded()

            XCTAssertTrue(lastRow.visibleRect.contains(lastRow.bounds), "Focus kind \(focusKind) must remain visible after resize")
        }
    }

    func testShortChooserStaysCompactAndSourceContextStaysOutsideTheScrollArea() throws {
        let plain = try makePresentation(rowCount: 1)
        let sourced = try makePresentation(rowCount: 1, source: .unknown)
        defer {
            withExtendedLifetime((plain.controller, sourced.controller)) {
                plain.view.onCancel?()
                sourced.view.onCancel?()
            }
        }
        XCTAssertEqual(plain.panel.frame.height, 146)
        XCTAssertEqual(sourced.panel.frame.height, 164)
        XCTAssertEqual(plain.panel.frame.size, plain.view.preferredSize)
        XCTAssertEqual(sourced.view.displaySource, "Unknown source")
        XCTAssertNotNil(sourced.view.subviews.first { $0 is LinkSourceView })
        for context in sourced.view.subviews where !(context is NSScrollView) {
            XCTAssertTrue(context.visibleRect.contains(context.bounds))
        }
    }

    func testReorderedSmallerPresentationUsesFreshScreenGeometryAndScrollPosition() throws {
        let browsers = (0..<30).map {
            makeBrowser(name: "Browser \($0)", bundleIdentifier: "test.browser.\($0)")
        }
        var visibleFrame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        var panels: [NSPanel] = []
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { panels.append($0) },
            screenGeometry: { (visibleFrame, NSPoint(x: visibleFrame.minX + 4, y: visibleFrame.minY + 4)) },
            mouseEvents: ChooserMouseEventSource().events
        )
        defer { withExtendedLifetime(controller) { browserChooserView(in: panels.last?.contentView)?.onCancel?() } }
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: browsers.map { OpenDestination(browser: $0, mode: .normal) },
            recentBrowserID: browsers[29].id
        ) { _ in }
        let oldView = try XCTUnwrap(browserChooserView(in: panels[0].contentView))
        let oldScroll = try XCTUnwrap(oldView.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(oldScroll.contentView.bounds.minY, 0)
        let oldRow = try XCTUnwrap(browserChooserRows(in: oldView).last)
        XCTAssertTrue(panels[0].makeFirstResponder(oldRow))

        visibleFrame = NSRect(x: -1600, y: 900, width: 1600, height: 500)
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!, source: .unknown),
            destinations: [browsers[29], browsers[0]].map { OpenDestination(browser: $0, mode: .normal) },
            recentBrowserID: browsers[0].id
        ) { _ in }
        let panel = try XCTUnwrap(panels.last)
        let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let rows = browserChooserRows(in: view)
        XCTAssertTrue(panel.firstResponder === view)
        panel.sendEvent(chooserKeyEvent(keyCode: 48, characters: "\t", windowNumber: panel.windowNumber))
        XCTAssertEqual((panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.copyLink")
        XCTAssertTrue(visibleFrame.insetBy(dx: 8, dy: 8).contains(panel.frame))
        XCTAssertEqual(panel.maxSize.height, 484)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(rows.map { $0.accessibilityLabel() }, [
            "Open Browser 29 normally, Chooser shortcut 1", "Open Browser 0 normally, Chooser shortcut 2"
        ])
        XCTAssertTrue(rows.allSatisfy { $0.visibleRect.contains($0.bounds) })
    }

    func testResizingKeepsTheSelectedLastRowVisibleWithoutChangingDocumentHeight() throws {
        let presentation = try makePresentation(rowCount: 30, recentIndex: 29)
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        let lastRow = try XCTUnwrap(browserChooserRows(in: presentation.view).last)
        let document = try XCTUnwrap(lastRow.superview)
        let originalHeight = document.frame.height

        presentation.panel.setContentSize(NSSize(width: presentation.panel.frame.width, height: 400))
        presentation.panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(lastRow.visibleRect.contains(lastRow.bounds))
        XCTAssertEqual(document.frame.height, originalHeight)
    }

    func testAccessibilityAndKeyboardFocusRevealNormalAndPrivateControls() throws {
        let presentation = try makePresentation(rowCount: 30, privateIndex: 29)
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        let rows = browserChooserRows(in: presentation.view)
        let privateButton = try XCTUnwrap(browserChooserPrivateButton(in: rows[29]))

        rows[29].setAccessibilityFocused(true)
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))
        rows[0].setAccessibilityFocused(true)
        XCTAssertTrue(rows[0].visibleRect.contains(rows[0].bounds))
        privateButton.setAccessibilityFocused(true)
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))
        rows[0].setAccessibilityFocused(true)
        XCTAssertTrue(presentation.panel.makeFirstResponder(privateButton))
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))
    }

    func testInitialLastRowAndArrowNavigationRevealTheirTargets() throws {
        let presentation = try makePresentation(rowCount: 30, recentIndex: 29)
        defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
        let rows = browserChooserRows(in: presentation.view)
        XCTAssertEqual(presentation.panel.frame.height, 704)
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))

        for _ in 0..<29 {
            XCTAssertTrue(presentation.view.handleKeyDown(chooserKeyEvent(keyCode: 126, characters: "\u{F700}")))
        }
        XCTAssertTrue(rows[0].visibleRect.contains(rows[0].bounds))
        for _ in 0..<29 {
            XCTAssertTrue(presentation.view.handleKeyDown(chooserKeyEvent(keyCode: 125, characters: "\u{F701}")))
        }
        XCTAssertTrue(rows[29].visibleRect.contains(rows[29].bounds))
        var selected: OpenDestinationID?
        presentation.view.onSelect = { selected = $0.id }
        XCTAssertTrue(presentation.view.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertEqual(selected, OpenDestinationID(browserID: "test.browser.29", mode: .normal))
    }

    func testEighteenRowsFitShortScreenAndBothEndsRemainClickable() throws {
        try checkLongChooser(rowCount: 18)
    }

    func testThirtyRowsFitShortScreenAndBothEndsRemainClickable() throws {
        try checkLongChooser(rowCount: 30)
    }

    private func checkLongChooser(rowCount: Int) throws {
        let visibleFrame = NSRect(x: -1440, y: -120, width: 1440, height: 720)
        let browsers = (0..<rowCount).map {
            makeBrowser(name: "Browser \($0)", bundleIdentifier: "test.browser.\($0)")
        }
        var panels: [NSPanel] = []
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { panels.append($0) },
            screenGeometry: { (visibleFrame, NSPoint(x: -80, y: 540)) },
            mouseEvents: ChooserMouseEventSource().events
        )
        var selected: [OpenDestinationID] = []
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!, source: .unknown),
            destinations: browsers.map { OpenDestination(browser: $0, mode: .normal) },
            recentBrowserID: nil
        ) { if let destination = $0 { selected.append(destination.id) } }
        let panel = try XCTUnwrap(panels.first)
        let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(visibleFrame.insetBy(dx: 8, dy: 8).contains(panel.frame))
        XCTAssertEqual(panel.frame.height, 704)
        let scrollView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let rows = browserChooserRows(in: view)
        XCTAssertEqual(rows.count, rowCount)
        XCTAssertTrue(rows.allSatisfy { $0.frame.height == 40 })
        XCTAssertTrue(try XCTUnwrap(rows.first).visibleRect.contains(rows[0].bounds))
        let lastRow = try XCTUnwrap(rows.last)
        XCTAssertTrue(lastRow.scrollToVisible(lastRow.bounds))
        XCTAssertTrue(lastRow.visibleRect.contains(lastRow.bounds))
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
        let location = lastRow.convert(NSPoint(x: 3, y: 20), to: nil)
        XCTAssertTrue(panel.contentView?.hitTest(location) === lastRow)
        lastRow.mouseDown(with: chooserMouseEvent(location: location, windowNumber: panel.windowNumber))
        XCTAssertEqual(selected, [OpenDestinationID(browserID: browsers[rowCount - 1].id, mode: .normal)])

        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: browsers.map { OpenDestination(browser: $0, mode: .normal) },
            recentBrowserID: nil
        ) { if let destination = $0 { selected.append(destination.id) } }
        let nextPanel = try XCTUnwrap(panels.last)
        let nextView = try XCTUnwrap(browserChooserView(in: nextPanel.contentView))
        nextPanel.contentView?.layoutSubtreeIfNeeded()
        let firstRow = try XCTUnwrap(browserChooserRows(in: nextView).first)
        XCTAssertTrue(firstRow.visibleRect.contains(firstRow.bounds))
        firstRow.mouseDown(with: chooserMouseEvent(
            location: firstRow.convert(NSPoint(x: 3, y: 20), to: nil),
            windowNumber: nextPanel.windowNumber
        ))
        XCTAssertEqual(selected.last, OpenDestinationID(browserID: browsers[0].id, mode: .normal))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(nextPanel.isVisible)
    }

    private func makePresentation(rowCount: Int, recentIndex: Int? = nil, privateIndex: Int? = nil, source: LinkSource? = nil) throws -> (
        controller: ChooserWindowController, panel: NSPanel, view: ChooserView
    ) {
        let browsers = (0..<rowCount).map {
            makeBrowser(
                name: $0 == privateIndex ? "Google Chrome" : "Browser \($0)",
                bundleIdentifier: $0 == privateIndex ? "com.google.Chrome" : "test.browser.\($0)"
            )
        }
        var displayedPanel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { displayedPanel = $0 },
            screenGeometry: { (NSRect(x: 0, y: 0, width: 1280, height: 720), NSPoint(x: 640, y: 360)) },
            mouseEvents: ChooserMouseEventSource().events
        )
        var destinations = browsers.map { OpenDestination(browser: $0, mode: .normal) }
        if let privateIndex {
            destinations.append(OpenDestination(browser: browsers[privateIndex], mode: .privateBrowsing))
        }
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!, source: source),
            destinations: destinations,
            recentBrowserID: recentIndex.map { browsers[$0].id }
        ) { _ in }
        let panel = try XCTUnwrap(displayedPanel)
        let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
        panel.contentView?.layoutSubtreeIfNeeded()
        return (controller, panel, view)
    }
}
