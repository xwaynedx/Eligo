import SwiftUI

struct DomainRuleSettingsDisplayError: Error, Equatable {
    let messageKey: String

    @MainActor
    func text(using store: AppLanguageStore) -> String { store.text(messageKey) }
}

struct DomainRuleDeferredChooserNotice: View {
    let isDeferred: Bool
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        if let message = DomainRuleSettingsAdapter.deferredChooserNotice(
            isDeferred: isDeferred,
            appLanguageStore: appLanguageStore
        ) {
            // Attention-worthy but non-error styling: the waiting request is informational,
            // so it must stand out from secondary caption text without reading as a failure.
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}

struct DomainRuleSettingsPresentationRelay {
    struct SingleItem: Identifiable {
        let id: DomainRuleSettingsSession.PresentationID
        let draft: RuleEditorDraft
    }

    struct BulkItem: Identifiable {
        let id: DomainRuleSettingsSession.PresentationID
    }

    struct DeleteItem: Identifiable {
        let id: DomainRuleSettingsSession.PresentationID
        let target: DomainRuleSettingsSession.DeleteTarget
        let rowHost: String?
    }

    enum Item: Identifiable {
        case single(SingleItem)
        case bulk(BulkItem)
        case delete(DeleteItem)

        var id: DomainRuleSettingsSession.PresentationID {
            switch self {
            case let .single(item): item.id
            case let .bulk(item): item.id
            case let .delete(item): item.id
            }
        }
    }

    private(set) var item: Item?
    private(set) var dismissedPresentationID: DomainRuleSettingsSession.PresentationID?
    private var justCompletedDismissal = false

    /// Synchronizes the relay item with the Session's current presentation.
    ///
    /// Returns `true` when the caller must defer re-presentation by one runloop turn: assigning
    /// a new sheet item synchronously inside the previous sheet's dismissal chain makes SwiftUI
    /// stack a sheet detached from its binding (the zombie sheet of settings-sheet-zombie/01).
    /// The defer marker is consumed by every call, so the deferred retry assigns normally.
    mutating func synchronize(
        with presentation: DomainRuleSettingsSession.Presentation?,
        rules: [DomainRule],
        destinations: [OpenDestination]
    ) -> Bool {
        defer { justCompletedDismissal = false }
        guard item?.id != presentation?.id else { return false }
        guard let presentation else {
            item = nil
            return false
        }
        guard !justCompletedDismissal else { return true }

        switch presentation {
        case let .singleRuleCreate(id, prefill):
            let draft: RuleEditorDraft
            if let prefill {
                draft = RuleEditorDraft(
                    destinationID: prefill.destinationID,
                    host: prefill.matcher.normalizedHost,
                    includesSubdomains: prefill.matcher.includesSubdomains
                )
            } else {
                draft = RuleEditorDraft(destinationID: destinations.first?.id)
            }
            item = .single(SingleItem(id: id, draft: draft))

        case let .singleRuleEdit(id, ruleID):
            guard let rule = rules.first(where: { $0.id == ruleID }) else { return false }
            item = .single(SingleItem(id: id, draft: RuleEditorDraft(rule: rule)))

        case let .bulkRuleCreate(id):
            item = .bulk(BulkItem(id: id))

        case let .deleteConfirmation(id, target):
            let rowHost: String?
            if case let .row(ruleID) = target {
                rowHost = rules.first(where: { $0.id == ruleID })?.matcher.normalizedHost
            } else {
                rowHost = nil
            }
            item = .delete(DeleteItem(id: id, target: target, rowHost: rowHost))
        }
        return false
    }

    mutating func presentationWillDismiss() {
        guard let item else { return }
        dismissedPresentationID = item.id
        self.item = nil
    }

    mutating func presentationDidDismiss() -> DomainRuleSettingsSession.PresentationID? {
        defer { dismissedPresentationID = nil }
        if dismissedPresentationID != nil {
            justCompletedDismissal = true
        }
        return dismissedPresentationID
    }
}

private struct DomainRuleDeleteConfirmationSheet: View {
    let item: DomainRuleSettingsPresentationRelay.DeleteItem
    @ObservedObject var appLanguageStore: AppLanguageStore
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(DomainRuleSettingsAdapter.deleteTitle(
                for: item,
                appLanguageStore: appLanguageStore
            ))
            .font(.title3.weight(.semibold))

