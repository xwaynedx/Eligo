import AppKit
import SwiftUI

struct GeneralSettingsView: View, AppLocalizing {
    let defaultBrowserState: DefaultBrowserState
    let configurationIssueMessages: [String]
    let browserAvailability: BrowserAvailability
    let onReset: () -> Void
    let browserCount: Int
    let enabledBrowserCount: Int
    let routingSettings: RoutingSettings
    let normalDestinations: [OpenDestination]
    let routingFeedback: RoutingGeneralFeedback?
    let onSetAsDefaultBrowser: () -> Void
    let onAddBrowser: () -> Void
    let onEditScope: () -> Void
    let onSetAlwaysShowChooser: (Bool) -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @State private var showsSetupDetails = false

    var showsSetupRepair: Bool {
        needsActivation || browserAvailability == .configurationUnreadable || !configurationIssueMessages.isEmpty
    }

    private var needsActivation: Bool {
        !SetupGuideActivation.isComplete(
            isDefaultBrowser: defaultBrowserState.isDefaultBrowser,
            hasUsableBrowsers: hasUsableBrowsers
        )
    }

    var launchAtLoginStep: LaunchAtLoginSetupStep {
        LaunchAtLoginSetupStep(appLanguageStore: appLanguageStore, launchAtLoginController: launchAtLoginController)
    }

    var routingMessage: String? {
        routingFeedback?.text(using: appLanguageStore)
    }

    private var browserSetupDetail: String {
        if browserAvailability == .configurationUnreadable {
            return t("Browser Settings Need Repair")
        }
        if browserCount == 0 {
            return t("No browsers detected")
        }

        if enabledBrowserCount == 0 {
            return [
                appLanguageStore.format("%@ detected", String(browserCount)),
                t("Enable at least one")
            ].joined(separator: "\n")
        }

        return appLanguageStore.format(
            "%@ detected, %@ available",
            String(browserCount),
            String(enabledBrowserCount)
        )
    }

    private var hasUsableBrowsers: Bool {
        browserCount > 0 && enabledBrowserCount > 0
    }

    private var routingScopeValue: String {
        switch routingSettings.scope {
        case .allDomains:
            t("All domains")
        case .onlyThese:
            t("Only these domains")
        case .allExceptThese:
            t("All domains except these")
        }
    }

    var setupGuide: SetupGuideView {
        SetupGuideView(
            defaultBrowserState: defaultBrowserState,
            browserSetupDetail: browserSetupDetail,
            hasUsableBrowsers: hasUsableBrowsers,
            onSetAsDefaultBrowser: onSetAsDefaultBrowser,
            onAddBrowser: onAddBrowser,
            browserConfigurationUnreadable: browserAvailability == .configurationUnreadable,
            onReset: onReset,
            appLanguageStore: appLanguageStore
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !showsSetupRepair {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(t("Eligo is ready")).font(.callout)
                        Spacer()
                        Button(t(showsSetupDetails ? "Hide setup details" : "View setup status")) {
                            showsSetupDetails.toggle()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                if needsActivation || browserAvailability == .configurationUnreadable || showsSetupDetails {
                    DefaultBrowserSummaryView(
                        status: defaultBrowserState.statusText(using: appLanguageStore),
                        message: defaultBrowserState.feedbackText(using: appLanguageStore),
                        isDefaultBrowser: defaultBrowserState.isDefaultBrowser,
                        appLanguageStore: appLanguageStore
                    )
                    if needsActivation {
                        SetupGuideWelcomeView(appLanguageStore: appLanguageStore)
                    }
                    setupGuide
                }
                if !configurationIssueMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(configurationIssueMessages.enumerated()), id: \.offset) { _, issue in
                            Text(t(issue))
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Button(t("Reset Settings"), action: onReset)
                            .controlSize(.small)
                    }
                }
                RoutingCard(
                    alwaysShowChooser: routingSettings.alwaysShowChooser,
                    message: routingMessage,
                    onSetAlwaysShowChooser: onSetAlwaysShowChooser,
                    scopeValue: routingScopeValue,
                    bypassDestinationTitle: routingSettings.scope.bypassDestinationID.map {
                        normalDestinations.displayName(for: $0, using: appLanguageStore)
                    },
                    onEditScope: onEditScope,
                    appLanguageStore: appLanguageStore
                )
                VStack(alignment: .leading, spacing: 14) {
                    Text(t("Preferences")).font(.headline)
                    LanguageSettingsView(appLanguageStore: appLanguageStore)
                    Divider()
                    launchAtLoginStep
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

private struct DefaultBrowserSummaryView: View {
    let status: String
    let message: String?
    let isDefaultBrowser: Bool
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Eligo")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text(status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            if !isDefaultBrowser {
                Text(appLanguageStore.text(
                    "In System Settings, choose Eligo as the default web browser for HTTP and HTTPS links."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        }
    }
}

private struct RoutingCard: View {
    let alwaysShowChooser: Bool
    let message: String?
    let onSetAlwaysShowChooser: (Bool) -> Void
    let scopeValue: String
    let bypassDestinationTitle: String?
    let onEditScope: () -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguageStore.text("Routing"))
                .font(.headline)

            Toggle(
                appLanguageStore.text("Always Show Chooser"),
                isOn: Binding(
                    get: { alwaysShowChooser },
                    set: { onSetAlwaysShowChooser($0) }
                )
            )

            Text(appLanguageStore.text("When off, links within Routing Scope follow Domain Rules, or show the chooser if no rule matches; links outside the scope use the Bypass Destination. When on, every link shows the chooser."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text(appLanguageStore.text("Routing Scope"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(appLanguageStore.text("Edit Scope…"), action: onEditScope)
                    .controlSize(.small)
            }

            Button(action: onEditScope) {
                HStack {
                    Text(scopeValue)
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Text(appLanguageStore.text("Only links in the Routing Scope use Domain Rules and the chooser."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let bypassDestinationTitle {
                Text(appLanguageStore.format("Bypass Destination: %@", bypassDestinationTitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
