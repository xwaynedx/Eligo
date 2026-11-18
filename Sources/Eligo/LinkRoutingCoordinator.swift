import Foundation

@MainActor
protocol BrowserChoosing: AnyObject {
    func present(
        link: IncomingLink,
        destinations: [OpenDestination],
        recentBrowserID: Browser.ID?,
        routingHint: ChooserRoutingHint?,
        onCreateRule: ((String, OpenDestination) -> Void)?,
        completion: @escaping (OpenDestination?) -> Void
    )

    func presentRecovery(
        message: String,
        source: LinkSource?,
        primaryAction: ChooserRecoveryAction,
        secondaryAction: ChooserRecoveryAction?,
        onCancel: @escaping @MainActor @Sendable () -> Void
    )
}

@MainActor
protocol DestinationLaunching: AnyObject {
    func open(
        _ url: URL,
        in destination: OpenDestination,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    )

    /// Delivery can finish before an OS focus request. Keep the current route
    /// owned until that request can no longer affect the next link.
    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void)
}

extension ChooserWindowController: BrowserChoosing {}
extension BrowserLauncher: DestinationLaunching {}

@MainActor
final class LinkRoutingCoordinator {
    private let browserRepository: BrowserRepository
    private let destinationLauncher: any DestinationLaunching
    private let chooser: any BrowserChoosing
    private let routingPolicy: RoutingPolicy
    private let routingPreferencesStore: RoutingPreferencesStore
    private let appLanguageStore: AppLanguageStore
    private let destinationCatalog: @Sendable ([Browser]) -> DestinationCatalog
    private let onOpenSettings: @MainActor @Sendable () -> Void
    private let onCreateRule: ((String, OpenDestination, @escaping (OpenDestinationID?) -> Void) -> Void)?
    private let now: @MainActor () -> TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    init(
        browserRepository: BrowserRepository,
        destinationLauncher: any DestinationLaunching,
        chooser: any BrowserChoosing,
        routingPolicy: RoutingPolicy = RoutingPolicy(),
        routingPreferencesStore: RoutingPreferencesStore,
        appLanguageStore: AppLanguageStore,
        destinationCatalog: @escaping @Sendable ([Browser]) -> DestinationCatalog = { DestinationCatalog(enabledBrowsers: $0) },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, action in
            let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        onOpenSettings: @escaping @MainActor @Sendable () -> Void,
        onCreateRule: ((String, OpenDestination, @escaping (OpenDestinationID?) -> Void) -> Void)? = nil
    ) {
        self.browserRepository = browserRepository
        self.destinationLauncher = destinationLauncher
        self.chooser = chooser
        self.routingPolicy = routingPolicy
        self.routingPreferencesStore = routingPreferencesStore
        self.appLanguageStore = appLanguageStore
        self.destinationCatalog = destinationCatalog
        self.now = now
        self.schedule = schedule
        self.onOpenSettings = onOpenSettings
        self.onCreateRule = onCreateRule
    }

    @discardableResult
    func route(
        _ link: IncomingLink,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        let request = Request(link: link, completion: completion)
        return Task { [weak self] in
            await withTaskCancellationHandler {
                guard let self, !Task.isCancelled else { request.finish(); return }
                let settings = self.routingPreferencesStore.settings
                let plan = self.routingPolicy.basePlan(for: link.url, settings: settings)
                guard self.refresh(for: request) else { return }
                let target: OpenDestinationID?
                switch plan {
                case .choose: target = nil
                case let .open(id, _): target = settings.alwaysShowChooser ? nil : id
                }
                if self.needsDiscovery(for: target), let scan = self.browserRepository.discoveryTask {
                    guard await self.waitForDiscovery(scan, target: target, request: request, recoveryPlan: plan) else { return }
                } else if self.browserRepository.enabledBrowsers.isEmpty, !self.browserRepository.discoveryResult.wasAccepted {
                    self.presentBrowserOperationFailure(self.browserRepository.discoveryResult, for: request)
                    return
                }
                guard !Task.isCancelled, !request.finished else { request.finish(); return }
                self.presentRoutedLink(request, plan: plan)
            } onCancel: {
                Task { @MainActor in request.finish() }
            }
        }
    }

    private var catalog: DestinationCatalog { destinationCatalog(browserRepository.enabledBrowsers) }

    private func needsDiscovery(for target: OpenDestinationID?) -> Bool {
        if let target { return catalog.destination(for: target) == nil }
        return browserRepository.enabledBrowsers.isEmpty
    }

    private func refresh(for request: Request) -> Bool {
        guard !request.finished else { return false }
        let result = browserRepository.refreshInstallations()
        guard result.wasAccepted else {
            presentBrowserOperationFailure(result, for: request)
            return false
        }
        return true
    }

