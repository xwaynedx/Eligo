import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ChooserURLCopyTests: XCTestCase {
    func testCopyUsesOriginalFullURLWithoutChoosingOrCancelling() throws {
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        for string in [
            "http://localhost:8095/a%20b?q=one%26two&x=3#section",
            "https://example.com/路径?query=value#fragment",
            "file:///tmp/a%20b.html"
        ] {
            let url = try XCTUnwrap(URL(string: string))
            let view = ChooserView(link: IncomingLink(url: url), destinations: [], recentBrowserID: nil, pasteboard: pasteboard)
            var selections = 0
            var cancellations = 0
            view.onSelect = { _ in selections += 1 }
            view.onCancel = { cancellations += 1 }
            let button = try copyButton(in: view)
            XCTAssertEqual(button.accessibilityLabel(), "Copy Full Link")
            button.performClick(nil)
            XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
            XCTAssertEqual(selections, 0)
            XCTAssertEqual(cancellations, 0)
            XCTAssertEqual(button.toolTip, "Link copied")
            view.onSelect = nil
            XCTAssertFalse(button.isEnabled)
            let completedChangeCount = pasteboard.changeCount
            XCTAssertFalse(button.accessibilityPerformPress())
            XCTAssertEqual(pasteboard.changeCount, completedChangeCount)
        }
    }

    func testCopyFeedbackRestartsOnRepeatedClickAndRestoresLocalizedAction() async throws {
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let view = ChooserView(
            link: IncomingLink(url: URL(string: "https://example.com/path?q=1")!),
            destinations: [], recentBrowserID: nil, language: .simplifiedChinese, pasteboard: pasteboard
        )
        view.onSelect = { _ in XCTFail("Copy must not open a browser") }
        let button = try copyButton(in: view)
        XCTAssertEqual(button.toolTip, "复制完整链接")
        XCTAssertEqual(button.accessibilityLabel(), "复制完整链接")
        button.performClick(nil)
        XCTAssertEqual(button.accessibilityValue() as? String, "已复制链接")
        try await Task.sleep(for: .milliseconds(650))
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(button.toolTip, "已复制链接", "A second click must restart the feedback duration")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while button.toolTip != "复制完整链接", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(button.toolTip, "复制完整链接")
        XCTAssertNil(button.accessibilityValue())
        withExtendedLifetime(view) {}
    }

    func testExpandedURLWrapsInScrollableChildWindowWithoutChangingChooserSize() throws {
        _ = NSApplication.shared
        let url = URL(string: "https://example.com/" + String(repeating: "long-path/", count: 100) + "?q=one%26two#fragment")!
        let view = ChooserView(link: IncomingLink(url: url), destinations: [], recentBrowserID: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.closeURLPreview(); window.close() }
        let copy = try copyButton(in: view)
        let title = try XCTUnwrap(copy.superview)
        let label = try XCTUnwrap(title.subviews.compactMap { $0 as? NSTextField }.first)
        for width: CGFloat in [268, 380] {
            window.setContentSize(NSSize(width: width, height: view.preferredSize.height))
            view.layoutSubtreeIfNeeded()
            let size = window.frame.size
            let copyFrame = copy.frame
            _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: "", modifiers: .option))
            let preview = try XCTUnwrap(window.childWindows?.first)
            preview.contentView?.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(preview.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            text.layoutManager?.ensureLayout(for: try XCTUnwrap(text.textContainer))
            XCTAssertEqual(text.string, url.absoluteString)
            XCTAssertTrue(text.isSelectable)
            XCTAssertFalse(text.isEditable)
            XCTAssertTrue(scroll.hasVerticalScroller)
            XCTAssertTrue(text.textContainer?.widthTracksTextView == true)
            XCTAssertGreaterThan(try XCTUnwrap(text.layoutManager?.usedRect(for: XCTUnwrap(text.textContainer))).height, scroll.contentSize.height)
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertEqual(window.frame.size, size)
            XCTAssertEqual(copy.frame, copyFrame)
            _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: ""))
            XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        }
    }

    func testPinnedURLPreviewSurvivesOptionReleaseAndEscapeReturnsToChooser() throws {
        let pasteboard = NSPasteboard(name: .init("EligoTests.Preview.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let url = URL(string: "https://example.com/full?x=one%26two#anchor")!
        let view = ChooserView(link: IncomingLink(url: url), destinations: [], recentBrowserID: nil, pasteboard: pasteboard)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.onSelect = { _ in XCTFail("查看链接不能触发打开") }
        var cancellations = 0
        view.onCancel = { cancellations += 1 }
        defer { view.closeURLPreview(); window.close() }
        let copy = try copyButton(in: view)
        let expand = try XCTUnwrap(copy.superview?.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "chooser.expandLink" })
        _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: "", modifiers: .option))
        expand.performClick(nil)
        _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: ""))
        let preview = try XCTUnwrap(window.childWindows?.first)
        let previewCopy = try XCTUnwrap(preview.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Copy Full Link" })
        let text = try previewText(in: window)
        let raw = url.absoluteString as NSString
        XCTAssertEqual(text.textStorage?.attribute(.font, at: raw.range(of: "example.com").location,
                                                   effectiveRange: nil) as? NSFont,
                       .monospacedSystemFont(ofSize: 12, weight: .semibold))
        XCTAssertEqual(text.string, url.absoluteString)
        previewCopy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
        XCTAssertEqual(previewCopy.title, "Link copied")
        XCTAssertTrue(preview.firstResponder === text)
        preview.sendEvent(chooserKeyEvent(keyCode: 53, characters: "\u{1b}", windowNumber: preview.windowNumber))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(view.handleKeyDown(chooserKeyEvent(keyCode: 53, characters: "")))
        XCTAssertEqual(cancellations, 1)
    }

    func testChooserWidthStaysStableAcrossLongHostsPathsAndFileNames() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init("EligoTests.Width.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let browsers = [
            makeBrowser(name: "Firefox Nightly", bundleIdentifier: "org.mozilla.nightly"),
            makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        ]
        let destinations = DestinationCatalog(enabledBrowsers: browsers).destinations
        let baseline = ChooserView(
            link: IncomingLink(url: URL(string: "https://github.com")!), destinations: destinations,
            recentBrowserID: nil, pasteboard: pasteboard
        ).preferredSize.width
        let source = LinkSource.app(AppSender(
            name: String(repeating: "Long source name ", count: 12), bundleIdentifier: "test.long-source", appURL: nil
        ))
        for string in [
            "https://github.com/settings/personal-access-tokens",
            "https://github.com/" + String(repeating: "long-path/", count: 40) + "?q=1#fragment",
            "http://" + String(repeating: "long-subdomain.", count: 8) + "example.com:8095/a?q=1#fragment",
            "file:///tmp/" + String(repeating: "long-file-name-", count: 12) + ".html"
        ] {
            let url = try XCTUnwrap(URL(string: string))
            let view = ChooserView(
                link: IncomingLink(url: url, source: url.isFileURL ? nil : source), destinations: destinations,
                recentBrowserID: nil, pasteboard: pasteboard
            )
            view.onSelect = { _ in XCTFail("Copy must not open a browser") }
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { view.closeURLPreview(); window.close() }
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.preferredSize.width, baseline)
            XCTAssertEqual(window.frame.width, baseline)
            let button = try copyButton(in: view)
            let title = try XCTUnwrap(button.superview)
            let label = try XCTUnwrap(title.subviews.compactMap { $0 as? NSTextField }.first)
            if url.host == "github.com" { XCTAssertEqual(label.stringValue, "https://github.com") }
            let originalSize = window.frame.size
            _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: "", modifiers: .option))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertEqual(try previewText(in: window).string, url.absoluteString)
            XCTAssertEqual(window.frame.size, originalSize)
            XCTAssertTrue(title.bounds.contains(button.frame))
            button.performClick(nil)
            XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
            XCTAssertEqual(window.frame.size, originalSize)
        }
    }

    func testKeyboardFocusCopiesWithEnterAndNavigationReturnsToChooser() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let url = URL(string: "https://example.com/full?query=1#fragment")!
        let view = ChooserView(
            link: IncomingLink(url: url), destinations: DestinationCatalog(enabledBrowsers: [safari]).destinations,
            recentBrowserID: nil, pasteboard: pasteboard
        )
        var selected = 0
        view.onSelect = { _ in selected += 1 }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.closeURLPreview(); window.close() }
        let button = try copyButton(in: view)
        let row = try XCTUnwrap(browserChooserRows(in: view).first)
        XCTAssertTrue(view.nextKeyView === button)
        XCTAssertEqual(button.nextKeyView?.accessibilityIdentifier(), "chooser.expandLink")
        XCTAssertTrue(button.nextKeyView?.nextKeyView === row)
        XCTAssertEqual(row.nextKeyView?.accessibilityIdentifier(), "chooser.createRule")
        XCTAssertTrue(row.nextKeyView?.nextKeyView === view)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(view.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
        XCTAssertEqual(selected, 0)
        XCTAssertTrue(view.handleKeyDown(chooserKeyEvent(keyCode: 125, characters: "\u{F701}")))
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertTrue(view.handleKeyDown(chooserKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertEqual(selected, 1)
    }

    func testContinuousHoverBetweenCopyAndURLKeepsCopyStableAndStillExpands() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let url = URL(string: "https://example.com/" + String(repeating: "long-path/", count: 20))!
        for entersCopyFirst in [true, false] {
            let view = ChooserView(link: IncomingLink(url: url), destinations: [], recentBrowserID: nil, pasteboard: pasteboard)
            view.onSelect = { _ in XCTFail("Copy must not choose a browser") }
            let window = HoverPointerWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { view.closeURLPreview(); window.close() }
            view.layoutSubtreeIfNeeded()
            let button = try copyButton(in: view)
            let title = try XCTUnwrap(button.superview)
            let label = try XCTUnwrap(title.subviews.compactMap { $0 as? NSTextField }.first)
            title.updateTrackingAreas()
            XCTAssertTrue(title.trackingAreas.contains { $0.options.contains(.mouseMoved) },
                          "AppKit must deliver movement within the same title tracking area")
            let compactFrame = button.frame
            let compactLabelWidth = label.frame.width
            let copyPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)
            let urlPoint = NSPoint(x: label.frame.midX, y: label.frame.midY)
            func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
                window.pointerLocation = title.convert(point, to: nil)
                if type == .mouseMoved {
                    return try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: window.pointerLocation, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 0, pressure: 0
                    ))
                }
                return try XCTUnwrap(NSEvent.enterExitEvent(
                    with: type, location: window.pointerLocation, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil
                ))
            }
            title.mouseEntered(with: try event(.mouseEntered, at: entersCopyFirst ? copyPoint : urlPoint))
            if !entersCopyFirst {
                // Cross to Copy before the URL's delay expires, without leaving the header.
                title.mouseMoved(with: try event(.mouseMoved, at: copyPoint))
            }
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertEqual(button.frame, compactFrame)
            button.performClick(nil)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(button.frame, compactFrame, "The checkmark must not move Copy")
            XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)

            // Both trajectories return to URL via mouseMoved, never a synthetic exit/re-entry.
            title.mouseMoved(with: try event(.mouseMoved, at: urlPoint))
            _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 56, characters: "", modifiers: .shift))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while window.childWindows?.isEmpty ?? true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(try previewText(in: window).string, url.absoluteString)
            _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 56, characters: ""))
            XCTAssertEqual(try previewText(in: window).string, url.absoluteString)
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertEqual(label.frame.width, compactLabelWidth)
            XCTAssertEqual(button.frame, compactFrame)
            let expandedFrame = button.frame
            title.mouseMoved(with: try event(.mouseMoved, at: NSPoint(x: button.frame.midX, y: button.frame.midY)))
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertTrue(window.childWindows?.isEmpty ?? true)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(button.frame, expandedFrame)
            title.mouseExited(with: try event(.mouseExited, at: NSPoint(x: title.bounds.maxX + 1, y: title.bounds.midY)))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(label.stringValue, view.displayURL)
            XCTAssertEqual(button.frame, compactFrame)
        }
    }

    private func previewText(in window: NSWindow) throws -> NSTextView {
        let preview = try XCTUnwrap(window.childWindows?.first)
        let scroll = try XCTUnwrap(preview.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        return try XCTUnwrap(scroll.documentView as? NSTextView)
    }

    private func copyButton(in view: NSView) throws -> NSButton {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        return try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "chooser.copyLink"
        })
    }

    func testProductionPanelShiftEnterFromCopyPreservesPrivateContract() throws {
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        for browser in [
            makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        ] {
            for keyCode: UInt16 in [36, 76] {
                pasteboard.clearContents()
                pasteboard.setString("keep clipboard", forType: .string)
                let changeCount = pasteboard.changeCount
                var completions: [OpenDestinationID?] = []
                let presentation = try makePresentation(browser: browser, pasteboard: pasteboard) {
                    completions.append($0?.id)
                }
                defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
                XCTAssertTrue(presentation.panel.makeFirstResponder(presentation.copy))
                presentation.panel.sendEvent(chooserKeyEvent(
                    keyCode: keyCode, characters: keyCode == 36 ? "\r" : "\u{3}",
                    modifiers: .shift, windowNumber: presentation.panel.windowNumber
                ))
                if browser.bundleIdentifier == "com.google.Chrome" {
                    XCTAssertEqual(completions, [OpenDestinationID(browserID: browser.id, mode: .privateBrowsing)])
                    XCTAssertFalse(presentation.copy.isEnabled)
                } else {
                    XCTAssertTrue(completions.isEmpty)
                    XCTAssertTrue(presentation.copy.isEnabled)
                }
                XCTAssertEqual(pasteboard.changeCount, changeCount, "Shift+Enter must never copy, even without Private support")
                XCTAssertEqual(pasteboard.string(forType: .string), "keep clipboard")
            }
        }
    }

    func testProductionPanelDispatchesCopyKeysNavigationAndCancellation() throws {
        let pasteboard = NSPasteboard(name: .init("EligoTests.Copy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        for (keyCode, characters) in [(UInt16(36), "\r"), (76, "\u{3}"), (49, " ")] {
            var completions: [OpenDestinationID?] = []
            let presentation = try makePresentation(browser: safari, pasteboard: pasteboard) { completions.append($0?.id) }
            defer { withExtendedLifetime(presentation.controller) { presentation.view.onCancel?() } }
            XCTAssertTrue(presentation.panel.makeFirstResponder(presentation.copy))
            pasteboard.clearContents()
            presentation.panel.sendEvent(chooserKeyEvent(
                keyCode: keyCode, characters: characters, windowNumber: presentation.panel.windowNumber
            ))
            let copiedChangeCount = pasteboard.changeCount
            presentation.panel.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: presentation.panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )))
            XCTAssertEqual(pasteboard.changeCount, copiedChangeCount, "Key-up must not copy a second time")
            XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/full?query=1#fragment")
            XCTAssertTrue(completions.isEmpty)
            XCTAssertTrue(presentation.copy.isEnabled)
            pasteboard.clearContents()
            XCTAssertTrue(presentation.copy.accessibilityPerformPress())
            XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/full?query=1#fragment")
            XCTAssertTrue(completions.isEmpty)
            presentation.panel.sendEvent(chooserKeyEvent(
                keyCode: 48, characters: "\t", windowNumber: presentation.panel.windowNumber
            ))
            XCTAssertEqual((presentation.panel.firstResponder as? NSView)?.accessibilityIdentifier(), "chooser.expandLink")
            presentation.panel.sendEvent(chooserKeyEvent(keyCode: 48, characters: "\t", windowNumber: presentation.panel.windowNumber))
            XCTAssertTrue(presentation.panel.firstResponder === browserChooserRows(in: presentation.view).first)
            for (navigationCode, navigationCharacter) in [(UInt16(125), "\u{F701}"), (1, "s")] {
                XCTAssertTrue(presentation.panel.makeFirstResponder(presentation.copy))
                presentation.panel.sendEvent(chooserKeyEvent(
                    keyCode: navigationCode, characters: navigationCharacter, windowNumber: presentation.panel.windowNumber
                ))
                XCTAssertTrue(presentation.panel.firstResponder === presentation.view)
                XCTAssertTrue(completions.isEmpty)
            }
            XCTAssertTrue(presentation.panel.makeFirstResponder(presentation.copy))
            presentation.panel.sendEvent(chooserKeyEvent(
                keyCode: 53, characters: "\u{1B}", windowNumber: presentation.panel.windowNumber
            ))
            XCTAssertEqual(completions, [nil])
            XCTAssertFalse(presentation.copy.isEnabled)
            let completedChangeCount = pasteboard.changeCount
            XCTAssertFalse(presentation.copy.accessibilityPerformPress())
            XCTAssertEqual(pasteboard.changeCount, completedChangeCount)
        }
    }

    private func makePresentation(
        browser: Browser, pasteboard: NSPasteboard, completion: @escaping (OpenDestination?) -> Void
    ) throws -> (controller: ChooserWindowController, panel: NSPanel, view: ChooserView, copy: NSButton) {
        _ = NSApplication.shared
        var displayedPanel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { displayedPanel = $0 },
            mouseEvents: ChooserMouseEventSource().events, pasteboard: pasteboard
        )
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com/full?query=1#fragment")!),
            destinations: DestinationCatalog(enabledBrowsers: [browser]).destinations,
            recentBrowserID: nil, completion: completion
        )
        let panel = try XCTUnwrap(displayedPanel)
        let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
        panel.contentView?.layoutSubtreeIfNeeded()
        return (controller, panel, view, try copyButton(in: view))
    }
}

/// Keep the event coordinates and fire-time pointer sample consistent without moving the user's cursor.
@MainActor
private final class HoverPointerWindow: NSWindow {
    var pointerLocation: NSPoint = .zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}
