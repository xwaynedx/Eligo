import Foundation

/// A link that arrived at Eligo, paired with what is known about its origin.
///
/// The pair travels as one value from the AppleEvent/file entry points through
/// URLRouter and LinkRoutingCoordinator into the chooser, so future per-link facts
/// (a RoutingReason, say) become a new field here instead of another parameter on
/// every signature along the path.
struct IncomingLink: Equatable, Sendable {
    let url: URL
    /// `nil` for channels with no sender concept (local file opens); see `LinkSource`.
    let source: LinkSource?

    init(url: URL, source: LinkSource? = nil) {
        self.url = url
        self.source = source
    }
}
