import Combine
import Foundation

struct ScopePasteDraft: Identifiable {
    let id = UUID()
    var text = ""
    var includesSubdomains = true
    var preview = DomainListParser().parse("", includesSubdomains: true)
}

/// Owns one edit; views never coordinate draft writes, validation and Undo.
@MainActor
final class ScopeEditorSession: ObservableObject {
    @Published private(set) var mode: ScopeEditorKind
    @Published private(set) var bypassDestinationID: OpenDestinationID?
    @Published private(set) var validation: ScopeMatcherDraftValidation
    @Published private(set) var touchedRowIDs = Set<UUID>()
    @Published private(set) var pasteDraft: ScopePasteDraft?
    @Published private(set) var saveFeedback: ScopeSaveFeedback?
    @Published private(set) var isActive = true
    @Published private(set) var isSaving = false
    @Published private var feedbackState = ScopeEditorFeedbackState()

    private let store: RoutingPreferencesStore
    private let editor: RoutingSettingsEditor
    private let browserRepository: BrowserRepository
    private let now: () -> ContinuousClock.Instant
    private let resolveMatcher: (ScopeMatcherDraft) throws -> DomainMatcher?
    private var referenceSubscriptions = Set<AnyCancellable>()
    private var expiryTask: Task<Void, Never>?
    private var unavailableFailureWasPublished = false

