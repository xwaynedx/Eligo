import SwiftUI

struct ScopeDomainEditor: View {
    @ObservedObject var session: ScopeEditorSession
    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var isConfirmingClearDomains = false
    @FocusState private var focusedRowID: ScopeMatcherDraft.ID?

    private var scopeKind: ScopeEditorKind { session.mode }
    private var matchers: [ScopeMatcherDraft] { session.validation.drafts }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appLanguageStore.text(
                scopeKind == .onlyThese
                    ? "Only matching domains show Eligo rules and the chooser."
                    : "Matching domains bypass Eligo rules and the chooser."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(appLanguageStore.text("Domains"))
                        .font(.headline)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button(appLanguageStore.text("Add Domain"), action: addEmptyDomain)
                        .controlSize(.small)
                    Button(appLanguageStore.text("Paste Domains…")) {
                        _ = session.beginPaste()
                    }
                    .controlSize(.small)
                    if scopeKind == .onlyThese, !session.ruleMatchers.isEmpty {
                        Button(appLanguageStore.text("Add All Rule Domains"), action: session.addAllRuleDomains)
                            .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(appLanguageStore.text("Added Domains"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(
                            appLanguageStore.text("Clear All Domains"),
                            role: .destructive,
                            action: confirmClearDomains
                        )
                        .controlSize(.small)
                        .disabled(matchers.isEmpty)
                    }

                    ScrollView {
                        if matchers.isEmpty {
                            Text(appLanguageStore.text("No domains added yet."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 12)
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(matchers) { matcher in
                                    ScopeMatcherRow(
                                        rowID: matcher.id,
                                        onRemove: { session.removeDomain(rowID: matcher.id) },
                                        onFinish: { session.finishRowEditing(rowID: matcher.id) },
                                        issue: displayedIssue(for: matcher),
                                        supportsSubdomains: session.validation.supportsSubdomains(for: matcher.id),
                                        host: Binding(get: { session.validation.drafts.first { $0.id == matcher.id }?.host ?? "" },
                                                      set: { session.editHost(rowID: matcher.id, text: $0) }),
                                        includesSubdomains: Binding(get: { session.validation.drafts.first { $0.id == matcher.id }?.includesSubdomains ?? false },
                                                                    set: { session.setIncludesSubdomains(rowID: matcher.id, enabled: $0) }),
                                        focusedRowID: $focusedRowID,
                                        appLanguageStore: appLanguageStore
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(height: 180)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                ScopeFeedbackBanner(
                    feedback: session.feedback,
                    onUndo: session.undo,
                    appLanguageStore: appLanguageStore
                )
            }
        }
        .onChange(of: focusedRowID) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                session.finishRowEditing(rowID: oldValue)
            }
        }
        .confirmationDialog(
            appLanguageStore.text("Clear all routing scope domains?"),
            isPresented: $isConfirmingClearDomains,
            titleVisibility: .visible
        ) {
            Button(appLanguageStore.text("Clear All Domains"), role: .destructive, action: session.clearDomains)
        } message: {
            Text(appLanguageStore.format(
                "This will remove all %@ domains from the routing scope.",
                String(matchers.count)
            ))
        }
        .background {
            if let paste = session.pasteDraft {
                ScopePastePresentationAnchor(session: session, pasteID: paste.id, appLanguageStore: appLanguageStore)
                    .id(paste.id)
            }
        }
    }

    private func displayedIssue(for matcher: ScopeMatcherDraft) -> ScopeMatcherDraftIssue? {
        guard session.touchedRowIDs.contains(matcher.id) else { return nil }
        return session.validation.issue(for: matcher.id)
    }

    private func addEmptyDomain() { focusedRowID = session.addDomain() }
    private func confirmClearDomains() { isConfirmingClearDomains = true }
}

private struct ScopePastePresentationAnchor: View {
    @ObservedObject var session: ScopeEditorSession
    let pasteID: UUID
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { session.isActive && session.pasteDraft?.id == pasteID },
                set: { if !$0 { session.cancelPaste(pasteID: pasteID) } }
            )) {
                ScopeBulkPasteSheet(session: session, pasteID: pasteID, appLanguageStore: appLanguageStore)
                    .onDisappear { session.cancelPaste(pasteID: pasteID) }
            }
            .onDisappear { session.cancelPaste(pasteID: pasteID) }
    }
}

/// Reserved-height banner: the slot keeps its size even with no feedback, so
/// transient messages never push the surrounding layout around.
private struct ScopeFeedbackBanner: View {
    let feedback: ScopeEditorFeedback?
    let onUndo: (UUID) -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        HStack(spacing: 8) {
            if let feedback {
                Text(text(for: feedback))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if feedback.canUndo {
                    Button(appLanguageStore.text("Undo")) { onUndo(feedback.id) }
                        .controlSize(.small)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(feedback == nil ? 0 : 0.16))
        )
    }

    private func text(for feedback: ScopeEditorFeedback) -> String {
        switch feedback.message {
        case let .pasteResult(added, skippedDuplicates):
            if skippedDuplicates > 0 {
                return appLanguageStore.format(
                    "Added %@ domains, skipped %@ duplicates",
                    String(added), String(skippedDuplicates)
                )
            }
            return appLanguageStore.format("Added %@ domains", String(added))
        case let .removedRow(host):
            return appLanguageStore.format("Removed %@", host)
        case let .clearedRows(count):
            return appLanguageStore.format("Cleared %@ domains", String(count))
        }
    }
}

private struct ScopeMatcherRow: View {
    let rowID: UUID
    let onRemove: () -> Void
    let onFinish: () -> Void
    let issue: ScopeMatcherDraftIssue?
    let supportsSubdomains: Bool
    @Binding var host: String
    @Binding var includesSubdomains: Bool
    var focusedRowID: FocusState<ScopeMatcherDraft.ID?>.Binding
    @ObservedObject var appLanguageStore: AppLanguageStore

    private var isRowFocused: Bool {
        focusedRowID.wrappedValue == rowID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                TextField("example.com", text: $host)
                    .textFieldStyle(.plain)
                    .focused(focusedRowID, equals: rowID)
                    .onSubmit { onFinish(); focusedRowID.wrappedValue = nil }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(borderColor, lineWidth: isRowFocused ? 1.5 : 1)
                    )
                    .layoutPriority(1)
                    .accessibilityLabel(appLanguageStore.text("Host"))

                Toggle(
                    appLanguageStore.text("Include subdomains"),
                    isOn: $includesSubdomains
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!supportsSubdomains)

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help(appLanguageStore.text("Remove Domain"))
                .accessibilityLabel(appLanguageStore.text("Remove Domain"))
            }

            if let issue {
                Text(appLanguageStore.text(issue.message))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.opacity(0.72))
        .contentShape(Rectangle())
    }

    private var borderColor: Color {
        if issue != nil { return .red }
        return isRowFocused ? .accentColor : .secondary.opacity(0.22)
    }
}
