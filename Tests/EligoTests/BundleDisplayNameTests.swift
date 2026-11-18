import Foundation
import XCTest
@testable import Eligo

final class BundleDisplayNameTests: XCTestCase {
    func testEmptyDisplayNameFallsBackToBundleName() throws {
        let (bundle, appURL) = try makeBundle(displayName: "", bundleName: "Example Browser")
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL) }

        XCTAssertEqual(
            BundleDisplayName.resolve(bundle: bundle, appURL: appURL, fallback: "Fallback"),
            "Example Browser"
        )
    }

    func testWhitespaceBundleNamesFallBackToApplicationFileName() throws {
        let (bundle, appURL) = try makeBundle(displayName: " ", bundleName: "\n")
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL) }

        XCTAssertEqual(
            BundleDisplayName.resolve(bundle: bundle, appURL: appURL, fallback: "Fallback"),
            appURL.deletingPathExtension().lastPathComponent
        )
    }

    private func makeBundle(displayName: String?, bundleName: String?) throws -> (Bundle, URL) {
        let appURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).app", directoryHint: .isDirectory)
        let contentsURL = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": "test.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL"
        ]
        info["CFBundleDisplayName"] = displayName
        info["CFBundleName"] = bundleName
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appending(path: "Info.plist"))

        return (try XCTUnwrap(Bundle(url: appURL)), appURL)
    }
}
