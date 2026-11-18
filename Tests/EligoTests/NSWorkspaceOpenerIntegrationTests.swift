import AppKit
import CoreGraphics
import Darwin
import XCTest
@testable import Eligo

@MainActor
final class NSWorkspaceOpenerIntegrationTests: XCTestCase {
    func testColdLaunchForwardsCompleteOrderedArgumentsAndApplicationIdentity() async throws {
        let fixture = try await makeFixture()
        let arguments = ["--incognito", "https://fixture.invalid/cold?request=\(UUID().uuidString)"]

        let (success, application) = try await open(fixture.appURL, arguments: arguments, newInstance: true)
        XCTAssertTrue(success)
        let app = try XCTUnwrap(application)
        let record = try await fixture.record(for: app)

        XCTAssertEqual(record.arguments, arguments, "Cold launch must forward the complete ordered argv")
        XCTAssertEqual(record.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(record.processIdentifier, app.processIdentifier)
        XCTAssertFalse(record.launchID.isEmpty)
        XCTAssertFalse(app.isTerminated)
        XCTAssertEqual(app.bundleURL?.resolvingSymlinksInPath(), fixture.appURL.resolvingSymlinksInPath())
        workspaceFixtureEvent("cold.accepted", ["pid": app.processIdentifier, "argv": record.arguments, "launchID": record.launchID])
    }

    func testWarmLaunchCreatesDistinctInstanceReceivingThisRequestsArguments() async throws {
        let fixture = try await makeFixture()
        let firstArguments = ["--incognito", "https://fixture.invalid/first?request=\(UUID().uuidString)"]
        let (firstSuccess, firstApplication) = try await open(fixture.appURL, arguments: firstArguments, newInstance: false)
        XCTAssertTrue(firstSuccess)
        let first = try XCTUnwrap(firstApplication)
        let firstRecord = try await fixture.record(for: first)
        XCTAssertEqual(firstRecord.arguments, firstArguments)
        XCTAssertFalse(first.isTerminated)

        let secondArguments = ["--incognito", "https://fixture.invalid/second?request=\(UUID().uuidString)"]
        let (secondSuccess, secondApplication) = try await open(fixture.appURL, arguments: secondArguments, newInstance: true)
        XCTAssertTrue(secondSuccess)
        let second = try XCTUnwrap(secondApplication)
        let secondRecord = try await fixture.record(for: second)

        XCTAssertNotEqual(second.processIdentifier, first.processIdentifier, "Warm launch must create a new process")
        XCTAssertNotEqual(secondRecord.launchID, firstRecord.launchID, "Warm launch must not reuse the first record")
        XCTAssertEqual(secondRecord.arguments, secondArguments, "Warm launch must receive this request's ordered argv")
        XCTAssertEqual(secondRecord.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(secondRecord.processIdentifier, second.processIdentifier)
        XCTAssertFalse(first.isTerminated)
        XCTAssertFalse(second.isTerminated)
        workspaceFixtureEvent("warm.observed", [
            "firstPID": first.processIdentifier, "secondPID": second.processIdentifier,
            "firstLaunchID": firstRecord.launchID, "secondLaunchID": secondRecord.launchID,
            "firstArguments": firstRecord.arguments, "secondArguments": secondRecord.arguments
        ])
    }

    func testMissingApplicationReportsFailureWithoutAnApplication() async throws {
        try requireDesktopSession()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("EligoMissingWorkspaceFixture-\(UUID().uuidString).app")
        let (success, application) = try await open(missing, arguments: ["--incognito", "https://fixture.invalid/missing"], newInstance: true)
        XCTAssertFalse(success)
        XCTAssertNil(application)
        workspaceFixtureEvent("missing.rejected", ["success": success, "applicationIsNil": application == nil])
    }

    func testExternalToolTimeoutIsBoundedAndReapsProcess() throws {
        let start = ContinuousClock.now
        do {
            try WorkspaceFixtureTools.run("/bin/sh", ["-c", "sleep 30 & wait"], timeout: 0.05)
            XCTFail("A hanging fixture tool must time out")
        } catch WorkspaceFixtureError.toolTimedOut(let pid) {
            XCTAssertGreaterThan(pid, 0)
            XCTAssertFalse(workspaceProcessExists(pid))
            XCTAssertFalse(workspaceProcessGroupExists(pid), "A timed-out compiler's child processes must also exit")
            // Timeout + TERM/KILL/group waits can total 4.05s before scheduling overhead.
            XCTAssertLessThan(start.duration(to: .now), .seconds(6))
            workspaceFixtureEvent("tool.timeoutVerified", ["pid": pid, "reaped": true, "childGroupGone": true])
        }
    }

    func testMissingApplicationForURLsReportsFailure() async throws {
        try requireDesktopSession()
        let identity = UUID().uuidString
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("EligoMissingWorkspaceFixture-\(identity).app")
        let url = try XCTUnwrap(URL(string: "eligo-fixture-\(identity.lowercased())://missing"))
        let completed = expectation(description: "Real NSWorkspace URL-open failure callback")
        completed.assertForOverFulfill = true
        var result: Bool?
        var callbackCount = 0
        NSWorkspaceOpener().openURLs([url], withApplicationAt: missing) { success in
            XCTAssertTrue(Thread.isMainThread)
            callbackCount += 1
            result = success
            completed.fulfill()
        }
        let wait = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(wait, .completed)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(try XCTUnwrap(result))
        workspaceFixtureEvent("missingURLs.rejected", ["success": result == true, "callbackCount": callbackCount])
    }

    func testRegistryReadbackRejectsUnknownOrIncompleteRecords() throws {
        let separator = "\n--------------------------------------------------------------------------------\n"
        let identifier = "test.eligo.nsworkspace.parser"
        let record = separator + "identifier: " + identifier + "\npath: /tmp/fixture.app\n"
        XCTAssertEqual(try WorkspaceForwardingFixture.registrationPaths(in: record, for: identifier), ["/tmp/fixture.app"])
        XCTAssertEqual(try WorkspaceForwardingFixture.registrationPaths(in: record, for: "different.identifier"), [])
        XCTAssertThrowsError(try WorkspaceForwardingFixture.registrationPaths(in: "unknown registry output", for: identifier))
        XCTAssertThrowsError(try WorkspaceForwardingFixture.registrationPaths(in: separator + "path: /tmp/fixture.app\n", for: identifier))
        let incomplete = record + separator + "identifier: " + identifier + "\n"
        XCTAssertThrowsError(try WorkspaceForwardingFixture.registrationPaths(in: incomplete, for: identifier))
    }

    private func requireDesktopSession() throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            workspaceFixtureEvent("environment.unavailable", ["reason": "No WindowServer session; skip is not desktop acceptance"])
            throw XCTSkip("Real NSWorkspace integration requires a macOS graphical session; not acceptance proof")
        }
    }