    init(
        store: RoutingPreferencesStore,
        editor: RoutingSettingsEditor,
        browserRepository: BrowserRepository,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        resolvingMatcher: @escaping (ScopeMatcherDraft) throws -> DomainMatcher? = ScopeMatcherDraftLogic.matcher(for:)
    ) {
        self.store = store
        self.editor = editor
        self.browserRepository = browserRepository
        self.now = now
        resolveMatcher = resolvingMatcher
        let drafts: [ScopeMatcherDraft]
        switch store.settings.scope {
        case .allDomains:
            mode = .allDomains
            drafts = []
            bypassDestinationID = DestinationCatalog(enabledBrowsers: browserRepository.enabledBrowsers)
                .normalDestinations.first?.id
        case let .onlyThese(matchers, destination):
            mode = .onlyThese
            drafts = matchers.map(ScopeMatcherDraft.init)
            bypassDestinationID = destination
        case let .allExceptThese(matchers, destination):
            mode = .allExceptThese
            drafts = matchers.map(ScopeMatcherDraft.init)
            bypassDestinationID = destination
        }
        validation = ScopeMatcherDraftLogic.validation(for: drafts, resolvingMatcher: resolvingMatcher)
        // Publications precede assignment. Invalidate display without reading
        // old reference values or synchronizing a second editable snapshot.
        for publisher in [store.objectWillChange, browserRepository.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &referenceSubscriptions)
        }
    }

    var normalDestinations: [OpenDestination] {
        DestinationCatalog(enabledBrowsers: browserRepository.enabledBrowsers).normalDestinations
    }
    var ruleMatchers: [DomainMatcher] { store.settings.rules.map(\.matcher) }
    var feedback: ScopeEditorFeedback? { feedbackState.feedback }
    var destinationIssue: ScopeSaveError? {
        guard mode != .allDomains else { return nil }
        if browserRepository.availability == .configurationUnreadable { return .browserConfigurationUnavailable }
        guard let bypassDestinationID,
              normalDestinations.contains(where: { $0.id == bypassDestinationID }) else {
            return .bypassDestinationUnavailable
        }
        return nil
    }
    var canSave: Bool {
        isActive && !isSaving && (mode == .allDomains || (validation.invalidDraftIDs.isEmpty && destinationIssue == nil))
    }
    var displayedIssue: ScopeSaveFeedback? {
        if mode != .allDomains, !validation.invalidDraftIDs.isEmpty { return .editorValidation(.invalidDomains) }
        if let issue = destinationIssue {
            if issue == .bypassDestinationUnavailable, bypassDestinationID == nil {
                return .editorValidation(.bypassDestinationRequired)
            }
            return .destinationValidation(issue)
        }
        if case .destinationValidation(.browserConfigurationUnavailable) = saveFeedback,
           browserRepository.availability != .configurationUnreadable { return nil }
        if case .destinationValidation(.bypassDestinationUnavailable) = saveFeedback,
           unavailableFailureWasPublished { return nil }
        return saveFeedback
    }
    private var canEdit: Bool { isActive && !isSaving }

    func setMode(_ value: ScopeEditorKind) {
        guard canEdit, value != mode else { return }
        resetFeedback()
        mode = value
        clearResolvedFieldFeedback()
    }
    func selectBypassDestination(_ value: OpenDestinationID?) {
        guard canEdit, value != bypassDestinationID else { return }
        bypassDestinationID = value
        if case .destinationValidation(.bypassDestinationUnavailable) = saveFeedback {
            saveFeedback = nil
        }
        clearResolvedFieldFeedback()
    }
    @discardableResult
    func addDomain() -> UUID? {
        guard canEdit else { return nil }
        feedbackState.willAddRow()
        if feedback == nil { expiryTask?.cancel() }
        if let empty = validation.drafts.first(where: { $0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return empty.id
        }
        let draft = ScopeMatcherDraft()
        updateDrafts([draft] + validation.drafts)
        return draft.id
    }
    func editHost(rowID: UUID, text: String) {
        guard canEdit, let index = validation.drafts.firstIndex(where: { $0.id == rowID }),
              validation.drafts[index].host != text else { return }
        var drafts = validation.drafts
        drafts[index].host = text
        updateDrafts(drafts)
    }
    func setIncludesSubdomains(rowID: UUID, enabled: Bool) {
        guard canEdit, let index = validation.drafts.firstIndex(where: { $0.id == rowID }),
              validation.drafts[index].includesSubdomains != enabled else { return }
        var drafts = validation.drafts
        drafts[index].includesSubdomains = enabled
        updateDrafts(drafts)
    }
    func finishRowEditing(rowID: UUID) {
        guard canEdit, let draft = validation.drafts.first(where: { $0.id == rowID }) else { return }
        if !touchedRowIDs.contains(rowID) { touchedRowIDs.insert(rowID) }
        if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let host = ScopeMatcherDraftLogic.normalizedHostInput(draft.host) {
            editHost(rowID: rowID, text: host)
        }
    }
    func removeDomain(rowID: UUID) {
        guard canEdit, validation.drafts.contains(where: { $0.id == rowID }) else { return }
        var drafts = validation.drafts
        feedbackState.removeRow(id: rowID, from: &drafts, touchedRowIDs: &touchedRowIDs, now: now())
        updateDrafts(drafts)
        scheduleExpiry()
    }
    func clearDomains() {
        guard canEdit, !validation.drafts.isEmpty else { return }
        var drafts = validation.drafts
        feedbackState.clearRows(drafts: &drafts, touchedRowIDs: &touchedRowIDs, now: now())
        updateDrafts(drafts)
        scheduleExpiry()
    }
    func undo(feedbackID: UUID) {
        guard canEdit, let feedback, feedback.id == feedbackID, feedback.canUndo else { return }
        guard now() < feedback.expiresAt else {
            feedbackState.expire(eventID: feedbackID, now: now())
            expiryTask?.cancel()
            return
        }
        var drafts = validation.drafts
        feedbackState.undo(drafts: &drafts, touchedRowIDs: &touchedRowIDs)
        updateDrafts(drafts)
        expiryTask?.cancel()
    }
    func addAllRuleDomains() {
        guard canEdit else { return }
        appendAndReport(ruleMatchers)
    }
    @discardableResult
    func beginPaste() -> UUID? {
        guard canEdit, pasteDraft == nil else { return nil }
        let draft = ScopePasteDraft()
        pasteDraft = draft
        return draft.id
    }
    func editPasteText(pasteID: UUID, text: String) {
        guard canEdit, var draft = pasteDraft, draft.id == pasteID, draft.text != text else { return }
        draft.text = text
        draft.preview = DomainListParser().parse(text, includesSubdomains: draft.includesSubdomains)
        pasteDraft = draft
    }
    func setPasteIncludesSubdomains(pasteID: UUID, enabled: Bool) {
        guard canEdit, var draft = pasteDraft, draft.id == pasteID, draft.includesSubdomains != enabled else { return }
        draft.includesSubdomains = enabled
        draft.preview = DomainListParser().parse(draft.text, includesSubdomains: enabled)
        pasteDraft = draft
    }
    @discardableResult
    func confirmPaste(pasteID: UUID) -> Bool {
        guard canEdit, let draft = pasteDraft, draft.id == pasteID,
              !draft.preview.matchers.isEmpty, draft.preview.invalidInputs.isEmpty else { return false }
        appendAndReport(draft.preview.matchers)
        pasteDraft = nil
        return true
    }
    func cancelPaste(pasteID: UUID) {
        guard canEdit, pasteDraft?.id == pasteID else { return }
        pasteDraft = nil
    }
    @discardableResult
    func save() -> Bool {
        guard canEdit else { return false }
        isSaving = true
        defer { isSaving = false }
        saveFeedback = nil
        unavailableFailureWasPublished = false
        do {
            let scope: RoutingScope
            switch mode {
            case .allDomains: scope = .allDomains
            case .onlyThese, .allExceptThese:
                guard let bypassDestinationID else { throw ScopeEditorError.bypassDestinationRequired }
                guard let matchers = validation.validatedMatchers(for: validation.drafts) else {
                    throw ScopeEditorError.invalidDomains
                }
                scope = mode == .onlyThese
                    ? .onlyThese(matchers: matchers, bypassDestinationID: bypassDestinationID)
                    : .allExceptThese(matchers: matchers, bypassDestinationID: bypassDestinationID)
            }
            try editor.saveScope(scope, browserRepository: browserRepository)
            end()
            return true
        } catch {
            // A published eligibility failure can resolve without a new selection.
            // Keep commit-only failures (e.g. a removed app still in the cache).
            unavailableFailureWasPublished = (error as? ScopeSaveError) == .bypassDestinationUnavailable
                && destinationIssue == .bypassDestinationUnavailable
            saveFeedback = ScopeSaveFeedback(error: error)
            return false
        }
    }
    func end() {
        guard isActive else { return }
        isActive = false
        resetFeedback()
        pasteDraft = nil
        referenceSubscriptions.removeAll()
    }

    private func updateDrafts(_ drafts: [ScopeMatcherDraft]) {
        guard drafts != validation.drafts else { return }
        validation = ScopeMatcherDraftLogic.validation(for: drafts, resolvingMatcher: resolveMatcher)
        clearResolvedFieldFeedback()
    }
    private func clearResolvedFieldFeedback() {
        switch saveFeedback {
        case .editorValidation(.invalidDomains) where mode == .allDomains || validation.invalidDraftIDs.isEmpty:
            saveFeedback = nil
        case .editorValidation(.bypassDestinationRequired) where mode == .allDomains || bypassDestinationID != nil:
            saveFeedback = nil
        case .destinationValidation where mode == .allDomains:
            saveFeedback = nil
        default: break
        }
    }
    private func appendAndReport(_ matchers: [DomainMatcher]) {
        let result = validation.appending(matchers)
        updateDrafts(result.drafts)
        feedbackState.showPasteResult(added: result.addedCount, skippedDuplicates: result.skippedDuplicateCount, now: now())
        scheduleExpiry()
    }
    private func resetFeedback() {
        expiryTask?.cancel()
        expiryTask = nil
        feedbackState.reset()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let feedback else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(until: feedback.expiresAt, clock: .continuous) } catch { return }
            guard let self, self.isActive else { return }
            self.feedbackState.expire(eventID: feedback.id, now: self.now())
        }
    }
}


