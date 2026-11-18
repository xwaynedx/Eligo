import Foundation

enum BrowserPreferencesError: Error, Equatable {
    case unreadableConfiguration
    case encodingFailed
}

final class BrowserPreferences {
    static let storageKey = "BrowserPreferences.v1"

    struct StoredBrowser: Codable {
        var name: String
        var bundleIdentifier: String
        var appPath: String
        var priority: Int
    }

    struct StoredPreferences: Codable {
        var orderedBundleIdentifiers: [String]
        var disabledBundleIdentifiers: [String]
        var customBrowsers: [StoredBrowser]
        var recentBrowserIdentifier: String?
        var scannedBrowsers: [StoredBrowser]
        var lastBrowserScanDate: Date?

        init(
            orderedBundleIdentifiers: [String],
            disabledBundleIdentifiers: [String],
            customBrowsers: [StoredBrowser],
            recentBrowserIdentifier: String?,
            scannedBrowsers: [StoredBrowser],
            lastBrowserScanDate: Date?
        ) {
            self.orderedBundleIdentifiers = orderedBundleIdentifiers
            self.disabledBundleIdentifiers = disabledBundleIdentifiers
            self.customBrowsers = customBrowsers
            self.recentBrowserIdentifier = recentBrowserIdentifier
            self.scannedBrowsers = scannedBrowsers
            self.lastBrowserScanDate = lastBrowserScanDate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            orderedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .orderedBundleIdentifiers) ?? []
            disabledBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .disabledBundleIdentifiers) ?? []
            customBrowsers = try container.decodeIfPresent([StoredBrowser].self, forKey: .customBrowsers) ?? []
            recentBrowserIdentifier = try container.decodeIfPresent(String.self, forKey: .recentBrowserIdentifier)
            scannedBrowsers = try container.decodeIfPresent([StoredBrowser].self, forKey: .scannedBrowsers) ?? []
            lastBrowserScanDate = try container.decodeIfPresent(Date.self, forKey: .lastBrowserScanDate)
        }
    }

    private let userDefaults: UserDefaults

    enum LoadResult {
        case missing
        case readable(StoredPreferences)
        case unreadable
    }

    private let encode: (StoredPreferences) throws -> Data

    init(
        userDefaults: UserDefaults = .standard,
        encode: @escaping (StoredPreferences) throws -> Data = { try JSONEncoder().encode($0) }
    ) {
        self.userDefaults = userDefaults
        self.encode = encode
    }

    func customBrowsers() throws(BrowserPreferencesError) -> [Browser] {
        customBrowsers(in: try load())
    }

    func cachedScannedBrowsers() throws(BrowserPreferencesError) -> [Browser] {
        cachedScannedBrowsers(in: try load())
    }

    func recentBrowserIdentifier() throws(BrowserPreferencesError) -> String? {
        try load().recentBrowserIdentifier
    }

    func apply(to browsers: [Browser]) throws(BrowserPreferencesError) -> [ConfiguredBrowser] {
        apply(try load(), to: browsers)
    }

    func shouldRefreshBrowserCache(now: Date, maximumAge: TimeInterval) throws(BrowserPreferencesError) -> Bool {
        shouldRefreshBrowserCache(in: try load(), now: now, maximumAge: maximumAge)
    }

    func customBrowsers(in preferences: StoredPreferences) -> [Browser] {
        preferences.customBrowsers.map { browser(from: $0, isCustom: true) }
    }

    func cachedScannedBrowsers(in preferences: StoredPreferences) -> [Browser] {
        preferences.scannedBrowsers.map { browser(from: $0, isCustom: false) }
    }

    func shouldRefreshBrowserCache(in preferences: StoredPreferences, now: Date, maximumAge: TimeInterval) -> Bool {
        guard !preferences.scannedBrowsers.isEmpty, let lastBrowserScanDate = preferences.lastBrowserScanDate else {
            return true
        }

        return now.timeIntervalSince(lastBrowserScanDate) > maximumAge
    }

    @discardableResult
    func saveScannedBrowsers(_ browsers: [Browser], at date: Date) throws(BrowserPreferencesError) -> StoredPreferences {
        var preferences = try load()
        preferences.scannedBrowsers = browsers.map(storedBrowser(from:))
        preferences.lastBrowserScanDate = date
        let saved = try save(preferences)
        AppLog.browsers.info("Browser scan cache saved with \(browsers.count, privacy: .public) result(s)")
        return saved
    }

    func apply(_ preferences: StoredPreferences, to browsers: [Browser]) -> [ConfiguredBrowser] {
        let disabled = Set(preferences.disabledBundleIdentifiers)
        var order: [String: Int] = [:]
        for (offset, identifier) in preferences.orderedBundleIdentifiers.enumerated() where order[identifier] == nil {
            order[identifier] = offset
        }

        return browsers
            .map { ConfiguredBrowser(browser: $0, isEnabled: !disabled.contains($0.bundleIdentifier)) }
            .sorted { lhs, rhs in
                let lhsOrder = order[lhs.browser.bundleIdentifier]
                let rhsOrder = order[rhs.browser.bundleIdentifier]

                switch (lhsOrder, rhsOrder) {
                case let (lhs?, rhs?):
                    return lhs < rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    if lhs.browser.priority != rhs.browser.priority {
                        return lhs.browser.priority < rhs.browser.priority
                    }

                    let nameOrder = lhs.browser.name.localizedCaseInsensitiveCompare(rhs.browser.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return lhs.browser.bundleIdentifier < rhs.browser.bundleIdentifier
                }
            }
    }

    @discardableResult
    func save(_ browsers: [ConfiguredBrowser]) throws(BrowserPreferencesError) -> StoredPreferences {
        var preferences = try load()
        let displayed = Set(browsers.map(\.id))
        var requestedOrder = browsers.map(\.id).makeIterator()
        // Unavailable entries keep their slots while visible entries are reordered.
        preferences.orderedBundleIdentifiers = preferences.orderedBundleIdentifiers.map {
            displayed.contains($0) ? requestedOrder.next()! : $0
        } + Array(requestedOrder)
        preferences.disabledBundleIdentifiers = browsers.filter { !$0.isEnabled }.map(\.id)
            + preferences.disabledBundleIdentifiers.filter { !displayed.contains($0) }
        let saved = try save(preferences)
        AppLog.browsers.info("Browser preferences saved")
        return saved
    }

    @discardableResult
    func saveCustomBrowser(_ browser: Browser) throws(BrowserPreferencesError) -> StoredPreferences {
        var preferences = try load()
        preferences.customBrowsers.removeAll { $0.bundleIdentifier == browser.bundleIdentifier }
        preferences.customBrowsers.append(storedBrowser(from: browser))

        if !preferences.orderedBundleIdentifiers.contains(browser.bundleIdentifier) {
            preferences.orderedBundleIdentifiers.append(browser.bundleIdentifier)
        }

        let saved = try save(preferences)
        AppLog.browsers.info("Custom browser saved: \(browser.name, privacy: .public)")
        return saved
    }

    @discardableResult
    func removeCustomBrowser(bundleIdentifier: String, preservingBrowserChoices: Bool = false) throws(BrowserPreferencesError) -> StoredPreferences {
        var preferences = try load()
        preferences.customBrowsers.removeAll { $0.bundleIdentifier == bundleIdentifier }
        if !preservingBrowserChoices {
            preferences.orderedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
            preferences.disabledBundleIdentifiers.removeAll { $0 == bundleIdentifier }
            if preferences.recentBrowserIdentifier == bundleIdentifier {
                preferences.recentBrowserIdentifier = nil
            }
        }
        let saved = try save(preferences)
        AppLog.browsers.info("Custom browser removed: \(bundleIdentifier, privacy: .public)")
        return saved
    }

    @discardableResult
    func saveRecentBrowserIdentifier(_ browserIdentifier: String) throws(BrowserPreferencesError) -> StoredPreferences {
        var preferences = try load()
        preferences.recentBrowserIdentifier = browserIdentifier
        let saved = try save(preferences)
        AppLog.browsers.info("Recent browser saved: \(browserIdentifier, privacy: .public)")
        return saved
    }

    @discardableResult
    func reset() throws(BrowserPreferencesError) -> StoredPreferences {
        switch loadResult() {
        case let .readable(existing):
            var reset = emptyPreferences()
            reset.scannedBrowsers = existing.scannedBrowsers
            reset.lastBrowserScanDate = existing.lastBrowserScanDate
            return try save(reset)
        case .missing:
            return emptyPreferences()
        case .unreadable:
            userDefaults.removeObject(forKey: Self.storageKey)
            return emptyPreferences()
        }
    }

    /// Missing is a normal installation; unreadable bytes must survive until Reset.
    func load() throws(BrowserPreferencesError) -> StoredPreferences {
        switch loadResult() {
        case .missing: return emptyPreferences()
        case let .readable(preferences): return preferences
        case .unreadable: throw .unreadableConfiguration
        }
    }

    func loadResult() -> LoadResult {
        guard let object = userDefaults.object(forKey: Self.storageKey) else { return .missing }
        guard let data = object as? Data else { return .unreadable }
        do {
            return .readable(sanitize(try JSONDecoder().decode(StoredPreferences.self, from: data)))
        } catch {
            return .unreadable
        }
    }

    private func save(_ preferences: StoredPreferences) throws(BrowserPreferencesError) -> StoredPreferences {
        let data: Data
        do {
            data = try encode(preferences)
        } catch {
            throw .encodingFailed
        }
        userDefaults.set(data, forKey: Self.storageKey)
        return preferences
    }

    private func emptyPreferences() -> StoredPreferences {
        StoredPreferences(
            orderedBundleIdentifiers: [],
            disabledBundleIdentifiers: [],
            customBrowsers: [],
            recentBrowserIdentifier: nil,
            scannedBrowsers: [],
            lastBrowserScanDate: nil
        )
    }

    private func sanitize(_ preferences: StoredPreferences) -> StoredPreferences {
        StoredPreferences(
            orderedBundleIdentifiers: stableUnique(preferences.orderedBundleIdentifiers),
            disabledBundleIdentifiers: stableUnique(preferences.disabledBundleIdentifiers),
            customBrowsers: uniqueBrowsers(preferences.customBrowsers),
            recentBrowserIdentifier: preferences.recentBrowserIdentifier,
            scannedBrowsers: uniqueBrowsers(preferences.scannedBrowsers),
            lastBrowserScanDate: preferences.lastBrowserScanDate
        )
    }

    private func stableUnique(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func uniqueBrowsers(_ browsers: [StoredBrowser]) -> [StoredBrowser] {
        var result: [StoredBrowser] = []
        var indexes: [String: Int] = [:]
        for browser in browsers {
            if let index = indexes[browser.bundleIdentifier] {
                result[index] = browser
            } else {
                indexes[browser.bundleIdentifier] = result.count
                result.append(browser)
            }
        }
        return result
    }

    private func browser(from storedBrowser: StoredBrowser, isCustom: Bool) -> Browser {
        Browser(
            name: storedBrowser.name,
            bundleIdentifier: storedBrowser.bundleIdentifier,
            appURL: URL(fileURLWithPath: storedBrowser.appPath, isDirectory: true),
            priority: storedBrowser.priority,
            isCustom: isCustom
        )
    }

    private func storedBrowser(from browser: Browser) -> StoredBrowser {
        StoredBrowser(
            name: browser.name,
            bundleIdentifier: browser.bundleIdentifier,
            appPath: browser.appURL.path,
            priority: browser.priority
        )
    }
}
