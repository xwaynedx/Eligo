import Foundation

/// Pure state machine for the first-run Welcome Guide window.
///
/// Mirrors the `ChooserSelection` idiom: an AppKit-free, `Equatable`, `Sendable`
/// value type that owns step navigation, button availability and the
/// activation → completion auto-advance trigger. The SwiftUI view stays thin:
/// it feeds activation status in and reacts to the returned cues.
struct WelcomeGuideModel: Equatable, Sendable {
    enum Step: Int, CaseIterable, Equatable, Sendable {
        case language
        case welcome
        case howItWorks
        case rulesAndScope
        case activation
        case complete
    }

    /// What the activation step presents.
    enum ActivationPresentation: Equatable, Sendable {
        /// Activation incomplete: offer the real action plus a way to continue
        /// anyway. The guide never forces activation.
        case pending
        /// Activation complete: static success state, manual advance.
        case succeeded
    }

    private(set) var step: Step
    private(set) var activationComplete: Bool
    /// Ensures the activation → complete auto-advance fires at most once per
    /// guide session.
    private var didConsumeActivationTransition: Bool

    init(activationComplete: Bool) {
        step = .language
        self.activationComplete = activationComplete
        didConsumeActivationTransition = false
    }

    var canGoBack: Bool { step != .language }
    var canGoForward: Bool { step != .complete }

    /// Skip is always available so the guide never traps the user.
    var canSkip: Bool { true }

    var activationPresentation: ActivationPresentation {
        activationComplete ? .succeeded : .pending
    }

    mutating func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    mutating func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Records the latest activation status. Returns `true` exactly once — when
    /// the user is on the activation step and the status flips from incomplete
    /// to complete — which is the view's cue to show the success state and then
    /// auto-advance after a beat.
    ///
    /// A user who reaches the step already activated (e.g. re-opened the guide
    /// from the menu bar) sees a static success state and advances manually, so
    /// re-opened guides never flash past the step.
    mutating func noteActivationComplete(_ isComplete: Bool) -> Bool {
        let flipped = isComplete && !activationComplete
        activationComplete = isComplete
        guard flipped, step == .activation, !didConsumeActivationTransition else { return false }
        didConsumeActivationTransition = true
        return true
    }
}
