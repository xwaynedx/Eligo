import Combine
import Foundation

@MainActor
final class BrowserRepository: ObservableObject {
    // One publication carries the list, availability, and Recent Browser together.
    private enum State: Equatable {
        case configured([ConfiguredBrowser], unavailableCustom: [Browser], recentBrowserID: String?)
        case unreadable
    }

    @Published private var state = State.configured([], unavailableCustom: [], recentBrowserID: nil)
    @Published private(set) var isScanning = false
    @Published private(set) var operationFeedback: BrowserOperationFeedback? {
        didSet { feedbackRevision += 1 }
    }
    private var feedbackRevision = 0

    private let scanner: any BrowserScanning
    private let preferences: BrowserPreferences
    private let now: @Sendable () -> Date
    private let currentApplicationBundleIdentifier: String
    private let currentApplicationURL: URL
    private struct PendingScan {
        let id: UUID
        let task: Task<BrowserMutationResult, Never>
        let continuation: AsyncStream<BrowserMutationResult>.Continuation
        var unavailableInstallations: Set<Browser.InstallationID>
    }
    private var pendingScan: PendingScan?
    private var lastScanResult: BrowserMutationResult = .unchanged
    private var consumedAutomaticScanInstallations = Set<Browser.InstallationID>()

    init(
        scanner: any BrowserScanning = BrowserScanner(),
        preferences: BrowserPreferences = BrowserPreferences(),
        cacheMaximumAge: TimeInterval = 6 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init,
        currentApplicationBundleIdentifier: String = LaunchServicesBrowserManager.bundleIdentifier,
        currentApplicationURL: URL = Bundle.main.bundleURL
    ) {
        self.scanner = scanner
        self.preferences = preferences
        self.now = now
        self.currentApplicationBundleIdentifier = currentApplicationBundleIdentifier
        self.currentApplicationURL = currentApplicationURL
        do {
            let snapshot = try preferences.load()
            refreshInstallations()
            if preferences.shouldRefreshBrowserCache(in: snapshot, now: now(), maximumAge: cacheMaximumAge) {
                rescan()
            }
        } catch {
            noteFailure(error)
        }
    }

    var browsers: [ConfiguredBrowser] {
        if case let .configured(browsers, _, _) = state { return browsers }
        return []
    }

    var unavailableCustomBrowsers: [Browser] {
        if case let .configured(_, unavailable, _) = state { return unavailable }
        return []
    }

    var enabledBrowsers: [Browser] { browsers.filter(\.isEnabled).map(\.browser) }

    var discoveryTask: Task<BrowserMutationResult, Never>? { pendingScan?.task }
    var discoveryResult: BrowserMutationResult { lastScanResult }

    /// Natural checkpoints re-read storage and disk. Getters and merging stay pure.
    @discardableResult
    func refreshInstallations() -> BrowserMutationResult {
        do {
            let snapshot = try trustedSnapshot()
            let unavailable = publish(snapshot)
            pendingScan?.unavailableInstallations.formUnion(unavailable)
            let newlyUnavailable = unavailable.subtracting(consumedAutomaticScanInstallations)
            if !newlyUnavailable.isEmpty {
                consumedAutomaticScanInstallations.formUnion(newlyUnavailable)
                rescan()
            }
            return .unchanged
        } catch { return noteFailure(error) }
    }

    /// A commit-time read must include external preference changes and apps
    /// removed since the last scan. This never launches or rescans a browser.
    func currentNormalDestination(for id: OpenDestinationID) throws(BrowserPreferencesError) -> OpenDestination? {
        do {
            let snapshot = try trustedSnapshot()
            publish(snapshot)
            let catalog = DestinationCatalog(enabledBrowsers: enabledBrowsers)
            guard id.mode == .normal,
                  let destination = catalog.destination(for: id) else {
                return nil
            }
            return destination
        } catch {
            noteFailure(error)
            throw error
        }
    }

    var recentBrowserIdentifier: String? {
        if case let .configured(_, _, recentBrowserID) = state { return recentBrowserID }
        return nil
    }

