import Foundation

enum OpeningMode: String, Codable, Hashable, Sendable {
    case normal
    case privateBrowsing
}

struct OpenDestinationID: Codable, Hashable, Sendable {
    let browserID: Browser.ID
    let mode: OpeningMode
}

struct OpenDestination: Identifiable, Hashable, Sendable {
    let browser: Browser
    let mode: OpeningMode

    var id: OpenDestinationID {
        OpenDestinationID(browserID: browser.id, mode: mode)
    }
}
