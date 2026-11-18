import Combine
import CoreServices
import Foundation

/// One observation round, not an atomic transaction provided by macOS.
struct DefaultBrowserObservation: Equatable {
    let http: String?
    let https: String?

    func isDefaultBrowser(_ bundleIdentifier: String) -> Bool {
        http == bundleIdentifier && https == bundleIdentifier
    }
}

enum DefaultBrowserFeedback: Equatable {
    case notConfirmed
    case notCompleted
    case unchanged
    case restored
    case restorationIncomplete
}

struct DefaultBrowserState: Equatable {
    let observation: DefaultBrowserObservation
    let bundleIdentifier: String
    var feedback: DefaultBrowserFeedback?
    var isRequesting = false

    var isDefaultBrowser: Bool { observation.isDefaultBrowser(bundleIdentifier) }
    var canRequest: Bool { !isDefaultBrowser && !isRequesting }

    @MainActor
    func statusText(using language: AppLanguageStore) -> String {
        if isDefaultBrowser {
            return language.text("Eligo is the default browser for HTTP and HTTPS.")
        }
        if observation.http == observation.https, let handler = observation.http {
            return language.format("Current default browser: %@", handler)
        }
        return language.format(
            "Current defaults: HTTP %@; HTTPS %@",
            observation.http ?? language.text("Unknown"),
            observation.https ?? language.text("Unknown")
        )
    }

    @MainActor
    func feedbackText(using language: AppLanguageStore) -> String? {
        switch feedback {
        case .notConfirmed:
            language.text("The change is not confirmed. You can retry or choose Eligo in System Settings.")
        case .notCompleted:
            language.text("Automatic setup did not complete. You can retry or choose Eligo in System Settings.")
        case .unchanged:
            language.text("Automatic setup did not complete. Your default browser settings are unchanged.")
        case .restored:
            language.text("Automatic setup did not complete. Your previous default browser settings were restored.")
        case .restorationIncomplete:
            language.text("Automatic setup did not complete, and the previous defaults could not be fully restored. Check the current HTTP and HTTPS defaults in System Settings.")
        case nil:
            nil
        }
    }

    @MainActor
    func actionTitle(using language: AppLanguageStore) -> String {
        language.text(feedback == nil ? "Set Eligo as default" : "Retry")
    }
}

/// Owns system facts and request feedback for the application session. Only
/// the handler adapter crosses into LaunchServices; views never read it.
///
/// System confirmations and external default-handler edits can take effect
/// without another app-activation event. The public handler APIs used here
/// provide no change notification, so poll while a Settings or Welcome window
/// is open; the foreground refresh only reduces latency.
@MainActor
final class DefaultBrowserController: ObservableObject {
    @Published private(set) var state: DefaultBrowserState

    private let manager: any DefaultBrowserHandlerManaging
    private let registerApplication: () -> Void
    private var requestInProgress = false
    private var isPublishing = false
    private let schedule: (@escaping @MainActor @Sendable () -> Void) -> Void
    private var observingWindows: Set<ObjectIdentifier> = []
    private var pollGeneration = 0

    convenience init() {
        self.init(
            manager: LaunchServicesDefaultBrowserHandlerManager(),
            bundleIdentifier: LaunchServicesBrowserManager.bundleIdentifier,
            registerApplication: LaunchServicesBrowserManager.registerCurrentApplication
        )
    }

    init(
        manager: any DefaultBrowserHandlerManaging,
        bundleIdentifier: String,
        registerApplication: @escaping () -> Void = {},
        schedule: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { tick in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
        }
    ) {
        self.manager = manager
        self.registerApplication = registerApplication
        self.schedule = schedule
        state = DefaultBrowserState(
            observation: Self.read(using: manager), bundleIdentifier: bundleIdentifier
        )
    }

    func beginObserving(for window: AnyObject) {
        let wasEmpty = observingWindows.isEmpty
        observingWindows.insert(ObjectIdentifier(window))
        let generation = pollGeneration
        refresh()
        if wasEmpty, !observingWindows.isEmpty, generation == pollGeneration { scheduleNextPoll() }
    }

