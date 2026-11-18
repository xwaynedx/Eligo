import Combine
import Foundation

@MainActor
final class DomainRuleSettingsSession: ObservableObject {
    struct PresentationID: Hashable, Sendable {
        private let token: UUID

        init() {
            token = UUID()
        }
    }

    enum PageFailure: Equatable, Sendable {
        case updateRuleDestination(ruleID: DomainRule.ID)
        case deleteRules(target: DeleteTarget)
        case addRuleMatcherToRoutingScope(
            ruleID: DomainRule.ID,
            matcher: DomainMatcher
        )
    }

    enum Effect: Equatable, Sendable {
        case revealRules
    }

    struct SingleRulePrefill: Equatable, Sendable {
        let matcher: DomainMatcher
        let destinationID: OpenDestinationID
    }

    enum DeleteConfirmationRequest: Sendable {
        case row(ruleID: DomainRule.ID)
        case selected
        case all
    }

    enum DeleteTarget: Equatable, Sendable {
        case row(ruleID: DomainRule.ID)
        case selected(ruleIDs: Set<DomainRule.ID>)
        case all(ruleIDs: Set<DomainRule.ID>)

        var ruleIDs: Set<DomainRule.ID> {
            switch self {
            case let .row(ruleID):
                [ruleID]
            case let .selected(ruleIDs), let .all(ruleIDs):
                ruleIDs
            }
        }
    }

    enum CommitError: Error, Equatable {
        case stalePresentation
        case wrongPresentationKind
        case alreadyCommitted
        case destinationRequired
        case invalidMatcher(DomainMatcherValidationError)
        case duplicateRuleMatcher
        case ruleNotFound
        case emptyBulkSubmission
        case persistenceFailure
    }

    enum Submission: Equatable, Sendable {
        case singleRule(
            presentationID: PresentationID,
            host: String,
            includesSubdomains: Bool,
            destinationID: OpenDestinationID?
        )
        case bulkRule(
            presentationID: PresentationID,
            matchers: [DomainMatcher],
            destinationID: OpenDestinationID,
            replaceExisting: Bool
        )

        var presentationID: PresentationID {
            switch self {
            case let .singleRule(presentationID, _, _, _),
                 let .bulkRule(presentationID, _, _, _):
                presentationID
            }
        }

    }

    enum Presentation: Equatable, Sendable {
        case singleRuleCreate(
            id: PresentationID,
            prefill: SingleRulePrefill?
        )
        case singleRuleEdit(
            id: PresentationID,
            ruleID: DomainRule.ID
        )
        case bulkRuleCreate(id: PresentationID)
        case deleteConfirmation(id: PresentationID, target: DeleteTarget)

        var id: PresentationID {
            switch self {
            case let .singleRuleCreate(id, _),
                 let .singleRuleEdit(id, _),
                 let .bulkRuleCreate(id),
                 let .deleteConfirmation(id, _):
                id
            }
        }
    }

    struct State: Equatable, Sendable {
        var selectedRuleIDs: Set<DomainRule.ID>
        var presentation: Presentation?
        var pageFailure: PageFailure?
        fileprivate var pendingChooserRequest: ChooserRuleRequest? = nil
        fileprivate var chooserPresentationID: PresentationID? = nil

        var isEditingPendingLink: Bool {
            chooserPresentationID != nil && chooserPresentationID == presentation?.id
        }

        var hasDeferredChooserRequest: Bool {
            pendingChooserRequest != nil
        }

        init(
            selectedRuleIDs: Set<DomainRule.ID> = [],
            presentation: Presentation? = nil,
            pageFailure: PageFailure? = nil
        ) {
            self.selectedRuleIDs = selectedRuleIDs
            self.presentation = presentation
            self.pageFailure = pageFailure
        }
    }

    enum Intent: Sendable {
        case setRuleSelection(id: DomainRule.ID, isSelected: Bool)
        case toggleRuleSelection(id: DomainRule.ID)
        case selectAllRules
        case clearSelection
        case presentSingleRuleCreate
        case presentSingleRuleEdit(ruleID: DomainRule.ID)
        case presentBulkRuleCreate
        case requestRuleFromChooser(
            host: String,
            destinationID: OpenDestinationID
        )
        case presentDeleteConfirmation(target: DeleteConfirmationRequest)
        case confirmDelete(presentationID: PresentationID)
        case addRuleMatcherToRoutingScope(ruleID: DomainRule.ID)
        case setRuleDestination(ruleID: DomainRule.ID, destinationID: OpenDestinationID)
        case presentationEnded(id: PresentationID)
        case windowClosed
    }

    @Published private(set) var state = State()

