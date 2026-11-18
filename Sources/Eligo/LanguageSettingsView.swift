import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        HStack {
            Text(appLanguageStore.text("Language"))
            Spacer()
            Picker(appLanguageStore.text("Language"), selection: Binding(
                get: { appLanguageStore.language }, set: { appLanguageStore.select($0) }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }
}
