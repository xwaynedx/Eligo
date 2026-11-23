import Foundation

/// The sending application of a link, resolved from the GetURL event sender.
struct AppSender: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let appURL: URL?
}

/// The origin of an incoming link.
///
/// `nil` (rather than a case) means the link arrived via a channel with no sender
/// concept at all — the local-file open path — so the Browser Chooser hides the
/// source line instead of claiming anything. `.unknown` means a GetURL event did
/// arrive but its sender could not be resolved; the chooser says so explicitly,
/// because an unresolvable sender is itself the useful signal ("something
/// programmatic opened this link").
enum LinkSource: Equatable, Sendable {
    /// The sending process resolved to a running application.
    case app(AppSender)
    /// The GetURL event's sender was missing or already gone — typically a
    /// short-lived process such as `open` or a script that exited before lookup.
    case unknown

    var logDescription: String {
        switch self {
        case let .app(sender):
            sender.bundleIdentifier.map { "\(sender.name) (\($0))" } ?? sender.name
        case .unknown:
            "unknown"
        }
    }

    /// The localized "From <app>" caption shown under the URL title.
    func displayText(language: AppLanguage) -> String {
        switch self {
        case let .app(sender):
            String(format: AppLanguageStore.localizedText("From %@", for: language), sender.name)
        case .unknown:
            AppLanguageStore.localizedText("Unknown source", for: language)
        }
    }

    /// 悬停时显示完整应用名，并在下一行显示可用的 bundle ID。
    var toolTip: String? {
        switch self {
        case let .app(sender):
            sender.bundleIdentifier.map { "\(sender.name)\n\($0)" } ?? sender.name
        case .unknown:
            nil
        }
    }
}