    private let store: RoutingPreferencesStore
    private let editor: RoutingSettingsEditor
    private var settingsCancellable: AnyCancellable?
    private var committedPresentationID: PresentationID?
    var onChooserRuleFinished: ((OpenDestinationID?) -> Void)?
    private var savedChooserDestinationID: OpenDestinationID?

    fileprivate struct ChooserRuleRequest: Equatable, Sendable {
        let host: String
        let destinationID: OpenDestinationID
    }

    init(
        store: RoutingPreferencesStore,
        editor: RoutingSettingsEditor? = nil
    ) {
        self.store = store
        self.editor = editor ?? RoutingSettingsEditor(store: store)
        settingsCancellable = store.$settings.sink { [weak self] settings in
            self?.reconcileSelection(with: settings)
        }
    }

    func send(_ intent: Intent) -> Effect? {
        switch intent {
        case let .setRuleSelection(id, isSelected):
            setRuleSelection(id: id, isSelected: isSelected)
        case let .toggleRuleSelection(id):
            toggleRuleSelection(id: id)
        case .selectAllRules:
            selectAllRules()
        case .clearSelection:
            updateState { $0.selectedRuleIDs = [] }
        case .presentSingleRuleCreate:
            presentSingleRuleCreate()
        case let .presentSingleRuleEdit(ruleID):
            presentSingleRuleEdit(ruleID: ruleID)
        case .presentBulkRuleCreate:
            presentBulkRuleCreate()
        case let .requestRuleFromChooser(host, destinationID):
            return requestRuleFromChooser(host: host, destinationID: destinationID)
        case let .presentDeleteConfirmation(target):
            presentDeleteConfirmation(target: target)
        case let .confirmDelete(presentationID):
            confirmDelete(presentationID: presentationID)
        case let .addRuleMatcherToRoutingScope(ruleID):
            addRuleMatcherToRoutingScope(ruleID: ruleID)
        case let .setRuleDestination(ruleID, destinationID):
            setRuleDestination(ruleID: ruleID, destinationID: destinationID)
        case let .presentationEnded(id):
            return endPresentation(id: id)
        case .windowClosed:
            committedPresentationID = nil
            updateState { $0 = State() }
            finishChooserRequest()
        }

        return nil
    }

    func commit(_ submission: Submission) throws(CommitError) {
        guard let presentation = state.presentation else {
            throw CommitError.stalePresentation
        }
        guard presentation.id == submission.presentationID else {
            throw CommitError.stalePresentation
        }

        let perform: () throws -> Void
        switch (presentation, submission) {
        case let (
            .singleRuleCreate(id, _),
            .singleRule(submissionID, host, includesSubdomains, destinationID)
        ) where id == submissionID:
            perform = { [editor] in
                try editor.createRule(
                    host: host,
                    includesSubdomains: includesSubdomains,
                    destinationID: destinationID
                )
            }
        case let (
            .singleRuleEdit(id, ruleID),
            .singleRule(submissionID, host, includesSubdomains, destinationID)
        ) where id == submissionID:
            perform = { [editor] in
                try editor.saveRule(
                    existingRuleID: ruleID,
                    host: host,
                    includesSubdomains: includesSubdomains,
                    destinationID: destinationID
                )
            }
        case let (
            .bulkRuleCreate(id),
            .bulkRule(submissionID, matchers, destinationID, replaceExisting)
        ) where id == submissionID:
            perform = { [editor] in
                try editor.saveRulesInBulk(
                    matchers,
                    destinationID: destinationID,
                    replaceExisting: replaceExisting
                )
            }
        default:
            throw CommitError.wrongPresentationKind
        }
        guard committedPresentationID != presentation.id else {
            throw CommitError.alreadyCommitted
        }

        do {
            try perform()
        } catch {
            throw commitError(for: error)
        }

        committedPresentationID = presentation.id
        if state.isEditingPendingLink,
           case let .singleRule(_, _, _, destinationID) = submission {
            savedChooserDestinationID = destinationID
        }
    }

    private func setRuleSelection(id: DomainRule.ID, isSelected: Bool) {
        guard containsRule(id: id) else { return }

        updateState { state in
            if isSelected {
                state.selectedRuleIDs.insert(id)
            } else {
                state.selectedRuleIDs.remove(id)
            }
        }
    }

    private func toggleRuleSelection(id: DomainRule.ID) {
        guard containsRule(id: id) else { return }

        updateState { state in
            if state.selectedRuleIDs.contains(id) {
                state.selectedRuleIDs.remove(id)
            } else {
                state.selectedRuleIDs.insert(id)
            }
        }
    }

