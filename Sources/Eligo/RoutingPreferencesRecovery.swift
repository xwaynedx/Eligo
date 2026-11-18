import Darwin
import Foundation

/// Offline repair of v2 host-normalization damage. Nothing here writes live preferences.
struct RoutingPreferencesRecovery {
    struct Entry {
        let number: Int
        let originalHost: String
        let rule: DomainRule
    }

    struct Conflict {
        let matcher: DomainMatcher
        let entries: [Entry]
    }

    struct InvalidRule {
        let number: Int
        let originalHost: String
        let includesSubdomains: Bool
        let id: UUID
        let destinationID: OpenDestinationID
        let reason: DomainMatcherValidationError
    }

    struct ScopeEntry {
        let number: Int
        let originalHost: String
        let matcher: DomainMatcher
    }

    struct ScopeConflict {
        let matcher: DomainMatcher
        let entries: [ScopeEntry]
    }

    struct InvalidScopeEntry {
        let number: Int
        let originalHost: String
        let includesSubdomains: Bool
        let reason: DomainMatcherValidationError
    }

    let originalData: Data
    let conflicts: [Conflict]
    let invalidRules: [InvalidRule]
    let scopeConflicts: [ScopeConflict]
    let invalidScopeEntries: [InvalidScopeEntry]
    private let entries: [Entry]
    private let scopeEntries: [ScopeEntry]
    private let snapshot: Snapshot

    var needsRepair: Bool {
        !conflicts.isEmpty || !invalidRules.isEmpty || !scopeConflicts.isEmpty || !invalidScopeEntries.isEmpty
    }

