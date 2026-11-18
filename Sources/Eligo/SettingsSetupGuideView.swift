import SwiftUI

struct SetupGuideWelcomeView: View, AppLocalizing {
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("Welcome to Eligo"))
                .font(.headline)

            Text(t("Set Eligo as the default browser and enable at least one browser to get started."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SetupGuideView: View, AppLocalizing {
    let defaultBrowserState: DefaultBrowserState
    let browserSetupDetail: String
    let hasUsableBrowsers: Bool
    let onSetAsDefaultBrowser: () -> Void
    let onAddBrowser: () -> Void
    let browserConfigurationUnreadable: Bool
    let onReset: () -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Setup"))
                .font(.headline)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 2),
                alignment: .leading,
                spacing: 12
            ) {
                SetupStepView(
                    title: t("Default Browser"),
                    detail: defaultBrowserState.isDefaultBrowser ? t("Ready") : t("Set Eligo as default"),
                    isComplete: defaultBrowserState.isDefaultBrowser,
                    actionTitle: defaultBrowserState.isDefaultBrowser ? nil : t(defaultBrowserState.feedback == nil ? "Set" : "Retry"),
                    action: onSetAsDefaultBrowser,
                    actionDisabled: !defaultBrowserState.canRequest,
                    secondaryActionTitle: t("Open System Settings"),
                    secondaryAction: LaunchServicesBrowserManager.openDefaultBrowserSettings
                )

                SetupStepView(
                    title: t("Browsers"),
                    detail: browserSetupDetail,
                    isComplete: hasUsableBrowsers,
                    actionTitle: t(browserConfigurationUnreadable ? "Reset" : "Add App"),
                    action: browserConfigurationUnreadable ? onReset : onAddBrowser,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )

            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

}

struct LaunchAtLoginSetupStep: View {
    @ObservedObject var appLanguageStore: AppLanguageStore
    @ObservedObject var launchAtLoginController: LaunchAtLoginController

    var enabledBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginController.isEnabled },
            set: { _ = launchAtLoginController.setEnabled($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                appLanguageStore.text("Launch at Login"),
                isOn: enabledBinding
            )
            .disabled(!launchAtLoginController.isAvailable)

            Text(appLanguageStore.text("Keep Eligo available in the menu bar after you sign in."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if launchAtLoginController.requiresApproval {
                Text(appLanguageStore.text("macOS requires approval for this login item."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(
                    appLanguageStore.text("Open Login Items Settings"),
                    action: launchAtLoginController.openLoginItemsSettings
                )
                .controlSize(.small)
            } else if !launchAtLoginController.isAvailable {
                Text(appLanguageStore.text("Launch at Login is unavailable in this app bundle."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if launchAtLoginController.lastErrorMessage != nil {
                Text(appLanguageStore.text("Could not update Launch at Login."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
    }
}

private struct SetupStepView: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let actionTitle: String?
    let action: () -> Void
    var actionDisabled = false
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? .green : .secondary)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if actionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: 8) {
                    if let actionTitle {
                        Button(actionTitle, action: action)
                            .controlSize(.small)
                            .disabled(actionDisabled)
                    }
                    if let secondaryActionTitle, let secondaryAction {
                        Button(secondaryActionTitle, action: secondaryAction)
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
    }
}
