import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol BrowserAppPicking {
    func chooseBrowserApp(using store: AppLanguageStore, completion: @escaping @MainActor @Sendable (URL?) -> Void)
}

struct BrowserAppPicker: BrowserAppPicking {
    func chooseBrowserApp(using store: AppLanguageStore, completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = store.text("Choose Browser App")
        panel.message = store.text("Choose a browser app to show in Eligo.")
        panel.prompt = store.text("Add")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            Task { @MainActor in completion(url) }
        }
    }
}

extension SettingsView {
    // MARK: - Lifecycle and alerts

    func destructiveActionAlert(_ action: PendingDestructiveAction) -> Alert {
        Alert(
            title: Text(action.title(using: appLanguageStore)),
            message: Text(action.message(using: appLanguageStore)),
            primaryButton: .destructive(Text(action.confirmTitle(using: appLanguageStore))) {
                confirmPendingDestructiveAction(action)
            },
            secondaryButton: .cancel()
        )
    }

    func refreshExternalStatuses() {
        launchAtLoginController.refresh()
        browserRepository.refreshInstallations()
    }

    func refreshExternalStatuses(_: Notification) {
        refreshExternalStatuses()
    }

    func refreshDefaultStatus() {
        defaultBrowserController.refresh()
    }

    // MARK: - General / Routing Scope

    func presentScopeEditor() {
        scopePresentation.begin(store: routingPreferencesStore, editor: routingSettingsEditor, browserRepository: browserRepository)
    }

    func setAlwaysShowChooser(_ isEnabled: Bool) {
        // The editor publishes the semantic result; General localizes it at render time.
        try? routingSettingsEditor.setAlwaysShowChooser(isEnabled)
    }

    // MARK: - Default browser

    func setAsDefaultBrowser() {
        defaultBrowserController.requestDefaultBrowser()
    }

    // MARK: - Browsers

    func addCustomBrowser() {
        browserRepository.prepareToAddCustomBrowser()
        browserAppPicker.chooseBrowserApp(using: appLanguageStore) { url in
            guard let url else { return }
            _ = browserRepository.addCustomBrowser(appURL: url)
        }
    }

    func rescanBrowsers() {
        browserRepository.rescan()
        refreshDefaultStatus()
    }

    func setBrowserEnabled(_ browserID: Browser.ID, _ isEnabled: Bool) -> Bool {
        browserRepository.setEnabled(isEnabled, for: browserID).wasAccepted
    }

    func moveBrowser(from source: IndexSet, to destination: Int) -> Bool {
        browserRepository.moveBrowser(from: source, to: destination).wasAccepted
    }

    func requestSettingsReset() {
        pendingDestructiveAction = .reset
    }

    func requestCustomBrowserRemoval(_ browserID: Browser.ID) {
        guard let browser = browserRepository.browsers.first(where: { $0.id == browserID }) else {
            _ = browserRepository.removeCustomBrowser(id: browserID)
            return
        }
        pendingDestructiveAction = .removeBrowser(id: browserID, name: browser.browser.name)
    }

    func requestUnavailableCustomBrowserRemoval(_ id: Browser.InstallationID) {
        guard let browser = browserRepository.unavailableCustomBrowsers.first(where: { $0.installationID == id }) else { return }
        pendingDestructiveAction = .removeUnavailableBrowser(id: id, name: browser.name)
    }

    func confirmPendingDestructiveAction(_ action: PendingDestructiveAction) {
        switch action.kind {
        case .reset:
            guard browserRepository.resetPreferences().wasAccepted else { return }
            routingSettingsEditor.reset()
            appLanguageStore.reset()
            refreshDefaultStatus()
        case let .removeBrowser(id, _):
            _ = browserRepository.removeCustomBrowser(id: id)
        case let .removeUnavailableBrowser(id, _):
            _ = browserRepository.removeUnavailableCustomBrowser(id)
        }
    }
}

struct PendingDestructiveAction: Identifiable {
    enum Kind {
        case reset
        case removeBrowser(id: Browser.ID, name: String)
        case removeUnavailableBrowser(id: Browser.InstallationID, name: String)
    }

    let id: String
    let kind: Kind

    static let reset = PendingDestructiveAction(
        id: "reset",
        kind: .reset
    )

    static func removeBrowser(id: Browser.ID, name: String) -> PendingDestructiveAction {
        PendingDestructiveAction(
            id: "remove-\(id)",
            kind: .removeBrowser(id: id, name: name)
        )
    }

    static func removeUnavailableBrowser(id: Browser.InstallationID, name: String) -> PendingDestructiveAction {
        PendingDestructiveAction(id: "remove-unavailable-\(id.browserID)-\(id.appURL.path)", kind: .removeUnavailableBrowser(id: id, name: name))
    }

    @MainActor
    func title(using store: AppLanguageStore) -> String {
        switch kind {
        case .reset:
            store.text("Reset Eligo Settings?")
        case let .removeBrowser(_, name), let .removeUnavailableBrowser(_, name):
            store.format("Remove %@?", name)
        }
    }

    @MainActor
    func confirmTitle(using store: AppLanguageStore) -> String {
        switch kind {
        case .reset:
            store.text("Reset")
        case .removeBrowser, .removeUnavailableBrowser:
            store.text("Remove")
        }
    }

    @MainActor
    func message(using store: AppLanguageStore) -> String {
        switch kind {
        case .reset:
            store.text(
                "This clears custom browsers, browser order and enabled states, Recent Browser, Domain Rules, Routing Scope, Bypass Destination, Always Show Chooser, and language preferences. Readable scan results are kept; otherwise browsers are scanned again. Installed apps, the system default browser, Launch at Login, and Welcome Guide history are unchanged."
            )
        case let .removeBrowser(_, name):
            store.format(
                "%@ will be removed from Eligo. The app itself will not be deleted.",
                name
            )
        case let .removeUnavailableBrowser(_, name):
            store.format("The unavailable custom entry for %@ will be removed. Browser order, enabled states, Recent Browser, and routing settings are kept.", name)
        }
    }
}