enum ScopeEditorKind: String, CaseIterable, Identifiable {
    case allDomains
    case onlyThese
    case allExceptThese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allDomains: "All domains"
        case .onlyThese: "Only these domains"
        case .allExceptThese: "All domains except these"
        }
    }
}


/// Keep app errors semantic and distinguish raw system diagnostics from the
/// app-owned summary, which follows the current language.
enum ScopeSaveFeedback {
    case editorValidation(ScopeEditorError)
    case destinationValidation(ScopeSaveError)
    case routingConfigurationUnavailable
    case systemFailure(NSError)

    init(error: any Error) {
        switch error {
        case let error as ScopeEditorError: self = .editorValidation(error)
        case let error as ScopeSaveError: self = .destinationValidation(error)
        case RoutingPreferencesStoreError.savedSettingsUnreadable: self = .routingConfigurationUnavailable
        default: self = .systemFailure(error as NSError)
        }
    }

    @MainActor
    func text(using store: AppLanguageStore) -> String {
        switch self {
        case let .editorValidation(error): store.text(error.localizedDescription)
        case let .destinationValidation(error): store.text(error.localizedDescription)
        case .routingConfigurationUnavailable:
            store.text("Saved routing settings could not be read. The original data is preserved. Reset Settings will discard it.")
        case let .systemFailure(error):
            store.text("Routing Scope could not be updated.") + "\n" + store.format(
                "System error (%@, code %@): %@", error.domain, String(error.code), error.localizedDescription
            )
        }
    }
}

enum ScopeEditorError: LocalizedError {
    case bypassDestinationRequired
    case invalidDomains

    var errorDescription: String? {
        switch self {
        case .bypassDestinationRequired:
            "Choose a normal Bypass Destination before saving a limited scope."
        case .invalidDomains:
            "Resolve the highlighted domain issues before saving."
        }
    }
}
