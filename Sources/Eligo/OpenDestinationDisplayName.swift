import SwiftUI

extension OpenDestination {
    /// 提供文本描述，供搜索、辅助功能及不展示图标的位置使用。
    @MainActor
    func displayName(using appLanguageStore: AppLanguageStore) -> String {
        guard mode == .privateBrowsing else { return browser.name }
        let adapter = BrowserDefinition.definition(
            for: browser.bundleIdentifier
        )?.privateLaunchAdapter
        let privateTitle = adapter?.actionTitle(language: appLanguageStore.language)
            ?? appLanguageStore.text("Private")
        return "\(browser.name) \(privateTitle)"
    }
}

struct OpenDestinationPickerOptions<SelectionValue: Hashable>: View {
    let destinations: [OpenDestination]
    @ObservedObject var appLanguageStore: AppLanguageStore
    let tag: (OpenDestinationID) -> SelectionValue

    var body: some View {
        ForEach(destinations.filter { $0.mode == .normal }) { destination in
            Text(destination.browser.name).tag(tag(destination.id))
        }
        let privateDestinations = destinations.filter { $0.mode == .privateBrowsing }
        if !privateDestinations.isEmpty {
            Divider()
            ForEach(privateDestinations) { destination in
                Label(destination.browser.name, systemImage: "eyeglasses")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel(destination.displayName(using: appLanguageStore))
                    .help(destination.displayName(using: appLanguageStore))
                    .tag(tag(destination.id))
            }
        }
    }
}

extension Array where Element == OpenDestination {
    /// Settings rows resolve a saved destination ID to its display name, falling
    /// back to "Unavailable destination" when the destination no longer exists.
    @MainActor
    func displayName(for id: OpenDestinationID, using appLanguageStore: AppLanguageStore) -> String {
        guard let destination = first(where: { $0.id == id }) else {
            return appLanguageStore.text("Unavailable destination")
        }
        return destination.displayName(using: appLanguageStore)
    }
}
