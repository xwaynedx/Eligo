import SwiftUI

/// Show every extracted host and input issue in a scrollable, fixed-height
/// preview so URL boundary trade-offs stay visible before submission.
struct DomainListParseSummary: View {
    let isInputEmpty: Bool
    let preview: DomainListParseResult
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !isInputEmpty {
                    Text(appLanguageStore.format("%@ valid domains", String(preview.matchers.count)))
                        .foregroundStyle(.secondary)
                    if !preview.duplicateInputs.isEmpty {
                        Text(appLanguageStore.format("Skipped %@ duplicate inputs", String(preview.duplicateInputs.count)))
                            .foregroundStyle(.secondary)
                    }
                    if !preview.invalidInputs.isEmpty {
                        Text(appLanguageStore.format(
                            "Could not recognize: %@",
                            preview.invalidInputs.joined(separator: ", ")
                        ))
                        .foregroundStyle(.red)
                    }
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // One DNS option and exact IP flags make parsed, deduplicated hosts unique.
                        ForEach(preview.matchers, id: \.normalizedHost) { matcher in
                            Text(matcher.normalizedHost)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .frame(height: 112, alignment: .topLeading)
    }
}
