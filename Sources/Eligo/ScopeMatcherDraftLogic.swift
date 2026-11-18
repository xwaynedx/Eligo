import Foundation

struct ScopeMatcherDraft: Identifiable, Equatable {
    let id: UUID
    var host: String {
        didSet {
            if host != oldValue {
                includesSubdomains = DomainListParser.includesSubdomains(afterEditing: host, currentValue: includesSubdomains)
            }
        }
    }
    var includesSubdomains: Bool

    init(id: UUID = UUID(), host: String = "", includesSubdomains: Bool = true) {
        self.id = id
        self.host = host
        self.includesSubdomains = includesSubdomains
    }

    init(_ matcher: DomainMatcher) {
        self.init(host: matcher.normalizedHost, includesSubdomains: matcher.includesSubdomains)
    }
}

enum ScopeMatcherDraftIssue: Equatable {
    case invalidHost
    case ipAddressesCannotIncludeSubdomains
    case duplicate

    var message: String {
        switch self {
        case .invalidHost: "Enter a valid host or an absolute HTTP/HTTPS URL."
        case .ipAddressesCannotIncludeSubdomains:
            "IP addresses cannot include subdomains. Turn off Include subdomains."
        case .duplicate: "Duplicate domain"
        }
    }
}

struct ScopeMatcherDraftAppendResult: Equatable {
    var drafts: [ScopeMatcherDraft]
    var addedCount: Int
    var skippedDuplicateCount: Int
}

struct ScopeMatcherDraftValidation: Equatable {
    let drafts: [ScopeMatcherDraft]
    private let issuesByDraftID: [ScopeMatcherDraft.ID: ScopeMatcherDraftIssue]
    private let matchers: [DomainMatcher]
    private let ipAddressDraftIDs: Set<ScopeMatcherDraft.ID>

    let invalidDraftIDs: Set<ScopeMatcherDraft.ID>

    func issue(for draftID: ScopeMatcherDraft.ID) -> ScopeMatcherDraftIssue? {
        issuesByDraftID[draftID]
    }

    func supportsSubdomains(for draftID: ScopeMatcherDraft.ID) -> Bool {
        !ipAddressDraftIDs.contains(draftID)
    }

    /// Returns the normalized matchers only when this snapshot belongs to the
    /// current draft value and every non-empty row is valid and unique.
    func validatedMatchers(for currentDrafts: [ScopeMatcherDraft]) -> [DomainMatcher]? {
        guard currentDrafts == drafts, invalidDraftIDs.isEmpty else { return nil }
        return matchers
    }

    /// Merge against this snapshot's parsed rows, including when other rows are
    /// invalid. Existing drafts and their identities remain untouched.
    func appending(_ additions: [DomainMatcher]) -> ScopeMatcherDraftAppendResult {
        let merged = DomainConfigurationBatch().mergeMatchers(additions, into: matchers)
        let addedCount = merged.count - matchers.count
        let appendedDrafts = merged.dropFirst(matchers.count).map(ScopeMatcherDraft.init)
        return ScopeMatcherDraftAppendResult(
            drafts: drafts + appendedDrafts,
            addedCount: addedCount,
            skippedDuplicateCount: additions.count - addedCount
        )
    }

    fileprivate init(
        drafts: [ScopeMatcherDraft],
        issuesByDraftID: [ScopeMatcherDraft.ID: ScopeMatcherDraftIssue],
        matchers: [DomainMatcher],
        ipAddressDraftIDs: Set<ScopeMatcherDraft.ID>
    ) {
        self.drafts = drafts
        self.issuesByDraftID = issuesByDraftID
        self.matchers = matchers
        self.ipAddressDraftIDs = ipAddressDraftIDs
        invalidDraftIDs = Set(issuesByDraftID.keys)
    }
}

enum ScopeMatcherDraftLogic {
    /// Normalizes a single-row input the same way bulk paste does: extracts the
    /// host from an absolute HTTP/HTTPS URL, then applies DomainMatcher
    /// normalization (trimming, lowercasing, trailing-dot handling).
    /// Returns nil when the input cannot become a valid host.
    static func normalizedHostInput(_ input: String) -> String? {
        DomainListParser.normalizedHost(from: input)
    }

    /// A draft is actionable when its host is non-empty. Empty rows are treated
    /// as pending input: they never block saving and are dropped on save.
    static func matcher(for draft: ScopeMatcherDraft) throws -> DomainMatcher? {
        let trimmed = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let host = DomainListParser.host(from: trimmed) else {
            throw DomainMatcherValidationError.invalidHost
        }
        return try DomainMatcher(host: host, includesSubdomains: draft.includesSubdomains)
    }

    /// Validates one complete draft value in a single pass. Each non-empty row
    /// is parsed once, while a hash table identifies every canonical duplicate.
    static func validation(
        for drafts: [ScopeMatcherDraft],
        resolvingMatcher: (ScopeMatcherDraft) throws -> DomainMatcher? = matcher(for:)
    ) -> ScopeMatcherDraftValidation {
        var issuesByDraftID: [ScopeMatcherDraft.ID: ScopeMatcherDraftIssue] = [:]
        var firstDraftIDByMatcher: [DomainMatcher: ScopeMatcherDraft.ID] = [:]
        var matchers: [DomainMatcher] = []
        var ipAddressDraftIDs = Set<ScopeMatcherDraft.ID>()
        matchers.reserveCapacity(drafts.count)

        for draft in drafts {
            let trimmed = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let matcher: DomainMatcher
            do {
                guard let resolved = try resolvingMatcher(draft) else {
                    issuesByDraftID[draft.id] = .invalidHost
                    continue
                }
                matcher = resolved
            } catch DomainMatcherValidationError.ipAddressesCannotIncludeSubdomains {
                // Keep the control available so a residual invalid draft can
                // still be repaired by unchecking it.
                issuesByDraftID[draft.id] = .ipAddressesCannotIncludeSubdomains
                continue
            } catch {
                issuesByDraftID[draft.id] = .invalidHost
                continue
            }

            matchers.append(matcher)
            if matcher.isIPAddress { ipAddressDraftIDs.insert(draft.id) }
            if let firstDraftID = firstDraftIDByMatcher[matcher] {
                issuesByDraftID[firstDraftID] = .duplicate
                issuesByDraftID[draft.id] = .duplicate
            } else {
                firstDraftIDByMatcher[matcher] = draft.id
            }
        }

        return ScopeMatcherDraftValidation(
            drafts: drafts,
            issuesByDraftID: issuesByDraftID,
            matchers: matchers,
            ipAddressDraftIDs: ipAddressDraftIDs
        )
    }
}
