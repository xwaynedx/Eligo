import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ChooserPresentationLifecycleTests: XCTestCase {
    func testURLPreviewClicksDoNotCancelPendingLink() throws {
        let mouse = ChooserMouseEventSource()
        var panel: NSPanel?
        let controller = ChooserWindowController(appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { panel = $0 }, mouseEvents: mouse.events, now: { mouse.now })
        var completions = 0
        present(controller) { _ in completions += 1 }
        let parent = try XCTUnwrap(panel)
        let view = try XCTUnwrap(browserChooserView(in: parent.contentView))
        _ = view.handleFlagsChanged(chooserKeyEvent(keyCode: 58, characters: "", modifiers: .option))
        let preview = try XCTUnwrap(parent.childWindows?.first)
        let click = mouse.click(in: preview, at: mouse.now + 1)
        _ = mouse.localHandlers[0](click)
        mouse.globalHandlers[0](click)
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(mouse.removed.isEmpty)
        view.onCancel?()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }

    func testPanelInputDeliversEnterShiftEnterAndEscapeOnce() throws {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        for privateFocused in [false, true] {
            let plainMode: OpeningMode = privateFocused ? .privateBrowsing : .normal
            let keys: [(UInt16, String, NSEvent.ModifierFlags, OpeningMode?)] = [
                (36, "\r", [], plainMode), (76, "\u{3}", [], plainMode),
                (36, "\r", .shift, .privateBrowsing), (76, "\u{3}", .shift, .privateBrowsing),
                (53, "\u{1B}", [], nil)
            ]
            for (keyCode, characters, modifiers, expectedMode) in keys {
                var displayedPanel: NSPanel?
                let controller = ChooserWindowController(
                    appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { displayedPanel = $0 },
                    mouseEvents: ChooserMouseEventSource().events
                )
                var selected: [OpenDestinationID?] = []
                controller.present(
                    link: IncomingLink(url: URL(string: "https://example.com")!),
                    destinations: DestinationCatalog(enabledBrowsers: [chrome]).destinations,
                    recentBrowserID: nil
                ) { selected.append($0?.id) }
                let panel = try XCTUnwrap(displayedPanel)
                let view = try XCTUnwrap(browserChooserView(in: panel.contentView))
                defer { withExtendedLifetime(controller) { view.onCancel?() } }
                if privateFocused {
                    let row = try XCTUnwrap(browserChooserRows(in: view).first)
                    XCTAssertTrue(panel.makeFirstResponder(try XCTUnwrap(browserChooserPrivateButton(in: row))))
                }

                panel.sendEvent(chooserKeyEvent(
                    keyCode: keyCode, characters: characters, modifiers: modifiers,
                    windowNumber: panel.windowNumber
                ))

                XCTAssertEqual(selected, [expectedMode.map { OpenDestinationID(browserID: chrome.id, mode: $0) }])
                XCTAssertNil(view.onSelect)
                XCTAssertNil(view.onCancel)
                XCTAssertTrue(browserChooserRows(in: view).allSatisfy { !$0.isEnabled })
            }
        }
    }

    func testOldSelectionAndEscapeCallbacksCannotEndNextPresentation() throws {
        var panels: [NSPanel] = []
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panels.append($0) },
            mouseEvents: ChooserMouseEventSource().events
        )
        var results: [Int] = []
        present(controller) { _ in results.append(1) }
        let oldView = try XCTUnwrap(browserChooserView(in: panels[0].contentView))
        present(controller) { _ in results.append(2) }
        oldView.onCancel?()
        oldView.onSelect?(OpenDestination(browser: makeBrowser(name: "Test", bundleIdentifier: "test.browser"), mode: .normal))
        XCTAssertEqual(results, [1])
        let currentView = try XCTUnwrap(browserChooserView(in: panels[1].contentView))
        currentView.onCancel?()
        XCTAssertEqual(results, [1, 2])
    }

    func testOldWindowResignationCannotCancelNextPresentation() throws {
        var panels: [NSPanel] = []
        let mouse = ChooserMouseEventSource()
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(),
            displayPanel: { panels.append($0) }, mouseEvents: mouse.events, now: { mouse.now }
        )
        var results: [Int] = []
        present(controller) { _ in results.append(1) }
        present(controller) { _ in results.append(2) }
        XCTAssertEqual(results, [1])

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panels[0]))
        XCTAssertEqual(results, [1])
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panels[1]))
        XCTAssertEqual(results, [1]) // Current focus loss is not proof of a user click either.
        mouse.globalHandlers[1](mouse.click())
        XCTAssertEqual(results, [1, 2])
    }

    func testOutsideClicksCancelOnceForEveryMouseButtonWithOrWithoutKeyFocus() throws {
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            for global in [false, true] {
                let mouse = ChooserMouseEventSource()
                var panel: NSPanel?
                let controller = ChooserWindowController(
                    appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panel = $0 },
                    mouseEvents: mouse.events, now: { mouse.now }
                )
                var cancellations = 0
                present(controller) { destination in
                    XCTAssertNil(destination)
                    XCTAssertEqual(mouse.removed, [1, 2]) // Removed before completion can show another link.
                    cancellations += 1
                }
                let current = try XCTUnwrap(panel)
                controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: current))
                XCTAssertEqual(cancellations, 0)
                let other = NSPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
                let event = mouse.click(type, in: other)
                for _ in 0..<2 {
                    if global { mouse.globalHandlers[0](event) }
                    else { XCTAssertTrue(mouse.localHandlers[0](event) === event) }
                }
                XCTAssertEqual(cancellations, 1)
                XCTAssertEqual(mouse.masks, Array(repeating: [.leftMouseDown, .rightMouseDown, .otherMouseDown], count: 2))
            }
        }
    }

    func testInsideAndPredatingClicksDoNotDismissOrSwallowInput() throws {
        let mouse = ChooserMouseEventSource()
        var panel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panel = $0 },
            mouseEvents: mouse.events, now: { mouse.now }
        )
        var completions = 0
        present(controller) { _ in completions += 1 }
        let current = try XCTUnwrap(panel)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let inside = mouse.click(type, in: current)
            XCTAssertTrue(mouse.localHandlers[0](inside) === inside)
            for timestamp in [mouse.now - 1, mouse.now] {
                let old = mouse.click(type, at: timestamp)
                mouse.globalHandlers[0](old)
                XCTAssertTrue(mouse.localHandlers[0](old) === old)
            }
        }
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(mouse.removed.isEmpty)
        current.sendEvent(chooserKeyEvent(keyCode: 53, characters: "\u{1B}", windowNumber: current.windowNumber))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(mouse.removed, [1, 2])
    }

    func testStaleOutsideClickCallbacksCannotCancelNextPresentation() throws {
        let mouse = ChooserMouseEventSource()
        var panels: [NSPanel] = []
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panels.append($0) },
            mouseEvents: mouse.events, now: { mouse.now }
        )
        var results: [Int] = []
        present(controller) { _ in results.append(1) }
        mouse.now = 200
        present(controller) { _ in results.append(2) }
        XCTAssertEqual(mouse.removed, [1, 2])
        mouse.globalHandlers[0](mouse.click())
        _ = mouse.localHandlers[0](mouse.click())
        mouse.globalHandlers[1](mouse.click(at: 199)) // Delayed delivery to the new monitor.
        XCTAssertEqual(results, [1])
        mouse.globalHandlers[1](mouse.click())
        XCTAssertEqual(results, [1, 2])
        XCTAssertEqual(mouse.removed, [1, 2, 3, 4])
    }

    func testOwnWindowClickReportedByBothMonitorsKeepsPrivateButtonAction() throws {
        for globalFirst in [false, true] {
            let mouse = ChooserMouseEventSource()
            var panel: NSPanel?
            let controller = ChooserWindowController(
                appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panel = $0 },
                mouseEvents: mouse.events, now: { mouse.now }
            )
            let zen = makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen")
            var results: [OpenDestinationID?] = []
            controller.present(
                link: IncomingLink(url: URL(string: "https://example.com")!),
                destinations: DestinationCatalog(enabledBrowsers: [zen]).destinations,
                recentBrowserID: nil
            ) { results.append($0?.id) }
            let current = try XCTUnwrap(panel)
            let view = try XCTUnwrap(browserChooserView(in: current.contentView))
            let row = try XCTUnwrap(browserChooserRows(in: view).first)
            let button = try XCTUnwrap(browserChooserPrivateButton(in: row))

            // The failed native runs delivered the same window/event through
            // both monitors before the Private button could send its action.
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                let localEvent = mouse.click(type, in: current)
                let globalCopy = mouse.click(type, in: current)
                XCTAssertFalse(localEvent === globalCopy)
                if globalFirst { mouse.globalHandlers[0](globalCopy) }
                XCTAssertTrue(mouse.localHandlers[0](localEvent) === localEvent)
                if !globalFirst { mouse.globalHandlers[0](globalCopy) }
            }
            XCTAssertTrue(results.isEmpty)
            XCTAssertTrue(mouse.removed.isEmpty)
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil) // Exercise the production target/action.
            XCTAssertEqual(results, [OpenDestinationID(browserID: zen.id, mode: .privateBrowsing)])
            XCTAssertEqual(mouse.removed, [1, 2])
        }
    }

    func testOneOutsideClickCannotCancelSynchronousNextPresentation() throws {
        let mouse = ChooserMouseEventSource()
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { _ in },
            mouseEvents: mouse.events, now: { mouse.now }
        )
        var completions = 0
        present(controller) { _ in
            completions += 1
            self.present(controller) { _ in completions += 1 }
        }
        let firstClick = mouse.click(at: 101)
        mouse.now = 102 // The queued event is older than the next presentation.
        mouse.globalHandlers[0](firstClick)
        mouse.globalHandlers[1](firstClick)
        XCTAssertEqual(completions, 1)
        mouse.globalHandlers[1](mouse.click(at: 103))
        XCTAssertEqual(completions, 2)
    }

    func testRuleActionTearsDownClickMonitorsBeforeOpeningSettings() throws {
        let mouse = ChooserMouseEventSource()
        var panel: NSPanel?
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { panel = $0 },
            mouseEvents: mouse.events
        )
        var completions = 0
        var ruleActions = 0
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: [OpenDestination(browser: makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen"), mode: .normal)],
            recentBrowserID: nil,
            onCreateRule: { _, _ in
                XCTAssertEqual(mouse.removed, [1, 2])
                ruleActions += 1
            }
        ) { _ in completions += 1 }
        let view = try XCTUnwrap(browserChooserView(in: panel?.contentView))
        view.onCreateRule?("example.com", OpenDestination(
            browser: makeBrowser(name: "Zen", bundleIdentifier: "app.zen-browser.zen"), mode: .privateBrowsing
        ))
        XCTAssertEqual(completions, 0, "创建规则不能结束当前链接")
        XCTAssertEqual(ruleActions, 1)
    }

    func testControllerReleaseRemovesBothClickMonitors() {
        let mouse = ChooserMouseEventSource()
        weak var released: ChooserWindowController?
        // AppKit can autorelease temporary delegate references while building a
        // window. Check ownership after those references have actually drained.
        autoreleasepool {
            let controller = ChooserWindowController(
                appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { _ in }, mouseEvents: mouse.events
            )
            released = controller
            present(controller) { _ in XCTFail("Releasing a controller must not consume a URL") }
        }
        XCTAssertNil(released)
        XCTAssertEqual(mouse.removed, [1, 2])
    }

    func testNativeLocalMonitorCancelsOutsideClickWithoutSwallowingItsDelivery() throws {
        let mouse = ChooserMouseEventSource()
        let native = ChooserMouseEvents()
        // Exercise NSApplication -> real NSEvent local monitor -> controller.
        // Only the cross-application listener is isolated from the user's input.
        let events = ChooserMouseEvents(
            addLocal: native.addLocal,
            addGlobal: mouse.events.addGlobal,
            remove: { token in
                if token is Int { mouse.events.remove(token) }
                else { native.remove(token) }
            }
        )
        let controller = ChooserWindowController(
            appLanguageStore: makeEnglishAppLanguageStore(), displayPanel: { _ in }, mouseEvents: events
        )
        var cancellations = 0
        present(controller) { _ in cancellations += 1 }
        let receiver = ClickReceivingPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let event = mouse.click(in: receiver, at: ProcessInfo.processInfo.systemUptime + 1)
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(receiver.received.count, 1)
        XCTAssertTrue(receiver.received.first === event)
    }

    private func present(_ controller: ChooserWindowController, completion: @escaping (OpenDestination?) -> Void) {
        controller.present(
            link: IncomingLink(url: URL(string: "https://example.com")!),
            destinations: [OpenDestination(browser: makeBrowser(name: "Test", bundleIdentifier: "test.browser"), mode: .normal)],
            recentBrowserID: nil,
            completion: completion
        )
    }
}

@MainActor
private final class ClickReceivingPanel: NSPanel {
    var received: [NSEvent] = []

    override func sendEvent(_ event: NSEvent) {
        received.append(event)
    }
}