    private func makeFixture() async throws -> WorkspaceForwardingFixture {
        try requireDesktopSession()
        let tools = try WorkspaceFixtureTools.discover()
        let fixture = try await WorkspaceForwardingFixture(tools: tools)
        addTeardownBlock { try await fixture.cleanup() }
        return fixture
    }

    private func open(_ url: URL, arguments: [String], newInstance: Bool) async throws -> (Bool, NSRunningApplication?) {
        let completed = expectation(description: "Real NSWorkspace callback")
        completed.assertForOverFulfill = true
        var result: (Bool, NSRunningApplication?)?
        var callbackCount = 0
        NSWorkspaceOpener().openApplication(at: url, arguments: arguments, createsNewApplicationInstance: newInstance) { success, application in
            XCTAssertTrue(Thread.isMainThread, "NSWorkspace callback must reach the main actor")
            callbackCount += 1
            result = (success, application)
            workspaceFixtureEvent("callback", ["success": success, "pid": application?.processIdentifier ?? 0, "newInstance": newInstance])
            completed.fulfill()
        }
        let wait = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(wait, .completed, "Real NSWorkspace callback did not finish")
        XCTAssertEqual(callbackCount, 1)
        return try XCTUnwrap(result)
    }
}

@MainActor
private final class WorkspaceForwardingFixture {
    struct Record: Decodable {
        let processIdentifier: pid_t
        let launchID: String
        let bundleIdentifier: String
        let arguments: [String]
    }

    let bundleIdentifier: String
    let appURL: URL
    private let root: URL

