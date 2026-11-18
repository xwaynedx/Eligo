import Foundation

struct Browser: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let appURL: URL
    let priority: Int
    var isCustom = false

    var id: String {
        bundleIdentifier
    }

    struct InstallationID: Hashable, Sendable {
        let browserID: String
        let appURL: URL
    }

    var installationID: InstallationID {
        // Filesystem standardization can change /private aliases when an app vanishes.
        InstallationID(browserID: id, appURL: URL(fileURLWithPath: appURL.path, isDirectory: true))
    }

    var isAvailable: Bool {
        Self.application(at: appURL)?.id == id
    }

    static func application(at appURL: URL) -> Browser? {
        var isDirectory: ObjCBool = false
        guard appURL.isFileURL, appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let bundle = Bundle(url: appURL),
              let infoData = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty,
              executableName == (executableName as NSString).lastPathComponent else { return nil }
        // Bundle metadata is cached by Foundation even after an app is replaced.
        let executable = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return Browser(
            name: BundleDisplayName.resolve(bundle: bundle, appURL: appURL, fallback: "Browser"),
            bundleIdentifier: identifier, appURL: appURL, priority: 1_000, isCustom: true
        )
    }
}

struct ConfiguredBrowser: Identifiable, Hashable, Sendable {
    let browser: Browser
    var isEnabled: Bool
    var isCustom: Bool {
        browser.isCustom
    }

    var id: String {
        browser.id
    }
}
