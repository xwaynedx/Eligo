import Foundation

struct ScopeEditorFeedback: Equatable {
    enum Message: Equatable {
        case pasteResult(added: Int, skippedDuplicates: Int)
        case removedRow(host: String)
        case clearedRows(count: Int)
    }

    let id = UUID()
    let message: Message
    let expiresAt: ContinuousClock.Instant

    init(_ message: Message, now: ContinuousClock.Instant = .now) {
        self.message = message
        expiresAt = now.advanced(by: .seconds(6))
    }

    func shouldExpire(eventID: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        id == eventID && now >= expiresAt
    }

    var canUndo: Bool {
        switch message {
        case .removedRow, .clearedRows: true
        case .pasteResult: false
        }
    }
}

/// Keeps the current feedback and its single Undo snapshot together. No history
/// survives ending the edit or changing Scope mode.
struct ScopeEditorFeedbackState {
    private enum UndoSnapshot {
        case removed(draft: ScopeMatcherDraft, index: Int, wasTouched: Bool)
        case cleared(drafts: [ScopeMatcherDraft], touchedRowIDs: Set<ScopeMatcherDraft.ID>)
    }

    private(set) var feedback: ScopeEditorFeedback?
    private var undoSnapshot: UndoSnapshot?

    mutating func removeRow(
        id: ScopeMatcherDraft.ID,
        from drafts: inout [ScopeMatcherDraft],
        touchedRowIDs: inout Set<ScopeMatcherDraft.ID>,
        now: ContinuousClock.Instant = .now
    ) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let removed = drafts.remove(at: index)
        undoSnapshot = .removed(draft: removed, index: index, wasTouched: touchedRowIDs.contains(id))
        touchedRowIDs.remove(id)
        feedback = ScopeEditorFeedback(.removedRow(host: removed.host), now: now)
    }

    mutating func clearRows(
        drafts: inout [ScopeMatcherDraft],
        touchedRowIDs: inout Set<ScopeMatcherDraft.ID>,
        now: ContinuousClock.Instant = .now
    ) {
        undoSnapshot = .cleared(drafts: drafts, touchedRowIDs: touchedRowIDs)
        feedback = ScopeEditorFeedback(.clearedRows(count: drafts.count), now: now)
        drafts.removeAll()
        touchedRowIDs.removeAll()
    }

    mutating func undo(drafts: inout [ScopeMatcherDraft], touchedRowIDs: inout Set<ScopeMatcherDraft.ID>) {
        guard let undoSnapshot else { return }
        switch undoSnapshot {
        case let .removed(draft, index, wasTouched):
            drafts.insert(draft, at: min(index, drafts.count))
            if wasTouched { touchedRowIDs.insert(draft.id) }
        case let .cleared(snapshot, touched):
            drafts = snapshot
            touchedRowIDs = touched
        }
        reset()
    }

    mutating func willAddRow() {
        // Adding new input after Clear All must not let Undo replace that input.
        // A single-row deletion may still be undone alongside a new row.
        if case .cleared = undoSnapshot { reset() }
    }

    mutating func showPasteResult(
        added: Int, skippedDuplicates: Int, now: ContinuousClock.Instant = .now
    ) {
        undoSnapshot = nil
        feedback = ScopeEditorFeedback(.pasteResult(added: added, skippedDuplicates: skippedDuplicates), now: now)
    }

    mutating func expire(eventID: UUID, now: ContinuousClock.Instant = .now) {
        guard feedback?.shouldExpire(eventID: eventID, now: now) == true else { return }
        reset()
    }

    mutating func reset() {
        feedback = nil
        undoSnapshot = nil
    }
}
