import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let browserRepository: BrowserRepository
    private let routingPreferencesStore: RoutingPreferencesStore
    private let routingSettingsEditor: RoutingSettingsEditor
    private let appLanguageStore: AppLanguageStore
    private let launchAtLoginController: LaunchAtLoginController
    private let defaultBrowserController: DefaultBrowserController
    private let applicationPresentationController: ApplicationPresentationController
    private let domainRuleSession: DomainRuleSettingsSession
    private let sectionSelection: SettingsSectionSelection
    let scopePresentation = ScopeEditorPresentation()
    private var deferredRuleUntilScopeDismissal: (() -> Void)?
    private var languageCancellable: AnyCancellable?

    /// Selected Settings section. Owned by the window (not the SwiftUI root) so
    /// that a Chooser-initiated reveal can switch sections in the same call stack
    /// that sends the Session intent, without rebuilding the hosting root.
    var selectedSection: SettingsSection {
        get { sectionSelection.section }
        set { sectionSelection.section = newValue }
    }

    init(
        browserRepository: BrowserRepository,
        routingPreferencesStore: RoutingPreferencesStore,
        appLanguageStore: AppLanguageStore,
        launchAtLoginController: LaunchAtLoginController,
        defaultBrowserController: DefaultBrowserController,
        applicationPresentationController: ApplicationPresentationController
    ) {
        self.browserRepository = browserRepository
        self.routingPreferencesStore = routingPreferencesStore
        let routingSettingsEditor = RoutingSettingsEditor(store: routingPreferencesStore)
        self.routingSettingsEditor = routingSettingsEditor
        self.appLanguageStore = appLanguageStore
        self.launchAtLoginController = launchAtLoginController
        self.defaultBrowserController = defaultBrowserController
        self.applicationPresentationController = applicationPresentationController
        // The window owns the single long-lived Domain Rule Settings session; the
        // SwiftUI adapter observes it. Keeping it here means a Chooser handoff can
        // route through `send(.requestRuleFromChooser)` without rebuilding the root.
        self.domainRuleSession = DomainRuleSettingsSession(store: routingPreferencesStore)
        let sectionSelection = SettingsSectionSelection()
        self.sectionSelection = sectionSelection
        let hostingController = NSHostingController(
            rootView: SettingsView(
                browserRepository: browserRepository,
                routingPreferencesStore: routingPreferencesStore,
                routingSettingsEditor: routingSettingsEditor,
                appLanguageStore: appLanguageStore,
                launchAtLoginController: launchAtLoginController,
                defaultBrowserController: defaultBrowserController,
                domainRuleSession: domainRuleSession,
                sectionSelection: sectionSelection,
                scopePresentation: scopePresentation
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = appLanguageStore.text("Eligo Settings")
        window.setContentSize(SettingsLayout.minimumSize)
        window.contentMinSize = SettingsLayout.minimumSize
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        scopePresentation.onDismiss = { [weak self] in
            guard let self else { return }
            let request = deferredRuleUntilScopeDismissal
            deferredRuleUntilScopeDismissal = nil
            request?()
        }
        languageCancellable = appLanguageStore.$language.sink { [weak self] language in
            self?.window?.title = self?.appLanguageStore.text("Eligo Settings", for: language)
                ?? "Eligo Settings"
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        browserRepository.refreshInstallations()
        defaultBrowserController.beginObserving(for: window)
        applicationPresentationController.settingsWillShow()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        defaultBrowserController.endObserving(for: window)

        // Synchronously drop all transient Rule Settings state and pending Chooser
        // requests. This is decoupled from the async visibility heuristic below,
        // which only manages activation policy once the window is actually gone.
        deferredRuleUntilScopeDismissal = nil
        scopePresentation.windowWillClose()
        _ = domainRuleSession.send(.windowClosed)

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !window.isVisible else { return }
            self.applicationPresentationController.settingsDidClose()
        }
    }

    /// Entry point for Chooser-initiated "create Domain Rule" requests.
    ///
    /// This never rebuilds the hosting root, so any active Rules adapter subtree
    /// and its presentation state survive. The request becomes a Session intent;
    /// when there is no active presentation the Session returns a one-shot
    /// `.revealRules` effect that we honor in this call stack by revealing the
    /// Rules section. The same effect is delivered exactly once per request:
    /// here for a direct Chooser request, or via the adapter's `onEffect` when a
    /// deferred request is promoted after a presentation ends. Neither path
    /// stores or replays the effect.
    func requestRuleFromChooser(
        host: String,
        destination: OpenDestination,
        completion: ((OpenDestinationID?) -> Void)? = nil
    ) {
        domainRuleSession.onChooserRuleFinished = completion
        show()
        if scopePresentation.item != nil {
            deferredRuleUntilScopeDismissal = { [weak self] in
                self?.presentRuleFromChooser(host: host, destinationID: destination.id)
            }
            return
        }
        presentRuleFromChooser(host: host, destinationID: destination.id)
    }

    private func presentRuleFromChooser(host: String, destinationID: OpenDestinationID) {
        let effect = domainRuleSession.send(
            .requestRuleFromChooser(host: host, destinationID: destinationID)
        )
        if effect == .revealRules {
            selectedSection = .rules
        }
    }

    /// Test-only access to the window-owned Domain Rule Settings session, so
    /// integration tests can assert transient state without exercising SwiftUI.
    var domainRuleSessionForTesting: DomainRuleSettingsSession {
        domainRuleSession
    }

    /// Test-only access to the section-selection holder that `SettingsView`
    /// observes. Sharing this reference lets a test write through the window
    /// side and assert the SwiftUI view re-renders (it observes the same object
    /// rather than a detached binding that would miss the change).
    var sectionSelectionForTesting: SettingsSectionSelection {
        sectionSelection
    }
}

/// Observable holder for the selected Settings section, so the window can drive
/// section selection (e.g. a Chooser-initiated reveal) independently of the
/// SwiftUI root's lifetime while still binding `SettingsView` to it.
@MainActor
final class SettingsSectionSelection: ObservableObject {
    @Published var section: SettingsSection = .general
}
