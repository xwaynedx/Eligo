import SwiftUI

struct ScopeBulkPasteSheet: View, AppLocalizing {
    @ObservedObject var session: ScopeEditorSession
    let pasteID: UUID
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        if let draft = session.pasteDraft, draft.id == pasteID {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("Paste Domains")).font(.title3.weight(.semibold))
                Text(t("Paste domains or URLs separated by spaces, commas, or new lines."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(t("Enter a host, or an absolute HTTP/HTTPS URL. Paths, queries, fragments, and ports are ignored after extracting the host."))
                    .font(.caption).foregroundStyle(.secondary)
                DomainPasteForm(
                    text: Binding(get: { session.pasteDraft?.id == pasteID ? session.pasteDraft?.text ?? "" : "" },
                                  set: { session.editPasteText(pasteID: pasteID, text: $0) }),
                    includesSubdomains: Binding(get: { session.pasteDraft?.id == pasteID ? session.pasteDraft?.includesSubdomains ?? false : false },
                                                set: { session.setPasteIncludesSubdomains(pasteID: pasteID, enabled: $0) }),
                    preview: draft.preview,
                    appLanguageStore: appLanguageStore
                )
                SheetActionFooter(
                    isSaveDisabled: draft.preview.matchers.isEmpty || !draft.preview.invalidInputs.isEmpty,
                    onSave: { _ = session.confirmPaste(pasteID: pasteID) },
                    onCancel: { session.cancelPaste(pasteID: pasteID) },
                    appLanguageStore: appLanguageStore
                )
            }
            .padding(24)
            .frame(width: 600)
        }
    }
}
