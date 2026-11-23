import AppKit

@MainActor
protocol LinkCopyPasteboard {
    func clearContents() -> Int
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: LinkCopyPasteboard {}

@MainActor
private func applyCopyFeedback(_ copied: Bool, to button: NSButton, language: AppLanguage, iconOnly: Bool) {
    let message = AppLanguageStore.localizedText(copied ? "Link copied" : "Copy Full Link", for: language)
    let symbol = copied ? "checkmark" : "doc.on.doc"
    if iconOnly {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.toolTip = message
    } else {
        button.title = message
        button.image = copied ? NSImage(systemSymbolName: symbol, accessibilityDescription: nil) : nil
        button.imagePosition = copied ? .imageLeading : .noImage
    }
    button.setAccessibilityValue(copied ? message : nil)
}

final class URLTitleView: NSView {
    private static let buttonWidth: CGFloat = 22
    let copyButton = ChooserActionButton()
    let expandButton = ChooserActionButton()
    private let fullURL: String
    private let language: AppLanguage
    private let pasteboard: any LinkCopyPasteboard
    private let label: NSTextField
    private let warningIcon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private(set) var copyFeedbackTimer: Timer?
    private var copied = false
    private var optionHeld = false
    private var isHoveringURL = false
    private var isPinned = false
    private var preview: URLPreviewPanel?

    init(displayURL: String, fullURL: String, showsInsecureHTTPWarning: Bool,
         language: AppLanguage, pasteboard: any LinkCopyPasteboard) {
        self.fullURL = fullURL
        self.language = language
        self.pasteboard = pasteboard
        label = NSTextField(labelWithString: displayURL)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.textColor = .labelColor
        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: AppLanguageStore.localizedText("Insecure HTTP", for: language))
        warningIcon.contentTintColor = .systemOrange
        warningIcon.isHidden = !showsInsecureHTTPWarning
        for button in [copyButton, expandButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            addSubview(button)
        }
        copyButton.action = #selector(copyFullURL)
        copyButton.setAccessibilityIdentifier("chooser.copyLink")
        copyButton.setAccessibilityLabel(AppLanguageStore.localizedText("Copy Full Link", for: language))
        expandButton.action = #selector(togglePinnedPreview)
        expandButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        expandButton.toolTip = AppLanguageStore.localizedText("Inspect Full Link (hold Option to preview)", for: language)
        expandButton.setAccessibilityLabel(expandButton.toolTip)
        expandButton.setAccessibilityIdentifier("chooser.expandLink")
        addSubview(warningIcon)
        addSubview(label)
        toolTip = expandButton.toolTip
        updateCopyFeedback(copied: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let chrome = Self.buttonWidth * 2 + 8 + (warningIcon.isHidden ? 0 : 18)
        let labelWidth = ceil(label.frame(forAlignmentRect: NSRect(origin: .zero, size: label.intrinsicContentSize)).width)
        let width = min(labelWidth, max(0, bounds.width - chrome))
        var x = (bounds.width - width - chrome) / 2
        if !warningIcon.isHidden {
            warningIcon.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
            x += 18
        }
        label.frame = NSRect(x: x, y: (bounds.height - label.intrinsicContentSize.height) / 2,
                             width: width, height: label.intrinsicContentSize.height)
        expandButton.frame = NSRect(x: x + width + 3, y: 0, width: Self.buttonWidth, height: bounds.height)
        copyButton.frame = NSRect(x: expandButton.frame.maxX + 2, y: 0, width: Self.buttonWidth, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { togglePinnedPreview() }

    private func isPreviewPoint(_ point: NSPoint) -> Bool {
        bounds.contains(point) && !copyButton.frame.contains(point) && !expandButton.frame.contains(point)
    }

    private func updateHover(at point: NSPoint) {
        let hovering = isPreviewPoint(point)
        guard hovering != isHoveringURL else { return }
        isHoveringURL = hovering
        hoverTimer?.invalidate()
        hoverTimer = nil
        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    self.isHoveringURL = self.isPreviewPoint(point)
                    if self.isHoveringURL { self.showPreview(pinned: false) }
                }
            }
        } else if !optionHeld && !isPinned {
            _ = dismissPreview()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringURL = false
        hoverTimer?.invalidate()
        if !optionHeld && !isPinned { _ = dismissPreview() }
    }

    func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        if held { showPreview(pinned: false) }
        else if !isPinned { _ = dismissPreview() }
    }

    @objc private func togglePinnedPreview() {
        if isPinned { _ = dismissPreview() }
        else { showPreview(pinned: true) }
    }

