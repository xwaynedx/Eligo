import AppKit
import SwiftUI
import XCTest
@testable import Eligo

@MainActor
final class ScopeDomainEditorIntegrationTests: XCTestCase {
    func testNativeRuleCreationRecomputesActionAndSavesExpandedScopeFromBothEntrypoints() async throws {
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }
        for fromChooser in [false, true] {
            let (defaults, cleanup) = makeIsolatedUserDefaults()
            defer { cleanup() }
            let destination = OpenDestination(browser: makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari"), mode: .normal)
            let rule = DomainRule(matcher: try DomainMatcher(host: "example.com", includesSubdomains: false), destinationID: destination.id)
            let store = RoutingPreferencesStore(userDefaults: defaults)
            try store.replace(with: RoutingSettings(scope: .allDomains, rules: [rule], alwaysShowChooser: false))
            let session = DomainRuleSettingsSession(store: store)
            _ = session.send(fromChooser
                ? .requestRuleFromChooser(host: "example.com", destinationID: destination.id)
                : .presentSingleRuleCreate)
            let id = try XCTUnwrap(session.state.presentation?.id)
            let draft = RuleEditorDraft(destinationID: destination.id, host: "example.com", includesSubdomains: true)
            let item = DomainRuleSettingsPresentationRelay.SingleItem(id: id, draft: draft)
            let language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
            let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RuleEditorSheet(
                draft: draft, rules: [rule], destinationContext: .init(destinations: [destination], browserNames: [:], appLanguageStore: language),
                opensPendingLink: session.state.isEditingPendingLink
            ) { (submission: RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void in
                try DomainRuleSettingsAdapter.commitSingle(item: item, draft: submission, session: session)
            })
            window.orderFront(nil)
            defer { window.close() }
            let root = try XCTUnwrap(window.contentView)
            func button(_ title: String) -> NSObject? {
                accessibilityElement(title, in: window)
            }
            let expandTitle = fromChooser ? "Expand Rule and Open" : "Expand Existing Rule"
            let reuseTitle = fromChooser ? "Use Existing Rule and Open" : "Done"
            var field: NSTextField?
            guard try await waitUntil("扩展按钮和域名输入框出现", in: window, condition: {
                field = self.descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.delegate != nil }
                return field != nil && button(expandTitle) != nil
            }) else { return }
            let checkbox = try XCTUnwrap(accessibilityElement("Include subdomains", in: window)) as AnyObject
            XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
            guard try await waitUntil("取消子域名后切换为复用", in: window, condition: { button(reuseTitle) != nil }) else { return }
            edit(try XCTUnwrap(field), text: "new.example.com")
            guard try await waitUntil("更换域名后切换为新建", in: window, condition: {
                button(fromChooser ? "Save and Open" : "Save") != nil
            }) else { return }
            edit(try XCTUnwrap(field), text: "https://EXAMPLE.com./path")
            guard try await waitUntil("规范化后的同域名重新切换为复用", in: window, condition: { button(reuseTitle) != nil }) else { return }
            XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
            guard try await waitUntil("重新勾选子域名后切换为扩展", in: window, condition: { button(expandTitle) != nil }) else { return }
            XCTAssertEqual(store.settings.rules, [rule])
            let saveButton = try XCTUnwrap(button(expandTitle)) as AnyObject
            XCTAssertTrue(saveButton.accessibilityPerformPress?() ?? false)
            guard try await waitUntil("实际按钮将范围更新到原规则", in: window, condition: {
                store.settings.rules.first?.matcher.includesSubdomains == true
            }) else { return }
            XCTAssertEqual(store.settings.rules.map(\.id), [rule.id])
            XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, store.settings)
        }
    }

    func testBulkURLBoundaryPreviewMatchesSavedScopeInOrder() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let fixture = try ScopeDestinationFixture(userDefaults: defaults)
        defer { fixture.cleanup() }
        let preview = DomainListParser().parse(
            "https://a.example/path,ignored.example;https://b.example/?nested=one,https://c.example https://a.example./other",
            includesSubdomains: true
        )
        XCTAssertEqual(preview.matchers.map(\.normalizedHost), ["a.example", "b.example", "c.example"])
        XCTAssertEqual(preview.duplicateInputs, ["https://a.example./other"])
        XCTAssertEqual(preview.invalidInputs, [])
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let state = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store), browserRepository: fixture.repository)
        defer { state.end() }
        state.setMode(.onlyThese)
        let pasteID = try XCTUnwrap(state.beginPaste())
        state.editPasteText(pasteID: pasteID, text: "https://a.example/path,ignored.example;https://b.example/?nested=one,https://c.example https://a.example./other")
        XCTAssertEqual(state.pasteDraft?.preview.matchers, preview.matchers)
        XCTAssertTrue(state.confirmPaste(pasteID: pasteID))
        XCTAssertEqual(state.validation.drafts.count, 3)
        XCTAssertTrue(state.save())
        let scope = RoutingScope.onlyThese(matchers: preview.matchers, bypassDestinationID: fixture.destinationID)
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings.scope, scope)
        XCTAssertEqual(store.settings.rules, [])
    }

    func testNativeScopeIPInputClearsAndDisablesSubdomainsThenAllowsDNSWithoutRechecking() async throws {
        _ = NSApplication.shared
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let fixture = try ScopeDestinationFixture(userDefaults: defaults)
        defer { fixture.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let state = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store), browserRepository: fixture.repository)
        defer { state.end() }
        state.setMode(.onlyThese)
        _ = state.addDomain()
        let language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScopeRowsHost(state: state, language: language))
        window.orderFront(nil)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        var field: NSTextField?
        guard try await waitUntil("the new Scope row is ready", in: window, condition: {
            field = self.descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.delegate != nil }
            return field != nil
        }) else { return }
        let checkbox = try initialSubdomainToggle(in: root)
        edit(try XCTUnwrap(field), text: "https://[::1]:8080/path")
        guard try await waitUntil("the IP edit and disabled checkbox are rendered", in: window, condition: {
            state.validation.drafts[0].host == "https://[::1]:8080/path" && !state.validation.drafts[0].includesSubdomains
                && !checkbox.isEnabled && checkbox.state == .off
        }) else { return }
        XCTAssertEqual(state.validation.validatedMatchers(for: state.validation.drafts), [try DomainMatcher(host: "::1", includesSubdomains: false)])
        XCTAssertTrue(state.save())
        let reopened = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store), browserRepository: fixture.repository)
        defer { reopened.end() }
        window.contentView = NSHostingView(rootView: ScopeRowsHost(state: reopened, language: language))
        var reopenedField: NSTextField?
        var reopenedCheckbox: NSButton?
        guard try await waitUntil("the reopened saved IP row is ready", in: window, condition: {
            guard let root = window.contentView else { return false }
            reopenedField = self.descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.delegate != nil }
            reopenedCheckbox = self.descendants(root).compactMap { $0 as? NSButton }.first { !$0.isEnabled }
            return reopenedField != nil && reopenedCheckbox != nil
        }) else { return }
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings.scope, store.settings.scope)
        edit(try XCTUnwrap(reopenedField), text: "example.com")
        guard try await waitUntil("the DNS checkbox becomes available again", in: window, condition: {
            reopened.validation.drafts[0].host == "example.com" && reopenedCheckbox?.isEnabled == true
        }) else { return }
        XCTAssertFalse(reopened.validation.drafts[0].includesSubdomains)
        window.close()
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings.scope, store.settings.scope,
                       "Closing with a newer DNS draft must retain the saved IP scope")
    }

    func testNativeRuleIPInputDisablesSubdomainsAndClosingKeepsTheSavedRules() async throws {
        _ = NSApplication.shared
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let fixture = try ScopeDestinationFixture(userDefaults: defaults)
        defer { fixture.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        let draft = RuleEditorDraft(destinationID: fixture.destinationID, host: "example.com", includesSubdomains: true)
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 500, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RuleEditorSheet(
            draft: draft, rules: [], destinationContext: .init(
                destinations: [OpenDestination(browser: fixture.browser, mode: .normal)], browserNames: [:], appLanguageStore: language)
        ) { _ in
            XCTFail("Editing and closing the rule draft must not invoke Save")
        })
        window.orderFront(nil)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        var field: NSTextField?
        guard try await waitUntil("the rule host field is ready", in: window, condition: {
            field = self.descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.delegate != nil }
            return field != nil
        }) else { return }
        let checkbox = try initialSubdomainToggle(in: root)
        edit(try XCTUnwrap(field), text: "https://[2001:DB8::1]:8443/path")
        guard try await waitUntil("the IP rule checkbox is off and disabled", in: window, condition: {
            !checkbox.isEnabled && checkbox.state == .off
        }) else { return }
        XCTAssertEqual(store.settings, .default, "Editing must not persist before Save")
        edit(try XCTUnwrap(field), text: "other.example")
        guard try await waitUntil("the DNS rule checkbox becomes available without rechecking", in: window, condition: {
            checkbox.isEnabled && checkbox.state == .off
        }) else { return }
        window.close()
        XCTAssertEqual(RoutingPreferencesStore(userDefaults: defaults).settings, .default)
    }

    func testNativeRowEditUpdatesValidationAndPersistedScope() async throws {
        _ = NSApplication.shared
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: defaults)
        defer { browser.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let state = ScopeEditorSession(store: store, editor: RoutingSettingsEditor(store: store), browserRepository: browser.repository)
        defer { state.end() }
        state.setMode(.onlyThese)
        let pasteID = try XCTUnwrap(state.beginPaste())
        state.editPasteText(pasteID: pasteID, text: "example.com")
        XCTAssertTrue(state.confirmPaste(pasteID: pasteID))
        let second = try XCTUnwrap(state.addDomain())
        state.editHost(rowID: second, text: "other.example")
        state.setIncludesSubdomains(rowID: second, enabled: false)
        let language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScopeRowsHost(state: state, language: language))
        window.orderFront(nil)
        defer { window.close() }

        let root = try XCTUnwrap(window.contentView)
        var editableField: NSTextField?
        guard try await waitUntil("the native row text field is ready", in: window, condition: {
            editableField = self.descendants(root).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && $0.stringValue == "other.example" && $0.delegate != nil
            }
            return editableField != nil
        }) else { return }
        let field = try XCTUnwrap(editableField)
        edit(field, text: "foo/bar")
        guard try await waitUntil("the invalid edit reaches the draft", in: window, condition: {
            state.validation.drafts[0].host == "foo/bar"
        }) else { return }
        XCTAssertEqual(state.validation.issue(for: state.validation.drafts[0].id), .invalidHost)
        XCTAssertNil(state.validation.validatedMatchers(for: state.validation.drafts))

        edit(field, text: "https://EXAMPLE.com./path")
        guard try await waitUntil("the valid edit reaches the draft", in: window, condition: {
            state.validation.drafts[0].host == "https://EXAMPLE.com./path"
        }) else { return }
        XCTAssertTrue(state.validation.invalidDraftIDs.isEmpty)
        let matchers = try XCTUnwrap(state.validation.validatedMatchers(for: state.validation.drafts))
        XCTAssertTrue(state.save())
        guard case let .onlyThese(saved, _) = RoutingPreferencesStore(userDefaults: defaults).settings.scope else {
            return XCTFail("Expected saved limited scope")
        }
        XCTAssertEqual(saved.map(\.normalizedHost), ["example.com", "example.com"])
        XCTAssertEqual(saved.map(\.includesSubdomains), [false, true])
    }

    private func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func accessibilityElement(_ title: String, in root: NSObject) -> NSObject? {
        var pending = [root]
        var seen = Set<ObjectIdentifier>()
        while let element = pending.popLast() {
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            let object = element as AnyObject
            if object.accessibilityLabel?() == title { return element }
            for child in object.accessibilityChildren?() ?? [] {
                if let child = child as? NSObject { pending.append(child) }
            }
        }
        return nil
    }

    private func waitUntil(
        _ description: String,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return false
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func initialSubdomainToggle(in root: NSView) throws -> NSButton {
        // Each host has exactly one checked control initially: Include subdomains.
        // SwiftUI's native checkbox has an empty title, so inspect its checked
        // state before editing and keep that actual control through the edit.
        let checked = descendants(root).compactMap { $0 as? NSButton }.filter { $0.state == .on }
        XCTAssertEqual(checked.count, 1)
        return try XCTUnwrap(checked.count == 1 ? checked.first : nil)
    }
}

private struct ScopeRowsHost: View {
    @ObservedObject var state: ScopeEditorSession
    @ObservedObject var language: AppLanguageStore

    var body: some View {
        ScopeDomainEditor(session: state, appLanguageStore: language)
            .padding(24)
    }
}
