import XCTest
@testable import Eligo

final class ScopeEditorFeedbackTests: XCTestCase {
    func testSameHostDeletionHasANewIdentityAndFullUndoWindow() {
        let start = ContinuousClock.now
        let first = ScopeEditorFeedback(.removedRow(host: "example.com"), now: start)
        let second = ScopeEditorFeedback(.removedRow(host: "example.com"), now: start.advanced(by: .seconds(5)))
        XCTAssertEqual(first.message, second.message)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.shouldExpire(eventID: first.id, now: start.advanced(by: .seconds(6))))
        XCTAssertFalse(second.shouldExpire(eventID: first.id, now: start.advanced(by: .seconds(6))))
        XCTAssertFalse(second.shouldExpire(eventID: second.id, now: start.advanced(by: .seconds(6))))
        XCTAssertTrue(second.shouldExpire(eventID: second.id, now: start.advanced(by: .seconds(11))))
        XCTAssertFalse(second.shouldExpire(eventID: first.id, now: start.advanced(by: .seconds(12))))
        XCTAssertTrue(second.canUndo)
    }

    func testRepeatedClearAndReplacementFeedbackCannotShareAnExpiry() {
        let start = ContinuousClock.now
        let clear = ScopeEditorFeedback(.clearedRows(count: 2), now: start)
        let secondClear = ScopeEditorFeedback(.clearedRows(count: 2), now: start.advanced(by: .seconds(5)))
        let paste = ScopeEditorFeedback(.pasteResult(added: 2, skippedDuplicates: 0), now: start.advanced(by: .seconds(5)))
        XCTAssertNotEqual(clear.id, secondClear.id)
        for current in [secondClear, paste] {
            XCTAssertFalse(current.shouldExpire(eventID: clear.id, now: start.advanced(by: .seconds(6))))
            XCTAssertFalse(current.shouldExpire(eventID: current.id, now: start.advanced(by: .seconds(6))))
        }
        XCTAssertTrue(secondClear.canUndo)
        XCTAssertFalse(paste.canUndo)
    }
}
