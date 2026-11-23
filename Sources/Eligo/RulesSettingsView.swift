import SwiftUI

extension RoutingScopeCoverage {
    var badge: (title: String, explanation: String)? {
        switch self {
        case .full: nil
        case .partial:
            ("Partially active", "Only some matching hosts are within Routing Scope. More specific rules and Always Show Chooser still apply.")
        case .none:
            ("Inactive", "Matching hosts are outside Routing Scope. This rule is kept for future scope changes.")
        }
    }
}

enum RulesSettingsAction: Equatable, Sendable {
    case addRule
    case addRulesInBulk
    case requestDeleteSelectedRules
    case requestClearAllRules
    case setRuleSelection(ruleID: DomainRule.ID, isSelected: Bool)
    case addRuleMatcherToRoutingScope(ruleID: DomainRule.ID)
    case editRule(ruleID: DomainRule.ID)
    case setRuleDestination(ruleID: DomainRule.ID, destinationID: OpenDestinationID)
    case requestDeleteRule(ruleID: DomainRule.ID)
}

struct RulesSettingsView: View, AppLocalizing {
    let rules: [DomainRule]
    let scope: RoutingScope
    let destinationContext: RuleDestinationContext
    let selectedRuleIDs: Set<DomainRule.ID>
    let message: String?
    let onAction: (RulesSettingsAction) -> Void
    let onEditRoutingScope: () -> Void
    var appLanguageStore: AppLanguageStore { destinationContext.appLanguageStore }
    @State private var searchText = ""
    @State private var browserFilter: Browser.ID?

    static func filteredRules(
        _ rules: [DomainRule], query: String, browserID: Browser.ID?,
        context: RuleDestinationContext
    ) -> [DomainRule] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.filter { rule in
            (browserID == nil || rule.destinationID.browserID == browserID)
                && (query.isEmpty || rule.matcher.normalizedHost.localizedStandardContains(query)
                    || context.displayName(rule.destinationID)
                        .localizedStandardContains(query))
        }
    }

    private var visibleRules: [DomainRule] {
        Self.filteredRules(rules, query: searchText, browserID: browserFilter,
                           context: destinationContext)
    }

    private var filterBrowserIDs: [Browser.ID] {
        Set(rules.map { $0.destinationID.browserID } + destinationContext.destinations.map { $0.browser.id })
            .sorted { destinationContext.browserName($0).localizedStandardCompare(destinationContext.browserName($1)) == .orderedAscending }
    }

    private var isOnlyTheseScope: Bool {
        if case .onlyThese = scope {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("Rules"))
                    .font(.headline)
                Text(t("Matching links within Routing Scope follow the most specific rule. Always Show Chooser pauses direct opening."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(t("Search domains or browsers"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(t("Clear search"))
                    }
                }
                .padding(7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Picker(t("Target browser"), selection: $browserFilter) {
                    Text(t("All browsers")).tag(Optional<Browser.ID>.none)
                    ForEach(filterBrowserIDs, id: \.self) { id in
                        Text(destinationContext.browserName(id)).tag(Optional(id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            HStack(spacing: 8) {
                Text(appLanguageStore.format("%@ of %@ rules · %@ selected",
                    String(visibleRules.count), String(rules.count), String(selectedRuleIDs.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("Add Rule…")) { onAction(.addRule) }
                Button(t("Add Rules in Bulk…")) { onAction(.addRulesInBulk) }
                Button(t("Delete Selected Rules"), role: .destructive) {
                    onAction(.requestDeleteSelectedRules)
                }
                    .disabled(selectedRuleIDs.isEmpty)
                if !rules.isEmpty {
                    Button(t("Clear All Rules"), role: .destructive) {
                        onAction(.requestClearAllRules)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if rules.isEmpty {
                ContentUnavailableView(
                    t("No Domain Rules"),
                    systemImage: "slider.horizontal.3",
                    description: Text(t("Add a rule to always open a website in a browser."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRules.isEmpty {
                ContentUnavailableView(t("No matching rules"), systemImage: "magnifyingglass",
                    description: Text(t("Try another search or browser filter.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleRules) { rule in
                        let coverage = scope.coverage(of: rule.matcher)
                        RuleRowView(
                            rule: rule,
                            destinations: destinationContext.destinations,
                            unavailableDestinationTitle: destinationContext.unavailableDestinationTitle(rule.destinationID),
                            coverage: coverage,
                            canAddToScope: isOnlyTheseScope && coverage != .full,
                            isSelected: selectedRuleIDs.contains(rule.id),
                            onSelectionChange: {
                                onAction(.setRuleSelection(ruleID: rule.id, isSelected: $0))
                            },
                            onAddToScope: {
                                onAction(.addRuleMatcherToRoutingScope(ruleID: rule.id))
                            },
                            onEditScope: onEditRoutingScope,
                            onEdit: { onAction(.editRule(ruleID: rule.id)) },
                            onDestinationChange: { onAction(.setRuleDestination(ruleID: rule.id, destinationID: $0)) },
                            onDelete: { onAction(.requestDeleteRule(ruleID: rule.id)) },
                            appLanguageStore: appLanguageStore
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: filterBrowserIDs) { _, ids in
            if let browserFilter, !ids.contains(browserFilter) { self.browserFilter = nil }
        }
    }

}

private struct RuleRowView: View {
    let rule: DomainRule
    let destinations: [OpenDestination]
    let unavailableDestinationTitle: String
    let coverage: RoutingScopeCoverage
    let canAddToScope: Bool
    let isSelected: Bool
    let onSelectionChange: (Bool) -> Void
    let onAddToScope: () -> Void
    let onEditScope: () -> Void
    let onEdit: () -> Void
    let onDestinationChange: (OpenDestinationID) -> Void
    let onDelete: () -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { onSelectionChange($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .accessibilityLabel(
                appLanguageStore.format("Select rule %@", rule.matcher.normalizedHost)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.matcher.normalizedHost)
                        .fontWeight(.medium)
                    if rule.matcher.includesSubdomains {
                        Text(appLanguageStore.text("and subdomains"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let badge = coverage.badge {
                        Text(appLanguageStore.text(badge.title))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help(appLanguageStore.text(badge.explanation))
                    }
                }
                if canAddToScope {
                    Button(appLanguageStore.text("Add Domain to Routing Scope"), action: onAddToScope)
                        .controlSize(.small)
                } else if coverage != .full {
                    Button(appLanguageStore.text("Edit Routing Scope…"), action: onEditScope)
                        .controlSize(.small)
                }
            }

            Spacer()

            Picker(appLanguageStore.text("Open Destination"), selection: Binding(
                get: { rule.destinationID }, set: { onDestinationChange($0) }
            )) {
                if !destinations.contains(where: { $0.id == rule.destinationID }) {
                    Text(unavailableDestinationTitle).tag(rule.destinationID)
                }
                OpenDestinationPickerOptions(
                    destinations: destinations,
                    appLanguageStore: appLanguageStore,
                    tag: { $0 }
                )
            }
            .labelsHidden()
            .frame(width: 180)
            .accessibilityLabel(appLanguageStore.format("Destination for %@", rule.matcher.normalizedHost))
            Button(appLanguageStore.text("Edit"), action: onEdit)
                .controlSize(.small)
            Button(appLanguageStore.text("Delete"), role: .destructive, action: onDelete)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
