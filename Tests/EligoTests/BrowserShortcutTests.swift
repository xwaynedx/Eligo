import AppKit
import XCTest
@testable import Eligo

@MainActor
final class BrowserShortcutTests: XCTestCase {
    func testSettingsNumbersMatchActualChooserKeysAcrossDisabledRowsAndTenthShortcut() throws {
        let browsers = (0..<13).map { index in
            ConfiguredBrowser(
                browser: makeBrowser(name: "Browser \(index)", bundleIdentifier: "test.shortcuts.\(index)"),
                isEnabled: index != 1 && index != 7
            )
        }
        let expected = ["1", "", "2", "3", "4", "5", "6", "", "7", "8", "9", "0", ""]
        for language in [AppLanguage.english, .simplifiedChinese] {
            let coordinator = BrowserTableView.Coordinator(
                browsers: browsers, acceptedBrowsers: { browsers }, language: language,
                onToggle: { _, _ in false }, onMove: { _, _ in false }, onRemoveCustom: { _ in }
            )
            let table = NSTableView()
            let chooser = ChooserView(
                link: IncomingLink(url: URL(string: "https://example.com")!),
                destinations: DestinationCatalog(enabledBrowsers: browsers.filter(\.isEnabled).map(\.browser)).destinations,
                recentBrowserID: browsers[4].id, language: language
            )
            var selected: Browser.ID?
            chooser.onSelect = { selected = $0.browser.id }
            let rows = browserChooserRows(in: chooser)
            var enabledIndex = 0
            for (index, browser) in browsers.enumerated() {
                let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: nil, row: index))
                let badge = try shortcutBadge(in: cell)
                let text = try XCTUnwrap(badge.accessibilityValue() as? String)
                XCTAssertEqual(text, expected[index])
                XCTAssertEqual(badge.isAccessibilityElement(), !text.isEmpty)
                if browser.isEnabled {
                    XCTAssertEqual(try shortcutBadge(in: rows[enabledIndex]).accessibilityValue() as? String, text)
                    enabledIndex += 1
                }
                if !text.isEmpty {
                    XCTAssertTrue(chooser.handleKeyDown(chooserKeyEvent(keyCode: 18, characters: text)))
                    XCTAssertEqual(selected, browser.id, "The Settings badge must open that same browser")
                    XCTAssertEqual(badge.toolTip, language == .english ? "Chooser shortcut \(text)" : "选择器快捷键 \(text)")
                }
            }
        }
    }

    private func shortcutBadge(in view: NSView) throws -> NSView {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        return try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier() == "browser.shortcut" })
    }
}
