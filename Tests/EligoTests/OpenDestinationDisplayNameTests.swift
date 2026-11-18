import XCTest
@testable import Eligo

@MainActor
final class OpenDestinationDisplayNameTests: XCTestCase {
    private func makeStore(language: AppLanguage) -> (AppLanguageStore, () -> Void) {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(language)
        return (store, cleanup)
    }

    func testNormalDestinationShowsBrowserNameInBothLanguages() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let destination = OpenDestination(browser: chrome, mode: .normal)

        let (english, cleanupEnglish) = makeStore(language: .english)
        defer { cleanupEnglish() }
        XCTAssertEqual(destination.displayName(using: english), "Google Chrome")

        let (chinese, cleanupChinese) = makeStore(language: .simplifiedChinese)
        defer { cleanupChinese() }
        XCTAssertEqual(destination.displayName(using: chinese), "Google Chrome")
    }

    func testVerifiedPrivateDestinationAppendsAdapterActionTitle() {
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let destination = OpenDestination(browser: chrome, mode: .privateBrowsing)

        let (english, cleanupEnglish) = makeStore(language: .english)
        defer { cleanupEnglish() }
        XCTAssertEqual(destination.displayName(using: english), "Google Chrome Private")

        let (chinese, cleanupChinese) = makeStore(language: .simplifiedChinese)
        defer { cleanupChinese() }
        XCTAssertEqual(destination.displayName(using: chinese), "Google Chrome 隐私")
    }

    func testPrivateDestinationWithoutRegisteredAdapterFallsBackToGenericPrivateTitle() {
        let custom = makeBrowser(
            name: "Custom Browser",
            bundleIdentifier: "com.example.custom",
            isCustom: true
        )
        let destination = OpenDestination(browser: custom, mode: .privateBrowsing)

        let (english, cleanupEnglish) = makeStore(language: .english)
        defer { cleanupEnglish() }
        XCTAssertEqual(destination.displayName(using: english), "Custom Browser Private")

        let (chinese, cleanupChinese) = makeStore(language: .simplifiedChinese)
        defer { cleanupChinese() }
        XCTAssertEqual(destination.displayName(using: chinese), "Custom Browser 隐私")
    }
}
