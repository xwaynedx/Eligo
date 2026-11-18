import SwiftUI

struct BrowserSettingsView: View {
    let browsers: [ConfiguredBrowser]
    let unavailableCustomBrowsers: [Browser]
    let isScanning: Bool
    let language: AppLanguage
    let availability: BrowserAvailability
    let acceptedBrowsers: () -> [ConfiguredBrowser]
    let onAddBrowser: () -> Void
    let onRescan: () -> Void
    let onReset: () -> Void
    let onToggle: (Browser.ID, Bool) -> Bool
    let onMove: (IndexSet, Int) -> Bool
    let onRemoveCustom: (Browser.ID) -> Void
    let onRemoveUnavailableCustom: (Browser.InstallationID) -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(appLanguageStore.text("Browsers"))
                    .font(.headline)

                HStack(spacing: 8) {
                    Spacer()
                    Button(appLanguageStore.text("Add App..."), action: onAddBrowser)
                        .controlSize(.small)
                        .disabled(availability == .configurationUnreadable)
                    Button(appLanguageStore.text("Rescan"), action: onRescan)
                        .controlSize(.small)
                    Button(appLanguageStore.text("Reset"), action: onReset)
                        .controlSize(.small)
                }

                if !unavailableCustomBrowsers.isEmpty {
                    GroupBox(appLanguageStore.text("Unavailable Custom Apps")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(unavailableCustomBrowsers, id: \.installationID) { browser in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(browser.name).fontWeight(.medium)
                                            Text(browser.appURL.path)
                                                .font(.caption).foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                        Button(appLanguageStore.text("Remove")) {
                                            onRemoveUnavailableCustom(browser.installationID)
                                        }
                                        .accessibilityLabel(appLanguageStore.format("Remove unavailable custom app %@ (%@)", browser.name, browser.id))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                        .frame(maxHeight: 160)
                    }
                }
                if availability == .configurationUnreadable {
                    ContentUnavailableView(
                        appLanguageStore.text("Browser Settings Need Repair"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(BrowserPreferencesError.unreadableConfiguration.message(using: appLanguageStore))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isScanning, browsers.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(appLanguageStore.text("Looking for browsers…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browsers.isEmpty {
                    ContentUnavailableView(
                        appLanguageStore.text("No Browsers Found"),
                        systemImage: "safari",
                        description: Text(appLanguageStore.text(
                            "Install a supported browser in /Applications or ~/Applications, then rescan."
                        ))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BrowserTableView(
                        browsers: browsers,
                        acceptedBrowsers: acceptedBrowsers,
                        language: language,
                        onToggle: onToggle,
                        onMove: onMove,
                        onRemoveCustom: onRemoveCustom
                    )
                    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                }


            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text(appLanguageStore.text(
                    "Only enabled browsers appear in the chooser. Changes are saved automatically."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
