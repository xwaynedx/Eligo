import AppKit
import ServiceManagement
import XCTest
@testable import Eligo

@MainActor
final class AppDelegateOpenFilesTests: XCTestCase {
    func testColdAndWarmBatchesReplyOnceAndActuallyRetainOrDeliverEverySupportedFile() throws {
        let batches: [(files: [String], accepted: [String])] = [
            ([], []),
            (["notes.txt", "notes.md"], []),
            (["page.html"], ["page.html"]),
            (["page.htm"], ["page.htm"]),
            (["page.xhtml"], ["page.xhtml"]),
            (["a.html", "b.htm", "c.xhtml"], ["a.html", "b.htm", "c.xhtml"]),
            (["a.txt", "b.html", "c.md", "d.xhtml"], ["b.html", "d.xhtml"])
        ]
        for warm in [false, true] {
            for batch in batches {
                let fixture = try OpenFilesFixture()
                defer { fixture.cleanup() }
                var received: [IncomingLink] = []
                let handler: URLRouter.URLHandler = { link, completion in
                    received.append(link)
                    completion()
                }
                if warm { fixture.router.setHandler(handler) }
                fixture.delegate.application(NSApplication.shared, openFiles: batch.files.map { "/tmp/" + $0 })

                XCTAssertEqual(fixture.replies.values, [batch.accepted.isEmpty ? .failure : .success])
                if !warm {
                    XCTAssertTrue(received.isEmpty)
                    fixture.router.setHandler(handler)
                }
                XCTAssertEqual(received, batch.accepted.map { IncomingLink(url: URL(fileURLWithPath: "/tmp/" + $0)) })
                XCTAssertEqual(fixture.replies.values.count, 1)
            }
        }
    }

    func testSeparateCallbacksAndRepeatedFilesKeepOrderAndDoNotReplyAgainOnCompletion() throws {
        let fixture = try OpenFilesFixture()
        defer { fixture.cleanup() }
        let first = "/tmp/repeated.html"
        let last = "/tmp/last.xhtml"
        fixture.delegate.application(NSApplication.shared, openFiles: [first])
        fixture.delegate.application(NSApplication.shared, openFiles: ["/tmp/ignored.txt", first])
        XCTAssertEqual(fixture.replies.values, [.success, .success])

        var received: [URL] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        fixture.router.setHandler { link, completion in
            received.append(link.url)
            completions.append(completion)
        }
        fixture.delegate.application(NSApplication.shared, openFiles: [last])
        XCTAssertEqual(received, [URL(fileURLWithPath: first)])
        XCTAssertEqual(fixture.replies.values, [.success, .success, .success])
        try XCTUnwrap(completions.first)()
        completions[0]()
        XCTAssertEqual(received.count, 2)
        completions[1]()
        completions[2]()
        XCTAssertEqual(received, [first, first, last].map { URL(fileURLWithPath: $0) })
        XCTAssertEqual(fixture.replies.values, [.success, .success, .success])
    }

    func testCancellingRetainedChooserContinuesNextFileWithoutChangingRecentBrowserOrReply() async throws {
        let fixture = try OpenFilesFixture()
        defer { fixture.cleanup() }
        var panels: [NSPanel] = []
        let chooser = ChooserWindowController(
            appLanguageStore: fixture.language, displayPanel: { panels.append($0) },
            mouseEvents: ChooserMouseEventSource().events
        )
        let launcher = OpenFilesNoLaunch()
        let coordinator = LinkRoutingCoordinator(
            browserRepository: fixture.repository, destinationLauncher: launcher, chooser: chooser,
            routingPreferencesStore: fixture.routing, appLanguageStore: fixture.language, onOpenSettings: {}
        )
        var tasks: [Task<Void, Never>] = []
        var completed = 0
        fixture.delegate.application(NSApplication.shared, openFiles: ["/tmp/first.html", "/tmp/second.htm"])
        XCTAssertEqual(fixture.replies.values, [.success])
        fixture.router.setHandler { link, completion in
            tasks.append(coordinator.route(link) {
                completed += 1
                completion()
            })
        }
        try await XCTUnwrap(tasks.first).value
        XCTAssertEqual(panels.count, 1)
        let first = try XCTUnwrap(browserChooserView(in: panels[0].contentView))
        XCTAssertEqual(first.displayURL, "file://first.html")
        first.onCancel?()
        XCTAssertEqual(completed, 1)
        try await XCTUnwrap(tasks.last).value
        XCTAssertEqual(panels.count, 2)
        let second = try XCTUnwrap(browserChooserView(in: panels[1].contentView))
        XCTAssertEqual(second.displayURL, "file://second.htm")
        first.onCancel?()
        XCTAssertEqual(completed, 1)
        second.onCancel?()
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(fixture.repository.recentBrowserIdentifier, fixture.browser.id)
        XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), fixture.originalPreferences)
        XCTAssertEqual(fixture.replies.values, [.success])
        XCTAssertEqual(launcher.openCount, 0)
    }
}

@MainActor
private final class OpenFilesReplies {
    var values: [NSApplication.DelegateReply] = []
}

@MainActor
private final class OpenFilesFixture {
    let router = URLRouter()
    let replies = OpenFilesReplies()
    let browser = makeBrowser(name: "Fixture", bundleIdentifier: "test.openfiles")
    let defaults: UserDefaults
    let cleanup: () -> Void
    let originalPreferences: Data?
    let repository: BrowserRepository
    let language: AppLanguageStore
    let routing: RoutingPreferencesStore
    let delegate: AppDelegate

    init() throws {
        (defaults, cleanup) = makeIsolatedUserDefaults()
        let preferences = BrowserPreferences(userDefaults: defaults)
        try preferences.saveScannedBrowsers([browser], at: Date())
        try preferences.saveRecentBrowserIdentifier(browser.id)
        originalPreferences = defaults.data(forKey: BrowserPreferences.storageKey)
        repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: preferences)
        language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        routing = RoutingPreferencesStore(userDefaults: defaults)
        let replies = replies
        delegate = AppDelegate(
            browserRepository: repository, routingPreferencesStore: routing,
            setupGuideStore: SetupGuideStore(userDefaults: defaults), appLanguageStore: language,
            launchAtLoginController: LaunchAtLoginController(service: OpenFilesLoginService()),
            defaultBrowserController: DefaultBrowserController(
                manager: ControlledDefaultBrowserHandlers(), bundleIdentifier: "test.openfiles"
            ),
            urlRouter: router, replyToOpenOrPrint: { sender, reply in
                XCTAssertTrue(sender === NSApplication.shared)
                replies.values.append(reply)
            }
        )
    }
}

private struct OpenFilesLoginService: LaunchItemService {
    var status: SMAppService.Status { .notFound }
    func register() throws { XCTFail("File acceptance must not register login items") }
    func unregister() throws { XCTFail("File acceptance must not unregister login items") }
}

@MainActor
private final class OpenFilesNoLaunch: DestinationLaunching {
    var openCount = 0
    func open(_ url: URL, in destination: OpenDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        openCount += 1
        XCTFail("Cancellation must not launch a browser")
        completion(false)
    }
    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) { completion() }
}