    private func selectAllRules() {
        updateState {
            $0.selectedRuleIDs = Set(store.settings.rules.map(\.id))
        }
    }

    private func presentSingleRuleCreate() {
        guard state.presentation == nil else { return }
        updateState {
            $0.presentation = .singleRuleCreate(
                id: PresentationID(),
                prefill: nil
            )
        }
    }

    private func presentSingleRuleEdit(ruleID: DomainRule.ID) {
        guard state.presentation == nil else { return }
        guard containsRule(id: ruleID) else { return }

        updateState {
            $0.presentation = .singleRuleEdit(
                id: PresentationID(),
                ruleID: ruleID
            )
        }
    }

    private func presentBulkRuleCreate() {
        guard state.presentation == nil else { return }

        updateState {
            $0.presentation = .bulkRuleCreate(id: PresentationID())
        }
    }

    private func presentDeleteConfirmation(target: DeleteConfirmationRequest) {
        guard state.presentation == nil else { return }
        guard let frozenTarget = freezeDeleteTarget(target) else { return }

        updateState {
            $0.presentation = .deleteConfirmation(
                id: PresentationID(),
                target: frozenTarget
            )
        }
    }

    private func requestRuleFromChooser(
        host: String,
        destinationID: OpenDestinationID
    ) -> Effect? {
        guard state.presentation == nil else {
            updateState {
                $0.pendingChooserRequest = ChooserRuleRequest(
                    host: host,
                    destinationID: destinationID
                )
            }
            return nil
        }

        guard let presentation = makeChooserPresentation(
            host: host,
            destinationID: destinationID
        ) else {
            finishChooserRequest()
            return nil
        }

        updateState {
            $0.presentation = presentation
            $0.chooserPresentationID = presentation.id
            $0.pendingChooserRequest = nil
        }
        return .revealRules
    }

    private func endPresentation(id: PresentationID) -> Effect? {
        guard state.presentation?.id == id else { return nil }
        let finishesChooserRequest = state.chooserPresentationID == id
        let effect = advancePresentation()
        if finishesChooserRequest { finishChooserRequest() }
        return effect
    }

    private func finishChooserRequest() {
        let completion = onChooserRuleFinished
        let destinationID = savedChooserDestinationID
        onChooserRuleFinished = nil
        savedChooserDestinationID = nil
        completion?(destinationID)
    }

    private func advancePresentation() -> Effect? {
        committedPresentationID = nil

        guard let pendingChooserRequest = state.pendingChooserRequest else {
            updateState {
                $0.presentation = nil
                $0.chooserPresentationID = nil
            }
            return nil
        }

        guard let presentation = makeChooserPresentation(
            host: pendingChooserRequest.host,
            destinationID: pendingChooserRequest.destinationID
        ) else {
            updateState {
                $0.presentation = nil
                $0.pendingChooserRequest = nil
                $0.chooserPresentationID = nil
            }
            finishChooserRequest()
            return nil
        }

        updateState {
            $0.presentation = presentation
            $0.pendingChooserRequest = nil
            $0.chooserPresentationID = presentation.id
        }
        return .revealRules
    }

    private func makeChooserPresentation(
        host: String,
        destinationID: OpenDestinationID
    ) -> Presentation? {
        guard let matcher = try? DomainMatcher(
            host: host,
            includesSubdomains: false
        ) else {
            return nil
        }

        let prefill = SingleRulePrefill(
            matcher: matcher,
            destinationID: destinationID
        )
        return .singleRuleCreate(
            id: PresentationID(),
            prefill: prefill
        )
    }

    private func reconcileSelection(with settings: RoutingSettings) {
        let availableRuleIDs = Set(settings.rules.map(\.id))
        var nextState = state
        nextState.selectedRuleIDs = state.selectedRuleIDs.intersection(availableRuleIDs)

        if let pageFailure = state.pageFailure,
           !isPageFailureStillValid(pageFailure, in: settings) {
            nextState.pageFailure = nil
        }

        guard nextState != state else { return }
        state = nextState
    }

    private func freezeDeleteTarget(
        _ request: DeleteConfirmationRequest
    ) -> DeleteTarget? {
        let availableRuleIDs = Set(store.settings.rules.map(\.id))
        switch request {
        case let .row(ruleID):
            guard availableRuleIDs.contains(ruleID) else { return nil }
            return .row(ruleID: ruleID)
        case .selected:
            let selectedRuleIDs = currentSelectedRuleIDs
            guard !selectedRuleIDs.isEmpty else { return nil }
            return .selected(ruleIDs: selectedRuleIDs)
        case .all:
            guard !availableRuleIDs.isEmpty else { return nil }
            return .all(ruleIDs: availableRuleIDs)
        }
    }

