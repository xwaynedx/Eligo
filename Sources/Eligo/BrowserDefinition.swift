import Foundation

struct BrowserDefinition {
    let bundleIdentifiers: Set<String>
    let displayName: String
    let priority: Int
    let privateLaunchAdapter: PrivateLaunchAdapter?

    static let all: [BrowserDefinition] = [
        BrowserDefinition(bundleIdentifiers: ["com.apple.Safari"], displayName: "Safari", priority: 10, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["com.google.Chrome"], displayName: "Google Chrome", priority: 20, privateLaunchAdapter: .verifiedChromium),
        BrowserDefinition(bundleIdentifiers: ["com.google.Chrome.canary"], displayName: "Chrome Canary", priority: 30, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["org.mozilla.firefox"], displayName: "Firefox", priority: 40, privateLaunchAdapter: .verifiedFirefox),
        BrowserDefinition(bundleIdentifiers: ["org.mozilla.firefoxdeveloperedition"], displayName: "Firefox Developer Edition", priority: 50, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["org.mozilla.nightly"], displayName: "Firefox Nightly", priority: 55, privateLaunchAdapter: .verifiedFirefox),
        BrowserDefinition(bundleIdentifiers: ["company.thebrowser.Browser"], displayName: "Arc", priority: 60, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["net.imput.helium"], displayName: "Helium", priority: 63, privateLaunchAdapter: .verifiedChromium),
        // Dia remains listed for Normal opens, but Private is unsupported: it rejects a second
        // instance ("only one instance of Dia can be opened at a time"), and its AppleScript
        // dictionary has no window mode / incognito property to forward into a running app.
        BrowserDefinition(bundleIdentifiers: ["company.thebrowser.dia"], displayName: "Dia", priority: 65, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["com.microsoft.edgemac"], displayName: "Microsoft Edge", priority: 70, privateLaunchAdapter: .verifiedChromium),
        BrowserDefinition(bundleIdentifiers: ["com.brave.Browser"], displayName: "Brave", priority: 80, privateLaunchAdapter: .verifiedChromium),
        BrowserDefinition(bundleIdentifiers: ["com.operasoftware.Opera"], displayName: "Opera", priority: 90, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["com.vivaldi.Vivaldi"], displayName: "Vivaldi", priority: 100, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["com.kagi.kagimacOS", "com.kagi.orion"], displayName: "Orion", priority: 110, privateLaunchAdapter: nil),
        BrowserDefinition(bundleIdentifiers: ["app.zen-browser.zen", "org.mozilla.zen"], displayName: "Zen Browser", priority: 120, privateLaunchAdapter: .verifiedZenFirefox)
    ]

    static func definition(for bundleIdentifier: String) -> BrowserDefinition? {
        all.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }
}

struct PrivateLaunchAdapter: Sendable {
    let family: PrivateLaunchFamily
    let verification: PrivateLaunchVerification
    let privateWindowArgument: String

    static let verifiedChromium = PrivateLaunchAdapter(
        family: .chromium,
        verification: .verified,
        privateWindowArgument: "--incognito"
    )
    static let verifiedFirefox = PrivateLaunchAdapter(
        family: .firefox,
        verification: .verified,
        privateWindowArgument: "-private-window"
    )
    static let verifiedZenFirefox = PrivateLaunchAdapter(
        family: .firefox,
        verification: .verified,
        privateWindowArgument: "--private-window"
    )
    static let experimentalChromium = PrivateLaunchAdapter(
        family: .chromium,
        verification: .experimental,
        privateWindowArgument: "--incognito"
    )
    func actionTitle(language: AppLanguage, isSelected: Bool = false) -> String {
        decoratedTitle(base: localized("Private", language: language), language: language, isSelected: isSelected)
    }

    func chooserActionTitle(language: AppLanguage, isSelected: Bool = false) -> String {
        decoratedTitle(base: localized("Private mode", language: language), language: language, isSelected: isSelected)
    }

    func capabilityLabel(language: AppLanguage) -> String {
        switch verification {
        case .verified:
            localized("Private supported", language: language)
        case .experimental:
            localized("Privacy mode (Experimental)", language: language)
        }
    }

    func accessibilityLabel(browserName: String, language: AppLanguage) -> String {
        localizedFormat(
            "Open %@ in %@",
            language: language,
            browserName,
            chooserActionTitle(language: language)
        )
    }

    func toolTip(language: AppLanguage) -> String {
        switch verification {
        case .verified:
            localized("Open in Private mode", language: language)
        case .experimental:
            localized("Open in Private mode (Experimental)", language: language)
        }
    }

    func ruleMenuTitle(browserName: String, language: AppLanguage) -> String {
        localizedFormat(
            "Add %@ Rule for %@…",
            language: language,
            actionTitle(language: language),
            browserName
        )
    }

    private func decoratedTitle(base: String, language: AppLanguage, isSelected: Bool) -> String {
        let displayedTitle = verification == .experimental
            ? localizedFormat("%@ (Experimental)", language: language, base)
            : base
        return isSelected
            ? localizedFormat("%@ ✓", language: language, displayedTitle)
            : displayedTitle
    }

    private func localized(_ english: String, language: AppLanguage) -> String {
        AppLanguageStore.localizedText(english, for: language)
    }

    private func localizedFormat(_ english: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: localized(english, language: language), arguments: arguments)
    }
}

enum PrivateLaunchVerification: Equatable, Sendable {
    case verified
    case experimental
}

enum PrivateLaunchFamily: Equatable, Sendable {
    case chromium
    case firefox
}