    init(tools: WorkspaceFixtureTools) async throws {
        let identity = UUID().uuidString.lowercased()
        bundleIdentifier = "test.eligo.nsworkspace.\(identity)"
        let parent = ProcessInfo.processInfo.environment["WORKSPACE_FIXTURE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = parent.appendingPathComponent("EligoWorkspaceFixture-\(identity)", isDirectory: true)
        appURL = root.appendingPathComponent("Workspace Forwarding Fixture.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ownership: [String: String] = ["bundleID": bundleIdentifier, "app": appURL.path, "root": root.path]
            try JSONSerialization.data(withJSONObject: ownership, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("ownership.json"), options: .atomic)
            workspaceFixtureEvent("fixture.owned", ownership)
            let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": bundleIdentifier, "CFBundleName": "Workspace Forwarding Fixture",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "TestExecutable",
                "LSUIElement": true, "LSMultipleInstancesProhibited": false, "CFBundleVersion": "1"
            ]
            let info = contents.appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            let actual = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
            let noHandlers = actual["CFBundleURLTypes"] == nil && actual["CFBundleDocumentTypes"] == nil
            guard noHandlers else { throw WorkspaceFixtureError.operation("Fixture must not declare URL or document handlers") }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("records"), withIntermediateDirectories: true)
            let source = try XCTUnwrap(Bundle.module.url(forResource: "NSWorkspaceFixture", withExtension: "swift", subdirectory: "Fixtures"))
            try WorkspaceFixtureTools.run(tools.swiftc, [
                "-parse-as-library", "-swift-version", "6", "-module-cache-path", root.appendingPathComponent("module-cache").path,
                source.path, "-o", contents.appendingPathComponent("MacOS/TestExecutable").path
            ])
            try WorkspaceFixtureTools.run(tools.codesign, ["--force", "--sign", "-", appURL.path])
            try WorkspaceFixtureTools.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", appURL.path])
            guard try registrationPaths().contains(appURL.resolvingSymlinksInPath().path) else {
                throw WorkspaceFixtureError.operation("Fixture registration could not be read back")
            }
            workspaceFixtureEvent("fixture.created", ["bundleID": bundleIdentifier, "app": appURL.path, "declaresURLHandlers": !noHandlers])
        } catch {
            do { try await cleanup(phase: "initialization") }
            catch let cleanupError { throw WorkspaceFixtureError.operation("Initialization failed: \(error); cleanup failed: \(cleanupError)") }
            throw error
        }
    }

    func record(for application: NSRunningApplication) async throws -> Record {
        let url = root.appendingPathComponent("records/\(application.processIdentifier).json")
        guard try await waitUntil(timeout: 5, { FileManager.default.fileExists(atPath: url.path) }) else {
            throw WorkspaceFixtureError.operation("Fixture did not produce a launch record for PID \(application.processIdentifier)")
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    func cleanup(phase: String = "teardown") async throws {
        let applications = runningApplications
        let processIdentifiers = applications.map(\.processIdentifier)
        for application in applications { application.terminate() }
        if try await !waitUntil(timeout: 2, { self.runningApplications.isEmpty }) {
            for application in runningApplications { application.forceTerminate() }
        }
        let stopped = try await waitUntil(timeout: 3) { self.runningApplications.isEmpty }
        let pidsGone = try await waitUntil(timeout: 3) { processIdentifiers.allSatisfy { !workspaceProcessExists($0) } }
        // Registry I/O must not prevent stopping an already identified fixture.
        let registrationBefore = try registrationPaths()
        if registrationBefore.contains(where: { $0 != appURL.resolvingSymlinksInPath().path }) {
            throw WorkspaceFixtureError.operation("Refusing to unregister an unexpected application path")
        }
        let unregisterAttempted = !registrationBefore.isEmpty
        var cleanupError: Error?
        var unregisterExitZero: Any = NSNull()
        if unregisterAttempted {
            do {
                try WorkspaceFixtureTools.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", appURL.path])
                unregisterExitZero = true
            } catch { cleanupError = error; unregisterExitZero = false }
        }
        let registrationAfter = try registrationPaths()
        let registrationRemoved = registrationAfter.isEmpty
        if stopped && pidsGone && registrationRemoved && cleanupError == nil {
            do { try FileManager.default.removeItem(at: root) }
            catch { cleanupError = error }
        }
        let removed = !FileManager.default.fileExists(atPath: root.path)
        workspaceFixtureEvent("fixture.cleanup", [
            "bundleID": bundleIdentifier, "pids": processIdentifiers, "phase": phase,
            "registrationPresentBefore": !registrationBefore.isEmpty,
            "registeredPathsBefore": registrationBefore, "registeredPathsAfter": registrationAfter,
            "unregisterAttempted": unregisterAttempted,
            "unregisterExitZero": unregisterExitZero,
            "stopped": stopped, "pidsGone": pidsGone,
            "registrationRemoved": registrationRemoved, "removed": removed
        ])
        if let cleanupError { throw cleanupError }
        guard stopped, pidsGone, removed, registrationRemoved else { throw WorkspaceFixtureError.operation("Fixture cleanup did not finish") }
    }

    private func registrationPaths() throws -> [String] {
        let dump = try WorkspaceFixtureTools.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-dump"])
        return try Self.registrationPaths(in: dump, for: bundleIdentifier)
    }

    static func registrationPaths(in dump: String, for bundleIdentifier: String) throws -> [String] {
        let blocks = dump.components(separatedBy: "\n--------------------------------------------------------------------------------\n")
        let lines = dump.components(separatedBy: "\n")
        guard blocks.count > 1, lines.contains(where: { $0.hasPrefix("identifier:") }), lines.contains(where: { $0.hasPrefix("path:") }) else {
            throw WorkspaceFixtureError.operation("Unrecognized LaunchServices registry output")
        }
        return try blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard lines.contains(where: { $0.hasPrefix("identifier:") && $0.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces) == bundleIdentifier }) else { return nil }
            guard let line = lines.first(where: { $0.hasPrefix("path:") }) else {
                throw WorkspaceFixtureError.operation("Fixture registry record has no path")
            }
            let path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " (0x")[0]
            guard !path.isEmpty else { throw WorkspaceFixtureError.operation("Fixture registry path is empty") }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    }

    private var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            $0.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath()
        }
    }
}

