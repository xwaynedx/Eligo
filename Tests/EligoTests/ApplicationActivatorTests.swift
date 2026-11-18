import AppKit
import XCTest
@testable import Eligo

@MainActor
final class ApplicationActivatorTests: XCTestCase {
    func testActivationYieldsToTheTargetBeforeRequestingFocusFromEligo() {
        let system = ControlledActivationSystem()
        let application = ControlledActivationApplication()
        system.application = application
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(system: system, now: { clock.now }, schedule: clock.schedule)
        application.onActivation = { [weak system] in
            XCTAssertEqual(system?.yieldedProcessIdentifiers, [42])
        }

        _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { _ in }

        XCTAssertEqual(application.activationSourceIdentifiers, [NSRunningApplication.current.processIdentifier])
        XCTAssertEqual(application.activationCount, 1)
        clock.advance(to: 2)
        XCTAssertEqual(system.yieldedProcessIdentifiers, [application.processIdentifier])
        XCTAssertEqual(application.activationCount, 1)
    }

    func testDelayedDeadlineRecognizesCompletedHandoffWithoutAnotherNotification() {
        for alreadyDiscovered in [false, true] {
            let system = ControlledActivationSystem()
            let application = ControlledActivationApplication()
            if alreadyDiscovered { system.application = application }
            let clock = ActivationTestClock()
            let activator = NSRunningApplicationActivator(
                system: system, gate: ActivationHandoffGate(resume: { $0() }),
                now: { clock.now }, schedule: clock.schedule
            )
            var results: [ApplicationActivationResult] = []
            _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: true) { results.append($0) }
            var continued = 0
            activator.whenActivationSettles { continued += 1 }

            // The run loop returns after the budget; the OS handoff is already
            // complete, but its notifications have not been delivered to Eligo.
            system.application = application
            application.isActive = true
            system.isSourceActive = false
            clock.advanceAfterMainThreadBlock(to: 3)

            XCTAssertEqual(results, [.activated])
            XCTAssertEqual(continued, 1)
            XCTAssertEqual(application.activationCount, alreadyDiscovered ? 1 : 0)
            XCTAssertTrue(system.observers.isEmpty)
            XCTAssertTrue(clock.scheduled.isEmpty)
        }
    }

    func testCancellationReconcilesCompletedHandoffAndKeepsCancelledResult() {
        let system = ControlledActivationSystem()
        let application = ControlledActivationApplication()
        system.application = application
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(
            system: system, gate: ActivationHandoffGate(resume: { $0() }),
            now: { clock.now }, schedule: clock.schedule
        )
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        var continued = 0
        activator.whenActivationSettles { continued += 1 }

        application.isActive = true
        system.isSourceActive = false
        request.cancel()
        request.cancel()
        clock.advance(to: 10)

        XCTAssertEqual(results, [.cancelled])
        XCTAssertEqual(continued, 1)
        XCTAssertEqual(application.activationCount, 1)
        XCTAssertTrue(system.observers.isEmpty)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    func testBlockedMainQueueDoesNotRetryOrReleaseAnUnconfirmedHandoff() {
        for discoveredBeforeBlock in [false, true] {
            let system = ControlledActivationSystem()
            let application = ControlledActivationApplication()
            if discoveredBeforeBlock { system.application = application }
            let clock = ActivationTestClock()
            let activator = NSRunningApplicationActivator(
                system: system, gate: ActivationHandoffGate(resume: { $0() }),
                now: { clock.now }, schedule: clock.schedule
            )
            var results: [ApplicationActivationResult] = []
            _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: true) { results.append($0) }
            var continued = 0
            activator.whenActivationSettles { continued += 1 }
            system.application = application
            system.isSourceActive = false

            clock.advanceAfterMainThreadBlock(to: 3)
            system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 99))
            XCTAssertEqual(results, [.timedOut])
            XCTAssertEqual(continued, 0)
            XCTAssertEqual(application.activationCount, discoveredBeforeBlock ? 1 : 0)

            system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
            XCTAssertEqual(results, [.timedOut])
            XCTAssertEqual(continued, 1)
            XCTAssertTrue(system.observers.isEmpty)
        }
    }

    func testCancelledUnboundRequestResumesOnlyAfterDiscoveredTargetExits() {
        let system = ControlledActivationSystem()
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(
            system: system, gate: ActivationHandoffGate(resume: { $0() }),
            now: { clock.now }, schedule: clock.schedule
        )
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: true) { results.append($0) }
        request.cancel()
        var continued = 0
        activator.whenActivationSettles { continued += 1 }
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 99))
        XCTAssertEqual(continued, 0)
        system.application = ControlledActivationApplication()
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 99))
        XCTAssertEqual(continued, 0)
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 42))
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 42))
        clock.advance(to: 10)
        XCTAssertEqual(continued, 1)
        XCTAssertEqual(results, [.cancelled])
        XCTAssertEqual(system.application?.activationCount, 0)
        XCTAssertTrue(system.observers.isEmpty)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    func testUnboundTargetRejectsSameBundleEventsBeforeAndAfterCompletion() {
        let wrongEvents: [ApplicationActivationEvent] = [
            .terminated(bundleIdentifier: "test.browser", processIdentifier: 99),
            .activated(bundleIdentifier: "test.browser", processIdentifier: 99)
        ]
        for wrongEvent in wrongEvents {
            for earlyResult: ApplicationActivationResult? in [nil, .timedOut, .cancelled] {
                let system = ControlledActivationSystem()
                let clock = ActivationTestClock()
                let gate = ActivationHandoffGate(resume: { $0() })
                let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
                var results: [ApplicationActivationResult] = []
                let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: true) { results.append($0) }
                let staleTicks = clock.scheduled.map(\.action)
                let staleObservers = Array(system.observers.values)
                if earlyResult == .timedOut { clock.advance(to: 2) }
                if earlyResult == .cancelled { request.cancel() }
                var continued = 0
                gate.whenSafe { continued += 1 }
                for _ in 0..<2 {
                    system.emit(wrongEvent)
                    system.emit(.sourceDeactivated)
                }
                XCTAssertEqual(continued, 0)
                XCTAssertEqual(results, earlyResult.map { [$0] } ?? [])
                XCTAssertEqual(system.observers.count, 1)

                // A notification can trigger discovery, but its wrong PID must
                // not become a remembered activation fact for the new target.
                system.application = ControlledActivationApplication()
                system.emit(wrongEvent)
                system.emit(.sourceDeactivated)
                XCTAssertEqual(continued, 0)
                system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
                XCTAssertEqual(continued, 1)
                XCTAssertEqual(results, [earlyResult ?? .activated])
                XCTAssertTrue(system.observers.isEmpty)
                XCTAssertTrue(clock.scheduled.allSatisfy { clock.cancelled.contains($0.id) })
                request.cancel()
                staleTicks.forEach { $0() }
                staleObservers.forEach { $0(wrongEvent) }
                system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
                XCTAssertEqual(continued, 1)
                XCTAssertEqual(results, [earlyResult ?? .activated])
                XCTAssertEqual(system.application?.activationCount, 0)
            }
        }
    }

    func testHandoffResumesOutsideNotificationDeliveryAndRechecksNewWork() {
        var callbacks: [@MainActor () -> Void] = []
        let gate = ActivationHandoffGate(resume: { callbacks.append($0) })
        let first = UUID()
        gate.begin(first)
        var continued = 0
        gate.whenSafe { continued += 1 }
        gate.end(first)
        XCTAssertEqual(continued, 0)
        let second = UUID()
        gate.begin(second)
        callbacks.removeFirst()()
        XCTAssertEqual(continued, 0)
        gate.end(second)
        callbacks.removeFirst()()
        XCTAssertEqual(continued, 1)
    }

    func testAcceptedRequestTimesOutOnceButLateFocusStillGuardsPresentation() {
        let system = ControlledActivationSystem()
        system.application = ControlledActivationApplication()
        let clock = ActivationTestClock()
        let gate = ActivationHandoffGate(resume: { $0() })
        let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        clock.advance(to: 2)
        XCTAssertEqual(results, [.timedOut])
        var presented = false
        gate.whenSafe { presented = true }
        XCTAssertFalse(presented)
        request.cancel()
        clock.advance(to: 20)
        XCTAssertEqual(system.application?.activationCount, 1)
        system.emit(.activated(bundleIdentifier: "another.browser", processIdentifier: 99))
        system.emit(.sourceDeactivated)
        XCTAssertFalse(presented)
        system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
        XCTAssertTrue(presented)
        XCTAssertEqual(results, [.timedOut])
        XCTAssertTrue(system.observers.isEmpty)
    }

    func testCancelledAcceptedRequestWaitsForTargetExitAndNeverRetries() {
        let system = ControlledActivationSystem()
        system.application = ControlledActivationApplication()
        let clock = ActivationTestClock()
        let gate = ActivationHandoffGate(resume: { $0() })
        let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        request.cancel()
        request.cancel()
        var presented = false
        gate.whenSafe { presented = true }
        clock.advance(to: 20)
        XCTAssertEqual(results, [.cancelled])
        XCTAssertFalse(presented)
        XCTAssertEqual(system.application?.activationCount, 1)
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 99))
        XCTAssertFalse(presented)
        system.emit(.terminated(bundleIdentifier: "test.browser", processIdentifier: 42))
        XCTAssertTrue(presented)
        XCTAssertEqual(results, [.cancelled])
    }

    func testNeverDiscoveredTimesOutAndProcessLaunchRemainsGuarded() {
        for mayActivateOnLaunch in [false, true] {
            let system = ControlledActivationSystem()
            let clock = ActivationTestClock()
            let gate = ActivationHandoffGate(resume: { $0() })
            let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
            var results: [ApplicationActivationResult] = []
            _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: mayActivateOnLaunch) { results.append($0) }
            var presented = false
            gate.whenSafe { presented = true }
            clock.advance(to: 1.99)
            XCTAssertTrue(results.isEmpty)
            clock.advance(to: 2)
            XCTAssertEqual(results, [.timedOut])
            XCTAssertEqual(presented, !mayActivateOnLaunch)
            system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
            system.emit(.sourceDeactivated)
            XCTAssertEqual(presented, !mayActivateOnLaunch)
            system.application = ControlledActivationApplication()
            system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
            XCTAssertTrue(presented)
            XCTAssertEqual(results, [.timedOut])
        }
    }

    func testWarmActiveBrowserCompletesWithoutRequestOrRetryWindow() {
        let system = ControlledActivationSystem()
        system.application = ControlledActivationApplication()
        system.application?.isActive = true
        system.isSourceActive = false
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(system: system, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        XCTAssertEqual(results, [.activated])
        XCTAssertEqual(clock.now, 0)
        clock.advance(to: 10)
        XCTAssertEqual(system.application?.activationCount, 0)
        XCTAssertTrue(system.observers.isEmpty)
    }

    func testRefusedActivationCanRetryButAcceptedRequestCannot() {
        let system = ControlledActivationSystem()
        system.application = ControlledActivationApplication()
        system.application?.activationResults = [false, true]
        let clock = ActivationTestClock()
        let activator = NSRunningApplicationActivator(system: system, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        _ = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        clock.advance(to: 0.1)
        XCTAssertEqual(system.application?.activationCount, 2)
        system.emit(.sourceDeactivated)
        system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
        XCTAssertEqual(results, [.activated])
        clock.advance(to: 10)
        XCTAssertEqual(system.application?.activationCount, 2)
    }

    func testCancellationBeforeDiscoveryInvalidatesAlreadyScheduledTicks() {
        let system = ControlledActivationSystem()
        let clock = ActivationTestClock()
        let gate = ActivationHandoffGate(resume: { $0() })
        let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: false) { results.append($0) }
        let staleTicks = clock.scheduled.map(\.action)
        request.cancel()
        system.application = ControlledActivationApplication()
        staleTicks.forEach { $0() } // Simulate dispatch work already dequeued at cancellation.
        XCTAssertEqual(system.application?.activationCount, 0)
        XCTAssertEqual(results, [.cancelled])
        var presented = false
        gate.whenSafe { presented = true }
        XCTAssertTrue(presented)
    }

    func testColdStartWaitsForObservedFocusTransferAndFinishesEarly() {
        let system = ControlledActivationSystem()
        let clock = ActivationTestClock()
        let gate = ActivationHandoffGate(resume: { $0() })
        let activator = NSRunningApplicationActivator(system: system, gate: gate, now: { clock.now }, schedule: clock.schedule)
        var results: [ApplicationActivationResult] = []
        let request = activator.activate(bundleIdentifier: "test.browser", preferredApplication: nil, mayActivateOnLaunch: true) {
            results.append($0)
        }
        var presented = false
        gate.whenSafe { presented = true }
        XCTAssertFalse(presented)
        clock.advance(to: 0.1)
        system.application = ControlledActivationApplication()
        clock.advance(to: 0.35)
        XCTAssertEqual(system.application?.activationCount, 1)
        XCTAssertTrue(results.isEmpty) // activate() returning true is only request acceptance.
        system.emit(.activated(bundleIdentifier: "test.browser", processIdentifier: 42))
        XCTAssertTrue(results.isEmpty) // Eligo's deactivation has not arrived yet.
        system.emit(.sourceDeactivated)
        XCTAssertEqual(results, [.activated])
        XCTAssertTrue(presented)
        request.cancel()
        clock.advance(to: 10)
        XCTAssertEqual(results, [.activated])
        XCTAssertEqual(system.application?.activationCount, 1)
    }
}

