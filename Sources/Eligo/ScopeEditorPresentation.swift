import SwiftUI

/// Window-owned occupancy survives logical end until the matching UI receipt.
@MainActor
final class ScopeEditorPresentation: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let session: ScopeEditorSession
    }
    @Published private(set) var item: Item?
    @Published private(set) var isClosing = false
    var onDismiss: (() -> Void)?

    @discardableResult
    func begin(store: RoutingPreferencesStore, editor: RoutingSettingsEditor, browserRepository: BrowserRepository) -> Item? {
        guard item == nil else { return nil }
        let created = Item(session: ScopeEditorSession(store: store, editor: editor, browserRepository: browserRepository))
        isClosing = false
        item = created
        return created
    }
    func requestClose(id: UUID) {
        guard let item, item.id == id, !isClosing else { return }
        item.session.end()
        isClosing = true
    }
    func didDismiss(id: UUID) {
        guard let item, item.id == id else { return }
        item.session.end()
        self.item = nil
        isClosing = false
        onDismiss?()
    }
    func windowWillClose() {
        item?.session.end()
        item = nil
        isClosing = false
    }
}

/// Each anchor captures its original identity, including late Binding receipts.
struct ScopeEditorPresentationAnchor: View {
    @ObservedObject var presentation: ScopeEditorPresentation
    let item: ScopeEditorPresentation.Item
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { presentation.item?.id == item.id && !presentation.isClosing },
                set: { if !$0 { presentation.requestClose(id: item.id) } }
            ), onDismiss: { presentation.didDismiss(id: item.id) }) {
                ScopeEditorSheet(session: item.session, appLanguageStore: appLanguageStore,
                                 onClose: { presentation.requestClose(id: item.id) })
                    .onDisappear { presentation.requestClose(id: item.id) }
            }
            .onDisappear { presentation.requestClose(id: item.id) }
    }
}
