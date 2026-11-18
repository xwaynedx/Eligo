import Foundation

struct DomainConfigurationBatch {
    func mergeMatchers(_ additions: [DomainMatcher], into existing: [DomainMatcher]) -> [DomainMatcher] {
        var result = existing
        var seen = Set(existing)
        result.append(contentsOf: additions.filter { seen.insert($0).inserted })
        return result
    }

    func mergeRules(
        matchers: [DomainMatcher],
        destinationID: OpenDestinationID,
        replacingExisting: Bool,
        into existing: [DomainRule]
    ) -> [DomainRule] {
        var result = existing
        // Index the full matcher (host plus subdomain setting) once, so each
        // addition is a hash lookup instead of a scan of the growing result.
        var indexByMatcher: [DomainMatcher: Int] = [:]
        indexByMatcher.reserveCapacity(existing.count + matchers.count)
        for (index, rule) in result.enumerated() where indexByMatcher[rule.matcher] == nil {
            indexByMatcher[rule.matcher] = index
        }

        for matcher in matchers {
            if let index = indexByMatcher[matcher] {
                guard replacingExisting else { continue }
                result[index] = DomainRule(
                    id: result[index].id,
                    matcher: matcher,
                    destinationID: destinationID
                )
            } else {
                indexByMatcher[matcher] = result.count
                result.append(DomainRule(matcher: matcher, destinationID: destinationID))
            }
        }
        return result
    }

    func removeRules(withIDs ids: Set<DomainRule.ID>, from existing: [DomainRule]) -> [DomainRule] {
        existing.filter { !ids.contains($0.id) }
    }
}
