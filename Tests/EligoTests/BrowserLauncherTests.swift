import Darwin
import Foundation
import XCTest
@testable import Eligo

@MainActor
final class BrowserLauncherTests: XCTestCase {
    func testInjectedActivatorOwnsBothActivationAndHandoffWait() async {
        let system = ControlledActivationSystem()
        system.application = ControlledActivationApplication()
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(
            system: system, gate: ActivationHandoffGate(resume: { $0() }),
            now: { clock.now }, schedule: clock.schedule
        )
        let workspace = RecordingWorkspace(results: [true])
        // Injecting the component alone must suffice; callers must not have to
        // know which gate instance it uses internally.
        let launcher = BrowserLauncher(workspace: workspace, applicationActivator: activator)
        var deliveryResults: [Bool] = []
        launcher.open(URL(string: "https://example.com")!, in: OpenDestination(
            browser: makeBrowser(name: "Test", bundleIdentifier: "test.browser"), mode: .normal
        )) { deliveryResults.append($0) }
        clock.advance(to: 2)
        XCTAssertEqual(deliveryResults, [true])
        var continued = 0
        launcher.whenActivationSettles { continued += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(continued, 0)
        system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
        system.emit(.sourceDeactivated)
        XCTAssertEqual(continued, 1)
        XCTAssertEqual(deliveryResults, [true])
        XCTAssertEqual(workspace.urlRequests.count, 1)
        XCTAssertTrue(system.observers.isEmpty)
    }

    func testNormalDestinationUsesURLOpeningRequest() {
        let workspace = RecordingWorkspace(results: [true])
        let activator = RecordingApplicationActivator()
        let browser = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let url = URL(string: "https://example.com")!
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: activator).open(
            url,
            in: OpenDestination(browser: browser, mode: .normal)
        ) { result = $0 }

        XCTAssertEqual(workspace.urlRequests.count, 1)
        XCTAssertEqual(workspace.urlRequests.first?.0, [url])
        XCTAssertEqual(workspace.urlRequests.first?.1, browser.appURL)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertEqual(activator.bundleIdentifiers, [browser.bundleIdentifier])
        XCTAssertEqual(activator.mayActivateOnLaunchValues, [true])
        XCTAssertEqual(result, true)
    }

    func testNormalURLRequestsForegroundWithoutChangingURLOrFailureResult() throws {
        let browser = makeBrowser(name: "Firefox Nightly", bundleIdentifier: "org.mozilla.nightly")
        for string in ["https://example.com/a%20b?q=one%26two#fragment", "file:///tmp/a%20b.html"] {
            let url = try XCTUnwrap(URL(string: string))
            for succeeds in [true, false] {
                var requests = 0
                let workspace = NSWorkspaceOpener(openURLRequest: { urls, applicationURL, configuration, completion in
                    requests += 1
                    XCTAssertEqual(urls, [url])
                    XCTAssertEqual(urls.first?.absoluteString, url.absoluteString)
                    XCTAssertEqual(applicationURL, browser.appURL)
                    XCTAssertTrue(configuration.activates, "Background URL delivery creates a background tab in Firefox")
                    XCTAssertFalse(configuration.createsNewApplicationInstance)
                    XCTAssertFalse(configuration.addsToRecentItems)
                    XCTAssertFalse(configuration.promptsUserIfNeeded)
                    completion(succeeds, succeeds ? .current : nil)
                })
                let activator = RecordingApplicationActivator()
                var results: [Bool] = []
                BrowserLauncher(workspace: workspace, applicationActivator: activator).open(
                    url, in: OpenDestination(browser: browser, mode: .normal)
                ) { results.append($0) }
                XCTAssertEqual(requests, 1)
                XCTAssertEqual(results, [succeeds])
                XCTAssertEqual(activator.bundleIdentifiers, succeeds ? [browser.bundleIdentifier] : [])
                XCTAssertEqual(activator.mayActivateOnLaunchValues, succeeds ? [true] : [])
                XCTAssertEqual(activator.preferredPIDs, succeeds ? [NSRunningApplication.current.processIdentifier] : [])
            }
        }
    }

