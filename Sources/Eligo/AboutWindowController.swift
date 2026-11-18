import AppKit
import Combine
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    private let appLanguageStore: AppLanguageStore
    private var languageCancellable: AnyCancellable?

    init(appLanguageStore: AppLanguageStore) {
        self.appLanguageStore = appLanguageStore

        let hostingController = NSHostingController(
            rootView: AboutView(appLanguageStore: appLanguageStore)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = appLanguageStore.text("About Eligo")
        window.setContentSize(NSSize(width: 430, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        languageCancellable = appLanguageStore.$language.sink { [weak self] language in
            self?.window?.title = self?.appLanguageStore.text("About Eligo", for: language)
                ?? "About Eligo"
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View, AppLocalizing {
    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var isSupportPresented = false
    @State private var didCopySupportInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 18) {
                Image(nsImage: EligoIcon.appIcon(size: 76))
                    .resizable()
                    .frame(width: 76, height: 76)
                    .accessibilityLabel(t("Eligo app icon"))

                VStack(spacing: 5) {
                    Text(AppMetadata.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(appLanguageStore.format("Version %@ (Build %@)", AppMetadata.version, AppMetadata.build))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(t("A menu bar app that routes links to the browser destination you choose."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                informationSection(
                    title: t("Privacy"),
                    text: t("Eligo does not collect accounts, browsing history, analytics, or remote telemetry. URLs are passed only to the browser you choose, and local preferences stay on this Mac.")
                )

                informationSection(
                    title: t("Support"),
                    text: t("When reporting a problem, include the copied support information and the steps needed to reproduce it.")
                )

                HStack(spacing: 10) {
                    Button(t("Copy Support Info")) {
                        copySupportInfo()
                    }
                    .controlSize(.small)

                    Button(t("Support Guide")) {
                        isSupportPresented = true
                    }
                    .controlSize(.small)
                }

                if didCopySupportInfo {
                    Text(t("Support info copied."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(AppMetadata.copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .frame(width: 430, height: 560)
        .sheet(isPresented: $isSupportPresented) {
            SupportGuideView(appLanguageStore: appLanguageStore)
        }
    }

    private func informationSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copySupportInfo() {
        copySupportInfoToPasteboard()
        didCopySupportInfo = true
    }
}

/// Copies the support information bundle to the general pasteboard.
private func copySupportInfoToPasteboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(AppMetadata.supportInfo, forType: .string)
}

private struct SupportGuideView: View, AppLocalizing {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var didCopySupportInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Eligo Support"))
                .font(.title3)
                .fontWeight(.semibold)

            Text(t("Include the app version, macOS version, steps to reproduce, and the browser involved."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(AppMetadata.supportInfo)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(t("Copy Support Info")) {
                    copySupportInfoToPasteboard()
                    didCopySupportInfo = true
                }
                .controlSize(.small)

                if didCopySupportInfo {
                    Text(t("Support info copied."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(t("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 430, height: 300)
    }
}
