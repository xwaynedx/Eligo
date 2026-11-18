import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let browserRepository: BrowserRepository
    private let routingPreferencesStore: RoutingPreferencesStore
    private let setupGuideStore: SetupGuideStore
    private let appLanguageStore: AppLanguageStore
    private let launchAtLoginController: LaunchAtLoginController
    private let defaultBrowserController: DefaultBrowserController
    private let browserLauncher = BrowserLauncher()
    private let applicationPresentationController = ApplicationPresentationController()
    private lazy var chooserWindowController = ChooserWindowController(appLanguageStore: appLanguageStore)
    private lazy var applicationMenuController = ApplicationMenuController(appLanguageStore: appLanguageStore)
    private let urlRouter: URLRouter
    private let replyToOpenOrPrint: (NSApplication, NSApplication.DelegateReply) -> Void
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?
    private var welcomeWindowController: WelcomeWindowController?
    private lazy var linkRoutingCoordinator = LinkRoutingCoordinator(
        browserRepository: browserRepository,
        destinationLauncher: browserLauncher,
        chooser: chooserWindowController,
        routingPolicy: RoutingPolicy(),
        routingPreferencesStore: routingPreferencesStore,
        appLanguageStore: appLanguageStore,
        onOpenSettings: { [weak self] in self?.showSettings() },
        onCreateRule: { [weak self] host, destination, completion in
            self?.settingsWindowController?.requestRuleFromChooser(
                host: host, destination: destination, completion: completion
            )
        }
    )

    init(
        browserRepository: BrowserRepository = BrowserRepository(),
        routingPreferencesStore: RoutingPreferencesStore = RoutingPreferencesStore(),
        setupGuideStore: SetupGuideStore = SetupGuideStore(),
        appLanguageStore: AppLanguageStore = AppLanguageStore(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        defaultBrowserController: DefaultBrowserController = DefaultBrowserController(),
        urlRouter: URLRouter = URLRouter(),
        replyToOpenOrPrint: @escaping (NSApplication, NSApplication.DelegateReply) -> Void = {
            $0.reply(toOpenOrPrint: $1)
        }
    ) {
        self.browserRepository = browserRepository
        self.routingPreferencesStore = routingPreferencesStore
        self.setupGuideStore = setupGuideStore
        self.appLanguageStore = appLanguageStore
        self.launchAtLoginController = launchAtLoginController
        self.defaultBrowserController = defaultBrowserController
        self.urlRouter = urlRouter
        self.replyToOpenOrPrint = replyToOpenOrPrint
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationPresentationController.enterBackgroundMode()
        NSApp.applicationIconImage = EligoIcon.appIcon()
        applicationMenuController.install()
        LaunchServicesBrowserManager.registerCurrentApplication()
        installURLHandler()
        installURLRouterHandler()

        settingsWindowController = SettingsWindowController(
            browserRepository: browserRepository,
            routingPreferencesStore: routingPreferencesStore,
            appLanguageStore: appLanguageStore,
            launchAtLoginController: launchAtLoginController,
            defaultBrowserController: defaultBrowserController,
            applicationPresentationController: applicationPresentationController
        )
        aboutWindowController = AboutWindowController(appLanguageStore: appLanguageStore)
        welcomeWindowController = WelcomeWindowController(
            appLanguageStore: appLanguageStore,
            browserRepository: browserRepository,
            defaultBrowserController: defaultBrowserController,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onAddFirstRule: { [weak self] in self?.showSettingsRevealingRules() }
        )
        menuBarController = MenuBarController(
            onOpenSettings: { [weak self] in self?.showSettings() },
            onRescanBrowsers: { [weak self] in
                guard let self else { return }
                Task {
                    let result = await self.browserRepository.rescan().value
                    if !result.wasAccepted, result != .superseded {
                        self.showSettings()
                    }
                }
            },
            onHelpSetDefaultBrowser: { [weak self] in self?.showSettings() },
            onOpenAbout: { [weak self] in self?.showAbout() },
            onShowWelcomeGuide: { [weak self] in self?.showWelcomeGuide() },
            routingPreferencesStore: routingPreferencesStore,
            appLanguageStore: appLanguageStore,
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        presentSetupGuideIfActivationIncomplete()

        AppLog.app.info("Eligo launched")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        defaultBrowserController.applicationDidBecomeActive()
        browserRepository.refreshInstallations()
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        AppLog.routing.info("Installed URL event handler")
    }

    private func installURLRouterHandler() {
        urlRouter.setHandler { [weak self] link, completion in
            self?.linkRoutingCoordinator.route(link, completion: completion)
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else {
            AppLog.routing.error("Received invalid URL event")
            return
        }

        urlRouter.route(IncomingLink(url: url, source: LinkSourceResolver.source(for: event)))
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var acceptedAnyFile = false

        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            guard URLRouter.isSupported(url) else {
                AppLog.routing.warning("Ignored unsupported file open request: \(filename, privacy: .private)")
                continue
            }

            AppLog.routing.info("Received file open request: \(url.absoluteString, privacy: .private)")
            urlRouter.route(IncomingLink(url: url))
            acceptedAnyFile = true
        }

        // Success acknowledges Router ownership, before any chooser decision.
        replyToOpenOrPrint(sender, acceptedAnyFile ? .success : .failure)
    }

    /// Auto-opens the Welcome Guide exactly once per install, and only while
    /// activation is incomplete. Users who postpone are reminded passively via
    /// the menu bar's Help Set Default Browser item instead of repeated windows.
    private func presentSetupGuideIfActivationIncomplete() {
        defaultBrowserController.refresh()
        guard SetupGuideActivation.shouldAutoShow(
            hasAutoShownSetup: setupGuideStore.hasAutoShownSetup,
            isDefaultBrowser: defaultBrowserController.state.isDefaultBrowser,
            hasUsableBrowsers: !browserRepository.enabledBrowsers.isEmpty
        ) else {
            return
        }

        // Mark before showing so a crash while presenting cannot loop the window.
        setupGuideStore.markSetupAutoShown()
        showWelcomeGuide()
    }

    private func showWelcomeGuide() {
        welcomeWindowController?.show()
    }

    /// The complete page's "Add Your First Rule" follow-through: land the
    /// user directly on the Rules tab, mirroring `requestRuleFromChooser`.
    private func showSettingsRevealingRules() {
        settingsWindowController?.selectedSection = .rules
        showSettings()
    }

    private func showSettings() {
        settingsWindowController?.show()
    }

    private func showAbout() {
        aboutWindowController?.show()
    }
}