@MainActor
final class ControlledActivationApplication: ActivationApplication {
    let processIdentifier: pid_t = 42
    var isActive = false
    var isTerminated = false
    var activationResults = [true]
    var activationCount = 0
    var activationSourceIdentifiers: [pid_t] = []
    var onActivation: (() -> Void)?
    func activate(from application: NSRunningApplication, options: NSApplication.ActivationOptions) -> Bool {
        activationSourceIdentifiers.append(application.processIdentifier)
        onActivation?()
        activationCount += 1
        return activationResults.isEmpty ? false : activationResults.removeFirst()
    }
}

@MainActor
final class ControlledActivationSystem: ApplicationActivationSystem {
    var application: ControlledActivationApplication?
    var isSourceActive = true
    var yieldedProcessIdentifiers: [pid_t] = []
    var observers: [UUID: @MainActor @Sendable (ApplicationActivationEvent) -> Void] = [:]
    func yieldActivation(to application: any ActivationApplication) {
        yieldedProcessIdentifiers.append(application.processIdentifier)
    }
    func findApplication(bundleIdentifier: String, preferredApplication: NSRunningApplication?) -> (any ActivationApplication)? { application }
    func observe(_ action: @escaping @MainActor @Sendable (ApplicationActivationEvent) -> Void) -> () -> Void {
        let id = UUID()
        observers[id] = action
        return { [weak self] in self?.observers[id] = nil }
    }
    func emit(_ event: ApplicationActivationEvent) {
        if case .sourceDeactivated = event { isSourceActive = false }
        Array(observers.values).forEach { $0(event) }
    }
}

@MainActor
final class ActivationTestClock {
    var now: TimeInterval = 0
    struct Scheduled {
        let id: UUID
        let deadline: TimeInterval
        let action: @MainActor () -> Void
    }
    var scheduled: [Scheduled] = []
    var cancelled: Set<UUID> = []
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        scheduled.append(Scheduled(id: id, deadline: now + delay, action: action))
        return { [weak self] in self?.cancelled.insert(id) }
    }
    func advance(to end: TimeInterval) {
        while let next = scheduled.filter({ $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
            scheduled.removeAll { $0.id == next.id }
            now = next.deadline
            if !cancelled.contains(next.id) { next.action() }
        }
        now = end
    }
    func advanceAfterMainThreadBlock(to end: TimeInterval) {
        now = end
        while let next = scheduled.filter({ $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
            scheduled.removeAll { $0.id == next.id }
            if !cancelled.contains(next.id) { next.action() }
        }
    }
}
