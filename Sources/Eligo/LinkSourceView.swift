import AppKit

/// The one-line "From <app>" caption that answers "who sent this link" on the
/// Browser Chooser and on recovery panels.
///
/// Pure display: text decisions live on the `LinkSource` value itself (the repo's
/// pure-type idiom); only icon resolution stays here because it needs AppKit.
/// The layout constants are shared so the Chooser's height math derives
/// from them instead of duplicating magic numbers.
@MainActor
final class LinkSourceView: NSView {
    enum Alignment {
        /// Matches the chooser's centred URL title.
        case center
        /// Matches the recovery panel's left-aligned message.
        case leading
    }

    static let lineHeight: CGFloat = 16
    static let iconSize: CGFloat = 12
    static let spacing: CGFloat = 5
    static let textFont: NSFont = .systemFont(ofSize: 11)

    init(source: LinkSource, language: AppLanguage, alignment: Alignment = .center) {
        super.init(frame: .zero)

        let iconView = NSImageView(image: Self.icon(for: source))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: source.displayText(language: language))
        label.font = Self.textFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        var constraints = [
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ]
        switch alignment {
        case .center:
            constraints.append(stack.centerXAnchor.constraint(equalTo: centerXAnchor))
        case .leading:
            constraints.append(stack.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        toolTip = source.toolTip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func icon(for source: LinkSource) -> NSImage {
        switch source {
        case let .app(sender):
            if let appURL = sender.appURL {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        case .unknown:
            let image = NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
            image.isTemplate = true
            return image
        }
    }
}
