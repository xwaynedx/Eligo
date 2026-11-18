import XCTest
@testable import Eligo

final class ScopeEditorUndoTests: XCTestCase {
    func testExpiryClearsBothTheButtonAndSnapshotAfterASecondDifferentHostRemoval() throws {
        let start = ContinuousClock.now
        let first = ScopeMatcherDraft(host: "first.example")
        let second = ScopeMatcherDraft(host: "second.example", includesSubdomains: false)
        var drafts = [first, second]
        var touched: Set<ScopeMatcherDraft.ID> = [second.id]
        var state = ScopeEditorFeedbackState()
        state.removeRow(id: first.id, from: &drafts, touchedRowIDs: &touched, now: start)
        let oldID = try XCTUnwrap(state.feedback?.id)
        state.removeRow(id: second.id, from: &drafts, touchedRowIDs: &touched, now: start.advanced(by: .seconds(5)))
        let current = try XCTUnwrap(state.feedback)
        XCTAssertTrue(current.canUndo)
        state.expire(eventID: oldID, now: start.advanced(by: .seconds(6)))
        XCTAssertEqual(state.feedback, current)
        state.expire(eventID: current.id, now: start.advanced(by: .seconds(11)))
        XCTAssertNil(state.feedback)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertTrue(touched.isEmpty)
    }

    func testUndoThenNewRemovalAndClosingOrChangingModeInvalidatesOldExpiry() throws {
        let start = ContinuousClock.now
        let row = ScopeMatcherDraft(host: "example.com")
        var drafts = [row]
        var touched: Set<ScopeMatcherDraft.ID> = [row.id]
        var state = ScopeEditorFeedbackState()
        state.removeRow(id: row.id, from: &drafts, touchedRowIDs: &touched, now: start)
        let oldID = try XCTUnwrap(state.feedback?.id)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        state.removeRow(id: row.id, from: &drafts, touchedRowIDs: &touched, now: start.advanced(by: .seconds(5)))
        let secondEvent = try XCTUnwrap(state.feedback)
        state.expire(eventID: oldID, now: start.advanced(by: .seconds(6)))
        XCTAssertEqual(state.feedback, secondEvent)

        // This is the same reset invoked on Scope mode changes and disappear.
        state.reset()
        XCTAssertNil(state.feedback)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertTrue(drafts.isEmpty)
        drafts = [row]
        state.removeRow(id: row.id, from: &drafts, touchedRowIDs: &touched, now: start.advanced(by: .seconds(10)))
        let reopened = try XCTUnwrap(state.feedback)
        state.expire(eventID: secondEvent.id, now: start.advanced(by: .seconds(11)))
        XCTAssertEqual(state.feedback, reopened)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertEqual(drafts, [row])
    }

    func testReplacingRemovalWithRepeatedPasteFeedbackDiscardsUndoAndRestartsExpiry() throws {
        let start = ContinuousClock.now
        let row = ScopeMatcherDraft(host: "example.com")
        var drafts = [row]
        var touched = Set<ScopeMatcherDraft.ID>()
        var state = ScopeEditorFeedbackState()
        state.removeRow(id: row.id, from: &drafts, touchedRowIDs: &touched, now: start)
        let removalID = try XCTUnwrap(state.feedback?.id)
        state.showPasteResult(added: 2, skippedDuplicates: 0, now: start.advanced(by: .seconds(1)))
        let firstPaste = try XCTUnwrap(state.feedback)
        state.showPasteResult(added: 2, skippedDuplicates: 0, now: start.advanced(by: .seconds(5)))
        let secondPaste = try XCTUnwrap(state.feedback)
        XCTAssertEqual(firstPaste.message, secondPaste.message)
        XCTAssertNotEqual(firstPaste.id, secondPaste.id)
        XCTAssertFalse(secondPaste.canUndo)
        for staleID in [removalID, firstPaste.id] {
            state.expire(eventID: staleID, now: start.advanced(by: .seconds(7)))
            XCTAssertEqual(state.feedback, secondPaste)
        }
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertTrue(drafts.isEmpty)
    }

    func testClearUndoRestoresExactDraftsAndTouchedStateButCannotReplaceNewInput() {
        let invalid = ScopeMatcherDraft(host: "foo/bar")
        let valid = ScopeMatcherDraft(host: "example.com", includesSubdomains: false)
        var drafts = [invalid, valid]
        var touched: Set<ScopeMatcherDraft.ID> = [invalid.id]
        var state = ScopeEditorFeedbackState()
        state.clearRows(drafts: &drafts, touchedRowIDs: &touched)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertEqual(drafts, [invalid, valid])
        XCTAssertEqual(touched, [invalid.id])
        state.clearRows(drafts: &drafts, touchedRowIDs: &touched)
        state.willAddRow()
        let input = ScopeMatcherDraft(host: "new.example")
        drafts.append(input)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertEqual(drafts, [input])
        XCTAssertNil(state.feedback)
    }

    func testAddingAfterRowRemovalPreservesUndoAndTheRecordedPositionAndEditState() {
        let leading = ScopeMatcherDraft(host: "leading.example")
        let removed = ScopeMatcherDraft(host: "https://EXAMPLE.com/path", includesSubdomains: false)
        let trailing = ScopeMatcherDraft(host: "trailing.example")
        var drafts = [leading, removed, trailing]
        var touched: Set<ScopeMatcherDraft.ID> = [removed.id]
        var state = ScopeEditorFeedbackState()
        state.removeRow(id: removed.id, from: &drafts, touchedRowIDs: &touched)
        state.willAddRow()
        let added = ScopeMatcherDraft(host: "new.example")
        drafts.append(added)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertEqual(drafts, [leading, removed, trailing, added])
        XCTAssertEqual(touched, [removed.id])
        XCTAssertNil(state.feedback)
    }

    func testSecondSameHostDeletionGetsItsOwnUndoWindowAndRestoresOnlyTheLatestRow() throws {
        let start = ContinuousClock.now
        let first = ScopeMatcherDraft(host: "example.com", includesSubdomains: true)
        let second = ScopeMatcherDraft(host: "example.com", includesSubdomains: false)
        let tail = ScopeMatcherDraft(host: "other.example")
        var drafts = [first, second, tail]
        var touched: Set<ScopeMatcherDraft.ID> = [first.id, second.id]
        var state = ScopeEditorFeedbackState()
        state.removeRow(id: first.id, from: &drafts, touchedRowIDs: &touched, now: start)
        let firstEvent = try XCTUnwrap(state.feedback)
        state.removeRow(id: second.id, from: &drafts, touchedRowIDs: &touched, now: start.advanced(by: .seconds(5)))
        let secondEvent = try XCTUnwrap(state.feedback)
        XCTAssertEqual(firstEvent.message, secondEvent.message)
        XCTAssertNotEqual(firstEvent.id, secondEvent.id)
        state.expire(eventID: firstEvent.id, now: start.advanced(by: .seconds(6)))
        XCTAssertEqual(state.feedback, secondEvent)
        state.expire(eventID: secondEvent.id, now: start.advanced(by: .seconds(10)))
        XCTAssertEqual(state.feedback, secondEvent)
        state.undo(drafts: &drafts, touchedRowIDs: &touched)
        XCTAssertEqual(drafts, [second, tail])
        XCTAssertEqual(touched, [second.id])
        XCTAssertNil(state.feedback)
        state.expire(eventID: secondEvent.id, now: start.advanced(by: .seconds(11)))
        XCTAssertEqual(drafts, [second, tail])
    }
}
