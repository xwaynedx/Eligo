import AppKit

enum ApplicationActivationResult: Equatable {
    case activated
    case timedOut
    case cancelled
}

@MainActor
final class ActivationCancellation {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func cancel() {
        let action = action
        self.action = nil
        action?()
    }
}

/// Coordinates focus handoff with the completion of the current route. Queued
/// links remain in URLRouter; this holds only its current completion boundary.
@MainActor
final class ActivationHandoffGate {
    private var unsettled: Set<UUID> = []
    private var continuation: (@MainActor () -> Void)?
    private var resumeScheduled = false
    private let resume: @MainActor (@escaping @MainActor () -> Void) -> Void

    init(resume: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.async(execute: action)
    }) {
        self.resume = resume
    }

    func begin(_ id: UUID) { unsettled.insert(id) }

    func end(_ id: UUID) {
        unsettled.remove(id)
        scheduleResumeIfSafe()
    }

    func whenSafe(_ continuation: @escaping @MainActor () -> Void) {
        self.continuation = continuation
        if !unsettled.isEmpty {
            AppLog.routing.info("URL queue paused for unresolved browser focus handoff")
        }
        scheduleResumeIfSafe()
    }

    private func scheduleResumeIfSafe() {
        guard unsettled.isEmpty, continuation != nil, !resumeScheduled else { return }
        resumeScheduled = true
        // Unwind the workspace/application notification before activating a new
        // chooser. Historical window notifications are also checked by identity.
        resume { [weak self] in
            guard let self else { return }
            resumeScheduled = false
            guard unsettled.isEmpty else { return }
            let action = continuation
            continuation = nil
            action?()
        }
    }
}

@MainActor
protocol ApplicationActivating: AnyObject {
    func activate(
        bundleIdentifier: String,
        preferredApplication: NSRunningApplication?,
        mayActivateOnLaunch: Bool,
        completion: @escaping (ApplicationActivationResult) -> Void
    ) -> ActivationCancellation

    /// The same component owns activation and the barrier for its OS requests.
    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
protocol ActivationApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isActive: Bool { get }
    var isTerminated: Bool { get }
    func activate(from application: NSRunningApplication, options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: ActivationApplication {}

enum ApplicationActivationEvent: Sendable {
    case activated(bundleIdentifier: String?, processIdentifier: pid_t)
    case terminated(bundleIdentifier: String?, processIdentifier: pid_t)
    case sourceDeactivated
    case changed
}

@MainActor
protocol ApplicationActivationSystem: AnyObject {
    /// Whether Eligo, the app yielding focus, is active. This is independent
    /// of the incoming link's Link Source.
    var isSourceActive: Bool { get }
    func findApplication(bundleIdentifier: String, preferredApplication: NSRunningApplication?) -> (any ActivationApplication)?
    func yieldActivation(to application: any ActivationApplication)
    func observe(_ action: @escaping @MainActor @Sendable (ApplicationActivationEvent) -> Void) -> () -> Void
}

@MainActor
final class WorkspaceActivationSystem: ApplicationActivationSystem {
    var isSourceActive: Bool { NSApp?.isActive == true }

    func findApplication(bundleIdentifier: String, preferredApplication: NSRunningApplication?) -> (any ActivationApplication)? {
        preferredApplication ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    func yieldActivation(to application: any ActivationApplication) {
        guard let runningApplication = application as? NSRunningApplication else {
            let applicationType = String(reflecting: type(of: application))
            let targetPID = application.processIdentifier
            AppLog.routing.error("Browser focus yield skipped: unexpected application type \(applicationType, privacy: .public), targetPID \(targetPID, privacy: .public)")
            return
        }
        NSApp?.yieldActivation(to: runningApplication)
    }

    func observe(_ action: @escaping @MainActor @Sendable (ApplicationActivationEvent) -> Void) -> () -> Void {
        let workspace = NSWorkspace.shared.notificationCenter
        let activated = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let event = ApplicationActivationEvent.activated(bundleIdentifier: app?.bundleIdentifier, processIdentifier: app?.processIdentifier ?? -1)
            MainActor.assumeIsolated { action(event) }
        }
        let terminated = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let event = ApplicationActivationEvent.terminated(bundleIdentifier: app?.bundleIdentifier, processIdentifier: app?.processIdentifier ?? -1)
            MainActor.assumeIsolated { action(event) }
        }
        let launched = workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action(.changed) }
        }
        let resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action(.sourceDeactivated) }
        }
        return {
            [activated, terminated, launched].forEach { workspace.removeObserver($0) }
            NotificationCenter.default.removeObserver(resigned)
        }
    }
}

