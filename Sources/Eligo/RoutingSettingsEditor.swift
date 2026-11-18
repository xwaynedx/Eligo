import Combine
import Foundation

enum RoutingGeneralFeedback: Equatable {
    case alwaysShowChooserUpdateFailed

    @MainActor
    func text(using store: AppLanguageStore) -> String {
        switch self {
        case .alwaysShowChooserUpdateFailed:
            store.text("Always Show Chooser could not be updated.")
        }
    }
}

@MainActor
final class RoutingSettingsEditor: ObservableObject {
    @Published private(set) var generalFeedback: RoutingGeneralFeedback?
    private let store: RoutingPreferencesStore

    init(store: RoutingPreferencesStore) {
        self.store = store
    }

    func setAlwaysShowChooser(_ isEnabled: Bool) throws {
        do {
            try store.replace(with: store.settings.replacing(alwaysShowChooser: isEnabled))
            generalFeedback = nil
        } catch {
            generalFeedback = .alwaysShowChooserUpdateFailed
            throw error
        }
    }

    func saveScope(_ scope: RoutingScope, browserRepository: BrowserRepository) throws {
        if let destinationID = scope.bypassDestinationID {
            do {
                guard try browserRepository.currentNormalDestination(for: destinationID) != nil else {
                    throw ScopeSaveError.bypassDestinationUnavailable
                }
            } catch is BrowserPreferencesError {
                throw ScopeSaveError.browserConfigurationUnavailable
            }
        }
        try store.replace(with: store.settings.replacing(scope: scope))
    }

    func createRule(
        host: String,
        includesSubdomains: Bool,
        destinationID: OpenDestinationID?
    ) throws {
        let plan = try DomainRuleCreationPlan.plan(
            rules: store.settings.rules,
            host: host,
            includesSubdomains: includesSubdomains,
            destinationID: destinationID
        )
        let existingRuleID: DomainRule.ID?
        switch plan.action {
        case .create:
            existingRuleID = nil
        case .reuse:
            return
        case let .update(rule), let .expand(rule):
            existingRuleID = rule.id
        }
        try saveRule(
            existingRuleID: existingRuleID,
            host: plan.matcher.normalizedHost,
            includesSubdomains: plan.matcher.includesSubdomains,
            destinationID: plan.destinationID
        )
    }

    func saveRule(
        existingRuleID: UUID?,
        host: String,
        includesSubdomains: Bool,
        destinationID: OpenDestinationID?
    ) throws {
        let settings = store.settings
        let preflight = try DomainRuleSavePreflight.plan(
            settings: settings,
            existingRuleID: existingRuleID,
            host: host,
            includesSubdomains: includesSubdomains,
            destinationID: destinationID
        )
        let ruleID: UUID
        if let existingRuleID {
            ruleID = existingRuleID
        } else {
            var newRuleID = UUID()
            while settings.rules.contains(where: { $0.id == newRuleID }) {
                newRuleID = UUID()
            }
            ruleID = newRuleID
        }

        let candidateRule = DomainRule(
            id: ruleID,
            matcher: preflight.matcher,
            destinationID: preflight.destinationID
        )
        let candidateRules: [DomainRule]
        if let existingRuleID {
            candidateRules = settings.rules.map { $0.id == existingRuleID ? candidateRule : $0 }
        } else {
            candidateRules = settings.rules + [candidateRule]
        }
        let candidateSettings = try settings.replacing(rules: candidateRules)

        try store.replace(with: candidateSettings)
    }

    func saveRulesInBulk(
        _ matchers: [DomainMatcher],
        destinationID: OpenDestinationID,
        replaceExisting: Bool
    ) throws {
        guard !matchers.isEmpty else {
            throw RoutingSettingsEditorError.emptyBulkSubmission
        }
        let rules = DomainConfigurationBatch().mergeRules(
            matchers: matchers,
            destinationID: destinationID,
            replacingExisting: replaceExisting,
            into: store.settings.rules
        )
        try store.replace(with: store.settings.replacing(rules: rules))
    }

    func deleteRules(withIDs ids: Set<DomainRule.ID>) throws {
        let rules = DomainConfigurationBatch().removeRules(withIDs: ids, from: store.settings.rules)
        try store.replace(with: store.settings.replacing(rules: rules))
    }

    @discardableResult
    func addRuleMatcherToScope(_ matcher: DomainMatcher) throws -> Bool {
        guard case let .onlyThese(matchers, bypassDestinationID) = store.settings.scope,
              !store.settings.scope.contains(matcher)
        else {
            return false
        }

        // Adding a rule matcher preserves the existing scope destination; it is
        // not a complete interactive Scope replacement.
        let scope = RoutingScope.onlyThese(
            matchers: matchers + [matcher],
            bypassDestinationID: bypassDestinationID
        )
        try store.replace(with: store.settings.replacing(scope: scope))
        return true
    }

    func reset() {
        store.reset()
        generalFeedback = nil
    }
}

enum RoutingSettingsEditorError: LocalizedError, Equatable {
    case destinationRequired
    case ruleNotFound
    case emptyBulkSubmission

    var errorDescription: String? {
        switch self {
        case .destinationRequired:
            "Choose an enabled Open Destination before saving this rule."
        case .ruleNotFound, .emptyBulkSubmission:
            nil
        }
    }
}

enum ScopeSaveError: LocalizedError, Equatable {
    case bypassDestinationUnavailable
    case browserConfigurationUnavailable

    var errorDescription: String? {
        switch self {
        case .bypassDestinationUnavailable:
            "Bypass Destination is no longer available. Choose an enabled normal browser and try again."
        case .browserConfigurationUnavailable:
            "Browser configuration could not be read. Resolve the browser settings issue before saving Routing Scope."
        }
    }
}
