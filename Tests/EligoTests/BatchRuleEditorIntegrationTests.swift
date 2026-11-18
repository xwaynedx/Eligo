import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import Eligo

@MainActor
final class BatchRuleEditorIntegrationTests: XCTestCase {
    func testLargePreviewShowsCompleteInvalidFeedbackBeforeHostRows() async throws {
        let fixture = try BulkSheetFixture()
        defer { fixture.cleanup() }
        let sheet = try await fixture.present()
        let originalSettings = fixture.store.settings
        let originalBytes = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let hosts = (0..<5_000).map { "host\($0).example" }.joined(separator: "\n")
        let text = try fixture.textView(in: sheet)
        text.insertText(hosts + "\nhost0.example bad/path ftp://bad.example/a", replacementRange: NSRange(location: 0, length: 0))
        let feedback = try await fixture.element("Could not recognize: bad/path, ftp://bad.example/a", in: sheet)
        _ = try await fixture.element("5000 valid domains", in: sheet)
        _ = try await fixture.element("Skipped 1 duplicate inputs", in: sheet)
        let firstHost = try await fixture.element("host0.example", in: sheet)
        let errorFrame = fixture.frame(feedback)
        let hostFrame = fixture.frame(firstHost)
        XCTAssertGreaterThan(errorFrame.height, 0)
        XCTAssertGreaterThan(hostFrame.height, 0)
        XCTAssertGreaterThan(errorFrame.midY, hostFrame.midY, "Complete invalid feedback must precede the host list")
        // shortcut: Native reuse/laziness checks assume Text uses NSTextField.
        // Revisit these checks if SwiftUI changes its native text backend.
        let renderedFields = fixture.descendants(sheet.contentView).compactMap { $0 as? NSTextField }
        let firstHostField = try XCTUnwrap(renderedFields.first { $0.stringValue == "host0.example" })
        let viewport = try XCTUnwrap(firstHostField.enclosingScrollView)
        let visibleFrame = sheet.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        XCTAssertTrue(visibleFrame.contains(errorFrame), "Both invalid inputs must be fully visible before the host list")
        XCTAssertFalse(renderedFields.contains { $0.stringValue == "host4999.example" },
                       "The offscreen tail must not be materialized on the first screen")
        let toggle = try await fixture.element("Include subdomains", in: sheet)
        var expectedState = try XCTUnwrap(fixture.value(toggle) as? Int)
        var previousHost = firstHostField
        for _ in 0..<6 {
            expectedState = expectedState == 1 ? 0 : 1
            XCTAssertTrue(fixture.press(toggle))
            try await fixture.wait { fixture.value(toggle) as? Int == expectedState }
            // Let SwiftUI apply the diff before checking native field reuse.
            try await Task.sleep(for: .milliseconds(100))
            _ = try await fixture.element("host0.example", in: sheet)
            let updatedHost = try XCTUnwrap(fixture.descendants(sheet.contentView)
                .compactMap { $0 as? NSTextField }.first { $0.stringValue == "host0.example" })
            XCTAssertTrue(updatedHost === previousHost,
                          "Changing subdomain flags must retain the visible host field")
            previousHost = updatedHost
        }
        XCTAssertEqual(fixture.store.settings, originalSettings, "Editing the preview must not mutate stored settings")
        XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), originalBytes)
    }

    func testNativeValidToInvalidThenImmediateSaveRejectsEveryInvalidInput() async throws {
        let fixture = try BulkSheetFixture()
        defer { fixture.cleanup() }
        let sheet = try await fixture.present()
        let text = try fixture.textView(in: sheet)
        text.insertText("valid.example", replacementRange: NSRange(location: 0, length: 0))
        let save = try await fixture.element("Save", in: sheet)
        try await fixture.wait { fixture.isEnabled(save) }

        // Keep the already-enabled native action, with no runloop yield between
        // the invalid edit and submission. Require separate Save feedback below.
        let invalid = "valid.example bad/path ftp://bad.example/a"
        text.insertText(invalid, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        XCTAssertTrue(fixture.press(save))
        try await fixture.assertSaveFeedback("Could not recognize: bad/path, ftp://bad.example/a", in: sheet)
        XCTAssertEqual(text.string, invalid)
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertTrue(fixture.window.attachedSheet === sheet)
    }

    func testCancelAndReopenResetsTextSubdomainsAndFeedback() async throws {
        let fixture = try BulkSheetFixture()
        defer { fixture.cleanup() }
        let sheet = try await fixture.present()
        let text = try fixture.textView(in: sheet)
        text.insertText("before.example", replacementRange: NSRange(location: 0, length: 0))
        let save = try await fixture.element("Save", in: sheet)
        try await fixture.wait { fixture.isEnabled(save) }
        text.insertText("before.example bad/path", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        XCTAssertTrue(fixture.press(save))
        try await fixture.assertSaveFeedback("Could not recognize: bad/path", in: sheet)
        let toggle = try await fixture.element("Include subdomains", in: sheet)
        XCTAssertTrue(fixture.press(toggle))
        let cancel = try await fixture.element("Cancel", in: sheet)
        XCTAssertTrue(fixture.press(cancel))
        try await fixture.wait { fixture.window.attachedSheet == nil }

        let reopened = try await fixture.present()
        XCTAssertEqual(try fixture.textView(in: reopened).string, "")
        let freshToggle = try await fixture.element("Include subdomains", in: reopened)
        XCTAssertEqual(fixture.value(freshToggle) as? Int, 1)
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertFalse(fixture.texts(in: reopened).contains { $0.hasPrefix("Could not recognize:") })
    }

    func testRetainedOldNativeBindingAndSaveCannotChangeReopenedSheetOrStore() async throws {
        let fixture = try BulkSheetFixture()
        defer { fixture.cleanup() }
        let sheet = try await fixture.present()
        let oldText = try fixture.textView(in: sheet)
        let oldDelegate = try XCTUnwrap(oldText.delegate)
        oldText.insertText("old.example", replacementRange: NSRange(location: 0, length: 0))
        let oldSave = try await fixture.element("Save", in: sheet)
        try await fixture.wait { fixture.isEnabled(oldSave) }
        let cancel = try await fixture.element("Cancel", in: sheet)
        XCTAssertTrue(fixture.press(cancel))
        try await fixture.wait { fixture.window.attachedSheet == nil }
        let reopened = try await fixture.present()
        let freshText = try fixture.textView(in: reopened)

        withExtendedLifetime(oldDelegate) {
            oldText.insertText("late.example", replacementRange: NSRange(location: 0, length: (oldText.string as NSString).length))
            XCTAssertTrue(fixture.press(oldSave))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(freshText.string, "")
        XCTAssertTrue(fixture.window.attachedSheet === reopened)
        XCTAssertEqual(fixture.store.settings, .default)

        freshText.insertText("fresh.example", replacementRange: NSRange(location: 0, length: 0))
        let save = try await fixture.element("Save", in: reopened)
        try await fixture.wait { fixture.isEnabled(save) }
        XCTAssertTrue(fixture.press(save))
        try await fixture.wait { fixture.window.attachedSheet == nil }
        XCTAssertEqual(fixture.store.settings.rules.map(\.matcher.normalizedHost), ["fresh.example"])
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: fixture.defaults).settings, fixture.store.settings)
    }

    func testRealStoreFailureKeepsNativeInputSubdomainsFeedbackAndSheet() async throws {
        let fixture = try BulkSheetFixture(unreadable: true)
        defer { fixture.cleanup() }
        let original = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let sheet = try await fixture.present()
        let text = try fixture.textView(in: sheet)
        text.insertText("failure.example 127.0.0.1", replacementRange: NSRange(location: 0, length: 0))
        let toggle = try await fixture.element("Include subdomains", in: sheet)
        XCTAssertTrue(fixture.press(toggle))
        let save = try await fixture.element("Save", in: sheet)
        try await fixture.wait { fixture.isEnabled(save) }
        XCTAssertTrue(fixture.press(save))
        _ = try await fixture.element("The rules could not be saved.", in: sheet)
        XCTAssertEqual(text.string, "failure.example 127.0.0.1")
        XCTAssertEqual(fixture.value(toggle) as? Int, 0)
        XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), original)
        // Loading unreadable bytes starts from defaults. Check memory as well
        // as the original bytes so a partial in-memory commit cannot pass.
        XCTAssertEqual(fixture.store.settings, .default)
        XCTAssertTrue(fixture.window.attachedSheet === sheet)
    }
}

