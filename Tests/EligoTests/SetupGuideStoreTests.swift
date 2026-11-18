import XCTest
@testable import Eligo

final class SetupGuideStoreTests: XCTestCase {
    func testHasNotAutoShownSetupByDefault() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        XCTAssertFalse(SetupGuideStore(userDefaults: defaults).hasAutoShownSetup)
    }

    func testMarkingSetupAutoShownPersistsAcrossStoreInstances() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        SetupGuideStore(userDefaults: defaults).markSetupAutoShown()

        XCTAssertTrue(SetupGuideStore(userDefaults: defaults).hasAutoShownSetup)
    }
}
