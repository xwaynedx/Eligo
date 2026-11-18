import AppKit

@MainActor
protocol WorkspaceOpening: AnyObject {
    func openURLs(_ urls: [URL], withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Bool) -> Void)
    func openApplication(
        at applicationURL: URL,
        arguments: [String],
        createsNewApplicationInstance: Bool,
        completion: @escaping @MainActor (Bool, NSRunningApplication?) -> Void
    )
}

@MainActor
protocol GeckoPrivateLaunching: AnyObject {
    func openPrivateWindow(
        at applicationURL: URL,
        bundleIdentifier: String,
        arguments: [String],
        completion: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
protocol ProcessExecuting: AnyObject {
    func run(
        executableURL: URL,
        arguments: [String],
        waitForTermination: Bool,
        terminationTimeout: TimeInterval?,
        shouldTerminateOnTimeout: @escaping @MainActor (_ processIdentifier: pid_t) -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
final class NSWorkspaceOpener: WorkspaceOpening {
    typealias URLRequest = @MainActor (
        [URL], URL, NSWorkspace.OpenConfiguration, @escaping @MainActor (Bool) -> Void
    ) -> Void

    private let openURLRequest: URLRequest

    init(openURLRequest: @escaping URLRequest = { urls, applicationURL, configuration, completion in
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
            Task { @MainActor in completion(error == nil) }
        }
    }) {
        self.openURLRequest = openURLRequest
    }

    func openURLs(_ urls: [URL], withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        // Firefox interprets a background URL request as a background tab. Bringing
        // the app forward afterwards cannot select that tab; express the intent here.
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        openURLRequest(urls, applicationURL, configuration, completion)
    }

    func openApplication(
        at applicationURL: URL,
        arguments: [String],
        createsNewApplicationInstance: Bool,
        completion: @escaping @MainActor (Bool, NSRunningApplication?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = arguments
        // LaunchServices drops configuration.arguments when it reuses an already-running
        // instance. Force a new instance so --incognito and the URL reach Chromium.
        // This stays on NSWorkspace (Keychain-safe); bare Process launch does not.
        configuration.createsNewApplicationInstance = createsNewApplicationInstance
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            Task { @MainActor in completion(error == nil, application) }
        }
    }
}

@MainActor
final class ProcessExecutor: ProcessExecuting {
    private final class PendingProcess {
        let process: Process
        let completion: @MainActor (Bool) -> Void
        var timeoutWorkItem: DispatchWorkItem?

        init(process: Process, completion: @escaping @MainActor (Bool) -> Void) {
            self.process = process
            self.completion = completion
        }
    }

    private var pendingProcesses: [UUID: PendingProcess] = [:]

    func run(
        executableURL: URL,
        arguments: [String],
        waitForTermination: Bool,
        terminationTimeout: TimeInterval?,
        shouldTerminateOnTimeout: @escaping @MainActor (_ processIdentifier: pid_t) -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let processID = UUID()
        if waitForTermination {
            let pendingProcess = PendingProcess(process: process, completion: completion)
            pendingProcesses[processID] = pendingProcess
            process.terminationHandler = { [weak self] terminatedProcess in
                let wasSuccessful = terminatedProcess.terminationReason == .exit && terminatedProcess.terminationStatus == 0
                Task { @MainActor in
                    self?.completePendingProcess(id: processID, result: wasSuccessful, terminate: false)
                }
            }
            if let terminationTimeout {
                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.completePendingProcess(
                            id: processID,
                            result: false,
                            terminate: shouldTerminateOnTimeout(process.processIdentifier)
                        )
                    }
                }
                pendingProcess.timeoutWorkItem = timeoutWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + terminationTimeout, execute: timeoutWorkItem)
            }
        }

        do {
            try process.run()
            if !waitForTermination {
                completion(true)
            }
        } catch {
            pendingProcesses.removeValue(forKey: processID)?.timeoutWorkItem?.cancel()
            AppLog.routing.error("Gecko private launch process could not start: \(error.localizedDescription, privacy: .public)")
            completion(false)
        }
    }

    private func completePendingProcess(id: UUID, result: Bool, terminate: Bool) {
        guard let pendingProcess = pendingProcesses.removeValue(forKey: id) else { return }
        pendingProcess.timeoutWorkItem?.cancel()
        if terminate, pendingProcess.process.isRunning {
            pendingProcess.process.terminate()
        }
        pendingProcess.completion(result)
    }
}

/// Starts a Gecko-based browser through its own executable so that its Private
/// argument reaches an already-running profile. LaunchServices drops
/// command-line arguments when it reuses an existing app instance.
@MainActor
final class GeckoPrivateProcessLauncher: GeckoPrivateLaunching {
    private static let runningGeckoForwarderTimeout: TimeInterval = 10
    private let processExecutor: ProcessExecuting
    private let runningApplicationProcessIdentifiers: @MainActor (String) -> Set<pid_t>
    private let executableResolver: (URL) -> URL?

    init(
        processExecutor: ProcessExecuting = ProcessExecutor(),
        runningApplicationProcessIdentifiers: @escaping @MainActor (String) -> Set<pid_t> = { bundleIdentifier in
            Set(
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .map(\.processIdentifier)
            )
        },
        executableResolver: @escaping (URL) -> URL? = { applicationURL in
            Bundle(url: applicationURL)?.executableURL
        }
    ) {
        self.processExecutor = processExecutor
        self.runningApplicationProcessIdentifiers = runningApplicationProcessIdentifiers
        self.executableResolver = executableResolver
    }