@MainActor
private final class BulkSheetFixture {
    let defaults: UserDefaults
    let store: RoutingPreferencesStore
    let controller: SettingsWindowController
    let window: NSWindow
    private let removeSuite: () -> Void
    private let removeApp: () -> Void
    private let previousEnhancedUI: Bool

    init(unreadable: Bool = false) throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousEnhancedUI = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        let (defaults, removeSuite) = makeIsolatedUserDefaults()
        self.defaults = defaults
        self.removeSuite = removeSuite
        let (url, removeApp) = try makeApplicationBundle(name: "Bulk Fixture", bundleIdentifier: "test.bulk.\(UUID().uuidString)", urlSchemes: nil)
        self.removeApp = removeApp
        do {
            let browser = try XCTUnwrap(Browser.application(at: url))
            let preferences = BrowserPreferences(userDefaults: defaults)
            try preferences.saveScannedBrowsers([browser], at: Date())
            let repository = BrowserRepository(scanner: StubBrowserScanner(result: [browser]), preferences: preferences)
            if unreadable { defaults.set(Data("owned-unreadable-fixture".utf8), forKey: RoutingPreferencesStore.storageKey) }
            store = RoutingPreferencesStore(userDefaults: defaults)
            controller = SettingsWindowController(
                browserRepository: repository, routingPreferencesStore: store,
                appLanguageStore: AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"]),
                launchAtLoginController: LaunchAtLoginController(service: BulkReadOnlyLaunchService()),
                defaultBrowserController: DefaultBrowserController(manager: BulkReadOnlyDefaultHandlers(), bundleIdentifier: "test.bulk"),
                applicationPresentationController: ApplicationPresentationController())
            window = try XCTUnwrap(controller.window)
        } catch {
            removeApp()
            removeSuite()
            throw error
        }
        app.accessibilitySetValue(true, forAttribute: attribute)
        controller.selectedSection = .rules
        window.orderFront(nil)
    }

    func present(file: StaticString = #filePath, line: UInt = #line) async throws -> NSWindow {
        _ = controller.domainRuleSessionForTesting.send(.presentBulkRuleCreate)
        try await wait(file: file, line: line) { self.window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet, file: file, line: line)
        try await wait(file: file, line: line) { self.descendants(sheet.contentView).contains { $0 is NSTextView } }
        return sheet
    }

    func cleanup() {
        controller.close()
        NSApplication.shared.accessibilitySetValue(previousEnhancedUI, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        removeApp()
        removeSuite()
    }

    func textView(in window: NSWindow) throws -> NSTextView {
        try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? NSTextView }.first)
    }

    func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap(descendants)
    }

    func elements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in (object as AnyObject).accessibilityChildren?() ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
        }
        visit(root)
        return result
    }

    func texts(in window: NSWindow) -> [String] {
        elements(in: window).flatMap { object -> [String] in
            let item = object as AnyObject
            return [item.accessibilityLabel?(), self.value(object) as? String].compactMap { $0 }
        }
    }

    func assertSaveFeedback(
        _ text: String, in window: NSWindow,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        func hasSaveFeedback() -> Bool {
            window.contentView?.layoutSubtreeIfNeeded()
            return elements(in: window).contains {
                let object = $0 as AnyObject
                return object.accessibilityIdentifier?() == "rules.bulk.save-feedback"
                    && (object.accessibilityLabel?() == text || self.value($0) as? String == text)
            }
        }
        // Summary and action feedback have identical copy. Match the action
        // feedback's identity so wrapper or mirror elements do not affect it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !hasSaveFeedback() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            hasSaveFeedback(),
            "Missing independently identified Save feedback (rules.bulk.save-feedback): \(text)",
            file: file, line: line
        )
    }

    func element(
        _ text: String, in window: NSWindow,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> NSObject {
        var match: NSObject?
        try await wait("Missing bulk-sheet element: \(text)", file: file, line: line) {
            window.contentView?.layoutSubtreeIfNeeded()
            match = self.elements(in: window).first {
                let object = $0 as AnyObject
                return object.accessibilityLabel?() == text || self.value($0) as? String == text
            }
            return match != nil
        }
        return try XCTUnwrap(match, "Missing bulk-sheet element: \(text)", file: file, line: line)
    }

    func value(_ element: NSObject) -> Any? {
        let selector = #selector(NSAccessibilityProtocol.accessibilityValue)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }

    func press(_ object: NSObject) -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }

    func isEnabled(_ object: NSObject) -> Bool { (object as AnyObject).isAccessibilityEnabled?() ?? false }

    func frame(_ object: NSObject) -> NSRect { (object as AnyObject).accessibilityFrame?() ?? .zero }

    func wait(
        _ message: String = "Bulk sheet did not reach the expected state",
        timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(condition() ? true : nil, message, file: file, line: line)
    }
}

private struct BulkReadOnlyLaunchService: LaunchItemService {
    var status: SMAppService.Status { .enabled }
    func register() throws { XCTFail("Bulk tests must not mutate login items") }
    func unregister() throws { XCTFail("Bulk tests must not mutate login items") }
}

private struct BulkReadOnlyDefaultHandlers: DefaultBrowserHandlerManaging {
    func defaultHandler(for scheme: String) -> String? { "test.controlled" }
    func setDefaultHandler(_ bundleIdentifier: String, for scheme: String) -> OSStatus {
        XCTFail("Bulk tests must not mutate system handlers")
        return -1
    }
}