    func testNormalForegroundDeliveryPreservesEarlyAndLateActivationHandoff() {
        for activatesBeforeCallback in [true, false] {
            let browser = makeBrowser(name: "Firefox Nightly", bundleIdentifier: "org.mozilla.nightly")
            let system = ControlledActivationSystem()
            let clock = ActivationTestClock()
            let activator = NSRunningApplicationActivator(
                system: system, gate: ActivationHandoffGate(resume: { $0() }),
                now: { clock.now }, schedule: clock.schedule
            )
            var requests = 0
            let workspace = NSWorkspaceOpener(openURLRequest: { _, _, configuration, completion in
                requests += 1
                XCTAssertTrue(configuration.activates)
                if activatesBeforeCallback {
                    system.application = ControlledActivationApplication()
                    system.application?.isActive = true
                    system.isSourceActive = false
                }
                completion(true, nil)
            })
            let launcher = BrowserLauncher(workspace: workspace, applicationActivator: activator)
            var results: [Bool] = []
            launcher.open(URL(string: "https://example.com/foreground")!, in: OpenDestination(
                browser: browser, mode: .normal
            )) { results.append($0) }
            var handoffs = 0
            launcher.whenActivationSettles { handoffs += 1 }

            if activatesBeforeCallback {
                XCTAssertEqual(results, [true])
                XCTAssertEqual(handoffs, 1)
                XCTAssertEqual(system.application?.activationCount, 0, "Already-active delivery needs no second focus request")
            } else {
                XCTAssertTrue(results.isEmpty)
                clock.advance(to: 2)
                XCTAssertEqual(results, [true], "Focus timeout must not turn delivery into a retry")
                XCTAssertEqual(handoffs, 0, "The OS can still activate a foreground URL request after the retry deadline")
                system.emit(.activated(bundleIdentifier: browser.bundleIdentifier, processIdentifier: 42))
                system.emit(.sourceDeactivated)
                XCTAssertEqual(handoffs, 0, "An undiscovered process cannot settle the handoff")
                system.application = ControlledActivationApplication()
                system.application?.isActive = true
                system.emit(.activated(bundleIdentifier: browser.bundleIdentifier, processIdentifier: 42))
                XCTAssertEqual(handoffs, 1)
            }
            clock.advance(to: 5)
            XCTAssertEqual(results, [true])
            XCTAssertEqual(handoffs, 1)
            XCTAssertEqual(requests, 1, "Late activation must never resend the URL")
            XCTAssertTrue(system.observers.isEmpty)
            withExtendedLifetime(launcher) {}
        }
    }

    func testChromiumPrivateDestinationUsesIncognitoArgument() {
        assertPrivateLaunch(
            bundleIdentifier: "com.google.Chrome",
            expectedArguments: ["--incognito", "https://example.com/private"],
            expectedCreatesNewApplicationInstance: true
        )
    }

    func testHeliumPrivateDestinationUsesIncognitoArgument() {
        assertPrivateLaunch(
            bundleIdentifier: "net.imput.helium",
            expectedArguments: ["--incognito", "https://example.com/private"],
            expectedCreatesNewApplicationInstance: true
        )
    }