/// Retry discovery/refused requests for at most two seconds. Once AppKit accepts
/// a request, never send another: acceptance is not an acknowledgement of focus.
/// A timeout/cancel completes the launch lifecycle, but an unresolved system
/// request keeps the presentation barrier closed until an actual handoff/exit.
@MainActor
final class NSRunningApplicationActivator: ApplicationActivating {
    private let system: any ApplicationActivationSystem
    private let gate: ActivationHandoffGate
    private let now: @MainActor () -> TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var requests: [UUID: Request] = [:]

    init(
        system: any ApplicationActivationSystem = WorkspaceActivationSystem(),
        gate: ActivationHandoffGate = ActivationHandoffGate(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, action in
            let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    ) {
        self.system = system
        self.gate = gate
        self.now = now
        self.schedule = schedule
    }

    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) {
        gate.whenSafe(completion)
    }

    func activate(
        bundleIdentifier: String,
        preferredApplication: NSRunningApplication?,
        mayActivateOnLaunch: Bool,
        completion: @escaping (ApplicationActivationResult) -> Void
    ) -> ActivationCancellation {
        let id = UUID()
        let request = Request(
            id: id, system: system, bundleIdentifier: bundleIdentifier, preferredApplication: preferredApplication,
            mayActivateOnLaunch: mayActivateOnLaunch, now: now, schedule: schedule,
            completion: completion,
            onSettled: { [weak self, gate] in
                self?.requests[id] = nil
                AppLog.routing.info("Browser focus handoff settled: \(id.uuidString, privacy: .public)")
                gate.end(id)
            }
        )
        requests[id] = request
        gate.begin(id)
        AppLog.routing.info("Browser activation began: \(id.uuidString, privacy: .public) for \(bundleIdentifier, privacy: .public)")
        request.start()
        return ActivationCancellation { [weak request] in request?.cancel() }
    }

    @MainActor
    private final class Request {
        private static let retryBudget: TimeInterval = 2.0
        private let id: UUID
        private let system: any ApplicationActivationSystem
        private let bundleIdentifier: String
        private let preferredApplication: NSRunningApplication?
        private let mayActivateOnLaunch: Bool
        private let now: @MainActor () -> TimeInterval
        private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
        private let startedAt: TimeInterval
        private let deadline: TimeInterval
        private var completion: ((ApplicationActivationResult) -> Void)?
        private var onSettled: (() -> Void)?
        private var cancelObservation: (() -> Void)?
        private var timers: [() -> Void] = []
        private var application: (any ActivationApplication)?
        private var requestAccepted = false
        private var activationObserved = false
        private var activationRequestCount = 0

        init(
            id: UUID, system: any ApplicationActivationSystem, bundleIdentifier: String,
            preferredApplication: NSRunningApplication?, mayActivateOnLaunch: Bool,
            now: @escaping @MainActor () -> TimeInterval,
            schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void,
            completion: @escaping (ApplicationActivationResult) -> Void,
            onSettled: @escaping () -> Void
        ) {
            self.id = id
            self.system = system
            self.bundleIdentifier = bundleIdentifier
            self.preferredApplication = preferredApplication
            self.mayActivateOnLaunch = mayActivateOnLaunch
            self.now = now
            self.schedule = schedule
            let startedAt = now()
            self.startedAt = startedAt
            self.deadline = startedAt + Self.retryBudget
            self.completion = completion
            self.onSettled = onSettled
        }

        func start() {
            cancelObservation = system.observe { [weak self] in self?.observe($0) }
            logState("started")
            // Absolute offsets preserve the original retry cadence; the separate
            // deadline bounds discovery and accepted-but-unacknowledged requests.
            for offset in [0.1, 0.35, 0.85, 1.85] {
                timers.append(schedule(offset) { [weak self] in self?.attempt() })
            }
            timers.append(schedule(max(0, deadline - now())) { [weak self] in
                self?.resolveAtDeadline()
            })
            attempt()
        }

