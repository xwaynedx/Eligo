import AppKit
import Combine
import SwiftUI

enum SettingsLayout {
    static let minimumSize = NSSize(width: 720, height: 600)
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case browsers
    case rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .browsers: "Browsers"
        case .rules: "Rules"
        }
    }
}

struct SettingsView: View, AppLocalizing {
    @ObservedObject var routingSettingsEditor: RoutingSettingsEditor
    let browserAppPicker: any BrowserAppPicking
    @ObservedObject var browserRepository: BrowserRepository
    @ObservedObject var routingPreferencesStore: RoutingPreferencesStore
    @ObservedObject var appLanguageStore: AppLanguageStore
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var domainRuleSession: DomainRuleSettingsSession
    // The section holder is observed (not just bound) so that a window-driven
    // reveal (e.g. a Chooser handoff writing `sectionSelection.section = .rules`)
    // triggers a SwiftUI re-render here. A bare Binding would write through but
    // leave this view unaware of the change and stuck on the old section.
    @ObservedObject var sectionSelection: SettingsSectionSelection
    @ObservedObject var defaultBrowserController: DefaultBrowserController
    @ObservedObject var scopePresentation: ScopeEditorPresentation
    @State var pendingDestructiveAction: PendingDestructiveAction?

    var availableDestinations: [OpenDestination] {
        DestinationCatalog(enabledBrowsers: browserRepository.enabledBrowsers).destinations
    }

    private var normalDestinations: [OpenDestination] {
        DestinationCatalog(enabledBrowsers: browserRepository.enabledBrowsers).normalDestinations
    }

    private var ruleBrowserNames: [Browser.ID: String] {
        let knownBrowsers = browserRepository.browsers.map(\.browser) + browserRepository.unavailableCustomBrowsers
        return Dictionary(knownBrowsers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var configurationIssueMessages: [String] {
        [
            routingPreferencesStore.configurationIssueMessage
        ].compactMap { $0 }
    }

    init(
        browserRepository: BrowserRepository,
        routingPreferencesStore: RoutingPreferencesStore,
        routingSettingsEditor: RoutingSettingsEditor,
        appLanguageStore: AppLanguageStore,
        launchAtLoginController: LaunchAtLoginController,
        defaultBrowserController: DefaultBrowserController,
        domainRuleSession: DomainRuleSettingsSession,
        sectionSelection: SettingsSectionSelection,
        scopePresentation: ScopeEditorPresentation,
        browserAppPicker: any BrowserAppPicking = BrowserAppPicker()
    ) {
        _routingSettingsEditor = ObservedObject(wrappedValue: routingSettingsEditor)
        self.browserAppPicker = browserAppPicker
        _browserRepository = ObservedObject(wrappedValue: browserRepository)
        _routingPreferencesStore = ObservedObject(wrappedValue: routingPreferencesStore)
        _appLanguageStore = ObservedObject(wrappedValue: appLanguageStore)
        _launchAtLoginController = ObservedObject(wrappedValue: launchAtLoginController)
        _defaultBrowserController = ObservedObject(wrappedValue: defaultBrowserController)
        _domainRuleSession = ObservedObject(wrappedValue: domainRuleSession)
        _sectionSelection = ObservedObject(wrappedValue: sectionSelection)
        _scopePresentation = ObservedObject(wrappedValue: scopePresentation)
    }

    var generalSettings: GeneralSettingsView {
        GeneralSettingsView(
            defaultBrowserState: defaultBrowserController.state,
            configurationIssueMessages: configurationIssueMessages,
            browserAvailability: browserRepository.availability,
            onReset: requestSettingsReset,
            browserCount: browserRepository.browsers.count,
            enabledBrowserCount: browserRepository.enabledBrowsers.count,
            routingSettings: routingPreferencesStore.settings,
            normalDestinations: normalDestinations,
            routingFeedback: routingSettingsEditor.generalFeedback,
            onSetAsDefaultBrowser: setAsDefaultBrowser,
            onAddBrowser: addCustomBrowser,
            onEditScope: presentScopeEditor,
            onSetAlwaysShowChooser: setAlwaysShowChooser,
            appLanguageStore: appLanguageStore,
            launchAtLoginController: launchAtLoginController
        )
    }

    /// Shared by every section, including both Add App entry points.
    var browserFeedback: BrowserOperationFeedbackView {
        BrowserOperationFeedbackView(
            repository: browserRepository,
            appLanguageStore: appLanguageStore,
            onReset: requestSettingsReset
        )
    }

    var browserSettings: BrowserSettingsView {
        BrowserSettingsView(
            browsers: browserRepository.browsers,
            unavailableCustomBrowsers: browserRepository.unavailableCustomBrowsers,
            isScanning: browserRepository.isScanning,
            language: appLanguageStore.language,
            availability: browserRepository.availability,
            acceptedBrowsers: { browserRepository.browsers },
            onAddBrowser: addCustomBrowser,
            onRescan: rescanBrowsers,
            onReset: requestSettingsReset,
            onToggle: setBrowserEnabled,
            onMove: moveBrowser,
            onRemoveCustom: requestCustomBrowserRemoval,
            onRemoveUnavailableCustom: requestUnavailableCustomBrowserRemoval,
            appLanguageStore: appLanguageStore
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(t("Settings section"), selection: $sectionSelection.section) {
                ForEach(SettingsSection.allCases) { section in
                    Text(t(section.title)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            browserFeedback

            Group {
                switch sectionSelection.section {
                case .general:
                    generalSettings
                case .browsers:
                    browserSettings
                case .rules:
                    DomainRuleSettingsAdapter(
                        session: domainRuleSession,
                        rules: routingPreferencesStore.settings.rules,
                        scope: routingPreferencesStore.settings.scope,
                        destinationContext: RuleDestinationContext(
                            destinations: availableDestinations, browserNames: ruleBrowserNames,
                            appLanguageStore: appLanguageStore
                        ),
                        onEffect: { effect in
                            if effect == .revealRules {
                                sectionSelection.section = .rules
                            }
                        },
                        onEditRoutingScope: presentScopeEditor
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(
            minWidth: SettingsLayout.minimumSize.width,
            maxWidth: .infinity,
            minHeight: SettingsLayout.minimumSize.height,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear { refreshExternalStatuses() }
        .onChange(of: sectionSelection.section) { _, section in
            if section == .browsers { browserRepository.refreshInstallations() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: refreshExternalStatuses
        )
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification),
            perform: refreshExternalStatuses
        )
        .alert(item: $pendingDestructiveAction, content: destructiveActionAlert)
        .background {
            if let item = scopePresentation.item {
                ScopeEditorPresentationAnchor(presentation: scopePresentation, item: item, appLanguageStore: appLanguageStore)
                    .id(item.id)
            }
        }
    }

}