    private func presentRoutedLink(_ request: Request, plan: RoutingPlan) {
        guard refresh(for: request) else { return }
        switch browserRepository.availability {
        case .ready:
            // Keep the original target ID while honoring a newer chooser override.
            if routingPreferencesStore.settings.alwaysShowChooser {
                presentBrowserChooser(for: request)
                return
            }
            switch plan {
            case .choose: presentBrowserChooser(for: request)
            case let .open(id, _): open(request, destinationID: id, recordsManualSelection: false)
            }
        case let .allDisabled(suggestedBrowser):
            presentRecovery(
                message: appLanguageStore.format("No browsers are enabled. Enable %@ to continue.", suggestedBrowser.name),
                primaryTitle: appLanguageStore.format("Enable %@", suggestedBrowser.name),
                for: request
            ) { [weak self] in
                guard let self else { request.finish(); return }
                let result = browserRepository.setEnabled(true, for: suggestedBrowser.id)
                if result.wasAccepted { presentRoutedLink(request, plan: plan) }
                else { presentBrowserOperationFailure(result, for: request) }
            }
        case .configurationUnreadable:
            presentBrowserOperationFailure(.storageFailure(.unreadableConfiguration), for: request)
        case .noneDetected:
            presentDiscoveryRecovery(for: request, plan: plan)
        }
    }

    private func presentDiscoveryRecovery(for request: Request, plan: RoutingPlan, timedOut: Bool = false) {
        presentRecovery(
            message: appLanguageStore.text(timedOut
                ? "Browser discovery timed out. Rescan or add a browser in Settings."
                : "No browser apps were found. Rescan or add one in Settings."),
            primaryTitle: appLanguageStore.text("Rescan"), for: request
        ) { [weak self] in
            guard let self else { request.finish(); return }
            // An explicit retry starts a new wait; incidental refreshes never do.
            request.discoveryDeadline = nil
            let scan = browserRepository.rescan()
            Task { [weak self] in
                guard let self else { request.finish(); return }
                if await waitForDiscovery(scan, target: nil, request: request, recoveryPlan: plan) {
                    presentRoutedLink(request, plan: plan)
                }
            }
        }
    }

    private func presentBrowserOperationFailure(_ result: BrowserMutationResult, for request: Request) {
        presentRecovery(
            message: result.message(using: appLanguageStore),
            primaryTitle: appLanguageStore.text("Open Settings"), for: request, offersSettings: false
        ) { [weak self] in
            self?.onOpenSettings()
            request.finish()
        }
    }

    private func presentBrowserChooser(for request: Request, mayWait: Bool = true) {
        guard refresh(for: request) else { return }
        guard !catalog.destinations.isEmpty else {
            let plan = RoutingPlan.choose(reason: .noMatchingRule)
            if mayWait, let scan = browserRepository.discoveryTask {
                Task { [weak self] in
                    guard let self else { request.finish(); return }
                    if await waitForDiscovery(scan, target: nil, request: request, recoveryPlan: plan) {
                        presentBrowserChooser(for: request, mayWait: false)
                    }
                }
            } else {
                presentRoutedLink(request, plan: plan)
            }
            return
        }
        let step = request.nextStep()
        let createRule: ((String, OpenDestination) -> Void)? = onCreateRule.map { requestRuleCreation in
            { [weak self] host, destination in
                guard request.claim(step) else { return }
                let editingStep = request.nextStep()
                requestRuleCreation(host, destination) { [weak self] savedDestinationID in
                    guard request.claim(editingStep) else { return }
                    guard let self else { request.finish(); return }
                    request.discoveryDeadline = nil
                    if let savedDestinationID {
                        open(request, destinationID: savedDestinationID, recordsManualSelection: true)
                    } else {
                        presentBrowserChooser(for: request)
                    }
                }
            }
        }
        chooser.present(
            link: request.link, destinations: catalog.destinations,
            recentBrowserID: browserRepository.recentBrowserIdentifier,
            routingHint: routingPolicy.chooserHint(for: request.link.url, settings: routingPreferencesStore.settings),
            onCreateRule: createRule
        ) { [weak self] destination in
            guard request.claim(step) else { return }
            guard let self, let destination else { request.finish(); return }
            request.discoveryDeadline = nil
            open(request, destinationID: destination.id, recordsManualSelection: true)
        }
    }

    private func presentUnavailableDestinationRecovery(_ id: OpenDestinationID, for request: Request) {
        presentRecovery(
            message: appLanguageStore.format("Saved destination %@ is unavailable.", id.browserID),
            primaryTitle: appLanguageStore.text("Choose Another Browser"), for: request
        ) { [weak self] in
            guard let self else { request.finish(); return }
            // Rebuild the chooser when the user acts, not from a captured catalog.
            request.discoveryDeadline = nil
            presentBrowserChooser(for: request)
        }
    }

