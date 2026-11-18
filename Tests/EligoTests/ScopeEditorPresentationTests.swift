import XCTest
@testable import Eligo

@MainActor
final class ScopeEditorPresentationTests: XCTestCase {
    func testOrdinaryCloseRetainsOccupancyAndRejectsLateReceipts() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: defaults)
        defer { browser.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        let holder = ScopeEditorPresentation()
        let first = try XCTUnwrap(holder.begin(store: store, editor: editor, browserRepository: browser.repository))
        let row = try XCTUnwrap(first.session.addDomain())
        first.session.editHost(rowID: row, text: "pending.example")
        holder.requestClose(id: first.id)
        XCTAssertFalse(first.session.isActive)
        XCTAssertEqual(holder.item?.id, first.id)
        XCTAssertTrue(holder.isClosing)
        XCTAssertNil(holder.begin(store: store, editor: editor, browserRepository: browser.repository))
        holder.didDismiss(id: UUID())
        XCTAssertEqual(holder.item?.id, first.id)
        holder.didDismiss(id: first.id)
        let second = try XCTUnwrap(holder.begin(store: store, editor: editor, browserRepository: browser.repository))
        holder.requestClose(id: first.id)
        holder.didDismiss(id: first.id)
        first.session.editHost(rowID: row, text: "late.example")
        XCTAssertEqual(first.session.validation.drafts.first?.host, "pending.example")
        XCTAssertEqual(holder.item?.id, second.id)
        XCTAssertTrue(second.session.isActive)
        XCTAssertFalse(holder.isClosing)
        XCTAssertTrue(second.session.validation.drafts.isEmpty)
        XCTAssertNil(defaults.data(forKey: RoutingPreferencesStore.storageKey))
        holder.windowWillClose()
    }

    func testWindowCloseReleasesWithoutSwiftUIReceiptAndReopensFromLatestScope() throws {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let browser = try ScopeDestinationFixture(userDefaults: defaults)
        defer { browser.cleanup() }
        let store = RoutingPreferencesStore(userDefaults: defaults)
        let editor = RoutingSettingsEditor(store: store)
        let holder = ScopeEditorPresentation()
        let first = try XCTUnwrap(holder.begin(store: store, editor: editor, browserRepository: browser.repository))
        _ = first.session.beginPaste()
        holder.windowWillClose()
        XCTAssertNil(holder.item)
        XCTAssertFalse(first.session.isActive)
        XCTAssertNil(first.session.pasteDraft)
        let matcher = try DomainMatcher(host: "latest.example", includesSubdomains: false)
        try editor.saveScope(.onlyThese(matchers: [matcher], bypassDestinationID: browser.destinationID), browserRepository: browser.repository)
        let second = try XCTUnwrap(holder.begin(store: store, editor: editor, browserRepository: browser.repository))
        holder.requestClose(id: first.id)
        holder.didDismiss(id: first.id)
        XCTAssertEqual(holder.item?.id, second.id)
        XCTAssertTrue(second.session.isActive)
        XCTAssertEqual(second.session.validation.drafts.map(\.host), ["latest.example"])
        holder.windowWillClose()
        holder.windowWillClose()
    }
}
