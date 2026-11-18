import SwiftUI

/// Session feedback belongs to Installed Browser, so a failed Recent write is
/// still visible when Settings is opened later. Localization happens in views.
enum BrowserOperationFeedback: Equatable {
    case added(String)
    case removed(String)
    case invalidApplication
    case doesNotHandleWebURLs
    case currentApplicationNotAllowed
    case mutationRejected(BrowserMutationResult)
    case storageFailure(BrowserPreferencesError)
    case recentSaveFailed(BrowserPreferencesError)
    case settingsReset

    @MainActor
    func text(using store: AppLanguageStore) -> String {
        switch self {
        case let .added(name): store.format("Added %@.", name)
        case let .removed(name): store.format("Removed %@ from Eligo.", name)
        case .invalidApplication:
            store.text("That app could not be added. Choose a valid .app bundle with an executable.")
        case .doesNotHandleWebURLs:
            store.text("That app does not declare support for HTTP or HTTPS links.")
        case .currentApplicationNotAllowed:
            store.text("Eligo cannot be added as a browser destination.")
        case let .mutationRejected(result): result.message(using: store)
        case let .storageFailure(error): error.message(using: store)
        case .recentSaveFailed(.unreadableConfiguration):
            // The persistent repair banner already explains the configuration failure.
            store.text("The link opened, but Recent Browser could not be saved.")
        case let .recentSaveFailed(error):
            store.text("The link opened, but Recent Browser could not be saved.") + " " + error.message(using: store)
        case .settingsReset: store.text("Eligo settings were reset.")
        }
    }
}

extension BrowserPreferencesError {
    @MainActor
    func message(using store: AppLanguageStore) -> String {
        switch self {
        case .unreadableConfiguration:
            store.text("Saved browser settings could not be read. Reset Settings to repair them.")
        case .encodingFailed:
            store.text("Browser settings could not be saved. Your previous settings are unchanged. Try again.")
        }
    }
}

extension BrowserMutationResult {
    @MainActor
    func message(using store: AppLanguageStore) -> String {
        switch self {
        case .notFound: store.text("That browser is no longer available. Open Settings to rescan and try again.")
        case .wouldLeaveNoEnabledBrowser: store.text("At least one browser must stay enabled.")
        case let .storageFailure(error): error.message(using: store)
        case .superseded: store.text("Browser scan was superseded by a settings change. Try again.")
        case .applied, .unchanged: ""
        }
    }
}

struct BrowserOperationFeedbackView: View {
    @ObservedObject var repository: BrowserRepository
    @ObservedObject var appLanguageStore: AppLanguageStore
    let onReset: () -> Void

    var message: String? {
        guard let feedback = repository.operationFeedback,
              feedback != .storageFailure(.unreadableConfiguration) else { return nil }
        return feedback.text(using: appLanguageStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if repository.availability == .configurationUnreadable {
                Text(BrowserPreferencesError.unreadableConfiguration.message(using: appLanguageStore))
                    .foregroundStyle(.orange)
                Button(appLanguageStore.text("Reset"), action: onReset)
            }
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
