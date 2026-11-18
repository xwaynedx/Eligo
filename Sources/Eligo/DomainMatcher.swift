import Darwin
import Foundation

struct DomainMatcher: Codable, Hashable, Sendable {
    let normalizedHost: String
    let includesSubdomains: Bool

    var isIPAddress: Bool { Self.isIPAddress(normalizedHost) }

    init(host: String, includesSubdomains: Bool) throws {
        let normalizedHost = try Self.normalizedHost(from: host)
        if includesSubdomains, Self.isIPAddress(normalizedHost) {
            throw DomainMatcherValidationError.ipAddressesCannotIncludeSubdomains
        }

        self.normalizedHost = normalizedHost
        self.includesSubdomains = includesSubdomains
    }

    func matches(host: String) -> Bool {
        guard let normalizedHost = try? Self.normalizedHost(from: host) else { return false }

        if !includesSubdomains {
            return normalizedHost == self.normalizedHost
        }

        return normalizedHost == self.normalizedHost
            || normalizedHost.hasSuffix("." + self.normalizedHost)
    }

    func covers(_ other: DomainMatcher) -> Bool {
        guard
            normalizedHost == other.normalizedHost
                || includesSubdomains && other.normalizedHost.hasSuffix("." + normalizedHost)
        else {
            return false
        }

        return includesSubdomains || !other.includesSubdomains
    }

    static func normalizedHost(from url: URL) -> String? {
        // Keep URL extraction lossless: the string pipeline owns the single
        // percent-decoding pass, including rejection of nested escapes.
        guard let host = url.host(percentEncoded: true) else { return nil }
        return try? normalizedHost(from: host)
    }

    static func normalizedHost(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Foundation's controlCharacters also includes IDNA contextual joiners.
        // Let IDNA validate those two scalars in their surrounding script.
        let forbiddenControls = CharacterSet.controlCharacters.subtracting(
            CharacterSet(charactersIn: "\u{200C}\u{200D}")
        )
        // Decode once before IDNA conversion: URL.host can otherwise leave an
        // encoded Unicode dot for a later normalization pass to discover.
        guard
            let decoded = trimmed.removingPercentEncoding,
            !decoded.isEmpty,
            decoded.rangeOfCharacter(from: .whitespacesAndNewlines.union(forbiddenControls)) == nil,
            !decoded.contains(where: { "/\\?#@%".contains($0) })
        else {
            throw DomainMatcherValidationError.invalidHost
        }

        let unbracketed = unbracketedIPv6Host(from: decoded)
        guard
            !unbracketed.contains("[") && !unbracketed.contains("]")
        else {
            throw DomainMatcherValidationError.invalidHost
        }

        if unbracketed.contains(":") {
            guard var address = ipv6Address(unbracketed) else {
                throw DomainMatcherValidationError.invalidHost
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return buffer.withUnsafeMutableBufferPointer { output in
                guard let host = inet_ntop(AF_INET6, &address, output.baseAddress, socklen_t(output.count)) else {
                    preconditionFailure("A parsed IPv6 address must fit in INET6_ADDRSTRLEN bytes")
                }
                return String(cString: host)
            }
        }

        guard
            let host = URL(string: "http://\(unbracketed)")?.host,
            !host.isEmpty
        else {
            throw DomainMatcherValidationError.invalidHost
        }

        // Strip only one root dot after conversion. Preserve the URL reg-name
        // forms accepted by previous releases (e.g. '+' / '~' and interior empty
        // labels); tightening DNS grammar here would strand persisted settings.
        let canonical = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        guard !canonical.isEmpty,
              !canonical.hasPrefix("."), !canonical.hasSuffix("."),
              !canonical.contains(where: { "/\\?#@%:[]".contains($0) }),
              canonical.utf8.allSatisfy({ (33...126).contains($0) })
        else {
            throw DomainMatcherValidationError.invalidHost
        }
        if ipv4Components(in: canonical) != nil, !isIPAddress(canonical) {
            throw DomainMatcherValidationError.invalidHost
        }
        return canonical
    }

    private static func unbracketedIPv6Host(from host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// Use canonical hosts for matching and subdomain policy. Input classifiers
    /// may also check raw, unbracketed IPv6 literals; this predicate recognizes
    /// the literal without replacing later canonical host validation.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return ipv6Address(host) != nil
        }

        guard let components = ipv4Components(in: host) else { return false }
        return components.allSatisfy { component in
            guard let value = Int(component) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func ipv4Components(in host: String) -> [Substring]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return components
    }

    private static func ipv6Address(_ host: String) -> in6_addr? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            host: container.decode(String.self, forKey: .normalizedHost),
            includesSubdomains: container.decode(Bool.self, forKey: .includesSubdomains)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalizedHost, forKey: .normalizedHost)
        try container.encode(includesSubdomains, forKey: .includesSubdomains)
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedHost
        case includesSubdomains
    }
}

enum DomainMatcherValidationError: Error, Equatable {
    case invalidHost
    case ipAddressesCannotIncludeSubdomains
}
