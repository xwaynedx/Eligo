import AppKit
import Foundation
import XCTest
@testable import Eligo

/// Each physical scan can finish independently, including after Reset invalidates it.
final class ControlledBrowserScanner: BrowserScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [[Browser]]
    private let gates: [DispatchSemaphore]
    private var count = 0

    init(results: [[Browser]]) {
        self.results = results
        self.gates = results.map { _ in DispatchSemaphore(value: 0) }
    }

    func scan() -> [Browser] {
        let index = lock.withLock {
            let index = count
            count += 1
            return index
        }
        guard results.indices.contains(index) else { return [] }
        gates[index].wait()
        return results[index]
    }

    var scanCount: Int { lock.withLock { count } }
    func finish(_ index: Int) { gates[index].signal() }
    func finishAll() { gates.forEach { $0.signal() } }
}

final class StubBrowserScanner: BrowserScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: [Browser]
    private var storedScanCount = 0
    private var storedRanOnMainThread = false

    init(result: [Browser]) {
        self.result = result
    }

    func scan() -> [Browser] {
        lock.lock()
        storedScanCount += 1
        storedRanOnMainThread = storedRanOnMainThread || Thread.isMainThread
        lock.unlock()
        return result
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedScanCount
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedRanOnMainThread
    }
}

func makeBrowser(
    name: String,
    bundleIdentifier: String,
    isCustom: Bool = false,
    priority: Int = 10
) -> Browser {
    Browser(
        name: name,
        bundleIdentifier: bundleIdentifier,
        appURL: TestBrowserInstallations.shared.appURL(name: name, bundleIdentifier: bundleIdentifier),
        priority: priority,
        isCustom: isCustom
    )
}

/// Repository tests now check disk availability too. These executable bundles
/// replace imaginary /Applications paths; no fixture is registered or launched.
private final class TestBrowserInstallations: @unchecked Sendable {
    static let shared = TestBrowserInstallations()
    private let lock = NSLock()
    private var urls: [String: URL] = [:]
    private var cleanups: [() -> Void] = []

    private init() {
        atexit { TestBrowserInstallations.shared.cleanup() }
    }

    func appURL(name: String, bundleIdentifier: String) -> URL {
        lock.withLock {
            let key = "\(bundleIdentifier)/\(name)"
            if let url = urls[key] { return url }
            let (url, cleanup) = try! makeApplicationBundle(name: name, bundleIdentifier: bundleIdentifier, urlSchemes: ["https"])
            urls[key] = url
            cleanups.append(cleanup)
            return url
        }
    }

    private func cleanup() { cleanups.forEach { $0() } }
}

func makeIsolatedPreferences() -> (BrowserPreferences, () -> Void) {
    let (userDefaults, cleanup) = makeIsolatedUserDefaults()
    return (BrowserPreferences(userDefaults: userDefaults), cleanup)
}

func makeIsolatedUserDefaults(suiteName: String = "EligoTests.\(UUID().uuidString)") -> (UserDefaults, () -> Void) {
    let userDefaults = UserDefaults(suiteName: suiteName)!
    let cleanup = {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
    return (userDefaults, cleanup)
}

/// A language store pinned to English regardless of the host machine's locale,
/// for tests that assert user-facing strings. Uses a fixed throwaway suite
/// reset on every creation, so repeated runs leave at most one empty file.
@MainActor
func makeEnglishAppLanguageStore() -> AppLanguageStore {
    let suiteName = "EligoTests.englishLocale"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return AppLanguageStore(userDefaults: userDefaults, systemPreferredLanguages: ["en-US"])
}

/// A routing preferences store backed by a throwaway suite, so tests never
/// observe the host machine's real routing settings. Same fixed-suite-reset
/// pattern as `makeEnglishAppLanguageStore`.
@MainActor
func makeIsolatedRoutingPreferencesStore() -> RoutingPreferencesStore {
    let suiteName = "EligoTests.routingPreferences"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return RoutingPreferencesStore(userDefaults: userDefaults)
}

/// An executable fixture bundle for commit-time availability checks. Tests may
/// remove it to simulate uninstalling; the fixture is never launched.
@MainActor
final class ScopeDestinationFixture {
    let browser: Browser
    let preferences: BrowserPreferences
    let repository: BrowserRepository
    private let removeApp: () -> Void

    init(userDefaults: UserDefaults, browserID: String = "test.scope") throws {
        let (url, cleanup) = try makeApplicationBundle(
            name: "Scope Fixture", bundleIdentifier: browserID, urlSchemes: ["http", "https"]
        )
        removeApp = cleanup
        browser = Browser(name: "Scope Fixture", bundleIdentifier: browserID, appURL: url, priority: 0)
        preferences = BrowserPreferences(userDefaults: userDefaults)
        do {
            try preferences.saveScannedBrowsers([browser], at: Date())
            repository = BrowserRepository(scanner: StubBrowserScanner(result: [browser]), preferences: preferences)
        } catch {
            cleanup()
            throw error
        }
    }

    var destinationID: OpenDestinationID { OpenDestinationID(browserID: browser.id, mode: .normal) }
    func cleanup() { removeApp() }
}

func makeApplicationBundle(
    name: String,
    bundleIdentifier: String,
    urlSchemes: [String]?,
    includeExecutable: Bool = true
) throws -> (URL, () -> Void) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("EligoTests-\(UUID().uuidString)", isDirectory: true)
    let appURL = rootURL.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    var propertyList: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "TestExecutable"
    ]
    if let urlSchemes {
        propertyList["CFBundleURLTypes"] = [["CFBundleURLSchemes": urlSchemes]]
    }

    let data = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    if includeExecutable {
        let executableDirectory = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appendingPathComponent("TestExecutable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    return (appURL, {
        try? FileManager.default.removeItem(at: rootURL)
    })
}

/// Locate the production row controls without depending on their container layout.
@MainActor
func browserChooserRows(in view: NSView) -> [NSControl] {
    if let control = view as? NSControl,
       !(control is NSButton), control.accessibilityRole() == .button {
        return [control]
    }
    return view.subviews.flatMap { browserChooserRows(in: $0) }
}

@MainActor
func chooserMouseEvent(location: NSPoint = .zero, windowNumber: Int = 0) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )!
}

/// Find the chooser independently of decorative wrapper subviews.
@MainActor
func browserChooserView(in root: NSView?) -> ChooserView? {
    guard let root else { return nil }
    if let chooser = root as? ChooserView { return chooser }
    return root.subviews.lazy.compactMap { browserChooserView(in: $0) }.first
}

/// Match the action identity, rather than whichever button happens to come first.
@MainActor
func browserChooserPrivateButton(in row: NSView?) -> NSButton? {
    row?.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "chooser.private"
    }
}

@MainActor
func chooserKeyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], windowNumber: Int = 0) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
func waitForBrowserCondition(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2_000 where !predicate() { await Task.yield() }
    XCTAssertTrue(predicate(), file: file, line: line)
}