            Text(DomainRuleSettingsAdapter.deleteMessage(
                for: item,
                appLanguageStore: appLanguageStore
            ))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(appLanguageStore.text("Cancel")) {
                    dismiss()
                }
                Button(appLanguageStore.text("Delete"), role: .destructive) {
                    onConfirm()
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct DomainRuleSettingsAdapter: View {
    @ObservedObject var session: DomainRuleSettingsSession
    let rules: [DomainRule]
    let scope: RoutingScope
    let destinations: [OpenDestination]
    let browserNames: [Browser.ID: String]
    @ObservedObject var appLanguageStore: AppLanguageStore
    let onEffect: (DomainRuleSettingsSession.Effect) -> Void
    let onEditRoutingScope: () -> Void
    @State private var presentationRelay = DomainRuleSettingsPresentationRelay()

    var body: some View {
        RulesSettingsView(
            rules: rules,
            scope: scope,
            destinations: destinations,
            browserNames: browserNames,
            selectedRuleIDs: session.state.selectedRuleIDs,
            message: Self.pageMessage(
                for: session.state.pageFailure,
                appLanguageStore: appLanguageStore
            ),
            onAction: {
                Self.send($0, to: session, onEffect: onEffect)
            },
            onEditRoutingScope: onEditRoutingScope,
            appLanguageStore: appLanguageStore
        )
        .onAppear(perform: synchronizePresentation)
        .onChange(of: session.state.presentation) { _, _ in
            synchronizePresentation()
        }
        .sheet(item: presentationItemBinding, onDismiss: finishPresentationDismissal) { item in
            switch item {
            case let .single(singleItem):
                RuleEditorSheet(
                    draft: singleItem.draft,
                    rules: rules,
                    destinations: destinations,
                    appLanguageStore: appLanguageStore,
                    hasDeferredChooserRequest: session.state.hasDeferredChooserRequest,
                    opensPendingLink: session.state.isEditingPendingLink,
                    onSave: { (draft: RuleEditorDraft) throws(DomainRuleSettingsDisplayError) -> Void in
                        try Self.commitSingle(
                            item: singleItem,
                            draft: draft,
                            session: session
                        )
                    }
                )
            case let .bulk(bulkItem):
                BatchRuleEditorSheet(
                    destinations: destinations,
                    appLanguageStore: appLanguageStore,
                    hasDeferredChooserRequest: session.state.hasDeferredChooserRequest,
                    onSave: {
                        (matchers: [DomainMatcher], destinationID: OpenDestinationID, replaceExisting: Bool)
                            throws(DomainRuleSettingsDisplayError) -> Void in
                        try Self.commitBulk(
                            item: bulkItem,
                            matchers: matchers,
                            destinationID: destinationID,
                            replaceExisting: replaceExisting,
                            session: session
                        )
                    }
                )
            case let .delete(deleteItem):
                DomainRuleDeleteConfirmationSheet(
                    item: deleteItem,
                    appLanguageStore: appLanguageStore,
                    onConfirm: {
                        Self.confirmDelete(item: deleteItem, in: session)
                    }
                )
            }
        }
    }

    private var presentationItemBinding: Binding<DomainRuleSettingsPresentationRelay.Item?> {
        Binding(
            get: { presentationRelay.item },
            set: { item in
                if item == nil {
                    presentationRelay.presentationWillDismiss()
                }
            }
        )
    }

    private func synchronizePresentation() {
        if presentationRelay.synchronize(
            with: session.state.presentation,
            rules: rules,
            destinations: destinations
        ) {
            // Re-presenting a sheet synchronously inside the previous sheet's dismissal chain
            // produces a zombie sheet detached from its binding (settings-sheet-zombie/01).
            // Defer one runloop turn and re-read the latest Session state so interleaved changes
            // (windowClosed, a newer deferred request) are honoured.
            DispatchQueue.main.async {
                _ = presentationRelay.synchronize(
                    with: session.state.presentation,
                    rules: rules,
                    destinations: destinations
                )
            }
        }
    }

    private func finishPresentationDismissal() {
        if presentationRelay.dismissedPresentationID == nil {
            presentationRelay.presentationWillDismiss()
        }
        finishCapturedDismissal()
    }

    private func finishCapturedDismissal() {
        guard let presentationID = presentationRelay.presentationDidDismiss() else {
            return
        }
        Self.endPresentation(presentationID, in: session, onEffect: onEffect)
    }

    static func send(
        _ action: RulesSettingsAction,
        to session: DomainRuleSettingsSession,
        onEffect: (DomainRuleSettingsSession.Effect) -> Void = { _ in }
    ) {
        let intent: DomainRuleSettingsSession.Intent
        switch action {
        case .addRule:
            intent = .presentSingleRuleCreate
        case .addRulesInBulk:
            intent = .presentBulkRuleCreate
        case .requestDeleteSelectedRules:
            intent = .presentDeleteConfirmation(target: .selected)
        case .requestClearAllRules:
            intent = .presentDeleteConfirmation(target: .all)
        case let .setRuleSelection(ruleID, isSelected):
            intent = .setRuleSelection(id: ruleID, isSelected: isSelected)
        case let .addRuleMatcherToRoutingScope(ruleID):
            intent = .addRuleMatcherToRoutingScope(ruleID: ruleID)
        case let .editRule(ruleID):
            intent = .presentSingleRuleEdit(ruleID: ruleID)
        case let .setRuleDestination(ruleID, destinationID):
            intent = .setRuleDestination(ruleID: ruleID, destinationID: destinationID)
        case let .requestDeleteRule(ruleID):
            intent = .presentDeleteConfirmation(target: .row(ruleID: ruleID))
        }

        if let effect = session.send(intent) {
            onEffect(effect)
        }
    }

    static func commitSingle(
        item: DomainRuleSettingsPresentationRelay.SingleItem,
        draft: RuleEditorDraft,
        session: DomainRuleSettingsSession
    ) throws(DomainRuleSettingsDisplayError) {
        do {
            try session.commit(
                .singleRule(
                    presentationID: item.id,
                    host: draft.host,
                    includesSubdomains: draft.includesSubdomains,
                    destinationID: draft.destinationID
                )
            )
        } catch {
            throw displayError(for: error)
        }
    }

    static func commitBulk(
        item: DomainRuleSettingsPresentationRelay.BulkItem,
        matchers: [DomainMatcher],
        destinationID: OpenDestinationID,
        replaceExisting: Bool,
        session: DomainRuleSettingsSession
    ) throws(DomainRuleSettingsDisplayError) {
        do {
            try session.commit(
                .bulkRule(
                    presentationID: item.id,
                    matchers: matchers,
                    destinationID: destinationID,
                    replaceExisting: replaceExisting
                )
            )
        } catch {
            throw displayError(for: error)
        }
    }

    static func endPresentation(
        _ presentationID: DomainRuleSettingsSession.PresentationID,
        in session: DomainRuleSettingsSession,
        onEffect: (DomainRuleSettingsSession.Effect) -> Void
    ) {
        if let effect = session.send(.presentationEnded(id: presentationID)) {
            onEffect(effect)
        }
    }

    static func confirmDelete(
        item: DomainRuleSettingsPresentationRelay.DeleteItem,
        in session: DomainRuleSettingsSession
    ) {
        _ = session.send(.confirmDelete(presentationID: item.id))
    }

    static func displayError(
        for error: DomainRuleSettingsSession.CommitError
    ) -> DomainRuleSettingsDisplayError {
        let key: String
        switch error {
        case .destinationRequired:
            key = "Choose an enabled Open Destination before saving this rule."
        case .invalidMatcher(.invalidHost):
            key = ScopeMatcherDraftIssue.invalidHost.message
        case .invalidMatcher(.ipAddressesCannotIncludeSubdomains):
            key = "IP addresses cannot include subdomains."
        case .duplicateRuleMatcher:
            key = "A rule with this domain and subdomain setting already exists."
        case .ruleNotFound:
            key = "This rule no longer exists. Close the editor and try again."
        case .emptyBulkSubmission:
            key = "Add at least one valid domain."
        case .persistenceFailure:
            key = "The rules could not be saved."
        case .stalePresentation, .wrongPresentationKind, .alreadyCommitted:
            key = "This editor is no longer active. Close it and try again."
        }
        return DomainRuleSettingsDisplayError(messageKey: key)
    }

    static func pageMessage(
        for failure: DomainRuleSettingsSession.PageFailure?,
        appLanguageStore: AppLanguageStore
    ) -> String? {
        guard let failure else { return nil }
        switch failure {
        case .updateRuleDestination:
            return appLanguageStore.text("The rule destination could not be saved.")
        case .deleteRules:
            return appLanguageStore.text("The rules could not be deleted.")
        case .addRuleMatcherToRoutingScope:
            return appLanguageStore.text("Routing Scope could not be updated.")
        }
    }

    static func deferredChooserNotice(
        isDeferred: Bool,
        appLanguageStore: AppLanguageStore
    ) -> String? {
        guard isDeferred else { return nil }
        return appLanguageStore.text(
            "Another Domain Rule request is waiting and will open after this editor closes."
        )
    }

    static func deleteTitle(
        for item: DomainRuleSettingsPresentationRelay.DeleteItem,
        appLanguageStore: AppLanguageStore
    ) -> String {
        switch item.target {
        case .row:
            return appLanguageStore.text("Delete this rule?")
        case .selected:
            return appLanguageStore.text("Delete selected rules?")
        case .all:
            return appLanguageStore.text("Clear all rules?")
        }
    }

    static func deleteMessage(
        for item: DomainRuleSettingsPresentationRelay.DeleteItem,
        appLanguageStore: AppLanguageStore
    ) -> String {
        switch item.target {
        case .row:
            if let rowHost = item.rowHost {
                return appLanguageStore.format("The rule for %@ will be removed.", rowHost)
            }
            return appLanguageStore.text("The selected rule will be removed.")
        case let .selected(ruleIDs):
            return appLanguageStore.format(
                "This will remove %@ selected rules.",
                String(ruleIDs.count)
            )
        case let .all(ruleIDs):
            return appLanguageStore.format(
                "This will remove all %@ rules.",
                String(ruleIDs.count)
            )
        }
    }
}