    private var currentSelectedRuleIDs: Set<DomainRule.ID> {
        state.selectedRuleIDs.intersection(Set(store.settings.rules.map(\.id)))
    }

    private func containsRule(id: DomainRule.ID) -> Bool {
        store.settings.rules.contains { $0.id == id }
    }

    private func commitError(for error: Error) -> CommitError {
        if let error = error as? RoutingSettingsEditorError {
            switch error {
            case .destinationRequired:
                return .destinationRequired
            case .ruleNotFound:
                return .ruleNotFound
            case .emptyBulkSubmission:
                return .emptyBulkSubmission
            }
        }
        if let error = error as? DomainMatcherValidationError {
            return .invalidMatcher(error)
        }
        if let error = error as? RoutingSettingsValidationError {
            switch error {
            case .duplicateRuleMatcher:
                return .duplicateRuleMatcher
            case .bypassDestinationMustBeNormal:
                return .persistenceFailure
            }
        }
        return .persistenceFailure
    }

    private func confirmDelete(presentationID: PresentationID) {
        guard case let .deleteConfirmation(currentID, target)? = state.presentation,
              currentID == presentationID,
              committedPresentationID != currentID
        else {
            return
        }
        let targetRuleIDs = target.ruleIDs
        let availableRuleIDs = Set(store.settings.rules.map(\.id))
        guard !targetRuleIDs.isEmpty,
              targetRuleIDs.isSubset(of: availableRuleIDs)
        else {
            return
        }

        do {
            try editor.deleteRules(withIDs: targetRuleIDs)
            committedPresentationID = currentID
            clearDeletePageFailure(matching: target)
        } catch {
            updateState {
                $0.pageFailure = .deleteRules(target: target)
            }
        }
    }

    private func addRuleMatcherToRoutingScope(ruleID: DomainRule.ID) {
        guard let rule = store.settings.rules.first(where: { $0.id == ruleID }),
              case .onlyThese = store.settings.scope,
              !store.settings.scope.contains(rule.matcher)
        else {
            return
        }

        do {
            _ = try editor.addRuleMatcherToScope(rule.matcher)
            clearAddRulePageFailure(matching: ruleID, matcher: rule.matcher)
        } catch {
            updateState {
                $0.pageFailure = .addRuleMatcherToRoutingScope(
                    ruleID: ruleID,
                    matcher: rule.matcher
                )
            }
        }
    }

    private func setRuleDestination(ruleID: DomainRule.ID, destinationID: OpenDestinationID) {
        guard let rule = store.settings.rules.first(where: { $0.id == ruleID }),
              rule.destinationID != destinationID else { return }
        do {
            try editor.saveRule(
                existingRuleID: rule.id,
                host: rule.matcher.normalizedHost,
                includesSubdomains: rule.matcher.includesSubdomains,
                destinationID: destinationID
            )
            if state.pageFailure == .updateRuleDestination(ruleID: ruleID) {
                updateState { $0.pageFailure = nil }
            }
        } catch {
            updateState { $0.pageFailure = .updateRuleDestination(ruleID: ruleID) }
        }
    }

    private func clearDeletePageFailure(matching target: DeleteTarget) {
        guard case let .deleteRules(failedTarget)? = state.pageFailure,
              failedTarget == target
        else {
            return
        }
        updateState { $0.pageFailure = nil }
    }

    private func clearAddRulePageFailure(
        matching ruleID: DomainRule.ID,
        matcher: DomainMatcher
    ) {
        guard case let .addRuleMatcherToRoutingScope(
            failedRuleID,
            failedMatcher
        )? = state.pageFailure,
              failedRuleID == ruleID,
              failedMatcher == matcher
        else {
            return
        }
        updateState { $0.pageFailure = nil }
    }

    private func isPageFailureStillValid(
        _ pageFailure: PageFailure,
        in settings: RoutingSettings
    ) -> Bool {
        switch pageFailure {
        case let .updateRuleDestination(ruleID):
            return settings.rules.contains { $0.id == ruleID }
        case let .deleteRules(target):
            let availableRuleIDs = Set(settings.rules.map(\.id))
            return target.ruleIDs.isSubset(of: availableRuleIDs)
        case let .addRuleMatcherToRoutingScope(ruleID, matcher):
            guard let rule = settings.rules.first(where: { $0.id == ruleID }),
                  rule.matcher == matcher,
                  case .onlyThese = settings.scope
            else {
                return false
            }
            return !settings.scope.contains(matcher)
        }
    }

    private func updateState(_ update: (inout State) -> Void) {
        var nextState = state
        update(&nextState)
        guard nextState != state else { return }
        state = nextState
    }
}
