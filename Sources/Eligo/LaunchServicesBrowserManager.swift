import AppKit
import CoreServices

protocol DefaultBrowserHandlerManaging {
    func defaultHandler(for scheme: String) -> String?
    func setDefaultHandler(_ bundleIdentifier: String, for scheme: String) -> OSStatus
}

struct LaunchServicesDefaultBrowserHandlerManager: DefaultBrowserHandlerManaging {
    func defaultHandler(for scheme: String) -> String? {
        LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?
    }

    func setDefaultHandler(_ bundleIdentifier: String, for scheme: String) -> OSStatus {
        LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
    }
}

enum LaunchServicesBrowserManager {
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "io.github.xwaynedx.eligo"
    }

    static func registerCurrentApplication() {
        guard let bundleURL = Bundle.main.bundleURL as CFURL? else {
            AppLog.app.warning("Unable to register app with LaunchServices because bundle URL is unavailable")
            return
        }

        let status = LSRegisterURL(bundleURL, true)
        if status == noErr {
            AppLog.app.info("Registered Eligo with LaunchServices")
        } else {
            AppLog.app.error("LaunchServices registration failed: \(status, privacy: .public)")
        }
    }

    static func openDefaultBrowserSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")

        if let settingsURL, NSWorkspace.shared.open(settingsURL) {
            AppLog.app.info("Opened System Settings for default browser help")
        } else {
            AppLog.app.warning("Failed to open System Settings URL")
        }
    }

    static func applicationURLs(for bundleIdentifiers: Set<String>) -> [URL] {
        var urls: [URL] = []
        for bundleIdentifier in bundleIdentifiers {
            urls.append(contentsOf: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier))
        }

        return urls
    }

}
