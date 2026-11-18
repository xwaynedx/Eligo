import Foundation

enum RoutingScopeCoverage: Equatable {
    case full
    case partial
    case none
}

enum RoutingScope: Hashable, Sendable {
    case allDomains
    case onlyThese(matchers: [DomainMatcher], bypassDestinationID: OpenDestinationID)
    case allExceptThese(matchers: [DomainMatcher], bypassDestinationID: OpenDestinationID)

    func contains(_ host: String) -> Bool {
        switch self {
        case .allDomains:
            true
        case let .onlyThese(matchers, _):
            matchers.contains { $0.matches(host: host) }
        case let .allExceptThese(matchers, _):
            !matchers.contains { $0.matches(host: host) }
        }
    }

    func contains(_ matcher: DomainMatcher) -> Bool {
        switch self {
        case .allDomains:
            true
        case let .onlyThese(matchers, _):
            matchers.contains { $0.covers(matcher) }
        case let .allExceptThese(matchers, _):
            !matchers.contains { $0.covers(matcher) || matcher.covers($0) }
        }
    }

    /// Reports the scope's relationship to the whole matcher, independently of
    /// rule precedence and Always Show Chooser. Matcher intersections are nested:
    /// exact hosts and subdomain trees overlap only when one covers the other.
    func coverage(of matcher: DomainMatcher) -> RoutingScopeCoverage {
        switch self {
        case .allDomains:
            return .full
        case let .onlyThese(matchers, _):
            if matchers.contains(where: { $0.covers(matcher) }) { return .full }
            return matchers.contains(where: { matcher.covers($0) }) ? .partial : .none
        case let .allExceptThese(matchers, _):
            if matchers.contains(where: { $0.covers(matcher) }) { return .none }
            return matchers.contains(where: { matcher.covers($0) }) ? .partial : .full
        }
    }

    var bypassDestinationID: OpenDestinationID? {
        switch self {
        case .allDomains:
            nil
        case let .onlyThese(_, bypassDestinationID), let .allExceptThese(_, bypassDestinationID):
            bypassDestinationID
        }
    }
}

extension RoutingScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case matchers
        case bypassDestinationID
    }

    private enum Kind: String, Codable {
        case allDomains
        case onlyThese
        case allExceptThese
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .allDomains:
            self = .allDomains
        case .onlyThese:
            self = .onlyThese(
                matchers: try container.decode([DomainMatcher].self, forKey: .matchers),
                bypassDestinationID: try container.decode(OpenDestinationID.self, forKey: .bypassDestinationID)
            )
        case .allExceptThese:
            self = .allExceptThese(
                matchers: try container.decode([DomainMatcher].self, forKey: .matchers),
                bypassDestinationID: try container.decode(OpenDestinationID.self, forKey: .bypassDestinationID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allDomains:
            try container.encode(Kind.allDomains, forKey: .kind)
        case let .onlyThese(matchers, bypassDestinationID):
            try container.encode(Kind.onlyThese, forKey: .kind)
            try container.encode(matchers, forKey: .matchers)
            try container.encode(bypassDestinationID, forKey: .bypassDestinationID)
        case let .allExceptThese(matchers, bypassDestinationID):
            try container.encode(Kind.allExceptThese, forKey: .kind)
            try container.encode(matchers, forKey: .matchers)
            try container.encode(bypassDestinationID, forKey: .bypassDestinationID)
        }
    }
}

struct DomainRule: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let matcher: DomainMatcher
    let destinationID: OpenDestinationID

    init(
        id: UUID = UUID(),
        matcher: DomainMatcher,
        destinationID: OpenDestinationID
    ) {
        self.id = id
        self.matcher = matcher
        self.destinationID = destinationID
    }
}

struct RoutingSettings: Codable, Hashable, Sendable {
    let scope: RoutingScope
    let rules: [DomainRule]
    let alwaysShowChooser: Bool

    init(scope: RoutingScope, rules: [DomainRule], alwaysShowChooser: Bool) throws {
        try Self.validate(scope: scope, rules: rules)
        self.scope = scope
        self.rules = rules
        self.alwaysShowChooser = alwaysShowChooser
    }

    static let `default` = try! RoutingSettings(scope: .allDomains, rules: [], alwaysShowChooser: false)

    func replacing(scope: RoutingScope) throws -> RoutingSettings {
        try RoutingSettings(scope: scope, rules: rules, alwaysShowChooser: alwaysShowChooser)
    }

    func replacing(rules: [DomainRule]) throws -> RoutingSettings {
        try RoutingSettings(scope: scope, rules: rules, alwaysShowChooser: alwaysShowChooser)
    }

    func replacing(alwaysShowChooser: Bool) throws -> RoutingSettings {
        try RoutingSettings(scope: scope, rules: rules, alwaysShowChooser: alwaysShowChooser)
    }

    private static func validate(scope: RoutingScope, rules: [DomainRule]) throws {
        if let bypassDestinationID = scope.bypassDestinationID, bypassDestinationID.mode != .normal {
            throw RoutingSettingsValidationError.bypassDestinationMustBeNormal
        }

        var matchers = Set<DomainMatcher>()
        for rule in rules where !matchers.insert(rule.matcher).inserted {
            throw RoutingSettingsValidationError.duplicateRuleMatcher
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(RoutingScope.self, forKey: .scope),
            rules: container.decode([DomainRule].self, forKey: .rules),
            alwaysShowChooser: container.decode(Bool.self, forKey: .alwaysShowChooser)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(rules, forKey: .rules)
        try container.encode(alwaysShowChooser, forKey: .alwaysShowChooser)
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case rules
        case alwaysShowChooser
    }
}

enum RoutingSettingsValidationError: Error, Equatable {
    case bypassDestinationMustBeNormal
    case duplicateRuleMatcher
}