private enum WorkspaceFixtureError: Error {
    case operation(String)
    case commandFailed(Int32, String)
    case toolTimedOut(pid_t)
}

private struct WorkspaceFixtureTools {
    let swiftc: String
    let codesign: String

    @MainActor
    static func discover() throws -> Self {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("NSWorkspace fixture requires xcrun; ordinary Swift tests remain available")
        }
        do {
            let swiftc = try run("/usr/bin/xcrun", ["--find", "swiftc"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
            let codesign = try run("/usr/bin/xcrun", ["--find", "codesign"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard FileManager.default.isExecutableFile(atPath: swiftc), FileManager.default.isExecutableFile(atPath: codesign) else {
                throw XCTSkip("NSWorkspace fixture compiler/signing tools unavailable; not desktop acceptance")
            }
            return Self(swiftc: swiftc, codesign: codesign)
        } catch WorkspaceFixtureError.commandFailed(_, let output) {
            workspaceFixtureEvent("environment.toolsUnavailable", ["reason": output])
            throw XCTSkip("NSWorkspace fixture compiler/signing tools unavailable; not desktop acceptance")
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let parent = ProcessInfo.processInfo.environment["WORKSPACE_FIXTURE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let outputURL = parent.appendingPathComponent("EligoWorkspaceTool-\(UUID().uuidString).log")
        try Data().write(to: outputURL)
        defer {
            do { try FileManager.default.removeItem(at: outputURL) }
            catch { XCTFail("Could not remove fixture tool output: \(error)") }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            do { try output.close() }
            catch { XCTFail("Could not close fixture tool output: \(error)") }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let pid = process.processIdentifier
        let group = getpgid(pid)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Foundation gives Process its own group; never signal the test host's group.
            if group == pid { kill(-pid, SIGTERM) }
            else if process.isRunning { process.terminate() }
            let terminated = exited.wait(timeout: .now() + 1)
            if group == pid && workspaceProcessGroupExists(pid) { kill(-pid, SIGKILL) }
            if terminated == .timedOut {
                if process.isRunning { kill(pid, SIGKILL) }
                guard exited.wait(timeout: .now() + 2) == .success else {
                    throw WorkspaceFixtureError.operation("Fixture tool could not be reaped after timeout")
                }
            }
            guard group == pid else { throw WorkspaceFixtureError.operation("Fixture tool did not have its own process group") }
            let deadline = Date().addingTimeInterval(1)
            while workspaceProcessGroupExists(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard !workspaceProcessGroupExists(pid) else { throw WorkspaceFixtureError.operation("Fixture tool child group did not exit") }
            throw WorkspaceFixtureError.toolTimedOut(pid)
        }
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WorkspaceFixtureError.commandFailed(process.terminationStatus, text)
        }
        return text
    }
}

private func workspaceProcessExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

private func workspaceProcessGroupExists(_ group: pid_t) -> Bool {
    kill(-group, 0) == 0 || errno != ESRCH
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    return condition()
}

@MainActor
private func workspaceFixtureEvent(_ event: String, _ fields: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: ["event": event, "fields": fields], options: [.sortedKeys])
        FileHandle.standardOutput.write(Data(("WORKSPACE_FIXTURE_EVENT " + String(decoding: data, as: UTF8.self) + "\n").utf8))
    } catch { XCTFail("Could not serialize fixture evidence: \(error)") }
}