    var availability: BrowserAvailability {
        if case .unreadable = state { return .configurationUnreadable }
        if !enabledBrowsers.isEmpty { return .ready }
        if let suggestedBrowser = browsers.first?.browser { return .allDisabled(suggestedBrowser: suggestedBrowser) }
        return .noneDetected
    }

    @discardableResult
    func rescan() -> Task<BrowserMutationResult, Never> {
        do {
            _ = try trustedSnapshot()
        } catch {
            let result = noteFailure(error)
            return Task { result }
        }
        if let pendingScan { return pendingScan.task }

        // Waiters finish when this scan is invalidated, even if scan() cannot stop.
        let (stream, continuation) = AsyncStream<BrowserMutationResult>.makeStream()
        let task = Task {
            for await result in stream { return result }
            return BrowserMutationResult.superseded
        }
        let id = UUID()
        pendingScan = PendingScan(
            id: id, task: task, continuation: continuation,
            unavailableInstallations: consumedAutomaticScanInstallations
        )
        isScanning = true
        let scanner = self.scanner
        let scanDate = now()
        let feedbackRevisionAtStart = feedbackRevision
        Task { [weak self] in
            let scannedBrowsers = await Task.detached(priority: .utility) { scanner.scan() }.value
            guard let self, let pendingScan = self.pendingScan, pendingScan.id == id else { return }
            let result: BrowserMutationResult
            do throws(BrowserPreferencesError) {
                // Only scan fields change; user choices are read again at completion.
                let snapshot = try self.trustedSnapshot()
                let availableScanned = scannedBrowsers.filter(\.isAvailable)
                let discoveredIDs = Set(availableScanned.map(\.id))
                // A location may recover after scanning but before this publication.
                let retainedLocations = self.preferences.cachedScannedBrowsers(in: snapshot).filter {
                    !discoveredIDs.contains($0.id)
                        && (pendingScan.unavailableInstallations.contains($0.installationID) || !$0.isAvailable)
                }
                self.publish(try self.preferences.saveScannedBrowsers(availableScanned + retainedLocations, at: scanDate))
                // A scan may clear earlier feedback, but cannot dismiss a newer operation's result.
                if self.feedbackRevision == feedbackRevisionAtStart {
                    self.operationFeedback = nil
                }
                result = .applied
            } catch {
                result = self.noteFailure(error)
            }
            self.finishScan(id: id, result: result)
        }
        return task
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, for browserID: Browser.ID) -> BrowserMutationResult {
        do {
            let snapshot = try trustedSnapshot()
            var candidate = configuredBrowsers(in: snapshot)
            guard let index = candidate.firstIndex(where: { $0.id == browserID }) else { return noteResult(.notFound) }
            guard candidate[index].isEnabled != isEnabled else {
                publish(snapshot)
                return noteResult(.unchanged)
            }
            if !isEnabled, candidate[index].isEnabled, candidate.filter(\.isEnabled).count == 1 {
                return noteResult(.wouldLeaveNoEnabledBrowser)
            }
            candidate[index].isEnabled = isEnabled
            publish(try preferences.save(candidate))
            return noteResult(.applied)
        } catch { return noteFailure(error) }
    }

    @discardableResult
    func moveBrowser(from source: IndexSet, to destination: Int) -> BrowserMutationResult {
        do {
            let snapshot = try trustedSnapshot()
            // Resolve displayed IDs against current values without reinterpreting row offsets.
            let displayedIDs = browsers.map(\.id)
            let currentByID = Dictionary(uniqueKeysWithValues: configuredBrowsers(in: snapshot).map { ($0.id, $0) })
            var candidate = displayedIDs.compactMap { currentByID[$0] }
            guard candidate.count == displayedIDs.count, candidate.count == currentByID.count,
                  source.allSatisfy(candidate.indices.contains), (0...candidate.count).contains(destination) else {
                return noteResult(.notFound)
            }
            candidate.move(fromOffsets: source, toOffset: destination)
            if candidate.map(\.id) == displayedIDs {
                publish(snapshot)
                return noteResult(.unchanged)
            }
            publish(try preferences.save(candidate))
            return noteResult(.applied)
        } catch { return noteFailure(error) }
    }

