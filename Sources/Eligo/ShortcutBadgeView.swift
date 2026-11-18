import AppKit

/// A fixed-size shortcut slot; unassigned keys leave the column aligned without a visible badge.
@MainActor
final class ShortcutBadgeView: NSView {
    static let size: CGFloat = 20
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityIdentifier("browser.shortcut")
        setAccessibilityRole(.staticText)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(shortcut: String, language: AppLanguage) {
        label.stringValue = shortcut
        let description = shortcut.isEmpty ? nil : String(
            format: AppLanguageStore.localizedText("Chooser shortcut %@", for: language), shortcut
        )
        toolTip = description
        setAccessibilityElement(!shortcut.isEmpty)
        setAccessibilityLabel(description)
        setAccessibilityValue(shortcut)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !label.stringValue.isEmpty else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}
