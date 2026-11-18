import Foundation

/// A stateless translator from raw keyboard-input facts to a pure `ChooserSelection` intent.
///
/// It depends only on Foundation: callers extract the AppKit facts (key code, characters, whether
/// shift is held) and pass them as plain values, so the translator itself never imports AppKit and
/// holds no state. Key code 48 (Tab) and any input that is neither a selection command nor a
/// navigation/letter/number input maps to `nil`, signalling the AppKit adapter to leave the event
/// for the key-view loop.
struct ChooserKeyTranslator: Sendable {
    /// Raw keyboard facts, decoupled from `NSEvent` so the translator stays Foundation-only.
    struct KeyInput: Equatable, Sendable {
        let keyCode: UInt16
        let charactersIgnoringModifiers: String?
        let shiftHeld: Bool

        init(keyCode: UInt16, charactersIgnoringModifiers: String?, shiftHeld: Bool) {
            self.keyCode = keyCode
            self.charactersIgnoringModifiers = charactersIgnoringModifiers
            self.shiftHeld = shiftHeld
        }
    }

    /// A pure input intent the model can reduce. Mirrors the legacy ChooserView command set without
    /// any AppKit coupling.
    enum Intent: Equatable, Sendable {
        case choose
        case shiftChoose
        case cancel
        case moveUp
        case moveDown
        case selectByNumber(index: Int)
        case shiftSelectByNumber(index: Int)
        case selectByLetter(Character)
    }

    /// Map a key input to an intent, or `nil` when the input is not a selection command (Tab,
    /// unrecognised keys). The mapping is total over the legacy ChooserView command set.
    static func intent(for input: KeyInput) -> Intent? {
        switch input.keyCode {
        case 53:
            return .cancel
        case 36, 76:
            return input.shiftHeld ? .shiftChoose : .choose
        case 48:
            // Tab is left to the key-view loop for keyboard accessibility.
            return nil
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        default:
            if let index = numberIndex(from: input) {
                return input.shiftHeld ? .shiftSelectByNumber(index: index) : .selectByNumber(index: index)
            }
            if let letter = letter(from: input) {
                return .selectByLetter(letter)
            }
            return nil
        }
    }

    private static func numberIndex(from input: KeyInput) -> Int? {
        // Shift changes the printed character (1 -> !). macOS virtual key codes
        // are not contiguous in numeric order; include the numeric keypad too.
        let numberKeys: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
            22: 5, 26: 6, 28: 7, 25: 8, 29: 9,
            83: 0, 84: 1, 85: 2, 86: 3, 87: 4,
            88: 5, 89: 6, 91: 7, 92: 8, 82: 9
        ]
        if input.shiftHeld, let index = numberKeys[input.keyCode] { return index }
        guard let characters = input.charactersIgnoringModifiers, characters.count == 1 else { return nil }
        guard let value = Int(characters), (0...9).contains(value) else { return nil }
        return value == 0 ? 9 : value - 1
    }

    /// Shared by the chooser and Settings so the displayed key always matches this translator.
    static func shortcutText(forRowAt index: Int) -> String {
        switch index {
        case 0...8: String(index + 1)
        case 9: "0"
        default: ""
        }
    }

    private static func letter(from input: KeyInput) -> Character? {
        guard
            let characters = input.charactersIgnoringModifiers?.lowercased(),
            characters.count == 1,
            let character = characters.first,
            character.isLetter
        else {
            return nil
        }
        return character
    }
}
