import SwiftUI

/// Shared body for bulk domain paste sheets: monospaced editor (auto-focused),
/// subdomain toggle, and the live parse summary. Consumes the caller's preview
/// so the displayed summary and Save gating use the same parsed draft.
struct DomainPasteForm: View {
    @Binding var text: String
    @Binding var includesSubdomains: Bool
    let preview: DomainListParseResult
    @ObservedObject var appLanguageStore: AppLanguageStore
    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .focused($isTextFocused)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if !preview.hasOnlyIPAddresses {
                Toggle(appLanguageStore.text("Include subdomains"), isOn: $includesSubdomains)
            }
            if preview.hasIPAddresses {
                Text(appLanguageStore.text("Include subdomains applies only to DNS names. IP addresses always match exactly."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DomainListParseSummary(
                isInputEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                preview: preview,
                appLanguageStore: appLanguageStore
            )
        }
        .onAppear { isTextFocused = true }
    }
}