    func openPrivateWindow(
        at applicationURL: URL,
        bundleIdentifier: String,
        arguments: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let executableURL = executableResolver(applicationURL) else {
            AppLog.routing.error("Gecko private launch executable could not be resolved")
            completion(false)
            return
        }
        let originalProcessIdentifiers = runningApplicationProcessIdentifiers(bundleIdentifier)
        let isRunning = !originalProcessIdentifiers.isEmpty
        processExecutor.run(
            executableURL: executableURL,
            arguments: arguments,
            waitForTermination: isRunning,
            terminationTimeout: isRunning ? Self.runningGeckoForwarderTimeout : nil,
            shouldTerminateOnTimeout: { [runningApplicationProcessIdentifiers] launchedProcessIdentifier in
                // Timeout cleanup kills only a stray forwarder: never a process still
                // registered under the browser's bundle identifier (it may have become
                // a genuine browser instance), and only while an originally running
                // instance survives, so the user's own browser is never the casualty.
                let currentProcessIdentifiers = runningApplicationProcessIdentifiers(bundleIdentifier)
                guard !currentProcessIdentifiers.contains(launchedProcessIdentifier) else {
                    return false
                }
                return !originalProcessIdentifiers.isDisjoint(with: currentProcessIdentifiers)
            },
            completion: completion
        )
    }
}

@MainActor
final class BrowserLauncher {
    private let workspace: WorkspaceOpening
    private let geckoPrivateLauncher: GeckoPrivateLaunching
    private let applicationActivator: ApplicationActivating
    private var pendingLaunches: [UUID: PendingLaunch] = [:]

    private final class PendingLaunch {
        var deliveryHandled = false
        var activation: ActivationCancellation?
        let completion: @MainActor @Sendable (Bool) -> Void
        init(completion: @escaping @MainActor @Sendable (Bool) -> Void) { self.completion = completion }
    }

    init(
        workspace: WorkspaceOpening = NSWorkspaceOpener(),
        geckoPrivateLauncher: GeckoPrivateLaunching = GeckoPrivateProcessLauncher(),
        applicationActivator: ApplicationActivating = NSRunningApplicationActivator()
    ) {
        self.workspace = workspace
        self.geckoPrivateLauncher = geckoPrivateLauncher
        self.applicationActivator = applicationActivator
    }

    func open(_ url: URL, in destination: OpenDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let browser = destination.browser
        let id = UUID()
        let request = PendingLaunch(completion: completion)
        pendingLaunches[id] = request
        switch destination.mode {
        case .normal:
            let launchCompletion = completionAfterActivation(id: id, for: browser, mayActivateOnLaunch: true)
            workspace.openURLs([url], withApplicationAt: browser.appURL) { success in
                launchCompletion(success, nil)
            }
        case .privateBrowsing:
            guard let adapter = BrowserDefinition.definition(for: browser.bundleIdentifier)?.privateLaunchAdapter else {
                AppLog.routing.error("Private launch is unavailable for \(browser.name, privacy: .public)")
                finish(id: id, delivered: false)
                return
            }
            let launchCompletion = completionAfterActivation(
                id: id, for: browser, mayActivateOnLaunch: adapter.family == .firefox
            )
            switch adapter.family {
            case .chromium:
                workspace.openApplication(
                    at: browser.appURL,
                    arguments: privateArguments(for: adapter, url: url),
                    createsNewApplicationInstance: true,
                    completion: launchCompletion
                )
            case .firefox:
                geckoPrivateLauncher.openPrivateWindow(
                    at: browser.appURL,
                    bundleIdentifier: browser.bundleIdentifier,
                    arguments: privateArguments(for: adapter, url: url),
                    completion: { success in
                        launchCompletion(success, nil)
                    }
                )
            }
        }
    }

    /// Cancels only Eligo's activation work, never the browser or URL delivery.
    /// Any already-issued system request retains its presentation barrier.
    func cancelPendingActivations() {
        let activations = pendingLaunches.values.compactMap(\.activation)
        activations.forEach { $0.cancel() }
    }

    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) {
        applicationActivator.whenActivationSettles(completion)
    }

    private func completionAfterActivation(
        id: UUID,
        for browser: Browser,
        mayActivateOnLaunch: Bool
    ) -> @MainActor @Sendable (Bool, NSRunningApplication?) -> Void {
        let bundleIdentifier = browser.bundleIdentifier
        return { [self] success, preferredApplication in
            guard let request = pendingLaunches[id], !request.deliveryHandled else { return }
            request.deliveryHandled = true
            guard success else {
                finish(id: id, delivered: false)
                return
            }
            let activation = applicationActivator.activate(
                bundleIdentifier: bundleIdentifier,
                preferredApplication: preferredApplication,
                mayActivateOnLaunch: mayActivateOnLaunch
            ) { [self] _ in
                // Focus failure never changes successful delivery into a retry.
                finish(id: id, delivered: true)
            }
            pendingLaunches[id]?.activation = activation
        }
    }

    private func finish(id: UUID, delivered: Bool) {
        guard let request = pendingLaunches.removeValue(forKey: id) else { return }
        request.completion(delivered)
    }

    private func privateArguments(for adapter: PrivateLaunchAdapter, url: URL) -> [String] {
        [adapter.privateWindowArgument, url.absoluteString]
    }
}
