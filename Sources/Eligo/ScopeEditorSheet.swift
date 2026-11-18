import SwiftUI

struct ScopeEditorSheet: View, AppLocalizing {
    @ObservedObject var session: ScopeEditorSession
    @ObservedObject var appLanguageStore: AppLanguageStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Routing Scope")).font(.title3.weight(.semibold))
            Picker(t("Links managed by Eligo"), selection: Binding(
                get: { session.mode }, set: { session.setMode($0) }
            )) {
                ForEach(ScopeEditorKind.allCases) { kind in
                    Text(t(kind.title)).tag(kind)
                }
            }
            if session.mode != .allDomains {
                ScopeDomainEditor(session: session, appLanguageStore: appLanguageStore)
                Picker(t("Bypass Destination"), selection: Binding(
                    get: { session.bypassDestinationID }, set: { session.selectBypassDestination($0) }
                )) {
                    Text(t("Choose a destination")).tag(Optional<OpenDestinationID>.none)
                    ForEach(session.normalDestinations) { destination in
                        Text(destination.displayName(using: appLanguageStore)).tag(Optional(destination.id))
                    }
                }
                Text(t("Bypassed links open directly in this normal browser destination."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            saveIssueSlot
            SheetActionFooter(
                isSaveDisabled: !session.canSave,
                onSave: { if session.save() { onClose() } },
                onCancel: onClose,
                assignsDefaultAction: false,
                appLanguageStore: appLanguageStore
            )
        }
        .padding(24)
        .frame(width: 600)
    }

    private var saveIssueSlot: some View {
        let message = session.displayedIssue?.text(using: appLanguageStore)
        return Text(message ?? " ")
            .foregroundStyle(.red).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(message == nil ? 0 : 1)
    }
}
