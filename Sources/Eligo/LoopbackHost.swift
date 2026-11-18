import Darwin
import Foundation

/// Whether a host names the local machine, following W3C Secure Contexts
/// ("potentially trustworthy origin"): `localhost`, any `*.localhost` name,
/// the IPv4 range 127.0.0.0/8, and the IPv6 address `::1`.
///
/// Plain HTTP on a loopback host is the local-development norm, so the Browser
/// Chooser exempts it from the insecure-HTTP treatment. LAN addresses (RFC 1918),
/// `.local` names, and `0.0.0.0` are deliberately not loopback and keep the warning.
enum LoopbackHost {
    static func isLoopback(host: String) -> Bool {
        guard let normalizedHost = try? DomainMatcher.normalizedHost(from: host) else { return false }
        if normalizedHost == "localhost" || normalizedHost.hasSuffix(".localhost") {
            return true
        }
        return isIPv4Loopback(normalizedHost) || isIPv6Loopback(normalizedHost)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        // Mirrors `DomainMatcher.isIPAddress`'s dotted-quad check, and `isIPv6Loopback`
        // reuses `DomainMatcher.isIPv6Address`'s `inet_pton` idiom. Kept separate on
        // purpose: those helpers validate the rule model (they change with the rule
        // grammar), whereas this type classifies normalized hosts against the W3C
        // loopback definition (which changes with Secure Contexts). Sharing them would
        // weld two independently evolving decisions together. Accepted cost: if the
        // dotted-quad/IPv6 *parsing* rule itself ever changes, update both sites.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            guard
                !octet.isEmpty,
                octet.allSatisfy(\.isNumber),
                let value = Int(octet)
            else {
                return false
            }
            return (0...255).contains(value)
        }
    }

    private static func isIPv6Loopback(_ host: String) -> Bool {
        var address = in6_addr()
        var loopback = in6_addr()
        guard
            host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1,
            "::1".withCString({ inet_pton(AF_INET6, $0, &loopback) }) == 1
        else {
            return false
        }
        return memcmp(&address, &loopback, MemoryLayout<in6_addr>.size) == 0
    }
}
