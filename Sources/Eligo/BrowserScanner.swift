import AppKit

protocol BrowserScanning: Sendable {
    func scan() -> [Browser]
}

final class BrowserScanner: BrowserScanning, @unchecked Sendable {
    private let fileManager: FileManager
    private let searchRoots: [URL]
    private let registeredApplicationURLs: @Sendable () -> [URL]

    init(
        fileManager: FileManager = .default,
        searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ],
        registeredApplicationURLs: @escaping @Sendable () -> [URL] = {
            BrowserDefinition.all.flatMap { LaunchServicesBrowserManager.applicationURLs(for: $0.bundleIdentifiers) }
        }
    ) {
        self.fileManager = fileManager
        self.searchRoots = searchRoots
        self.registeredApplicationURLs = registeredApplicationURLs
    }

    func scan() -> [Browser] {
        var browsersByBundleID: [String: Browser] = [:]

        scanRegisteredApplications(into: &browsersByBundleID)

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            scan(root: root, into: &browsersByBundleID)
        }

        let browsers = browsersByBundleID.values.sorted(by: BrowserScanner.sortBrowsers)
        AppLog.browsers.info("Browser scan completed with \(browsers.count, privacy: .public) result(s)")
        return browsers
    }

    private func scanRegisteredApplications(into browsersByBundleID: inout [String: Browser]) {
        for appURL in registeredApplicationURLs() {
            addBrowserIfRecognized(at: appURL, into: &browsersByBundleID)
        }
    }

    private func scan(root: URL, into browsersByBundleID: inout [String: Browser]) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            AppLog.browsers.warning("Unable to enumerate browser search root: \(root.path, privacy: .public)")
            return
        }

        for case let appURL as URL in enumerator where appURL.pathExtension == "app" {
            addBrowserIfRecognized(at: appURL, into: &browsersByBundleID)
        }
    }

    private func addBrowserIfRecognized(at appURL: URL, into browsersByBundleID: inout [String: Browser]) {
        guard
            let application = Browser.application(at: appURL),
            let definition = BrowserDefinition.definition(for: application.id)
        else {
            return
        }
        let bundleIdentifier = application.id

        let browser = Browser(
            name: application.name,
            bundleIdentifier: bundleIdentifier,
            appURL: appURL,
            priority: definition.priority
        )

        if browsersByBundleID[bundleIdentifier] == nil {
            browsersByBundleID[bundleIdentifier] = browser
            AppLog.browsers.info("Detected browser: \(browser.name, privacy: .public) \(browser.bundleIdentifier, privacy: .public)")
        }
    }

    private static func sortBrowsers(_ lhs: Browser, _ rhs: Browser) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
