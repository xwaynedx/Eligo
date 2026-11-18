import SwiftUI

struct RuleEditorDraft: Identifiable {
    let id = UUID()
    let existingRuleID: UUID?
    var host: String {
        didSet {
            if host != oldValue {
                includesSubdomains = DomainListParser.includesSubdomains(afterEditing: host, currentValue: includesSubdomains)
            }
        }
    }
    var includesSubdomains: Bool
    var destinationID: OpenDestinationID?

    var supportsSubdomains: Bool {
        // A residual invalid draft must allow unchecking the option to recover.
        includesSubdomains || !DomainListParser.isIPAddressInput(host)
    }

    func normalizedForSaving() -> RuleEditorDraft {
        let originalSubdomainSetting = includesSubdomains
        var submission = self
        submission.host = DomainListParser.normalizedHost(from: host) ?? host
        // Setting host runs didSet on the copy. Restore the original submission
        // so canonicalization cannot bypass the model's IP subdomain guard.
        submission.includesSubdomains = originalSubdomainSetting
        return submission
    }

    func creationPlan(in rules: [DomainRule]) -> DomainRuleCreationPlan? {
        guard existingRuleID == nil else { return nil }
        let submission = normalizedForSaving()
        return try? DomainRuleCreationPlan.plan(
            rules: rules,
            host: submission.host,
            includesSubdomains: submission.includesSubdomains,
            destinationID: submission.destinationID
        )
    }

    init(
        existingRuleID: DomainRule.ID? = nil,
        destinationID: OpenDestinationID? = nil,
        host: String = "",
        includesSubdomains: Bool = false
    ) {
        self.existingRuleID = existingRuleID
        self.host = host
        self.includesSubdomains = includesSubdomains
        self.destinationID = destinationID
    }

    init(rule: DomainRule) {
        self.existingRuleID = rule.id
        self.host = rule.matcher.normalizedHost
        self.includesSubdomains = rule.matcher.includesSubdomains
        self.destinationID = rule.destinationID
    }
}

struct RuleEditorSheet: View, AppLocalizing {
    @Environment(\.dismiss) private var dismiss
    let rules: [DomainRule]
    let destinations: [OpenDestination]
    let hasDeferredChooserRequest: Bool
    let opensPendingLink: Bool
    let onSave: (RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var draft: RuleEditorDraft
    @State private var saveFailure: DomainRuleSettingsDisplayError?

    private var creationPlan: DomainRuleCreationPlan? { draft.creationPlan(in: rules) }

    private var formValidation: DomainRuleFormValidation {
        DomainRuleFormValidation.validate(
            host: draft.host,
            includesSubdomains: draft.includesSubdomains,
            destinationID: draft.destinationID
        )
    }

    private var validationMessage: String? {
        switch formValidation {
        case .valid, .missingDestination:
            nil
        case .missingDomain:
            "Enter a domain such as example.com."
        case .invalidDomain:
            ScopeMatcherDraftIssue.invalidHost.message
        case .ipAddressesCannotIncludeSubdomains:
            ScopeMatcherDraftIssue.ipAddressesCannotIncludeSubdomains.message
        }
    }

    init(
        draft: RuleEditorDraft,
        rules: [DomainRule],
        destinations: [OpenDestination],
        appLanguageStore: AppLanguageStore,
        hasDeferredChooserRequest: Bool = false,
        opensPendingLink: Bool = false,
        onSave: @escaping (RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void
    ) {
        self.rules = rules
        self.destinations = destinations
        self.hasDeferredChooserRequest = hasDeferredChooserRequest
        self.opensPendingLink = opensPendingLink
        self.onSave = onSave
        self.appLanguageStore = appLanguageStore
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(draft.existingRuleID == nil ? "Add Domain Rule" : "Edit Domain Rule"))
                .font(.title3.weight(.semibold))

            TextField(t("Host"), text: $draft.host, prompt: Text("example.com"))
            if let validationMessage {
                Text(t(validationMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle(t("Include subdomains"), isOn: $draft.includesSubdomains)
                .disabled(!draft.supportsSubdomains)

            Picker(t("Open Destination"), selection: $draft.destinationID) {
                Text(t("Choose a destination")).tag(Optional<OpenDestinationID>.none)
                OpenDestinationPickerOptions(
                    destinations: destinations,
                    appLanguageStore: appLanguageStore,
                    tag: Optional.some
                )
            }

            if let message = creationPlan?.message(destinations: destinations, using: appLanguageStore) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if opensPendingLink {
                Text(t("Cancel returns to the chooser."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DomainRuleDeferredChooserNotice(
                isDeferred: hasDeferredChooserRequest,
                appLanguageStore: appLanguageStore
            )

            if let saveFailure {
                Text(saveFailure.text(using: appLanguageStore))
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            SheetActionFooter(
                isSaveDisabled: formValidation != .valid,
                onSave: save,
                saveTitle: creationPlan?.saveTitle(opensPendingLink: opensPendingLink)
                    ?? (opensPendingLink ? "Save and Open" : "Save"),
                appLanguageStore: appLanguageStore
            )
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: draft.host) { _, _ in saveFailure = nil }
        .onChange(of: draft.includesSubdomains) { _, _ in saveFailure = nil }
        .onChange(of: draft.destinationID) { _, _ in saveFailure = nil }
    }

    private func save() {
        do {
            try onSave(draft.normalizedForSaving())
            dismiss()
        } catch {
            saveFailure = error
        }
    }
}

extension DomainRuleCreationPlan {
    func saveTitle(opensPendingLink: Bool) -> String {
        switch action {
        case .create:
            opensPendingLink ? "Save and Open" : "Save"
        case .reuse:
            opensPendingLink ? "Use Existing Rule and Open" : "Done"
        case .update:
            opensPendingLink ? "Update Rule and Open" : "Update Existing Rule"
        case .expand:
            opensPendingLink ? "Expand Rule and Open" : "Expand Existing Rule"
        }
    }

    @MainActor
    func message(destinations: [OpenDestination], using store: AppLanguageStore) -> String? {
        let host = matcher.normalizedHost
        let destination = destinations.displayName(for: destinationID, using: store)
        var messages: [String] = []
        switch action {
        case .create:
            break
        case let .reuse(rule):
            messages.append(store.format(
                rule.matcher == matcher
                    ? "This rule already exists: %@ → %@. No duplicate will be created."
                    : "The existing rule for %@ and its subdomains already uses %@. No new rule is needed.",
                host, destination
            ))
        case let .update(rule):
            messages.append(store.format(
                "A rule with this scope already exists. Update its destination: %@ → %@.",
                destinations.displayName(for: rule.destinationID, using: store), destination
            ))
        case .expand:
            messages.append(store.format(
                "The existing rule opens only %@ in %@. Expand it to include subdomains.",
                host, destination
            ))
        }
        if let overlappingRule, overlappingRule.destinationID != destinationID {
            let otherDestination = destinations.displayName(for: overlappingRule.destinationID, using: store)
            messages.append(store.format(
                "Both scopes will be kept. %@ uses %@; its subdomains default to %@. More specific rules take precedence.",
                host,
                matcher.includesSubdomains ? otherDestination : destination,
                matcher.includesSubdomains ? destination : otherDestination
            ))
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}
