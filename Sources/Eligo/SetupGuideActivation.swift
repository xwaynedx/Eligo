import Foundation

/// Activation means links can actually reach Eligo: it is the default
/// browser and at least one Installed Browser is usable. Launch at Login is an
/// optional convenience and deliberately not part of activation.
enum SetupGuideActivation {
    static func isComplete(isDefaultBrowser: Bool, hasUsableBrowsers: Bool) -> Bool {
        isDefaultBrowser && hasUsableBrowsers
    }

    /// The Welcome Guide auto-opens for setup exactly once per install, and
    /// only while activation is incomplete. Users who postpone are reminded
    /// passively through the menu bar instead of repeated windows.
    static func shouldAutoShow(hasAutoShownSetup: Bool, isDefaultBrowser: Bool, hasUsableBrowsers: Bool) -> Bool {
        !hasAutoShownSetup && !isComplete(isDefaultBrowser: isDefaultBrowser, hasUsableBrowsers: hasUsableBrowsers)
    }
}