    func endObserving(for window: AnyObject) {
        guard observingWindows.remove(ObjectIdentifier(window)) != nil else { return }
        if observingWindows.isEmpty { pollGeneration += 1 }
    }

    func applicationDidBecomeActive() {
        if !observingWindows.isEmpty { refresh() }
    }

    private func scheduleNextPoll() {
        let generation = pollGeneration
        schedule { [weak self] in
            guard let self, !observingWindows.isEmpty, generation == pollGeneration else { return }
            refresh()
            // Publication can close/reopen windows; the old chain must not revive.
            guard !observingWindows.isEmpty, generation == pollGeneration else { return }
            scheduleNextPoll()
        }
    }

    func refresh() {
        guard !requestInProgress, !isPublishing else { return }
        let observation = Self.read(using: manager)
        publish(observation, feedback: observation == state.observation ? state.feedback : nil)
    }

    func requestDefaultBrowser() {
        // Also guards synchronous reentry via publication or a system run loop.
        guard !requestInProgress, !isPublishing else { return }
        requestInProgress = true
        defer { requestInProgress = false }

        let previous = Self.read(using: manager)
        guard !previous.isDefaultBrowser(state.bundleIdentifier) else {
            publish(previous, feedback: nil)
            return
        }
        publish(previous, feedback: nil, isRequesting: true)
        registerApplication()
        let httpStatus = manager.setDefaultHandler(state.bundleIdentifier, for: "http")
        let httpsStatus = manager.setDefaultHandler(state.bundleIdentifier, for: "https")
        let updated = Self.read(using: manager)
        AppLog.app.info("Default browser attempt: HTTP \(httpStatus), HTTPS \(httpsStatus); before \(String(describing: previous), privacy: .public); after \(String(describing: updated), privacy: .public)")

        if updated.isDefaultBrowser(state.bundleIdentifier) {
            publish(updated, feedback: nil)
            return
        }
        if updated == previous {
            // 0/-54 has historical machine evidence; -54/0 is the symmetric
            // design case. Neither proves that a confirmation dialog exists.
            let unconfirmed = (httpStatus == noErr && httpsStatus == noErr)
                || (httpStatus == noErr && httpsStatus == -54)
                || (httpStatus == -54 && httpsStatus == noErr)
            publish(updated, feedback: unconfirmed ? .notConfirmed : .unchanged)
            return
        }

        var attemptedRestore = false
        for (scheme, before, after) in [
            ("http", previous.http, updated.http), ("https", previous.https, updated.https)
        ] {
            guard before != after, let before else { continue }
            attemptedRestore = true
            let status = manager.setDefaultHandler(before, for: scheme)
            AppLog.app.info("Default browser restore \(scheme, privacy: .public): \(status)")
        }
        let final = Self.read(using: manager)
        AppLog.app.info("Default browser after restore: \(String(describing: final), privacy: .public)")
        let feedback: DefaultBrowserFeedback?
        if final.isDefaultBrowser(state.bundleIdentifier) {
            feedback = nil
        } else if final == previous {
            // Returning to the same Unknown values does not prove restoration
            // or that the defaults stayed unchanged throughout the attempt.
            feedback = attemptedRestore ? .restored : .notCompleted
        } else {
            feedback = .restorationIncomplete
        }
        publish(final, feedback: feedback)
    }

    private static func read(using manager: any DefaultBrowserHandlerManaging) -> DefaultBrowserObservation {
        DefaultBrowserObservation(http: manager.defaultHandler(for: "http"), https: manager.defaultHandler(for: "https"))
    }

    private func publish(
        _ observation: DefaultBrowserObservation,
        feedback: DefaultBrowserFeedback?,
        isRequesting: Bool = false
    ) {
        let next = DefaultBrowserState(
            observation: observation, bundleIdentifier: state.bundleIdentifier,
            feedback: feedback, isRequesting: isRequesting
        )
        guard state != next else { return }
        isPublishing = true
        defer { isPublishing = false }
        state = next
    }
}
