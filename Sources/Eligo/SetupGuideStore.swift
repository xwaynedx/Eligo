import Foundation

/// Records whether the setup guide was already auto-presented once, so the
/// Welcome Guide never auto-opens for setup more than once per install.
final class SetupGuideStore {
    static let hasAutoShownSetupKey = "SetupGuide.hasAutoShownSetup.v1"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var hasAutoShownSetup: Bool {
        userDefaults.bool(forKey: Self.hasAutoShownSetupKey)
    }

    func markSetupAutoShown() {
        userDefaults.set(true, forKey: Self.hasAutoShownSetupKey)
    }
}
