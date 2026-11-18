import Foundation

/// A pure, AppKit-free value type that owns Chooser row layout, selection movement and the
/// choose/cancel effects derived from keyboard input.
///
/// `ChooserSelection` deliberately mirrors the design idiom of `DomainRuleSettingsSession`
/// (flat `Equatable`, `Sendable` value types, a typed `Effect` enum, fresh-model-per-test)
/// without sharing any state-machine abstraction with it. It never imports AppKit, never stores
/// closures, terminal effects, key events or window objects, and knows nothing about create-rule
/// host/destination pairing. Those concerns stay in the AppKit adapter.
struct ChooserSelection: Equatable, Sendable {
    /// A single Chooser row: a browser plus, when supported, its private-browsing destination.
    struct Row: Equatable, Sendable {
        let browser: Browser
        let privateDestination: OpenDestination?

        var normalDestination: OpenDestination {
            OpenDestination(browser: browser, mode: .normal)
        }
    }

    /// A terminal side-effect the AppKit adapter must perform (open a destination or cancel).
    enum Effect: Equatable, Sendable {
        case choose(OpenDestination)
        case cancel
    }

    /// The outcome of feeding a single intent to the model.
    ///
    /// Three deliberately distinct states so a caller can tell apart "this input was a selection
    /// command that moved the cursor but produced nothing to act on" from "this input is not a
    /// selection command at all". A single ambiguous `.none` is intentionally avoided.
    enum Transition: Equatable, Sendable {
        /// The input is not a selection command (e.g. Tab, an unmatched letter). The caller should
        /// let it propagate to the key-view loop. No effect is produced.
        case unhandled
        /// The input is a selection command that was consumed (e.g. arrow move, a matching letter
        /// that moved the cursor) but produced no terminal effect this turn.
        case handledWithoutEffect
        /// The input was consumed and produced a terminal effect the caller must perform.
        case handled(effect: Effect)
    }

    private(set) var rows: [Row]
    private(set) var selectedIndex: Int
    private(set) var selectedMode: OpeningMode

    init(destinations: [OpenDestination], recentBrowserID: Browser.ID?) {
        let normalDestinations = destinations.filter { $0.mode == .normal }
        let privateByBrowserID = destinations.reduce(into: [Browser.ID: OpenDestination]()) { result, destination in
            if destination.mode == .privateBrowsing, result[destination.browser.id] == nil {
                result[destination.browser.id] = destination
            }
        }
        rows = normalDestinations.map { destination in
            Row(
                browser: destination.browser,
                privateDestination: privateByBrowserID[destination.browser.id]
            )
        }
        selectedIndex = normalDestinations.firstIndex { $0.browser.id == recentBrowserID } ?? 0
        selectedMode = .normal
    }

    /// The currently selected destination, honouring a private selection when one is active.
    var selectedDestination: OpenDestination? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        let row = rows[selectedIndex]
        if selectedMode == .privateBrowsing, let privateDestination = row.privateDestination {
            return privateDestination
        }
        return row.normalDestination
    }

    /// Apply a movement intent that changes the cursor without choosing. The move is always
    /// consumed (clamping at a boundary is still a handled selection command), so callers reduce it
    /// to `.handledWithoutEffect` regardless of whether the index actually changed.
    mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let proposed = min(max(selectedIndex + delta, 0), rows.count - 1)
        if proposed == selectedIndex, selectedMode == .normal {
            return
        }
        selectedIndex = proposed
        selectedMode = .normal
    }

    /// Move the cursor directly to a row index (used by hover/click/letter/number navigation).
    /// Out-of-range indices are ignored.
    mutating func selectNormal(at index: Int) {
        guard rows.indices.contains(index) else { return }
        if index == selectedIndex, selectedMode == .normal {
            return
        }
        selectedIndex = index
        selectedMode = .normal
    }

    /// Move the cursor to a row and switch it to private mode. Returns whether the row supports a
    /// private destination; when it does not, the cursor is left untouched.
    @discardableResult
    mutating func selectPrivate(at index: Int) -> Bool {
        guard rows.indices.contains(index), rows[index].privateDestination != nil else {
            return false
        }
        selectedIndex = index
        selectedMode = .privateBrowsing
        return true
    }

    /// The destination a number shortcut (1–9 → 0–8, 0 → 9) would choose at the given index.
    /// Plain number shortcuts always open normally, independently of the current mode.
    func destinationForShortcut(at index: Int) -> OpenDestination? {
        guard rows.indices.contains(index) else { return nil }
        return rows[index].normalDestination
    }

    /// Advance the cursor to the next row whose browser name starts with `letter` (case-insensitive),
    /// wrapping past the end. Returns whether a matching row was found and the cursor moved. An empty
    /// model returns `false` rather than trapping on the wrap range.
    @discardableResult
    mutating func selectByLetter(_ letter: Character) -> Bool {
        guard !rows.isEmpty else { return false }
        let needle = String(letter).lowercased()
        let search = Array((selectedIndex + 1)..<rows.count) + Array(0...selectedIndex)
        guard let matchIndex = search.first(where: { rows[$0].browser.name.lowercased().hasPrefix(needle) }) else {
            return false
        }
        selectedIndex = matchIndex
        selectedMode = .normal
        return true
    }

    /// Build the terminal choose effect for the current selection. Returns `nil` only when there is
    /// no row to choose from.
    func chooseEffect() -> Effect? {
        guard let destination = selectedDestination else { return nil }
        return .choose(destination)
    }

    /// The terminal choose effect a Shift+Enter would produce at the current selection. Returns
    /// `nil` when the current row has no private destination, signalling the caller should beep
    /// rather than open anything.
    func shiftEnterEffect() -> Effect? {
        guard rows.indices.contains(selectedIndex), let privateDestination = rows[selectedIndex].privateDestination else {
            return nil
        }
        return .choose(privateDestination)
    }

    /// Reduce a pure input intent to a transition, mutating selection state in place.
    ///
    /// The mapping mirrors the legacy `ChooserView.handleKeyDown` observable behaviour exactly,
    /// while expressing it through the three-state `Transition` so callers can distinguish a
    /// consumed-but-effectless selection command (move, letter jump) from a genuinely unhandled
    /// input (Tab, unmatched letter/number).
    mutating func reduce(_ intent: ChooserKeyTranslator.Intent) -> Transition {
        switch intent {
        case .cancel:
            return .handled(effect: .cancel)
        case .choose:
            guard let effect = chooseEffect() else {
                return .handledWithoutEffect
            }
            return .handled(effect: effect)
        case .shiftChoose:
            guard let effect = shiftEnterEffect() else {
                // Legacy behaviour: Shift+Enter on a row without a private destination beeps and is
                // consumed (returns true) without selecting anything.
                return .handledWithoutEffect
            }
            return .handled(effect: effect)
        case .moveUp:
            moveSelection(by: -1)
            return .handledWithoutEffect
        case .moveDown:
            moveSelection(by: 1)
            return .handledWithoutEffect
        case let .selectByNumber(index):
            if let destination = destinationForShortcut(at: index) {
                selectNormal(at: index)
                return .handled(effect: .choose(destination))
            }
            return .unhandled
        case let .shiftSelectByNumber(index):
            guard rows.indices.contains(index) else { return .unhandled }
            guard selectPrivate(at: index), let destination = selectedDestination else {
                return .handledWithoutEffect
            }
            return .handled(effect: .choose(destination))
        case let .selectByLetter(letter):
            if selectByLetter(letter) {
                return .handledWithoutEffect
            }
            return .unhandled
        }
    }
}
