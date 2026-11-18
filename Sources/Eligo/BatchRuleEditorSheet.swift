import SwiftUI

/// The complete parser input and its synchronous result are one immutable value.
struct BatchRuleDraft {
    let text: String
    let includesSubdomains: Bool
    let preview: DomainListParseResult

    static let empty = BatchRuleDraft(
        text: "", includesSubdomains: true,
        preview: DomainListParseResult(matchers: [], duplicateInputs: [], invalidInputs: [])
    )

    init(text: String, includesSubdomains: Bool) {
        self.init(text: text, includesSubdomains: includesSubdomains,
                  preview: DomainListParser().parse(text, includesSubdomains: includesSubdomains))
    }

    private init(text: String, includesSubdomains: Bool, preview: DomainListParseResult) {
        self.text = text
        self.includesSubdomains = includesSubdomains
        self.preview = preview
    }
}

enum DomainRuleBulkFeedback {
    case invalidInputs([String])
    case emptySubmission
    case saveFailed(DomainRuleSettingsDisplayError)

    @MainActor
    func text(using store: AppLanguageStore) -> String {
        switch self {
        case let .invalidInputs(inputs): store.format("Could not recognize: %@", inputs.joined(separator: ", "))
        case .emptySubmission: store.text("Add at least one valid domain.")
        case let .saveFailed(error): error.text(using: store)
        }
    }
}

struct BatchRuleEditorSheet: View, AppLocalizing {
    @Environment(\.dismiss) private var dismiss
    let destinations: [OpenDestination]
    let hasDeferredChooserRequest: Bool
    let onSave: ([DomainMatcher], OpenDestinationID, Bool) throws(DomainRuleSettingsDisplayError) -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var draft = BatchRuleDraft.empty
    @State private var destinationID: OpenDestinationID?
    @State private var replaceExisting = false
    @State private var feedback: DomainRuleBulkFeedback?

    private var textBinding: Binding<String> {
        Binding(get: { draft.text }, set: { updatePreview(text: $0, includesSubdomains: draft.includesSubdomains) })
    }

    private var subdomainsBinding: Binding<Bool> {
        Binding(get: { draft.includesSubdomains }, set: { updatePreview(text: draft.text, includesSubdomains: $0) })
    }

    private func updatePreview(text: String, includesSubdomains: Bool) {
        guard draft.text != text || draft.includesSubdomains != includesSubdomains else { return }
        draft = BatchRuleDraft(text: text, includesSubdomains: includesSubdomains)
    }

    init(
        destinations: [OpenDestination],
        appLanguageStore: AppLanguageStore,
        hasDeferredChooserRequest: Bool = false,
        onSave: @escaping ([DomainMatcher], OpenDestinationID, Bool) throws(DomainRuleSettingsDisplayError) -> Void
    ) {
        self.destinations = destinations
        self.hasDeferredChooserRequest = hasDeferredChooserRequest
        self.onSave = onSave
        self.appLanguageStore = appLanguageStore
        _destinationID = State(initialValue: destinations.first?.id)
    }

    var body: some View {
        let preview = draft.preview
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Add Domain Rules in Bulk"))
                .font(.title3.weight(.semibold))
            Text(t("Paste domains or URLs separated by spaces, commas, or new lines."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(t(
                "Enter a host, or an absolute HTTP/HTTPS URL. Paths, queries, fragments, and ports are ignored after extracting the host."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            DomainPasteForm(
                text: textBinding,
                includesSubdomains: subdomainsBinding,
                preview: preview,
                appLanguageStore: appLanguageStore
            )
            Picker(t("Open Destination"), selection: $destinationID) {
                Text(t("Choose a destination")).tag(Optional<OpenDestinationID>.none)
                OpenDestinationPickerOptions(
                    destinations: destinations,
                    appLanguageStore: appLanguageStore,
                    tag: Optional.some
                )
            }
            Toggle(t("Replace existing rules for matching domains"), isOn: $replaceExisting)
            Text(t("Existing rules are skipped unless replacement is enabled."))
                .font(.caption)
                .foregroundStyle(.secondary)

            DomainRuleDeferredChooserNotice(
                isDeferred: hasDeferredChooserRequest,
                appLanguageStore: appLanguageStore
            )

            if let feedback {
                Text(feedback.text(using: appLanguageStore))
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("rules.bulk.save-feedback")
            }

            SheetActionFooter(
                isSaveDisabled: destinationID == nil
                    || preview.matchers.isEmpty
                    || !preview.invalidInputs.isEmpty,
                onSave: save,
                appLanguageStore: appLanguageStore
            )
        }
        .padding(24)
        .frame(width: 600)
    }

    private func save() {
        guard let destinationID else { return }
        // The Binding setter replaces the complete draft synchronously. Read it
        // at action time so an edit need not wait for another body evaluation.
        let result = draft.preview
        guard result.invalidInputs.isEmpty else {
            feedback = .invalidInputs(result.invalidInputs)
            return
        }
        guard !result.matchers.isEmpty else {
            feedback = .emptySubmission
            return
        }

        do {
            try onSave(result.matchers, destinationID, replaceExisting)
            dismiss()
        } catch {
            feedback = .saveFailed(error)
        }
    }
}