    private func showPreview(pinned: Bool) {
        guard let parent = window else { return }
        isPinned = isPinned || pinned
        if preview == nil {
            let panel = URLPreviewPanel(fullURL: fullURL, language: language, copied: copied,
                onCopy: { [weak self] in self?.copyFullURL() },
                onClose: { [weak self] in _ = self?.dismissPreview() },
                onOptionChanged: { [weak self] in self?.setOptionHeld($0) })
            let visible = parent.screen?.visibleFrame ?? parent.frame.insetBy(dx: -100, dy: -200)
            let anchor = parent.convertToScreen(convert(bounds, to: nil))
            let available = visible.insetBy(dx: 8, dy: 8)
            let below = min(anchor.minY - 6, available.maxY) - available.minY
            let above = available.maxY - max(anchor.maxY + 6, available.minY)
            let preferred = URLPreviewPanel.preferredSize
            let placeBelow = below >= preferred.height || below >= above
            let size = NSSize(width: min(preferred.width, available.width),
                              height: min(preferred.height, placeBelow ? below : above))
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(
                x: min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width),
                y: placeBelow ? available.minY + below - size.height : available.maxY - above
            ))
            panel.level = parent.level
            parent.addChildWindow(panel, ordered: .above)
            preview = panel
            panel.orderFront(nil)
        }
        expandButton.setAccessibilityValue(AppLanguageStore.localizedText("Expanded", for: language))
        if pinned { preview?.makeKeyAndOrderFront(nil) }
    }

    func dismissTemporaryPreview() {
        if !isPinned { dismissPreview() }
    }

    @discardableResult
    func dismissPreview() -> Bool {
        hoverTimer?.invalidate()
        isHoveringURL = false
        guard let preview else { return false }
        let wasKey = preview.isKeyWindow
        self.preview = nil
        isPinned = false
        preview.parent?.removeChildWindow(preview)
        preview.orderOut(nil)
        expandButton.setAccessibilityValue(nil)
        if wasKey {
            window?.makeKey()
            window?.makeFirstResponder(expandButton)
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTimer?.invalidate()
            isHoveringURL = false
            copyFeedbackTimer?.invalidate()
            _ = dismissPreview()
        }
    }

    @objc private func copyFullURL() {
        copyFeedbackTimer?.invalidate()
        _ = pasteboard.clearContents()
        guard pasteboard.setString(fullURL, forType: .string) else {
            updateCopyFeedback(copied: false)
            NSSound.beep()
            return
        }
        updateCopyFeedback(copied: true)
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCopyFeedback(copied: false) }
        }
    }

    private func updateCopyFeedback(copied: Bool) {
        self.copied = copied
        applyCopyFeedback(copied, to: copyButton, language: language, iconOnly: true)
        preview?.updateCopyFeedback(copied: copied)
    }
}

private final class URLPreviewPanel: NSPanel {
    static let preferredSize = NSSize(width: 420, height: 188)
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private let onOptionChanged: (Bool) -> Void
    private let copy = NSButton()
    private let language: AppLanguage
    override var canBecomeKey: Bool { true }

    init(fullURL: String, language: AppLanguage, copied: Bool, onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void, onOptionChanged: @escaping (Bool) -> Void) {
        self.onCopy = onCopy
        self.onClose = onClose
        self.onOptionChanged = onOptionChanged
        self.language = language
        let frame = NSRect(origin: .zero, size: Self.preferredSize)
        super.init(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let content = NSVisualEffectView(frame: frame)
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        contentView = content
        let heading = NSTextField(labelWithString: AppLanguageStore.localizedText("Full Link", for: language))
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        copy.target = self
        copy.action = #selector(copyLink)
        copy.controlSize = .small
        copy.bezelStyle = .rounded
        updateCopyFeedback(copied: !copied)
        let otherWidth = copy.intrinsicContentSize.width
        updateCopyFeedback(copied: copied)
        copy.widthAnchor.constraint(equalToConstant: max(otherWidth, copy.intrinsicContentSize.width)).isActive = true
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closePreview))
        close.isBordered = false
        close.setAccessibilityLabel(AppLanguageStore.localizedText("Close", for: language))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 392, height: 130))
        text.string = fullURL
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 392, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (fullURL as NSString).length))
        if let host = URLComponents(string: fullURL)?.rangeOfHost {
            text.textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                                           range: NSRange(host, in: fullURL))
        }
        text.setAccessibilityIdentifier("chooser.fullLinkText")
        text.setAccessibilityLabel(AppLanguageStore.localizedText("Full Link", for: language))
        scroll.documentView = text
        for view in [heading, copy, close, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18),
            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            copy.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        initialFirstResponder = text
    }

    @objc private func copyLink() { onCopy() }
    @objc private func closePreview() { onClose() }

    func updateCopyFeedback(copied: Bool) {
        applyCopyFeedback(copied, to: copy, language: language, iconOnly: false)
    }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func flagsChanged(with event: NSEvent) { onOptionChanged(event.modifierFlags.contains(.option)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == ChooserKeyTranslator.escape { onClose() }
        else { super.keyDown(with: event) }
    }
}