    init(originalData: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: originalData)
        // Decode raw matchers separately, so one bad historical host does not
        // prevent reporting the rest. Unrelated schema/destination errors fail.
        _ = try RoutingSettings(scope: snapshot.scope.makeScope(matchers: []), rules: [],
                                alwaysShowChooser: snapshot.alwaysShowChooser)
        var entries: [Entry] = []
        var invalidRules: [InvalidRule] = []
        for (index, raw) in snapshot.rules.enumerated() {
            do {
                entries.append(Entry(number: index + 1, originalHost: raw.matcher.normalizedHost,
                                     rule: DomainRule(id: raw.id, matcher: try raw.matcher.canonical(),
                                                      destinationID: raw.destinationID)))
            } catch let reason as DomainMatcherValidationError {
                invalidRules.append(InvalidRule(number: index + 1, originalHost: raw.matcher.normalizedHost,
                                               includesSubdomains: raw.matcher.includesSubdomains,
                                               id: raw.id, destinationID: raw.destinationID, reason: reason))
            }
        }
        var scopeEntries: [ScopeEntry] = []
        var invalidScopeEntries: [InvalidScopeEntry] = []
        for (index, raw) in snapshot.scope.activeMatchers.enumerated() {
            do {
                scopeEntries.append(ScopeEntry(number: index + 1, originalHost: raw.normalizedHost,
                                               matcher: try raw.canonical()))
            } catch let reason as DomainMatcherValidationError {
                invalidScopeEntries.append(InvalidScopeEntry(number: index + 1, originalHost: raw.normalizedHost,
                                                            includesSubdomains: raw.includesSubdomains, reason: reason))
            }
        }
        self.conflicts = Dictionary(grouping: entries, by: \.rule.matcher).compactMap { matcher, entries in
            entries.count > 1 ? Conflict(matcher: matcher, entries: entries) : nil
        }.sorted { $0.entries[0].number < $1.entries[0].number }
        self.scopeConflicts = Dictionary(grouping: scopeEntries, by: \.matcher).compactMap { matcher, entries in
            entries.count > 1 ? ScopeConflict(matcher: matcher, entries: entries) : nil
        }.sorted { $0.entries[0].number < $1.entries[0].number }
        self.originalData = originalData
        self.snapshot = snapshot
        self.entries = entries
        self.invalidRules = invalidRules
        self.scopeEntries = scopeEntries
        self.invalidScopeEntries = invalidScopeEntries
    }

    /// Retain one entry per conflict, and explicitly discard every invalid host.
    /// Unrelated entries cannot be discarded. Rule and Scope numbering is separate.
    func candidate(
        keepingRuleNumbers choices: Set<Int>,
        discardingRuleNumbers discardedRules: Set<Int> = [],
        keepingScopeNumbers scopeChoices: Set<Int> = [],
        discardingScopeNumbers discardedScope: Set<Int> = []
    ) throws -> Data {
        guard needsRepair else { throw RoutingPreferencesRecoveryError.noRepairs }
        guard discardedRules == Set(invalidRules.map(\.number)),
              discardedScope == Set(invalidScopeEntries.map(\.number))
        else { throw RoutingPreferencesRecoveryError.unresolvedInvalidHosts }
        let conflictedNumbers = try Self.validateChoices(choices, groups: conflicts.map { $0.entries.map(\.number) })
        let conflictedScopeNumbers = try Self.validateChoices(scopeChoices, groups: scopeConflicts.map { $0.entries.map(\.number) })
        let kept = entries.filter { !conflictedNumbers.contains($0.number) || choices.contains($0.number) }
        let keptScope = scopeEntries.filter { !conflictedScopeNumbers.contains($0.number) || scopeChoices.contains($0.number) }
        let settings = try RoutingSettings(scope: snapshot.scope.makeScope(matchers: keptScope.map(\.matcher)),
                                           rules: kept.map(\.rule), alwaysShowChooser: snapshot.alwaysShowChooser)

        // Preserve fields outside the current model too. Only explicitly resolved
        // entries are removed, and retained matchers get their canonical hosts.
        guard var document = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              let rawRules = document["rules"] as? [[String: Any]]
        else { throw RoutingPreferencesRecoveryError.invalidExport }
        document["rules"] = try kept.map { entry in
            guard rawRules.indices.contains(entry.number - 1) else {
                throw RoutingPreferencesRecoveryError.invalidExport
            }
            var raw = rawRules[entry.number - 1]
            guard var matcher = raw["matcher"] as? [String: Any] else {
                throw RoutingPreferencesRecoveryError.invalidExport
            }
            matcher["normalizedHost"] = entry.rule.matcher.normalizedHost
            raw["matcher"] = matcher
            return raw
        }
        if snapshot.scope.kind != .allDomains {
            guard var scope = document["scope"] as? [String: Any],
                  let rawMatchers = scope["matchers"] as? [[String: Any]]
            else { throw RoutingPreferencesRecoveryError.invalidExport }
            scope["matchers"] = try keptScope.map { entry in
                guard rawMatchers.indices.contains(entry.number - 1) else {
                    throw RoutingPreferencesRecoveryError.invalidExport
                }
                var raw = rawMatchers[entry.number - 1]
                raw["normalizedHost"] = entry.matcher.normalizedHost
                return raw
            }
            document["scope"] = scope
        }
        let candidate = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(RoutingSettings.self, from: candidate)
        let roundTrip = try JSONDecoder().decode(RoutingSettings.self, from: JSONEncoder().encode(decoded))
        guard decoded == settings, roundTrip == settings else {
            throw RoutingPreferencesRecoveryError.roundTripFailed
        }
        return candidate
    }

    private static func validateChoices(_ choices: Set<Int>, groups: [[Int]]) throws -> Set<Int> {
        let conflicted = Set(groups.flatMap { $0 })
        guard choices.isSubset(of: conflicted),
              groups.allSatisfy({ $0.filter { choices.contains($0) }.count == 1 })
        else { throw RoutingPreferencesRecoveryError.unresolvedConflicts }
        return conflicted
    }

    private struct Snapshot: Decodable {
        let scope: RawScope
        let rules: [RawRule]
        let alwaysShowChooser: Bool
    }

    private struct RawRule: Decodable {
        let id: UUID
        let matcher: RawMatcher
        let destinationID: OpenDestinationID
    }

    private struct RawMatcher: Decodable {
        let normalizedHost: String
        let includesSubdomains: Bool

        func canonical() throws -> DomainMatcher {
            try DomainMatcher(host: normalizedHost, includesSubdomains: includesSubdomains)
        }
    }

    private struct RawScope: Decodable {
        enum Kind: String, Decodable { case allDomains, onlyThese, allExceptThese }
        let kind: Kind
        let matchers: [RawMatcher]?
        let bypassDestinationID: OpenDestinationID?

        var activeMatchers: [RawMatcher] { kind == .allDomains ? [] : (matchers ?? []) }

        func makeScope(matchers canonicalMatchers: [DomainMatcher]) throws -> RoutingScope {
            if kind == .allDomains { return .allDomains }
            guard matchers != nil, let bypassDestinationID else {
                throw RoutingPreferencesRecoveryError.invalidExport
            }
            switch kind {
            case .allDomains: return .allDomains
            case .onlyThese: return .onlyThese(matchers: canonicalMatchers, bypassDestinationID: bypassDestinationID)
            case .allExceptThese: return .allExceptThese(matchers: canonicalMatchers, bypassDestinationID: bypassDestinationID)
            }
        }
    }
}

