import Combine
import Foundation

enum RoutingPreferencesStoreError: Error, Equatable {
    case savedSettingsUnreadable
}

@MainActor
final class RoutingPreferencesStore: ObservableObject {
    static let storageKey = "RoutingPreferences.v2"

    @Published private(set) var settings: RoutingSettings
    @Published private(set) var configurationIssueMessage: String?

    private let userDefaults: UserDefaults
    private var hasUnreadableSavedValue = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        guard let object = userDefaults.object(forKey: Self.storageKey) else {
            settings = .default
            configurationIssueMessage = nil
            return
        }

        do {
            guard let data = object as? Data else {
                throw RoutingPreferencesStoreError.savedSettingsUnreadable
            }
            settings = try JSONDecoder().decode(RoutingSettings.self, from: data)
            configurationIssueMessage = nil
        } catch {
            settings = .default
            configurationIssueMessage = "Saved routing settings could not be read. The original data is preserved. Reset Settings will discard it."
            AppLog.routing.error("Saved routing settings could not be decoded")
            hasUnreadableSavedValue = true
        }
    }

    func replace(with validatedSettings: RoutingSettings) throws {
        // Unreadable saved values are preserved for offline recovery or Reset;
        // settings derived from safe defaults would silently discard them.
        guard !hasUnreadableSavedValue else {
            throw RoutingPreferencesStoreError.savedSettingsUnreadable
        }
        let data = try JSONEncoder().encode(validatedSettings)
        userDefaults.set(data, forKey: Self.storageKey)
        settings = validatedSettings
        configurationIssueMessage = nil
        AppLog.routing.info("Routing settings saved")
    }

    func reset() {
        userDefaults.removeObject(forKey: Self.storageKey)
        settings = .default
        configurationIssueMessage = nil
        hasUnreadableSavedValue = false
        AppLog.routing.info("Routing settings reset")
    }
}
