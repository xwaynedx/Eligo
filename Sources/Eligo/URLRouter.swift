import Foundation

@MainActor
final class URLRouter {
    typealias URLHandler = (_ link: IncomingLink, _ completion: @escaping @MainActor @Sendable () -> Void) -> Void

    private var pendingLinks: [IncomingLink] = []
    private var currentRequestID: UUID?
    private var handler: URLHandler?

    func setHandler(_ handler: URLHandler?) {
        self.handler = handler
        processNextIfNeeded()
    }

    func route(_ link: IncomingLink) {
        guard Self.isSupported(link.url) else {
            AppLog.routing.warning("Ignored unsupported URL: \(link.url.absoluteString, privacy: .private)")
            return
        }

        AppLog.routing.info("Received URL: \(link.url.absoluteString, privacy: .private) from \(link.source?.logDescription ?? "local file", privacy: .public)")
        AppLog.routing.info("URL enqueued: \(link.url.absoluteString, privacy: .private)")
        pendingLinks.append(link)
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard currentRequestID == nil, !pendingLinks.isEmpty, let handler else { return }
        let link = pendingLinks.removeFirst()

        let requestID = UUID()
        currentRequestID = requestID
        handler(link) { [weak self] in
            self?.finishCurrent(requestID)
        }
    }

    private func finishCurrent(_ requestID: UUID) {
        guard currentRequestID == requestID else { return }
        currentRequestID = nil
        processNextIfNeeded()
    }

    static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" {
            return true
        }

        guard url.isFileURL else {
            return false
        }

        return ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }
}