    private func open(
        _ request: Request,
        destinationID: OpenDestinationID,
        recordsManualSelection: Bool,
        mayWait: Bool = true
    ) {
        guard refresh(for: request) else { return }
        guard let destination = catalog.destination(for: destinationID) else {
            if mayWait, let scan = browserRepository.discoveryTask {
                Task { [weak self] in
                    guard let self else { request.finish(); return }
                    if await waitForDiscovery(scan, target: destinationID, request: request) {
                        open(request, destinationID: destinationID, recordsManualSelection: recordsManualSelection, mayWait: false)
                    }
                }
            } else {
                presentUnavailableDestinationRecovery(destinationID, for: request)
            }
            return
        }
        let step = request.nextStep()
        destinationLauncher.open(request.link.url, in: destination) { [weak self] success in
            guard request.claim(step) else { return }
            guard let self else { request.finish(); return }
            if success {
                if recordsManualSelection { browserRepository.recordSelection(destination.browser) }
                // Delivery and the existing OS activation barrier remain separate.
                let settling = request.nextStep()
                destinationLauncher.whenActivationSettles {
                    if request.isCurrent(settling) { request.finish() }
                }
                return
            }
            presentRecovery(
                message: destination.mode == .privateBrowsing
                    ? appLanguageStore.format("%@ could not be opened in Private mode.", destination.browser.name)
                    : appLanguageStore.format("%@ could not be opened.", destination.browser.name),
                primaryTitle: appLanguageStore.text("Try Again"), for: request
            ) { [weak self] in
                guard let self else { request.finish(); return }
                request.discoveryDeadline = nil
                open(request, destinationID: destinationID, recordsManualSelection: recordsManualSelection)
            }
        }
    }

    private func presentRecovery(
        message: String, primaryTitle: String, for request: Request, offersSettings: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        guard !request.finished else { return }
        let step = request.nextStep()
        chooser.presentRecovery(
            message: message, source: request.link.source,
            primaryAction: ChooserRecoveryAction(title: primaryTitle) {
                guard request.claim(step) else { return }
                action()
            },
            secondaryAction: offersSettings ? ChooserRecoveryAction(title: appLanguageStore.text("Open Settings")) { [weak self] in
                guard request.claim(step) else { return }
                self?.onOpenSettings()
                request.finish()
            } : nil,
            onCancel: {
                if request.isCurrent(step) { request.finish() }
            }
        )
    }

    private func waitForDiscovery(
        _ scan: Task<BrowserMutationResult, Never>, target: OpenDestinationID?, request: Request,
        recoveryPlan: RoutingPlan = .choose(reason: .noMatchingRule)
    ) async -> Bool {
        guard !request.finished else { return false }
        let deadline = request.discoveryDeadline ?? (now() + 2)
        request.discoveryDeadline = deadline
        let waiter = ScanWait()
        request.cancelWait = { waiter.finish(.cancelled) }
        let observedOutcome = await waiter.value(for: scan, delay: max(0, deadline - now()), schedule: schedule)
        request.cancelWait = nil
        guard !request.finished, !Task.isCancelled else { request.finish(); return false }
        let outcome: ScanWait.Outcome
        if case let .completed(result) = observedOutcome, result.wasAccepted, now() >= deadline {
            outcome = .timedOut
        } else {
            outcome = observedOutcome
        }
        switch outcome {
        case let .completed(result):
            guard result.wasAccepted else { presentBrowserOperationFailure(result, for: request); return false }
            return true
        case .timedOut:
            if let target { presentUnavailableDestinationRecovery(target, for: request) }
            else { presentDiscoveryRecovery(for: request, plan: recoveryPlan, timedOut: true) }
            return false
        case .cancelled:
            request.finish()
            return false
        }
    }

    @MainActor
    private final class Request {
        let link: IncomingLink
        private let completion: @MainActor @Sendable () -> Void
        private var step = 0
        private(set) var finished = false
        var discoveryDeadline: TimeInterval?
        var cancelWait: (() -> Void)?

        init(link: IncomingLink, completion: @escaping @MainActor @Sendable () -> Void) {
            self.link = link
            self.completion = completion
        }

        @discardableResult
        func nextStep() -> Int { step += 1; return step }
        func isCurrent(_ expected: Int) -> Bool { !finished && step == expected }
        func claim(_ expected: Int) -> Bool {
            guard isCurrent(expected) else { return false }
            nextStep()
            return true
        }

        func finish() {
            guard !finished else { return }
            finished = true
            cancelWait?()
            cancelWait = nil
            completion()
        }
    }

    /// Race an uncancellable scanner without making a task group await its loser.
    @MainActor
    private final class ScanWait {
        enum Outcome {
            case completed(BrowserMutationResult)
            case timedOut
            case cancelled
        }
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var cancelTimer: (() -> Void)?

        func value(
            for scan: Task<BrowserMutationResult, Never>, delay: TimeInterval,
            schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
        ) async -> Outcome {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                cancelTimer = schedule(delay) { [weak self] in self?.finish(.timedOut) }
                Task { [weak self] in
                    let result = await scan.value
                    self?.finish(.completed(result))
                }
            }
        }

        func finish(_ outcome: Outcome) {
            guard let continuation else { return }
            self.continuation = nil
            cancelTimer?()
            cancelTimer = nil
            continuation.resume(returning: outcome)
        }
    }
}
