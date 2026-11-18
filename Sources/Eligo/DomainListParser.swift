import Foundation

struct DomainListParseResult: Equatable, Sendable {
    let matchers: [DomainMatcher]
    let duplicateInputs: [String]
    let invalidInputs: [String]

    var hasDNSHosts: Bool { matchers.contains { !$0.isIPAddress } }
    var hasIPAddresses: Bool { matchers.contains { $0.isIPAddress } }
    var hasOnlyIPAddresses: Bool { !matchers.isEmpty && matchers.allSatisfy(\.isIPAddress) }
}

struct DomainListParser {
    func parse(_ text: String, includesSubdomains: Bool) -> DomainListParseResult {
        var matchers: [DomainMatcher] = []
        var seen = Set<DomainMatcher>()
        var duplicates: [String] = []
        var invalid: [String] = []

        for input in tokens(in: text) {
            let matcher: DomainMatcher
            do {
                guard let host = Self.host(from: input) else {
                    throw DomainMatcherValidationError.invalidHost
                }
                do {
                    matcher = try DomainMatcher(host: host, includesSubdomains: includesSubdomains)
                } catch DomainMatcherValidationError.ipAddressesCannotIncludeSubdomains {
                    // The bulk option applies to DNS hosts only. IP addresses
                    // are retained as exact matches in preview and submission.
                    matcher = try DomainMatcher(host: host, includesSubdomains: false)
                }
            } catch {
                invalid.append(input)
                continue
            }

            if seen.insert(matcher).inserted {
                matchers.append(matcher)
            } else {
                duplicates.append(input)
            }
        }

        return DomainListParseResult(
            matchers: matchers,
            duplicateInputs: duplicates,
            invalidInputs: invalid
        )
    }

    private func tokens(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).flatMap { segment in
            segment.replacingOccurrences(
                of: "[,;](?=https?://)",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            ).components(separatedBy: "\n").flatMap { piece -> [String] in
                var input = piece
                if let last = input.last, ",;".contains(last) {
                    input.removeLast()
                }
                // URL punctuation belongs to the URL unless it introduces
                // another HTTP(S) entry at the boundary above.
                let domains = input.components(separatedBy: CharacterSet(charactersIn: ",;"))
                // A raw IPv6 literal can resemble a scheme prefix. Recognize
                // it here; parse still applies canonical host validation later.
                let startsWithScheme = input.range(
                    of: "^[a-z][a-z0-9+.-]*:", options: [.regularExpression, .caseInsensitive]
                ) != nil && !DomainMatcher.isIPAddress(domains[0])
                if input.contains("://") || startsWithScheme {
                    return [input]
                }
                return domains.filter { !$0.isEmpty }
            }
        }
    }

    static func host(from input: String) -> String? {
        if input.contains("://") {
            guard
                let components = URLComponents(string: input),
                let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                components.user == nil,
                components.password == nil,
                components.url != nil,
                let host = components.percentEncodedHost,
                let decodedHost = host.removingPercentEncoding,
                !decodedHost.contains(where: { ",;".contains($0) })
            else {
                return nil
            }
            // Foundation accepts out-of-range and overflowing ports, and
            // delimiters in authority hosts. Neither is a bulk list entry.
            if components.rangeOfPort != nil {
                guard let port = components.port, (0...65535).contains(port) else { return nil }
            }
            if decodedHost.hasPrefix("[") {
                guard decodedHost.hasSuffix("]"), decodedHost.contains(":"),
                      DomainMatcher.isIPAddress(String(decodedHost.dropFirst().dropLast()))
                else { return nil }
            }
            // DomainMatcher owns decoding. Returning .host would decode once
            // here and turn a double-encoded suffix into a different matcher.
            return host
        }

        if input.contains("/") || input.contains("?") || input.contains("#") {
            return nil
        }

        return input
    }

    static func normalizedHost(from input: String) -> String? {
        guard let host = host(from: input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? DomainMatcher.normalizedHost(from: host)
    }

    static func isIPAddressInput(_ input: String) -> Bool {
        guard let host = normalizedHost(from: input) else { return false }
        return DomainMatcher.isIPAddress(host)
    }

    /// Host edits clear an incompatible IP subdomain setting without enabling
    /// it again when the user returns to DNS. Initial/bypassed drafts still
    /// retain their original setting for model validation.
    static func includesSubdomains(afterEditing host: String, currentValue: Bool) -> Bool {
        currentValue && !isIPAddressInput(host)
    }
}
