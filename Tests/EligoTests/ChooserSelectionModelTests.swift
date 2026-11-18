import XCTest
@testable import Eligo

/// Pure-model tests for `ChooserSelection` and `ChooserKeyTranslator`.
///
/// These tests deliberately use a fresh `ChooserSelection` per scenario (never a shared, mutated
/// instance), never import AppKit, and assert on `Transition` three-states and `Effect` values
/// rather than closures or events. They mirror the observable behaviour pinned by the
/// characterization tests in `ChooserSelectionTests` but exercise the pure model directly.
final class ChooserSelectionModelTests: XCTestCase {
    func testShiftDigitsAndKeypadUsePhysicalPositions() {
        let keys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]
        for (index, symbol) in Array("!@#$%^&*()").enumerated() {
            for code in [keys[index], keypad[index]] {
                XCTAssertEqual(ChooserKeyTranslator.intent(for: .init(
                    keyCode: code, charactersIgnoringModifiers: String(symbol), shiftHeld: true
                )), .shiftSelectByNumber(index: index))
            }
        }
    }

    func testShiftDigitOpensRequestedPrivateRowWithoutMovingFirst() {
        var selection = makeSelection(browsers: [safari, chrome], recent: safari.id)
        XCTAssertEqual(selection.reduce(.shiftSelectByNumber(index: 1)),
            .handled(effect: .choose(OpenDestination(browser: chrome, mode: .privateBrowsing))))
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.reduce(.shiftSelectByNumber(index: 0)), .handledWithoutEffect)
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.reduce(.shiftSelectByNumber(index: 9)), .unhandled)
    }

    private let chrome = makeBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
    private let safari = makeBrowser(name: "Safari", bundleIdentifier: "com.apple.Safari")
    private let chromium = makeBrowser(name: "Chromium", bundleIdentifier: "org.chromium.Chromium")

    // MARK: - Initial selection

    func testInitialSelectionDefaultsToRecentBrowserNormalMode() {
        let selection = makeSelection(browsers: [chrome, safari], recent: safari.id)

        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.selectedDestination, OpenDestination(browser: safari, mode: .normal))
    }

    func testUnavailableRecentBrowserFallsBackToFirstRow() {
        let selection = makeSelection(browsers: [safari], recent: "com.example.missing")

        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertEqual(selection.selectedDestination, OpenDestination(browser: safari, mode: .normal))
    }

    func testEmptyDestinationsHaveNoSelectedDestination() {
        let selection = makeSelection(browsers: [], recent: nil)

        XCTAssertNil(selection.selectedDestination)
    }

    // MARK: - Transition three-state semantics

    func testCancelProducesHandledCancelEffect() {
        var selection = makeSelection(browsers: [safari], recent: nil)

        let transition = selection.reduce(.cancel)

        XCTAssertEqual(transition, .handled(effect: .cancel))
    }

    func testChooseProducesHandledChooseEffectForCurrentSelection() {
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)

        let transition = selection.reduce(.choose)

        XCTAssertEqual(transition, .handled(effect: .choose(OpenDestination(browser: chrome, mode: .normal))))
    }

    func testArrowMoveIsHandledWithoutEffect() {
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)

        let transition = selection.reduce(.moveDown)

        XCTAssertEqual(transition, .handledWithoutEffect)
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.selectedMode, .normal)
    }

    func testArrowClampAtBoundaryIsStillHandledWithoutEffect() {
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)

        // Already at the first row; moving up clamps but the input is still a consumed selection command.
        let transition = selection.reduce(.moveUp)

        XCTAssertEqual(transition, .handledWithoutEffect)
        XCTAssertEqual(selection.selectedIndex, 0)
    }

    func testTabKeyIsUnhandledByTranslator() {
        let intent = ChooserKeyTranslator.intent(for: .init(keyCode: 48, charactersIgnoringModifiers: "\t", shiftHeld: false))

        XCTAssertNil(intent)
    }

    func testUnmatchedLetterIsUnhandledWithNoCursorMove() {
        var selection = makeSelection(browsers: [safari], recent: nil)

        let transition = selection.reduce(.selectByLetter("z"))

        XCTAssertEqual(transition, .unhandled)
        XCTAssertEqual(selection.selectedIndex, 0)
    }

    func testLetterOnEmptyModelIsUnhandledRatherThanTrapping() {
        var selection = makeSelection(browsers: [], recent: nil)

        // Regression: the wrap range (selectedIndex + 1)..<rows.count would trap on an empty model.
        let transition = selection.reduce(.selectByLetter("a"))

        XCTAssertEqual(transition, .unhandled)
        XCTAssertNil(selection.selectedDestination)
    }

    // MARK: - Number shortcuts

    func testNumberShortcutChoosesImmediatelyAtNormalMode() {
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)

        let transition = selection.reduce(.selectByNumber(index: 1))

        XCTAssertEqual(transition, .handled(effect: .choose(OpenDestination(browser: safari, mode: .normal))))
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.selectedMode, .normal)
    }

    func testNumberShortcutOnPrivateSelectedRowChoosesNormalDestination() {
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)
        // Put the cursor on chrome in private mode first.
        XCTAssertTrue(selection.selectPrivate(at: 0))
        XCTAssertEqual(selection.selectedMode, .privateBrowsing)

        // 普通数字键独立于当前模式，始终打开普通模式。
        let transition = selection.reduce(.selectByNumber(index: 0))

        XCTAssertEqual(
            transition,
            .handled(effect: .choose(OpenDestination(browser: chrome, mode: .normal)))
        )
    }

    func testNumberShortcutBeyondRowCountIsUnhandled() {
        var selection = makeSelection(browsers: [safari], recent: nil)

        let transition = selection.reduce(.selectByNumber(index: 5))

        XCTAssertEqual(transition, .unhandled)
    }

    // MARK: - Private selection / Shift+Enter

    func testShiftChooseOnPrivateCapableRowProducesPrivateEffect() {
        var selection = makeSelection(browsers: [chrome], recent: nil)

        let transition = selection.reduce(.shiftChoose)

        XCTAssertEqual(
            transition,
            .handled(effect: .choose(OpenDestination(browser: chrome, mode: .privateBrowsing)))
        )
    }

    func testShiftChooseOnRowWithoutPrivateDestinationIsHandledWithoutEffect() {
        var selection = makeSelection(browsers: [safari], recent: nil)

        // Legacy behaviour: Shift+Enter on a row with no private adapter is consumed (beeps) but
        // selects nothing — distinct from `.unhandled`.
        let transition = selection.reduce(.shiftChoose)

        XCTAssertEqual(transition, .handledWithoutEffect)
    }

    func testChooseAfterSelectingPrivateRowYieldsPrivateDestination() {
        var selection = makeSelection(browsers: [chrome], recent: nil)

        XCTAssertTrue(selection.selectPrivate(at: 0))
        let transition = selection.reduce(.choose)

        XCTAssertEqual(
            transition,
            .handled(effect: .choose(OpenDestination(browser: chrome, mode: .privateBrowsing)))
        )
    }

    func testSelectPrivateOnRowWithoutPrivateDestinationFailsAndKeepsCursor() {
        var selection = makeSelection(browsers: [safari], recent: nil)

        // Both a private-less row and an out-of-range index reject the private selection.
        XCTAssertFalse(selection.selectPrivate(at: 0))
        XCTAssertFalse(selection.selectPrivate(at: 5))

        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertEqual(selection.selectedMode, .normal)
        XCTAssertEqual(selection.selectedDestination, OpenDestination(browser: safari, mode: .normal))
    }

    // MARK: - Letter navigation

    func testLetterAdvancesToNextMatchingRowWithoutChoosing() {
        var selection = makeSelection(browsers: [chrome, chromium, safari], recent: chrome.id)

        let transition = selection.reduce(.selectByLetter("c"))

        XCTAssertEqual(transition, .handledWithoutEffect)
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    func testLetterWrapsToEarlierMatchingRow() {
        var selection = makeSelection(browsers: [chrome, safari], recent: safari.id)

        // "g" matches "Google Chrome" only by wrapping back to row 0.
        let transition = selection.reduce(.selectByLetter("g"))

        XCTAssertEqual(transition, .handledWithoutEffect)
        XCTAssertEqual(selection.selectedIndex, 0)
    }

    // MARK: - Key translator boundaries

    func testTranslatorMapsReturnAndEnterToChoose() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 36, charactersIgnoringModifiers: "\r", shiftHeld: false)),
            .choose
        )
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 76, charactersIgnoringModifiers: "\r", shiftHeld: false)),
            .choose
        )
    }

    func testTranslatorMapsShiftReturnToShiftChoose() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 36, charactersIgnoringModifiers: "\r", shiftHeld: true)),
            .shiftChoose
        )
    }

    func testTranslatorMapsEscapeToCancel() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 53, charactersIgnoringModifiers: "\u{1B}", shiftHeld: false)),
            .cancel
        )
    }

    func testTranslatorMapsArrowsToMoveIntents() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 125, charactersIgnoringModifiers: "\u{F701}", shiftHeld: false)),
            .moveDown
        )
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 126, charactersIgnoringModifiers: "\u{F700}", shiftHeld: false)),
            .moveUp
        )
    }

    func testTranslatorMapsDigitsToNumberIndices() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 18, charactersIgnoringModifiers: "1", shiftHeld: false)),
            .selectByNumber(index: 0)
        )
        // "0" maps to the tenth row (index 9), matching the legacy shortcut layout.
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 29, charactersIgnoringModifiers: "0", shiftHeld: false)),
            .selectByNumber(index: 9)
        )
    }

    func testTranslatorMapsSingleLetterToLetterIntent() {
        XCTAssertEqual(
            ChooserKeyTranslator.intent(for: .init(keyCode: 8, charactersIgnoringModifiers: "c", shiftHeld: false)),
            .selectByLetter("c")
        )
    }

    func testTranslatorIgnoresUnrecognisedNonLetterNonDigitInput() {
        // A punctuation key (no keyCode match, not a digit, not a letter) is unhandled.
        XCTAssertNil(
            ChooserKeyTranslator.intent(for: .init(keyCode: 43, charactersIgnoringModifiers: "=", shiftHeld: false))
        )
    }

    func testTranslatorIgnoresMultiCharacterInput() {
        XCTAssertNil(
            ChooserKeyTranslator.intent(for: .init(keyCode: 0, charactersIgnoringModifiers: "ab", shiftHeld: false))
        )
    }

    // MARK: - Purity contract

    func testModelHoldsNoTerminalEffectAfterReduce() {
        // A move leaves no stored effect: the only way to observe a terminal effect is via the
        // returned Transition, never via later model state.
        var selection = makeSelection(browsers: [chrome, safari], recent: chrome.id)
        _ = selection.reduce(.moveDown)

        // Re-reducing a move produces handledWithoutEffect again, proving no effect leaked.
        XCTAssertEqual(selection.reduce(.moveUp), .handledWithoutEffect)
    }

    // MARK: - Helpers

    private func makeSelection(browsers: [Browser], recent: Browser.ID?) -> ChooserSelection {
        ChooserSelection(destinations: DestinationCatalog(enabledBrowsers: browsers).destinations, recentBrowserID: recent)
    }
}
