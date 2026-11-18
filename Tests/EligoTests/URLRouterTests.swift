import Foundation
import XCTest
@testable import Eligo

@MainActor
final class URLRouterTests: XCTestCase {
    func testLateCompletionCannotConsumeTheNextQueuedLink() {
        let router = URLRouter()
        var received: [URL] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        router.setHandler { link, completion in
            received.append(link.url)
            completions.append(completion)
        }
        let urls = (1...3).map { URL(string: "https://example.com/\($0)")! }
        urls.forEach { router.route(IncomingLink(url: $0)) }

        completions[0]()
        completions[0]() // A late callback still belongs to link 1.
        XCTAssertEqual(received, Array(urls.prefix(2)))
        completions[1]()
        XCTAssertEqual(received, urls)
    }

    func testQueuedURLsWaitUntilCurrentURLCompletes() {
        let router = URLRouter()
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        var handledURLs: [URL] = []
        var completions: [@MainActor @Sendable () -> Void] = []

        router.setHandler { link, completion in
            handledURLs.append(link.url)
            completions.append(completion)
        }

        router.route(IncomingLink(url: firstURL))
        router.route(IncomingLink(url: secondURL))

        XCTAssertEqual(handledURLs, [firstURL])
        XCTAssertEqual(completions.count, 1)

        completions[0]()

        XCTAssertEqual(handledURLs, [firstURL, secondURL])
        XCTAssertEqual(completions.count, 2)
    }

    func testSourceFlowsThroughTheQueueAlongsideItsURL() {
        let router = URLRouter()
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(fileURLWithPath: "/tmp/page.html")
        let source = LinkSource.app(AppSender(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            appURL: URL(fileURLWithPath: "/Applications/Slack.app", isDirectory: true)
        ))
        var received: [IncomingLink] = []
        var completions: [@MainActor @Sendable () -> Void] = []

        router.setHandler { link, completion in
            received.append(link)
            completions.append(completion)
        }

        router.route(IncomingLink(url: firstURL, source: source))
        router.route(IncomingLink(url: secondURL))

        XCTAssertEqual(received.map(\.url), [firstURL])
        XCTAssertEqual(received.first?.source, source)

        completions[0]()

        XCTAssertEqual(received.map(\.url), [firstURL, secondURL])
        XCTAssertEqual(received.count, 2)
        XCTAssertNil(received[1].source)
    }