    @discardableResult
    func resetPreferences() -> BrowserMutationResult {
        do {
            let snapshot = try preferences.reset()
            invalidateScan(result: .superseded)
            lastScanResult = .unchanged
            publish(snapshot)
            operationFeedback = .settingsReset
            if snapshot.scannedBrowsers.isEmpty { rescan() }
            return .applied
        } catch { return noteFailure(error) }
    }

    @discardableResult
    func removeCustomBrowser(id: Browser.ID) -> BrowserMutationResult {
        do {
            let candidate = configuredBrowsers(in: try trustedSnapshot())
            guard let browser = candidate.first(where: { $0.id == id }), browser.isCustom else {
                return noteResult(.notFound)
            }
            if browser.isEnabled, candidate.filter(\.isEnabled).count == 1 {
                return noteResult(.wouldLeaveNoEnabledBrowser)
            }
            publish(try preferences.removeCustomBrowser(bundleIdentifier: id))
            operationFeedback = .removed(browser.browser.name)
            return .applied
        } catch { return noteFailure(error) }
    }

    @discardableResult
    func removeUnavailableCustomBrowser(_ installationID: Browser.InstallationID) -> BrowserMutationResult {
        do {
            let snapshot = try trustedSnapshot()
            guard let browser = preferences.customBrowsers(in: snapshot).first(where: { $0.installationID == installationID }),
                  !browser.isAvailable else { return noteResult(.notFound) }
            publish(try preferences.removeCustomBrowser(bundleIdentifier: browser.id, preservingBrowserChoices: true))
            operationFeedback = .removed(browser.name)
            return .applied
        } catch { return noteFailure(error) }
    }

    /// A canceled picker must not look like the previous operation failed again.
    /// Persistence failures still need attention until an operation resolves them.
    func prepareToAddCustomBrowser() {
        switch operationFeedback {
        case .storageFailure, .recentSaveFailed: return
        default: operationFeedback = nil
        }
    }

    func addCustomBrowser(appURL: URL) -> AddCustomBrowserResult {
        do {
            _ = try trustedSnapshot()
            guard let browser = Browser.application(at: appURL) else {
                operationFeedback = .invalidApplication
                return .invalidApplication
            }
            guard !isCurrentApplication(browser, appURL: appURL) else {
                operationFeedback = .currentApplicationNotAllowed
                return .currentApplicationNotAllowed
            }
            guard BrowserRepository.handlesWebURLs(bundleAt: appURL) else {
                operationFeedback = .doesNotHandleWebURLs
                return .doesNotHandleWebURLs
            }
            publish(try preferences.saveCustomBrowser(browser))
            operationFeedback = .added(browser.name)
            return .added(browser)
        } catch {
            noteFailure(error)
            return .storageFailure(error)
        }
    }

    @discardableResult
    func recordSelection(_ browser: Browser) -> BrowserMutationResult {
        do {
            _ = try trustedSnapshot()
            publish(try preferences.saveRecentBrowserIdentifier(browser.bundleIdentifier))
            operationFeedback = nil
            return .applied
        } catch {
            let result = noteFailure(error)
            operationFeedback = .recentSaveFailed(error)
            return result
        }
    }

    private func trustedSnapshot() throws(BrowserPreferencesError) -> BrowserPreferences.StoredPreferences {
        guard availability != .configurationUnreadable else { throw .unreadableConfiguration }
        return try preferences.load()
    }

    private struct InstallationInspection {
        let configured: [ConfiguredBrowser]
        let unavailableCustom: [Browser]
        let available: Set<Browser.InstallationID>
        let unavailable: Set<Browser.InstallationID>
    }