    func testDiaPrivateDestinationIsUnavailable() {
        let workspace = RecordingWorkspace(results: [true])
        let dia = makeBrowser(name: "Dia", bundleIdentifier: "company.thebrowser.dia")
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: RecordingApplicationActivator()).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: dia, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertEqual(result, false)
    }

    func testChromiumPrivateLaunchForcesNewApplicationInstance() {
        let workspace = RecordingWorkspace(results: [true])
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: RecordingApplicationActivator()).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: chrome, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertEqual(workspace.applicationRequests.count, 1)
        XCTAssertEqual(workspace.applicationRequests.first?.2, true)
        XCTAssertEqual(result, true)
    }

    func testFirefoxPrivateDestinationUsesPrivateWindowArgument() {
        let workspace = RecordingWorkspace(results: [true])
        let gecko = RecordingGeckoPrivateLauncher(results: [true])
        let browser = makeBrowser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        let url = URL(string: "https://example.com/private")!
        var result: Bool?

        BrowserLauncher(workspace: workspace, geckoPrivateLauncher: gecko, applicationActivator: RecordingApplicationActivator()).open(
            url,
            in: OpenDestination(browser: browser, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertEqual(gecko.requests.count, 1)
        XCTAssertEqual(gecko.requests.first?.0, browser.appURL)
        XCTAssertEqual(gecko.requests.first?.1, browser.bundleIdentifier)
        XCTAssertEqual(gecko.requests.first?.2, ["-private-window", url.absoluteString])
        XCTAssertEqual(result, true)
    }

    func testZenPrivateDestinationUsesZenPrivateWindowArgument() {
        let workspace = RecordingWorkspace(results: [true])
        let gecko = RecordingGeckoPrivateLauncher(results: [true, true])
        let activator = RecordingApplicationActivator()
        let url = URL(string: "https://example.com/private")!

        for bundleIdentifier in ["app.zen-browser.zen", "org.mozilla.zen"] {
            let browser = makeBrowser(name: "Zen Browser", bundleIdentifier: bundleIdentifier)
            var result: Bool?

            BrowserLauncher(
                workspace: workspace,
                geckoPrivateLauncher: gecko,
                applicationActivator: activator
            ).open(
                url,
                in: OpenDestination(browser: browser, mode: .privateBrowsing)
            ) { result = $0 }

            XCTAssertEqual(result, true)
        }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertEqual(gecko.requests.map { $0.1 }, ["app.zen-browser.zen", "org.mozilla.zen"])
        XCTAssertEqual(
            gecko.requests.map { $0.2 },
            [["--private-window", url.absoluteString], ["--private-window", url.absoluteString]]
        )
        XCTAssertEqual(
            activator.bundleIdentifiers,
            ["app.zen-browser.zen", "org.mozilla.zen"]
        )
    }

    func testZenPrivateFailureDoesNotOpenNormally() {
        let workspace = RecordingWorkspace(results: [true])
        let gecko = RecordingGeckoPrivateLauncher(results: [false])
        let activator = RecordingApplicationActivator()
        let browser = makeBrowser(name: "Zen Browser", bundleIdentifier: "org.mozilla.zen")
        var result: Bool?

        BrowserLauncher(
            workspace: workspace,
            geckoPrivateLauncher: gecko,
            applicationActivator: activator
        ).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: browser, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertEqual(gecko.requests.count, 1)
        XCTAssertTrue(activator.bundleIdentifiers.isEmpty)
        XCTAssertEqual(result, false)
    }

    func testFirefoxPrivateProcessWaitsForRunningFirefoxForwarder() {
        let processExecutor = RecordingProcessExecutor(results: [true])
        let processIdentifiers = ProcessIdentifierSource(current: [101])
        let launcher = GeckoPrivateProcessLauncher(
            processExecutor: processExecutor,
            runningApplicationProcessIdentifiers: { bundleIdentifier in
                bundleIdentifier == "org.mozilla.nightly" ? processIdentifiers.current : []
            },
            executableResolver: { applicationURL in
                applicationURL.appending(path: "Contents/MacOS/firefox", directoryHint: .notDirectory)
            }
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/Firefox Nightly.app", isDirectory: true)
        let arguments = ["-private-window", "https://example.com/private"]
        var result: Bool?

        launcher.openPrivateWindow(
            at: applicationURL,
            bundleIdentifier: "org.mozilla.nightly",
            arguments: arguments
        ) { result = $0 }

        XCTAssertEqual(
            processExecutor.requests.first?.0,
            applicationURL.appending(path: "Contents/MacOS/firefox", directoryHint: .notDirectory)
        )
        XCTAssertEqual(processExecutor.requests.first?.1, arguments)
        XCTAssertEqual(processExecutor.requests.first?.2, true)
        XCTAssertEqual(processExecutor.requests.first?.3, 10)
        XCTAssertEqual(processExecutor.shouldTerminateOnTimeout.count, 1)
        XCTAssertTrue(processExecutor.shouldTerminateOnTimeout[0](303))
        processIdentifiers.current = [202]
        XCTAssertFalse(processExecutor.shouldTerminateOnTimeout[0](202))
        processIdentifiers.current = [101, 202]
        XCTAssertFalse(processExecutor.shouldTerminateOnTimeout[0](202))
        XCTAssertEqual(result, true)
    }

    func testFirefoxPrivateProcessDoesNotWaitWhenFirefoxIsStopped() {
        let processExecutor = RecordingProcessExecutor(results: [true])
        let launcher = GeckoPrivateProcessLauncher(
            processExecutor: processExecutor,
            runningApplicationProcessIdentifiers: { _ in [] },
            executableResolver: { applicationURL in
                applicationURL.appending(path: "Contents/MacOS/firefox", directoryHint: .notDirectory)
            }
        )
        var result: Bool?

        launcher.openPrivateWindow(
            at: URL(fileURLWithPath: "/Applications/Firefox.app", isDirectory: true),
            bundleIdentifier: "org.mozilla.firefox",
            arguments: ["-private-window", "https://example.com/private"]
        ) { result = $0 }

        XCTAssertEqual(processExecutor.requests.first?.2, false)
        XCTAssertNil(processExecutor.requests.first?.3)
        XCTAssertEqual(result, true)
    }

    func testZenPrivateProcessWaitsForRunningForwarderForBothBundleIdentifiers() {
        let processExecutor = RecordingProcessExecutor(results: [true, true])
        let launcher = GeckoPrivateProcessLauncher(
            processExecutor: processExecutor,
            runningApplicationProcessIdentifiers: { _ in [101] },
            executableResolver: { applicationURL in
                applicationURL.appending(path: "Contents/MacOS/zen", directoryHint: .notDirectory)
            }
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/Zen Browser.app", isDirectory: true)
        let arguments = ["--private-window", "https://example.com/private"]
        var result: Bool?

        for bundleIdentifier in ["app.zen-browser.zen", "org.mozilla.zen"] {
            launcher.openPrivateWindow(
                at: applicationURL,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments
            ) { result = $0 }

            XCTAssertEqual(result, true)
        }

        XCTAssertEqual(processExecutor.requests.count, 2)
        XCTAssertEqual(
            processExecutor.requests.map { $0.0 },
            [
                applicationURL.appending(path: "Contents/MacOS/zen", directoryHint: .notDirectory),
                applicationURL.appending(path: "Contents/MacOS/zen", directoryHint: .notDirectory)
            ]
        )
        XCTAssertEqual(processExecutor.requests.map { $0.1 }, [arguments, arguments])
        XCTAssertEqual(processExecutor.requests.map { $0.2 }, [true, true])
        XCTAssertEqual(processExecutor.requests.map { $0.3 }, [10, 10])
    }

    func testGeckoPrivateProcessUsesDefaultBundleExecutableResolver() {
        let processExecutor = RecordingProcessExecutor(results: [true])
        let launcher = GeckoPrivateProcessLauncher(
            processExecutor: processExecutor,
            runningApplicationProcessIdentifiers: { _ in [] }
        )
        let applicationURL = Bundle(for: BrowserLauncherTests.self).bundleURL
        let expectedExecutableURL = Bundle(url: applicationURL)?.executableURL
        var result: Bool?

        launcher.openPrivateWindow(
            at: applicationURL,
            bundleIdentifier: "org.mozilla.firefox",
            arguments: ["-private-window", "https://example.com/private"]
        ) { result = $0 }

        XCTAssertNotNil(expectedExecutableURL)
        XCTAssertEqual(processExecutor.requests.first?.0, expectedExecutableURL)
        XCTAssertEqual(result, true)
    }

    func testGeckoPrivateProcessFailsWhenBundleExecutableCannotBeResolved() {
        let processExecutor = RecordingProcessExecutor(results: [true])
        let launcher = GeckoPrivateProcessLauncher(
            processExecutor: processExecutor,
            executableResolver: { _ in nil }
        )
        var result: Bool?

        launcher.openPrivateWindow(
            at: URL(fileURLWithPath: "/Applications/Missing.app", isDirectory: true),
            bundleIdentifier: "org.mozilla.firefox",
            arguments: ["-private-window", "https://example.com/private"]
        ) { result = $0 }

        XCTAssertTrue(processExecutor.requests.isEmpty)
        XCTAssertEqual(result, false)
    }

    func testProcessExecutorReportsForwarderFailure() {
        let expectation = expectation(description: "process exits")
        var result: Bool?
        let executor = ProcessExecutor()

        executor.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            waitForTermination: true,
            terminationTimeout: 2,
            shouldTerminateOnTimeout: { _ in true }
        ) {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(result, false)
    }

    func testProcessExecutorLaunchFailureCompletesOnceAndAllowsNextRequest() {
        let failed = expectation(description: "missing executable fails")
        failed.assertForOverFulfill = true
        let recovered = expectation(description: "same executor completes the next request")
        recovered.assertForOverFulfill = true
        let timeoutSettled = expectation(description: "failed launch's original timeout has passed")
        let executor = ProcessExecutor()
        var failureResults: [Bool] = []
        var recoveryResults: [Bool] = []

        executor.run(
            executableURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EligoMissingProcess-\(UUID().uuidString)/missing"),
            arguments: [],
            waitForTermination: true,
            terminationTimeout: 0.25,
            shouldTerminateOnTimeout: { _ in false }
        ) { result in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            failureResults.append(result)
            XCTAssertEqual(failureResults.count, 1, "Launch failure must complete exactly once")
            if failureResults.count == 1 { failed.fulfill() }
        }
        executor.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            waitForTermination: true,
            terminationTimeout: 2,
            shouldTerminateOnTimeout: { _ in true }
        ) { result in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            recoveryResults.append(result)
            XCTAssertEqual(recoveryResults.count, 1, "Recovery request must complete exactly once")
            if recoveryResults.count == 1 { recovered.fulfill() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { timeoutSettled.fulfill() }
        wait(for: [failed, recovered, timeoutSettled], timeout: 3)
        XCTAssertEqual(failureResults, [false])
        XCTAssertEqual(recoveryResults, [true])
    }

    func testProcessExecutorNoWaitShortProcessCompletesOnce() {
        let completed = expectation(description: "short no-wait process starts")
        completed.assertForOverFulfill = true
        let exitSettled = expectation(description: "short process's late events settle")
        let executor = ProcessExecutor()
        var results: [Bool] = []

        executor.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            waitForTermination: false,
            terminationTimeout: nil,
            shouldTerminateOnTimeout: { _ in false }
        ) { result in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            results.append(result)
            XCTAssertEqual(results.count, 1, "No-wait must complete exactly once")
            if results.count == 1 { completed.fulfill() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exitSettled.fulfill() }
        wait(for: [completed, exitSettled], timeout: 3)
        XCTAssertEqual(results, [true])
    }

    func testProcessExecutorNoWaitCompletesBeforeControlledProcessExits() throws {
        let fixture = try ControlledProcessFixture()
        // The watchdog also releases a child if a regression blocks inside run().
        let watchdog = fixture.scheduleReleaseWatchdog(after: 5)
        defer {
            watchdog.cancel()
            fixture.cleanup()
        }
        let completed = expectation(description: "no-wait completes while child is gated")
        completed.assertForOverFulfill = true
        let exitSettled = expectation(description: "released child's late events settle")
        let executor = ProcessExecutor()
        var results: [Bool] = []

        executor.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
                set -eu
                printf '%s\\n' "$$" > "$1/pid"
                IFS= read -r -t 8 release <> "$1/release"
                printf 'released\\n' > "$1/exiting"
                exit 7
                """, "EligoControlledProcess", fixture.directory.path],
            waitForTermination: false,
            terminationTimeout: nil,
            shouldTerminateOnTimeout: { _ in false }
        ) { result in
            MainActor.assertIsolated()
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(fixture.waitUntilRunning(timeout: 2), "Child must still be running at completion")
            XCTAssertFalse(fixture.wasReleased, "Completion must precede even the watchdog's release")
            results.append(result)
            XCTAssertEqual(results.count, 1, "No-wait must complete exactly once")
            if results.count == 1 { completed.fulfill() }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertTrue(fixture.waitUntilRunning(timeout: 2))
        XCTAssertFalse(fixture.wasReleased)
        XCTAssertEqual(results, [true])
        XCTAssertTrue(fixture.release())
        XCTAssertTrue(fixture.waitUntilExited(timeout: 2), "Released child must exit within the cleanup bound")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("exiting"), encoding: .utf8), "released\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exitSettled.fulfill() }
        wait(for: [exitSettled], timeout: 2)
        XCTAssertEqual(results, [true], "A later nonzero exit must not complete no-wait a second time")
    }

    func testProcessExecutorTerminatesTimedOutForwarder() {
        let timeoutCompleted = expectation(description: "process times out")
        timeoutCompleted.assertForOverFulfill = true
        let raceSettled = expectation(description: "termination callback settles")
        var result: Bool?
        var completionCount = 0
        let executor = ProcessExecutor()

        executor.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            waitForTermination: true,
            terminationTimeout: 0.05,
            shouldTerminateOnTimeout: { _ in true }
        ) {
            completionCount += 1
            result = $0
            timeoutCompleted.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            raceSettled.fulfill()
        }
        wait(for: [timeoutCompleted, raceSettled], timeout: 2)
        XCTAssertEqual(result, false)
        XCTAssertEqual(completionCount, 1)
    }

    func testProcessExecutorDoesNotTerminateWhenTimeoutPolicyRejectsTermination() {
        let timeoutCompleted = expectation(description: "process times out")
        timeoutCompleted.assertForOverFulfill = true
        let processExited = expectation(description: "process exits after timeout")
        var completionCount = 0
        let executor = ProcessExecutor()

        executor.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0.15"],
            waitForTermination: true,
            terminationTimeout: 0.02,
            shouldTerminateOnTimeout: { _ in false }
        ) { result in
            completionCount += 1
            XCTAssertFalse(result)
            timeoutCompleted.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            processExited.fulfill()
        }
        wait(for: [timeoutCompleted, processExited], timeout: 2)
        XCTAssertEqual(completionCount, 1)
    }

    func testUnsupportedPrivateDestinationDoesNotLaunchNormally() {
        let workspace = RecordingWorkspace(results: [true])
        let activator = RecordingApplicationActivator()
        let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: activator).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: safari, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertTrue(activator.bundleIdentifiers.isEmpty)
        XCTAssertEqual(result, false)
    }

    func testPrivateFailureIssuesOnePrivateRequestAndNoNormalRequest() {
        let workspace = RecordingWorkspace(results: [false])
        let activator = RecordingApplicationActivator()
        let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: activator).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: chrome, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertEqual(workspace.applicationRequests.count, 1)
        XCTAssertTrue(activator.bundleIdentifiers.isEmpty)
        XCTAssertEqual(result, false)
    }

    func testFirefoxPrivateFailureDoesNotOpenNormally() {
        let workspace = RecordingWorkspace(results: [true])
        let gecko = RecordingGeckoPrivateLauncher(results: [false])
        let browser = makeBrowser(name: "Firefox Nightly", bundleIdentifier: "org.mozilla.nightly")
        var result: Bool?

        BrowserLauncher(workspace: workspace, geckoPrivateLauncher: gecko, applicationActivator: RecordingApplicationActivator()).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: browser, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertTrue(workspace.applicationRequests.isEmpty)
        XCTAssertEqual(gecko.requests.count, 1)
        XCTAssertEqual(result, false)
    }

    private func assertPrivateLaunch(
        bundleIdentifier: String,
        expectedArguments: [String],
        expectedCreatesNewApplicationInstance: Bool
    ) {
        let workspace = RecordingWorkspace(results: [true])
        let activator = RecordingApplicationActivator()
        let browser = makeBrowser(name: "Browser", bundleIdentifier: bundleIdentifier)
        var result: Bool?

        BrowserLauncher(workspace: workspace, applicationActivator: activator).open(
            URL(string: "https://example.com/private")!,
            in: OpenDestination(browser: browser, mode: .privateBrowsing)
        ) { result = $0 }

        XCTAssertTrue(workspace.urlRequests.isEmpty)
        XCTAssertEqual(workspace.applicationRequests.count, 1)
        XCTAssertEqual(workspace.applicationRequests.first?.0, browser.appURL)
        XCTAssertEqual(workspace.applicationRequests.first?.1, expectedArguments)
        XCTAssertEqual(workspace.applicationRequests.first?.2, expectedCreatesNewApplicationInstance)
        XCTAssertEqual(activator.bundleIdentifiers, [browser.bundleIdentifier])
        XCTAssertEqual(activator.mayActivateOnLaunchValues, [false])
        XCTAssertEqual(result, true)
    }
}

@MainActor
private final class RecordingWorkspace: WorkspaceOpening {
    private var results: [Bool]
    private(set) var urlRequests: [([URL], URL)] = []
    private(set) var applicationRequests: [(URL, [String], Bool)] = []

    init(results: [Bool]) {
        self.results = results
    }

    func openURLs(_ urls: [URL], withApplicationAt applicationURL: URL, completion: @escaping @MainActor (Bool, NSRunningApplication?) -> Void) {
        urlRequests.append((urls, applicationURL))
        completion(nextResult(), nil)
    }

    func openApplication(
        at applicationURL: URL,
        arguments: [String],
        createsNewApplicationInstance: Bool,
        completion: @escaping @MainActor (Bool, NSRunningApplication?) -> Void
    ) {
        applicationRequests.append((applicationURL, arguments, createsNewApplicationInstance))
        completion(nextResult(), nil)
    }

    private func nextResult() -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}

@MainActor
private final class RecordingApplicationActivator: ApplicationActivating {
    private(set) var bundleIdentifiers: [String] = []
    private(set) var preferredPIDs: [pid_t] = []
    private(set) var mayActivateOnLaunchValues: [Bool] = []

    func whenActivationSettles(_ completion: @escaping @MainActor @Sendable () -> Void) { completion() }

    func activate(
        bundleIdentifier: String, preferredApplication: NSRunningApplication?, mayActivateOnLaunch: Bool,
        completion: @escaping (ApplicationActivationResult) -> Void
    ) -> ActivationCancellation {
        if let preferredApplication { preferredPIDs.append(preferredApplication.processIdentifier) }
        bundleIdentifiers.append(bundleIdentifier)
        mayActivateOnLaunchValues.append(mayActivateOnLaunch)
        completion(.activated)
        return ActivationCancellation()
    }
}

@MainActor
private final class RecordingGeckoPrivateLauncher: GeckoPrivateLaunching {
    private var results: [Bool]
    private(set) var requests: [(URL, String, [String])] = []

    init(results: [Bool]) {
        self.results = results
    }

    func openPrivateWindow(
        at applicationURL: URL,
        bundleIdentifier: String,
        arguments: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        requests.append((applicationURL, bundleIdentifier, arguments))
        completion(results.isEmpty ? false : results.removeFirst())
    }
}

@MainActor
private final class RecordingProcessExecutor: ProcessExecuting {
    private var results: [Bool]
    private(set) var requests: [(URL, [String], Bool, TimeInterval?)] = []
    private(set) var shouldTerminateOnTimeout: [@MainActor (pid_t) -> Bool] = []

    init(results: [Bool]) {
        self.results = results
    }

    func run(
        executableURL: URL,
        arguments: [String],
        waitForTermination: Bool,
        terminationTimeout: TimeInterval?,
        shouldTerminateOnTimeout: @escaping @MainActor (pid_t) -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        requests.append((executableURL, arguments, waitForTermination, terminationTimeout))
        self.shouldTerminateOnTimeout.append(shouldTerminateOnTimeout)
        completion(results.isEmpty ? false : results.removeFirst())
    }
}

@MainActor
private final class ProcessIdentifierSource {
    var current: Set<pid_t>

    init(current: Set<pid_t>) {
        self.current = current
    }
}

/// A FIFO holds a shell with no child processes until the test releases it.
private final class ControlledProcessFixture: @unchecked Sendable {
    let directory: URL
    // Serialize the watchdog's release with test cleanup before closing the FIFO.
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var released = false

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EligoControlledProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let fifo = directory.appendingPathComponent("release")
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            descriptor = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not clean up fixture setup: \(error)") }
            throw error
        }
    }

    var wasReleased: Bool { lock.withLock { released } }

    func scheduleReleaseWatchdog(after timeout: TimeInterval) -> DispatchWorkItem {
        // Construct off the test's MainActor so this can run while that actor is blocked.
        let watchdog = DispatchWorkItem { [self] in XCTAssertTrue(release()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        return watchdog
    }

    private var processIdentifier: pid_t? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
              text.hasSuffix("\n"),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    private var isRunning: Bool {
        guard let pid = processIdentifier else { return false }
        return processExists(pid)
    }

    private func processExists(_ pid: pid_t) -> Bool {
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    func waitUntilRunning(timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !isRunning, !wasReleased, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return isRunning && !wasReleased
    }

    func release() -> Bool {
        lock.withLock {
            if released { return true }
            guard descriptor >= 0 else { return false }
            let written = [UInt8(10)].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            guard written == 1 else { return false }
            released = true
            return true
        }
    }

    func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        // A child that has not published its PID is not evidence of an exit.
        while processIdentifier == nil, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let pid = processIdentifier else { return false }
        while processExists(pid), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !processExists(pid)
    }

    func cleanup() {
        XCTAssertTrue(release(), "Fixture cleanup must release the child on every test path")
        XCTAssertTrue(waitUntilExited(timeout: 2), "Fixture child survived cleanup")
        lock.withLock {
            XCTAssertEqual(Darwin.close(descriptor), 0)
            descriptor = -1
        }
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Could not remove controlled process fixture: \(error)") }
    }
}
