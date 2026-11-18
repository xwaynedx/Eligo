import SwiftUI

/// Shared Cancel/Save footer for the settings sheets.
struct SheetActionFooter: View {
    let isSaveDisabled: Bool
    let onSave: () -> Void
    var saveTitle = "Save"
    var onCancel: (() -> Void)? = nil
    /// Whether Save is bound to Return. Input-heavy sheets should pass false so
    /// Return commits the focused text field instead of closing the sheet.
    var assignsDefaultAction = true
    @ObservedObject var appLanguageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button(appLanguageStore.text("Cancel")) {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button(appLanguageStore.text(saveTitle), action: onSave)
                .disabled(isSaveDisabled)
                .keyboardShortcut(assignsDefaultAction ? .defaultAction : nil)
        }
    }
}
