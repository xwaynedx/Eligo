import Foundation

enum DomainRuleFormValidation: Equatable {
    case valid
    case missingDomain
    case invalidDomain
    case ipAddressesCannotIncludeSubdomains
    case missingDestination

    static func validate(
        host: String,
        includesSubdomains: Bool,
        destinationID: OpenDestinationID?
    ) -> DomainRuleFormValidation {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingDomain
        }
        guard let extractedHost = DomainListParser.host(from: host.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .invalidDomain
        }
        do {
            _ = try DomainMatcher(host: extractedHost, includesSubdomains: includesSubdomains)
        } catch DomainMatcherValidationError.ipAddressesCannotIncludeSubdomains {
            return .ipAddressesCannotIncludeSubdomains
        } catch {
            return .invalidDomain
        }
        guard destinationID != nil else {
            return .missingDestination
        }
        return .valid
    }
}
