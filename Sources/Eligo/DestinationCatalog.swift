import Foundation

struct DestinationCatalog: Sendable {
    let destinations: [OpenDestination]

    private let destinationsByID: [OpenDestinationID: OpenDestination]

    init(enabledBrowsers: [Browser]) {
        var destinations: [OpenDestination] = []
        var seenBrowserIDs = Set<Browser.ID>()

        for browser in enabledBrowsers where seenBrowserIDs.insert(browser.id).inserted {
            destinations.append(OpenDestination(browser: browser, mode: .normal))

            if BrowserDefinition.definition(for: browser.bundleIdentifier)?.privateLaunchAdapter != nil {
                destinations.append(OpenDestination(browser: browser, mode: .privateBrowsing))
            }
        }

        self.destinations = destinations
        destinationsByID = destinations.reduce(into: [:]) { result, destination in
            result[destination.id] = destination
        }
    }

    var normalDestinations: [OpenDestination] {
        destinations.filter { $0.mode == .normal }
    }

    var privateDestinations: [OpenDestination] {
        destinations.filter { $0.mode == .privateBrowsing }
    }

    func destination(for id: OpenDestinationID) -> OpenDestination? {
        destinationsByID[id]
    }
}