enum RoutingPreferencesRecoveryError: LocalizedError, Equatable {
    case noRepairs
    case unresolvedInvalidHosts
    case unresolvedConflicts
    case invalidExport
    case roundTripFailed
    case outputAlreadyExists

    var errorDescription: String? {
        switch self {
        case .noRepairs:
            "No host-normalization repairs were found; no repair is needed."
        case .unresolvedInvalidHosts:
            "Explicitly discard every reported invalid rule/Scope entry, or cancel. Unrelated entries cannot be discarded."
        case .unresolvedConflicts:
            "Choose exactly one entry number from every rule/Scope conflict, and no unrelated entries."
        case .invalidExport:
            "Expected an exported preferences plist containing RoutingPreferences.v2 data."
        case .roundTripFailed:
            "The repair candidate did not pass complete decoding and round-trip validation."
        case .outputAlreadyExists:
            "The output directory already exists. Choose a new directory to preserve previous backups."
        }
    }
}

/// Works only on an explicitly supplied export. Publishing new files never
/// replaces the input or accesses UserDefaults, even after a failed write.
struct RoutingRecoveryExport {
    static let storageKey = "RoutingPreferences.v2"
    let recovery: RoutingPreferencesRecovery
    private let originalData: Data
    private let preferences: [String: Any]

    init(data: Data) throws {
        guard let preferences = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let blob = preferences[Self.storageKey] as? Data
        else { throw RoutingPreferencesRecoveryError.invalidExport }
        self.originalData = data
        self.preferences = preferences
        self.recovery = try RoutingPreferencesRecovery(originalData: blob)
    }

    func writeCandidate(
        keepingRuleNumbers choices: Set<Int>,
        discardingRuleNumbers discardedRules: Set<Int> = [],
        keepingScopeNumbers scopeChoices: Set<Int> = [],
        discardingScopeNumbers discardedScope: Set<Int> = [],
        to directory: URL
    ) throws {
        let candidate = try recovery.candidate(keepingRuleNumbers: choices, discardingRuleNumbers: discardedRules,
                                               keepingScopeNumbers: scopeChoices, discardingScopeNumbers: discardedScope)
        var preferences = preferences
        preferences[Self.storageKey] = candidate
        let export = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
        // One exclusive operation also gives concurrent callers the same useful
        // EEXIST message; there is no racy preflight existence check.
        guard mkdir(directory.path, S_IRWXU) == 0 else {
            let code = errno
            if code == EEXIST { throw RoutingPreferencesRecoveryError.outputAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // Do not remove incomplete output on failure: any successful backup is
        // retained. A subsequent attempt must use a new output directory.
        try recovery.originalData.write(to: directory.appendingPathComponent("original-routing.json"), options: .withoutOverwriting)
        try originalData.write(to: directory.appendingPathComponent("original.plist"), options: .withoutOverwriting)
        try candidate.write(to: directory.appendingPathComponent("candidate-routing.json"), options: .withoutOverwriting)
        try export.write(to: directory.appendingPathComponent("candidate.plist"), options: .withoutOverwriting)
    }
}
