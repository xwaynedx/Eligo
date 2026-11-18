import AppKit

@MainActor
protocol ApplicationActivationPolicyControlling: AnyObject {
    func activationPolicy() -> NSApplication.ActivationPolicy
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

extension NSApplication: ApplicationActivationPolicyControlling {}

@MainActor
final class ApplicationPresentationController {
    private let application: ApplicationActivationPolicyControlling

    init(application: ApplicationActivationPolicyControlling = NSApplication.shared) {
        self.application = application
    }

    func enterBackgroundMode() {
        transition(to: .accessory)
    }

    func settingsWillShow() {
        transition(to: .regular)
        application.activate()
    }

    func settingsDidClose() {
        transition(to: .accessory)
    }

    private func transition(to policy: NSApplication.ActivationPolicy) {
        guard application.activationPolicy() != policy else { return }

        guard application.setActivationPolicy(policy) else {
            AppLog.app.error("Failed to change application activation policy to \(String(describing: policy), privacy: .public)")
            return
        }

        AppLog.app.info("Changed application activation policy to \(String(describing: policy), privacy: .public)")
    }
}