        private func attempt() {
            guard completion != nil else { return }
            if now() >= deadline {
                resolveAtDeadline()
                return
            }
            discover()
            if settleIfObserved() { return }
            guard !requestAccepted, let application, !application.isTerminated else { return }
            // Regardless of the URL-delivery adapter, explicit focus transfer
            // supplies Eligo's cooperative yield and identifies Eligo as its source.
            system.yieldActivation(to: application)
            activationRequestCount += 1
            requestAccepted = application.activate(from: .current, options: [.activateAllWindows])
            logState("activationRequested")
            // Do not interpret a true return as actual focus transfer.
        }

        private func resolveAtDeadline() {
            guard completion != nil else { return }
            // A delayed main-queue tick can run after the OS already completed
            // handoff. Reconcile facts before timing out, without sending work.
            discover()
            logState("deadline")
            if !settleIfObserved() { finish(.timedOut) }
        }

        private func discover() {
            if application == nil {
                application = system.findApplication(bundleIdentifier: bundleIdentifier, preferredApplication: preferredApplication)
                if application != nil { logState("targetDiscovered") }
            }
        }

        private func observe(_ event: ApplicationActivationEvent) {
            guard onSettled != nil else { return }
            // Notifications prompt discovery; their bundle identifier alone
            // cannot identify the process receiving this launch request.
            discover()
            switch event {
            case let .activated(_, pid):
                guard matches(processIdentifier: pid) else { return }
                activationObserved = true
                logState("targetActivationObserved")
            case let .terminated(_, pid):
                guard matches(processIdentifier: pid) else { return }
                logState("targetTerminationObserved")
                settle()
                finish(.timedOut)
                return
            case .sourceDeactivated:
                logState("sourceDeactivated")
            case .changed:
                break
            }
            _ = settleIfObserved()
        }

        private func matches(processIdentifier: pid_t) -> Bool {
            guard let application else { return false }
            return application.processIdentifier == processIdentifier
        }

        @discardableResult
        private func settleIfObserved() -> Bool {
            if application?.isTerminated == true {
                settle()
                finish(.timedOut)
                return true
            }
            if application?.isActive == true { activationObserved = true }
            guard activationObserved, !system.isSourceActive else { return false }
            settle()
            finish(.activated)
            return true
        }

        func cancel() {
            logState("cancellationRequested")
            finish(.cancelled)
            // Cancellation stops Eligo's work, but observed OS facts can still
            // resolve its barrier. Preserve the single cancelled completion.
            guard onSettled != nil else { return }
            discover()
            _ = settleIfObserved()
        }

        private func finish(_ result: ApplicationActivationResult) {
            guard let completion else { return }
            self.completion = nil
            timers.forEach { $0() }
            timers.removeAll()
            // Foreground URL requests and process launches may activate before discovery;
            // cancellation of our timers cannot cancel that OS/browser work.
            if !requestAccepted && !mayActivateOnLaunch { settle() }
            let elapsed = now() - startedAt
            AppLog.routing.info("Browser activation finished: \(self.id.uuidString, privacy: .public), result \(String(describing: result), privacy: .public), elapsed \(elapsed, privacy: .public)s, handoffPending \(self.onSettled != nil, privacy: .public)")
            completion(result)
        }

        private func logState(_ phase: String) {
            AppLog.routing.info("Browser activation state: \(self.id.uuidString, privacy: .public), phase \(phase, privacy: .public), targetPID \(self.application?.processIdentifier ?? -1, privacy: .public), targetActive \(self.application?.isActive == true, privacy: .public), eligoActive \(self.system.isSourceActive, privacy: .public), requestCount \(self.activationRequestCount, privacy: .public), accepted \(self.requestAccepted, privacy: .public), activationObserved \(self.activationObserved, privacy: .public), mayActivateOnLaunch \(self.mayActivateOnLaunch, privacy: .public)")
        }

        private func settle() {
            guard let onSettled else { return }
            logState("settled")
            self.onSettled = nil
            cancelObservation?()
            cancelObservation = nil
            onSettled()
        }
    }
}
