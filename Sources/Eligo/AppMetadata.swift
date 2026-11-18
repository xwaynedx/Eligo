import Foundation

enum AppMetadata {
    static let name = BundleDisplayName.resolve(
        bundle: .main,
        appURL: Bundle.main.bundleURL,
        fallback: "Eligo"
    )

    static let version =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        ?? "dev"

    static let build =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        ?? "1"

    static let copyright =
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
        ?? "Copyright © 2026 Wayne. Licensed under the Sustainable Use License, Version 1.0."

    static var versionLabel: String {
        "\(version) (\(build))"
    }

    static var supportInfo: String {
        [
            "\(name) \(versionLabel)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architecture)"
        ].joined(separator: "\n")
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