    func testOnlyWebURLsAndHTMLFilesAreSupported() {
        XCTAssertTrue(URLRouter.isSupported(URL(string: "https://example.com")!))
        XCTAssertTrue(URLRouter.isSupported(URL(string: "http://example.com")!))
        XCTAssertTrue(URLRouter.isSupported(URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertFalse(URLRouter.isSupported(URL(string: "mailto:test@example.com")!))
        XCTAssertFalse(URLRouter.isSupported(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testLinksReceivedBeforeHandlerAreRetainedAndResumeWithoutAnotherRequest() throws {
        let router = URLRouter()
        let links = [
            IncomingLink(url: URL(string: "https://example.com/first")!, source: .unknown),
            IncomingLink(url: URL(fileURLWithPath: "/tmp/second.html"))
        ]
        var received: [IncomingLink] = []
        var completions: [@MainActor @Sendable () -> Void] = []

        links.forEach { router.route($0) }
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(completions.isEmpty)
        router.setHandler { link, completion in
            received.append(link)
            completions.append(completion)
        }

        XCTAssertEqual(received, [links[0]])
        try XCTUnwrap(completions.first)()
        XCTAssertEqual(received, links)
        XCTAssertEqual(completions.count, 2)
        try XCTUnwrap(completions.last)()
        XCTAssertEqual(received, links)
    }

    func testPausingAndReplacingHandlerPreservesInFlightAndQueuedOrder() throws {
        let router = URLRouter()
        let urls = (1...4).map { URL(string: "https://example.com/\($0)")! }
        var received: [URL] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        let handler: URLRouter.URLHandler = { link, completion in
            received.append(link.url)
            completions.append(completion)
        }
        router.route(IncomingLink(url: urls[0]))
        router.route(IncomingLink(url: urls[1]))
        router.setHandler(handler)
        router.route(IncomingLink(url: urls[2]))
        router.setHandler(handler)
        XCTAssertEqual(received, [urls[0]])

        router.setHandler(nil)
        try XCTUnwrap(completions.first)()
        router.route(IncomingLink(url: urls[3]))
        XCTAssertEqual(received, [urls[0]])
        var replacementReceived: [URL] = []
        router.setHandler { link, completion in
            replacementReceived.append(link.url)
            handler(link, completion)
        }
        XCTAssertEqual(received, Array(urls.prefix(2)))
        completions[0]() // The old handler cannot finish the replacement's request.
        XCTAssertEqual(received, Array(urls.prefix(2)))
        completions[1]()
        completions[2]()
        completions[3]()
        router.setHandler(handler)
        XCTAssertEqual(received, urls)
        XCTAssertEqual(replacementReceived, Array(urls.dropFirst()))
    }

    func testSynchronousRecoveryAndReentrantEnqueueKeepFIFOWithDuplicateCompletions() {
        let router = URLRouter()
        let urls = (1...3).map { URL(string: "https://example.com/\($0)")! }
        router.route(IncomingLink(url: urls[0]))
        router.route(IncomingLink(url: urls[1]))
        var received: [URL] = []
        router.setHandler { link, completion in
            received.append(link.url)
            if link.url == urls[0] {
                router.route(IncomingLink(url: urls[2]))
            }
            completion()
            completion()
        }
        XCTAssertEqual(received, urls)
    }

    func testRetainedInputsKeepSourcesAndTreatRepeatedURLAsIndependentRequests() {
        let router = URLRouter()
        let source = LinkSource.app(AppSender(name: "Sender", bundleIdentifier: "test.sender", appURL: nil))
        let web = IncomingLink(url: URL(string: "https://example.com/repeated")!, source: source)
        let links = [web, IncomingLink(url: URL(string: "http://example.com")!, source: .unknown)]
            + ["html", "HTM", "xhtml"].map { IncomingLink(url: URL(fileURLWithPath: "/tmp/page.\($0)")) }
            + [web]
        links.forEach { router.route($0) }
        router.route(IncomingLink(url: URL(fileURLWithPath: "/tmp/notes.txt")))
        router.route(IncomingLink(url: URL(string: "mailto:test@example.com")!))
        var received: [IncomingLink] = []
        router.setHandler { link, completion in
            received.append(link)
            completion()
        }
        XCTAssertEqual(received, links)
    }

    func testAsynchronousCompletionAfterRestoringHandlerAdvancesOnlyOnce() async throws {
        let router = URLRouter()
        let urls = (1...3).map { URL(string: "https://example.com/\($0)")! }
        urls.forEach { router.route(IncomingLink(url: $0)) }
        var received: [URL] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        router.setHandler { link, completion in
            received.append(link.url)
            completions.append(completion)
        }
        let first = try XCTUnwrap(completions.first)
        await Task { @MainActor in
            await Task.yield()
            first()
            first()
        }.value
        XCTAssertEqual(received, Array(urls.prefix(2)))
        completions[1]()
        XCTAssertEqual(received, urls)
        completions[2]()
    }

    func testHandlerCanPauseDuringSynchronousRecoveryWithoutConsumingNextRequest() {
        let router = URLRouter()
        let urls = (1...2).map { URL(string: "https://example.com/\($0)")! }
        urls.forEach { router.route(IncomingLink(url: $0)) }
        var received: [URL] = []
        router.setHandler { link, completion in
            received.append(link.url)
            router.setHandler(nil)
            completion()
        }
        XCTAssertEqual(received, [urls[0]])
        router.setHandler { link, completion in
            received.append(link.url)
            completion()
        }
        XCTAssertEqual(received, urls)
    }
}
