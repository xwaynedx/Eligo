import Foundation

struct RoutingPolicy {
    func chooserHint(for url: URL, settings: RoutingSettings) -> ChooserRoutingHint? {
        guard settings.alwaysShowChooser else { return nil }
        return resolve(for: url, settings: settings).hint
    }

    func plan(for url: URL, settings: RoutingSettings) -> RoutingPlan {
        let plan = basePlan(for: url, settings: settings)
        guard settings.alwaysShowChooser, case let .open(_, reason) = plan else { return plan }
        return .choose(reason: .alwaysShowChooser(base: reason))
    }

    /// Capture the destination independently of the user's current chooser override.
    func basePlan(for url: URL, settings: RoutingSettings) -> RoutingPlan {
        resolve(for: url, settings: settings).plan
    }

    private func resolve(for url: URL, settings: RoutingSettings) -> (plan: RoutingPlan, hint: ChooserRoutingHint?) {
        if url.isFileURL {
            return (.choose(reason: .localFile), nil)
        }
        guard let host = DomainMatcher.normalizedHost(from: url) else {
            return (.choose(reason: .missingHost), nil)
        }

        if !settings.scope.contains(host), let bypassDestinationID = settings.scope.bypassDestinationID {
            return (.open(destinationID: bypassDestinationID, reason: .bypassed), .bypass(bypassDestinationID))
        } else if let rule = mostSpecificRule(matching: host, rules: settings.rules) {
            return (.open(destinationID: rule.destinationID, reason: .domainRule),
                    .domainRule(rule.destinationID, domain: rule.matcher.normalizedHost))
        } else {
            return (.choose(reason: .noMatchingRule), nil)
        }
    }

    private func mostSpecificRule(matching host: String, rules: [DomainRule]) -> DomainRule? {
        let matchingRules = rules.filter { $0.matcher.matches(host: host) }
        if let exactRule = matchingRules.first(where: { !$0.matcher.includesSubdomains }) {
            return exactRule
        }

        return matchingRules
            .filter { $0.matcher.includesSubdomains }
            .max { lhs, rhs in
                lhs.matcher.normalizedHost.split(separator: ".").count
                    < rhs.matcher.normalizedHost.split(separator: ".").count
            }
    }
}

/// Informational only: Recent Browser continues to own the initial selection.
enum ChooserRoutingHint: Equatable, Sendable {
    case domainRule(OpenDestinationID, domain: String)
    case bypass(OpenDestinationID)

    var destinationID: OpenDestinationID {
        switch self {
        case let .domainRule(id, _), let .bypass(id): id
        }
    }
}

enum RoutingPlan: Equatable, Sendable {
    case choose(reason: RoutingReason)
    case open(destinationID: OpenDestinationID, reason: RoutingReason)
}

enum RoutingReason: Equatable, Sendable {
    case localFile
    case missingHost
    case noMatchingRule
    case domainRule
    case bypassed
    indirect case alwaysShowChooser(base: RoutingReason)
}
