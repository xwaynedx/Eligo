import Foundation

struct DomainRuleCreationPlan: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case create
        case reuse(DomainRule)
        case update(DomainRule)
        case expand(DomainRule)
    }

    let matcher: DomainMatcher
    let destinationID: OpenDestinationID
    let action: Action
    let overlappingRule: DomainRule?

    static func plan(
        rules: [DomainRule],
        host: String,
        includesSubdomains: Bool,
        destinationID: OpenDestinationID?
    ) throws -> Self {
        guard let destinationID else {
            throw RoutingSettingsEditorError.destinationRequired
        }
        let matcher = try DomainMatcher(host: host, includesSubdomains: includesSubdomains)
        let overlappingRule = rules.first {
            $0.matcher.normalizedHost == matcher.normalizedHost && $0.matcher != matcher
        }
        let action: Action
        if let existingRule = rules.first(where: { $0.matcher == matcher }) {
            action = existingRule.destinationID == destinationID ? .reuse(existingRule) : .update(existingRule)
        } else if let overlappingRule, overlappingRule.destinationID == destinationID {
            action = includesSubdomains ? .expand(overlappingRule) : .reuse(overlappingRule)
        } else {
            action = .create
        }
        return Self(
            matcher: matcher,
            destinationID: destinationID,
            action: action,
            overlappingRule: overlappingRule
        )
    }
}

struct DomainRuleSavePreflight: Equatable, Sendable {
    let matcher: DomainMatcher
    let destinationID: OpenDestinationID

    static func plan(
        settings: RoutingSettings,
        existingRuleID: DomainRule.ID?,
        host: String,
        includesSubdomains: Bool,
        destinationID: OpenDestinationID?
    ) throws -> Self {
        guard let destinationID else {
            throw RoutingSettingsEditorError.destinationRequired
        }

        let matcher = try DomainMatcher(
            host: host,
            includesSubdomains: includesSubdomains
        )
        if settings.rules.contains(where: {
            $0.id != existingRuleID && $0.matcher == matcher
        }) {
            throw RoutingSettingsValidationError.duplicateRuleMatcher
        }
        if let existingRuleID,
           !settings.rules.contains(where: { $0.id == existingRuleID }) {
            throw RoutingSettingsEditorError.ruleNotFound
        }

        return Self(matcher: matcher, destinationID: destinationID)
    }
}