    private func inspect(_ snapshot: BrowserPreferences.StoredPreferences) -> InstallationInspection {
        let scanned = preferences.cachedScannedBrowsers(in: snapshot).filter { !isCurrentApplication($0, appURL: $0.appURL) }
        let custom = preferences.customBrowsers(in: snapshot).filter { !isCurrentApplication($0, appURL: $0.appURL) }
        var availability: [Browser.InstallationID: Bool] = [:]
        for browser in scanned + custom where availability[browser.installationID] == nil {
            availability[browser.installationID] = browser.isAvailable
        }
        var browsersByID: [Browser.ID: Browser] = [:]
        for browser in scanned where availability[browser.installationID] == true && browsersByID[browser.id] == nil {
            browsersByID[browser.id] = browser
        }
        for browser in custom where availability[browser.installationID] == true {
            browsersByID[browser.id] = browser
        }
        return InstallationInspection(
            configured: preferences.apply(snapshot, to: Array(browsersByID.values)),
            unavailableCustom: custom.filter { availability[$0.installationID] == false },
            available: Set(availability.filter(\.value).map(\.key)),
            unavailable: Set(availability.filter { !$0.value }.map(\.key))
        )
    }

    private func configuredBrowsers(in snapshot: BrowserPreferences.StoredPreferences) -> [ConfiguredBrowser] {
        inspect(snapshot).configured
    }

    @discardableResult
    private func publish(_ snapshot: BrowserPreferences.StoredPreferences) -> Set<Browser.InstallationID> {
        // One disk inspection per location in this publication; never cache across checkpoints.
        let inspection = inspect(snapshot)
        // Only observed restoration renews a run's quota, including after record removal.
        consumedAutomaticScanInstallations.subtract(inspection.available)
        let updated = State.configured(
            inspection.configured, unavailableCustom: inspection.unavailableCustom,
            recentBrowserID: snapshot.recentBrowserIdentifier
        )
        if state != updated { state = updated }
        return inspection.unavailable
    }

    @discardableResult
    private func noteFailure(_ error: BrowserPreferencesError) -> BrowserMutationResult {
        if error == .unreadableConfiguration {
            state = .unreadable
            invalidateScan(result: .storageFailure(error))
        }
        operationFeedback = .storageFailure(error)
        return .storageFailure(error)
    }

    private func noteResult(_ result: BrowserMutationResult) -> BrowserMutationResult {
        operationFeedback = result.wasAccepted ? nil : .mutationRejected(result)
        return result
    }

    private func finishScan(id: UUID, result: BrowserMutationResult) {
        guard pendingScan?.id == id else { return }
        lastScanResult = result
        invalidateScan(result: result)
    }

    private func invalidateScan(result: BrowserMutationResult) {
        pendingScan?.continuation.yield(result)
        pendingScan?.continuation.finish()
        pendingScan = nil
        isScanning = false
    }

    private func isCurrentApplication(_ browser: Browser, appURL: URL) -> Bool {
        if browser.bundleIdentifier == currentApplicationBundleIdentifier {
            return true
        }
        return appURL.standardizedFileURL.resolvingSymlinksInPath()
            == currentApplicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func handlesWebURLs(bundleAt appURL: URL) -> Bool {
        guard let bundle = Bundle(url: appURL) else { return false }
        let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .map { $0.lowercased() }
        return schemes.contains("http") || schemes.contains("https")
    }
}

enum BrowserAvailability: Equatable {
    case ready
    case allDisabled(suggestedBrowser: Browser)
    case noneDetected
    case configurationUnreadable
}

enum BrowserMutationResult: Equatable, Sendable {
    case applied
    case unchanged
    case notFound
    case wouldLeaveNoEnabledBrowser
    case storageFailure(BrowserPreferencesError)
    case superseded

    var wasAccepted: Bool { self == .applied || self == .unchanged }
}

enum AddCustomBrowserResult: Equatable {
    case added(Browser)
    case invalidApplication
    case doesNotHandleWebURLs
    case currentApplicationNotAllowed
    case storageFailure(BrowserPreferencesError)
}
