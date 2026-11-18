import AppKit

/// The AppKit adapter for the Browser Chooser.
///
/// All row/selection decisions live in the pure `ChooserSelection` model; this view only
/// translates AppKit facts into model intents (`handleKeyDown` via `ChooserKeyTranslator`,
/// hover/click into direct selection calls), executes the one-shot effects the model returns,
/// and owns the menu, focus-loop and window-callback lifecycle. The create-rule callback still
/// pairs the rule host with the clicked row's Open Destination here — it never enters the
/// selection model.
@MainActor
final class ChooserView: NSVisualEffectView {
    let displayURL: String
    /// Localized "From <app>" caption text, `nil` when the link carries no sender
    /// (local-file opens) and the source line is omitted entirely.
    let displaySource: String?
    let preferredSize: NSSize
    var onSelect: ((OpenDestination) -> Void)? {
        didSet { updateRowAvailability() }
    }
    var onCancel: (() -> Void)?
    var onCreateRule: ((String, OpenDestination) -> Void)? {
        didSet { updateRuleActions() }
    }

    private let fullURLString: String
    private let showsInsecureHTTPWarning: Bool
    private let language: AppLanguage
    private let ruleHost: String?
    private let routingHint: ChooserRoutingHint?
    private let linkSource: LinkSource?
    private var selection: ChooserSelection
    private var titleView: URLTitleView?
    private let ruleButton = ChooserActionButton()
    private let rowsScrollView = NSScrollView()
    private let rowsDocumentView = ChooserRowsView()
    private let rowsHeight: CGFloat
    private var rowViews: [BrowserRowView] = []
    private weak var rowToReveal: BrowserRowView?
    private weak var focusedAction: NSView?

    init(
        link: IncomingLink,
        destinations: [OpenDestination],
        recentBrowserID: Browser.ID?,
        routingHint: ChooserRoutingHint? = nil,
        language: AppLanguage = .english,
        pasteboard: NSPasteboard = .general
    ) {
        self.displayURL = Self.displayURL(for: link.url)
        self.displaySource = link.source?.displayText(language: language)
        self.fullURLString = link.url.absoluteString
        self.showsInsecureHTTPWarning = Self.showsInsecureHTTPWarning(for: link.url)
        self.language = language
        self.ruleHost = link.url.isFileURL ? nil : DomainMatcher.normalizedHost(from: link.url)
        self.routingHint = routingHint
        self.linkSource = link.source
        let selection = ChooserSelection(destinations: destinations, recentBrowserID: recentBrowserID)
        self.selection = selection

        let rowHeight: CGFloat = 40
        self.rowsHeight = CGFloat(selection.rows.count) * rowHeight + CGFloat(max(0, selection.rows.count - 1))
        let addedSourceHeight: CGFloat = link.source == nil ? 0 : Self.sourceAreaHeight
        let addedRuleHeight: CGFloat = ruleHost == nil ? 0 : 34
        let height = CGFloat(48) + addedSourceHeight + rowsHeight + 10 + addedRuleHeight
        self.preferredSize = NSSize(
            width: Self.preferredWidth(browsers: selection.rows.map(\.browser)),
            height: max(112 + addedSourceHeight + addedRuleHeight, height)
        )

        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        setupView(rowHeight: rowHeight, pasteboard: pasteboard)
        updateSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            rowToReveal = row(containing: focusedAction)
                ?? row(containing: window?.firstResponder)
                ?? (rowViews.indices.contains(selection.selectedIndex) ? rowViews[selection.selectedIndex] : nil)
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        rowsDocumentView.setFrameSize(NSSize(
            width: rowsScrollView.contentSize.width,
            height: max(rowsHeight, rowsScrollView.contentSize.height)
        ))
        rowsDocumentView.layoutSubtreeIfNeeded()
        if let row = rowToReveal {
            rowToReveal = nil
            row.scrollToVisible(row.bounds)
        }
    }

    private func row(containing responder: NSResponder?) -> BrowserRowView? {
        guard let responder else { return nil }
        return rowViews.first { $0 === responder || $0.keyboardFocusablePrivateButton === responder }
    }

    private func handleFocusChange(for action: NSView, isFocused: Bool) {
        if isFocused {
            focusedAction = action
            if let row = row(containing: action) {
                row.scrollToVisible(row.bounds)
            }
        } else if focusedAction === action {
            focusedAction = nil
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, titleView?.dismissPreview() == true { return true }
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 36 || event.keyCode == 76 { return createRuleForSelection() }
            return false
        }
        if !event.modifierFlags.intersection([.control, .option]).isEmpty { return false }
        let input = ChooserKeyTranslator.KeyInput(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            shiftHeld: event.modifierFlags.contains(.shift)
        )
        let intent = ChooserKeyTranslator.intent(for: input)
        if intent == .choose || event.keyCode == 49 {
            let responder = window?.firstResponder
            if responder === ruleButton {
                return createRuleForSelection()
            }
            if let button = responder as? NSButton, button.isEnabled,
               button === titleView?.expandButton || button === titleView?.copyButton {
                button.performClick(nil)
                return true
            }
            if let index = rowViews.firstIndex(where: { $0 === responder }) {
                return selectNormalDestination(at: index)
            }
        }
        guard let intent else { return false }
        guard intent == .cancel || onSelect != nil else { return false }

        let transition = selection.reduce(intent)
        switch transition {
        case .unhandled:
            return false
        case .handledWithoutEffect:
            switch intent {
            case .shiftChoose, .shiftSelectByNumber:
                NSSound.beep()
                return true
            default:
                break
            }
            switch intent {
            case .moveUp, .moveDown, .selectByLetter:
                // Arrow/letter navigation returns to the chooser's selection commands;
                // a row action must not keep keyboard focus as its row scrolls away.
                if window?.firstResponder !== self {
                    window?.makeFirstResponder(self)
                }
            default:
                break
            }
            updateSelection()
            return true
        case .handled(let effect):
            updateSelection()
            perform(effect)
            return true
        }
    }

    func handleFlagsChanged(_ event: NSEvent) -> Bool {
        titleView?.setOptionHeld(event.modifierFlags.contains(.option))
        return false
    }

    func closeURLPreview() { _ = titleView?.dismissPreview() }

    @discardableResult
    private func createRuleForSelection() -> Bool {
        guard let ruleHost, let onCreateRule, let destination = selection.selectedDestination else { return false }
        onCreateRule(ruleHost, destination)
        return true
    }

    @objc private func createRule() { createRuleForSelection() }

    private func setupView(rowHeight: CGFloat, pasteboard: NSPasteboard) {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let titleView = URLTitleView(
            displayURL: displayURL,
            fullURL: fullURLString,
            showsInsecureHTTPWarning: showsInsecureHTTPWarning,
            language: language,
            pasteboard: pasteboard
        )
        titleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleView)
        self.titleView = titleView
        titleView.copyButton.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        titleView.expandButton.onKeyDown = titleView.copyButton.onKeyDown

        NSLayoutConstraint.activate([
            titleView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            titleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            titleView.heightAnchor.constraint(equalToConstant: 18)
        ])

        var previousBottom = titleView.bottomAnchor
        if let linkSource {
            let sourceView = LinkSourceView(source: linkSource, language: language)
            sourceView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sourceView)

            NSLayoutConstraint.activate([
                sourceView.topAnchor.constraint(equalTo: titleView.bottomAnchor, constant: Self.titleToSourceSpacing),
                sourceView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                sourceView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
                sourceView.heightAnchor.constraint(equalToConstant: LinkSourceView.lineHeight)
            ])

            previousBottom = sourceView.bottomAnchor
        }

        rowsScrollView.translatesAutoresizingMaskIntoConstraints = false
        rowsScrollView.drawsBackground = false
        rowsScrollView.contentView.drawsBackground = false
        rowsScrollView.hasVerticalScroller = true
        rowsScrollView.autohidesScrollers = true
        rowsScrollView.scrollerStyle = .overlay
        rowsDocumentView.frame = NSRect(x: 0, y: 0, width: preferredSize.width - 12, height: rowsHeight)
        rowsDocumentView.autoresizingMask = [.width]
        rowsScrollView.documentView = rowsDocumentView
        addSubview(rowsScrollView)
        NSLayoutConstraint.activate([
            rowsScrollView.topAnchor.constraint(equalTo: previousBottom, constant: 8),
            rowsScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rowsScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rowsScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: ruleHost == nil ? -10 : -44)
        ])

        if ruleHost != nil {
            ruleButton.title = AppLanguageStore.localizedText("Create rule for this site…", for: language)
            ruleButton.font = .systemFont(ofSize: 11)
            ruleButton.isBordered = false
            ruleButton.bezelStyle = .inline
            ruleButton.alignment = .left
            ruleButton.contentTintColor = .secondaryLabelColor
            ruleButton.target = self
            ruleButton.action = #selector(createRule)
            ruleButton.setAccessibilityIdentifier("chooser.createRule")
            ruleButton.setAccessibilityHelp(AppLanguageStore.localizedText("Command-Return: create a rule and open this link", for: language))
            ruleButton.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
            ruleButton.translatesAutoresizingMaskIntoConstraints = false
            let shortcut = NSTextField(labelWithString: "⌘↩")
            shortcut.font = .systemFont(ofSize: 11)
            shortcut.textColor = .tertiaryLabelColor
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            shortcut.setAccessibilityElement(false)
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            addSubview(ruleButton)
            addSubview(shortcut)
            NSLayoutConstraint.activate([
                separator.topAnchor.constraint(equalTo: rowsScrollView.bottomAnchor, constant: 6),
                separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
                ruleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                ruleButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
                ruleButton.heightAnchor.constraint(equalToConstant: 22),
                ruleButton.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -8),
                shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
                shortcut.centerYAnchor.constraint(equalTo: ruleButton.centerYAnchor)
            ])
        }

        previousBottom = rowsDocumentView.topAnchor
        for (index, row) in selection.rows.enumerated() {
            let privateAdapter = row.privateDestination == nil
                ? nil
                : BrowserDefinition.definition(for: row.browser.bundleIdentifier)?.privateLaunchAdapter
            let rowView = BrowserRowView(
                browser: row.browser,
                shortcut: ChooserKeyTranslator.shortcutText(forRowAt: index),
                privateAdapter: privateAdapter,
                language: language
            )
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowView.onHighlight = { [weak self] in
                guard let self else { return }
                selection.selectNormal(at: index)
                updateSelection()
            }
            rowView.onKeyDown = { [weak self] event in
                self?.handleKeyDown(event) ?? false
            }
            rowView.onSelect = { [weak self] in
                self?.selectNormalDestination(at: index) ?? false
            }
            rowView.onPrivateSelect = { [weak self] in
                self?.selectPrivateDestination(at: index)
            }
            rowView.onFocusChanged = { [weak self] action, isFocused in
                self?.handleFocusChange(for: action, isFocused: isFocused)
            }
            if let routingHint, routingHint.destinationID.browserID == row.browser.id {
                rowView.showRoutingHint(routingHint)
            }
            configureRuleActions(for: rowView, at: index)
            rowsDocumentView.addSubview(rowView)
            rowViews.append(rowView)

            NSLayoutConstraint.activate([
                rowView.topAnchor.constraint(equalTo: previousBottom, constant: index == 0 ? 0 : 1),
                rowView.leadingAnchor.constraint(equalTo: rowsDocumentView.leadingAnchor),
                rowView.trailingAnchor.constraint(equalTo: rowsDocumentView.trailingAnchor),
                rowView.heightAnchor.constraint(equalToConstant: rowHeight)
            ])

            previousBottom = rowView.bottomAnchor
        }

        // Private is a sibling AX action, since an AX button is a navigation leaf.
        let accessibilityActions: [NSView] = rowViews.flatMap { row in
            if let privateButton = row.keyboardFocusablePrivateButton {
                return [row, privateButton]
            }
            return [row]
        }
        rowsDocumentView.setAccessibilityElement(true)
        rowsDocumentView.setAccessibilityRole(.group)
        rowsDocumentView.setAccessibilityLabel(AppLanguageStore.localizedText("Browsers", for: language))
        rowsDocumentView.setAccessibilityChildren(accessibilityActions)
        rowsDocumentView.setAccessibilityChildrenInNavigationOrder(accessibilityActions)
        for action in accessibilityActions {
            action.setAccessibilityParent(rowsDocumentView)
        }
        configureKeyboardFocusLoop()
        updateRowAvailability()
        updateRuleActions()
    }

    private func configureKeyboardFocusLoop() {
        let rowActions: [NSView] = rowViews.flatMap { row in
            if let privateButton = row.keyboardFocusablePrivateButton {
                return [row, privateButton]
            }
            return [row]
        }
        let focusableViews: [NSView] = [self]
            + [titleView?.copyButton, titleView?.expandButton].compactMap { $0 }
            + rowActions + (ruleHost == nil ? [] : [ruleButton])
        guard focusableViews.count > 1 else { return }
        for (index, view) in focusableViews.enumerated() {
            view.nextKeyView = focusableViews[(index + 1) % focusableViews.count]
        }
    }

    private func perform(_ effect: ChooserSelection.Effect) {
        switch effect {
        case .choose(let destination):
            onSelect?(destination)
        case .cancel:
            onCancel?()
        }
    }

    @discardableResult
    func selectNormalDestination(at index: Int) -> Bool {
        guard selection.rows.indices.contains(index), let onSelect else { return false }
        selection.selectNormal(at: index)
        updateSelection()
        onSelect(selection.rows[index].normalDestination)
        return true
    }

    func selectPrivateDestination(at index: Int) {
        guard let onSelect else { return }
        guard selection.selectPrivate(at: index) else {
            NSSound.beep()
            return
        }
        updateSelection()
        // `selectPrivate` succeeded, so the selected row is guaranteed to have a Private destination.
        if let destination = selection.selectedDestination {
            onSelect(destination)
        }
    }

    private func updateSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isSelected = index == selection.selectedIndex
            rowView.isPrivateSelected = index == selection.selectedIndex && selection.selectedMode == .privateBrowsing
        }
        rowToReveal = rowViews.indices.contains(selection.selectedIndex) ? rowViews[selection.selectedIndex] : nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateRowAvailability() {
        titleView?.copyButton.isEnabled = onSelect != nil
        titleView?.expandButton.isEnabled = onSelect != nil
        for rowView in rowViews {
            rowView.isEnabled = onSelect != nil
        }
    }

    private func updateRuleActions() {
        ruleButton.isEnabled = onCreateRule != nil && ruleHost != nil
        for (index, rowView) in rowViews.enumerated() {
            configureRuleActions(for: rowView, at: index)
        }
    }

    private func configureRuleActions(for rowView: BrowserRowView, at index: Int) {
        guard let ruleHost, let onCreateRule, selection.rows.indices.contains(index) else {
            rowView.onCreateNormalRule = nil
            rowView.onCreatePrivateRule = nil
            return
        }
        let row = selection.rows[index]
        rowView.onCreateNormalRule = { onCreateRule(ruleHost, row.normalDestination) }
        if let privateDestination = row.privateDestination {
            rowView.onCreatePrivateRule = { onCreateRule(ruleHost, privateDestination) }
        } else {
            rowView.onCreatePrivateRule = nil
        }
    }

    /// The insecure-HTTP treatment — an orange warning triangle beside the URL — applies
    /// to plain HTTP links, except on loopback hosts (see `LoopbackHost`) where HTTP is
    /// the local-development norm and the triangle stays hidden.
    nonisolated static func showsInsecureHTTPWarning(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return !LoopbackHost.isLoopback(host: host)
    }

    /// The URL text shown in the panel. Local files show as `file://<name>` and links with
    /// no host show as "Unknown URL"; everything else shows `scheme://host`, with the port
    /// appended whenever the link carries a non-default one — explicit default ports (`:80`
    /// for HTTP, `:443` for HTTPS) stay hidden even though `URL.port` reports them. IPv6
    /// hosts are re-bracketed so the text stays a parseable authority.
    nonisolated static func displayURL(for url: URL) -> String {
        if url.isFileURL {
            let filename = url.lastPathComponent.isEmpty ? "Local file" : url.lastPathComponent
            return "file://\(filename)"
        }

        guard let host = url.host, !host.isEmpty else {
            return "Unknown URL"
        }

        let scheme = url.scheme?.lowercased()
        var authority = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, !isDefaultPort(port, for: scheme) {
            authority += ":\(port)"
        }

        if let scheme, !scheme.isEmpty {
            return "\(scheme)://\(authority)"
        }

        return authority
    }

    private nonisolated static func isDefaultPort(_ port: Int, for scheme: String?) -> Bool {
        (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
    }
}

private final class ChooserRowsView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class BrowserRowView: NSControl {
    let browser: Browser
    var onHighlight: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onSelect: (() -> Bool)?
    var onPrivateSelect: (() -> Void)?
    var onFocusChanged: ((NSView, Bool) -> Void)? {
        didSet { privateButton?.onFocusChanged = onFocusChanged }
    }
    var onCreateNormalRule: (() -> Void)? {
        didSet { updateRuleMenus() }
    }
    var onCreatePrivateRule: (() -> Void)? {
        didSet { updateRuleMenus() }
    }

    var isSelected = false {
        didSet {
            needsDisplay = true
            updatePrivateButton()
        }
    }

    var isPrivateSelected = false {
        didSet {
            needsDisplay = true
            updatePrivateButton()
        }
    }

    override var isEnabled: Bool {
        didSet { privateButton?.isEnabled = isEnabled }
    }

    private let shortcutBadge = ShortcutBadgeView()
    private let iconView: NSImageView
    private let nameLabel: NSTextField
    private let modeSeparator: NSBox?
    private let privateButton: PrivateModeButton?
    private let privateAdapter: PrivateLaunchAdapter?
    private let language: AppLanguage

    var keyboardFocusablePrivateButton: NSButton? { privateButton }

    func showRoutingHint(_ hint: ChooserRoutingHint) {
        let isPrivate = hint.destinationID.mode == .privateBrowsing
        guard !isPrivate || privateButton != nil else { return }
        let mode = AppLanguageStore.localizedText(isPrivate ? "Private" : "Normal", for: language)
        let detail: String
        if let domain = hint.matchedDomain {
            let template = AppLanguageStore.localizedText("Rule target: %@ → %@ (%@)", for: language)
            detail = String(format: template, domain, browser.name, mode)
        } else {
            let template = AppLanguageStore.localizedText("Out-of-scope default destination: %@ (%@)", for: language)
            detail = String(format: template, browser.name, mode)
        }
        let marker = NSImageView()
        marker.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        marker.contentTintColor = isPrivate ? .systemPurple : .secondaryLabelColor
        marker.toolTip = detail
        marker.setAccessibilityIdentifier("chooser.routingHint")
        marker.setAccessibilityElement(false)
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)
        if isPrivate, let privateButton {
            privateButton.toolTip = detail + "\n" + (privateButton.toolTip ?? "")
            privateButton.setAccessibilityHelp(detail)
            privateButton.setAccessibilityLabel((privateButton.accessibilityLabel() ?? browser.name) + ", " + detail)
            NSLayoutConstraint.activate([
                marker.trailingAnchor.constraint(equalTo: privateButton.trailingAnchor, constant: -2),
                marker.topAnchor.constraint(equalTo: privateButton.topAnchor, constant: 2)
            ])
        } else {
            setAccessibilityHelp(detail)
            setAccessibilityLabel((accessibilityLabel() ?? browser.name) + ", " + detail)
            NSLayoutConstraint.activate([
                marker.trailingAnchor.constraint(equalTo: modeSeparator?.leadingAnchor ?? trailingAnchor, constant: -5),
                marker.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 10),
            marker.heightAnchor.constraint(equalToConstant: 10)
        ])
    }

    init(browser: Browser, shortcut: String, privateAdapter: PrivateLaunchAdapter?, language: AppLanguage) {
        self.browser = browser
        self.language = language
        self.privateAdapter = privateAdapter
        self.iconView = NSImageView(image: NSWorkspace.shared.icon(forFile: browser.appURL.path))
        self.nameLabel = NSTextField(labelWithString: browser.name)
        self.modeSeparator = privateAdapter.map { _ in NSBox() }
        self.privateButton = privateAdapter.map { _ in PrivateModeButton() }

        super.init(frame: .zero)

        shortcutBadge.configure(shortcut: shortcut, language: language)
        setup()
        updatePrivateButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        onHighlight?()
        onFocusChanged?(self, true)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChanged?(self, false)
        needsDisplay = true
        return true
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 3) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }

    override func isAccessibilityFocused() -> Bool {
        window?.firstResponder === self || super.isAccessibilityFocused()
    }

    override func accessibilityValue() -> Any? {
        AppLanguageStore.localizedText(isSelected && !isPrivateSelected ? "Selected" : "Not selected", for: language)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 8, yRadius: 8).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        onHighlight?()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let privateButton, privateButton.frame.contains(location) {
            return
        }
        _ = performNormalSelection()
    }

    override func accessibilityPerformPress() -> Bool {
        performNormalSelection()
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        onFocusChanged?(self, accessibilityFocused)
    }

    private func performNormalSelection() -> Bool {
        guard isEnabled, let onSelect else { return false }
        return onSelect()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeRuleMenu(for: .normal)
    }

    private func setup() {
        wantsLayer = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
        let normalModeLabel = AppLanguageStore.localizedText("Open %@ normally", for: language)
        var description = String(format: normalModeLabel, browser.name)
        if let shortcutDescription = shortcutBadge.accessibilityLabel() {
            description += ", \(shortcutDescription)"
        }
        setAccessibilityLabel(description)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutBadge)
        addSubview(iconView)
        addSubview(nameLabel)

        if let privateButton, let privateAdapter, let modeSeparator {
            modeSeparator.boxType = .separator
            modeSeparator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(modeSeparator)

            privateButton.target = self
            privateButton.action = #selector(openPrivately)
            privateButton.toolTip = privateAdapter.toolTip(language: language)
            privateButton.setAccessibilityLabel(
                privateAdapter.accessibilityLabel(browserName: browser.name, language: language)
            )
            privateButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(privateButton)
        }
        updateRuleMenus()

        NSLayoutConstraint.activate([
            shortcutBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            shortcutBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: shortcutBadge.trailingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(
                equalTo: modeSeparator?.leadingAnchor ?? trailingAnchor,
                constant: -20
            ),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if let privateButton, let modeSeparator {
            NSLayoutConstraint.activate([
                modeSeparator.trailingAnchor.constraint(equalTo: privateButton.leadingAnchor),
                modeSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
                modeSeparator.widthAnchor.constraint(equalToConstant: 1),
                modeSeparator.heightAnchor.constraint(equalToConstant: 22),

                privateButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                privateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                privateButton.widthAnchor.constraint(equalToConstant: 44),
                privateButton.heightAnchor.constraint(equalToConstant: 34)
            ])
        }
    }

    private func updatePrivateButton() {
        guard let privateButton else { return }
        let privateSelected = isSelected && isPrivateSelected
        privateButton.isRowSelected = isSelected
        privateButton.isModeSelected = privateSelected
        privateButton.setAccessibilityValue(AppLanguageStore.localizedText(
            privateSelected ? "Selected" : "Not selected",
            for: language
        ))
    }

    @objc private func openPrivately() { onPrivateSelect?() }

    @objc private func createNormalRule() { onCreateNormalRule?() }

    @objc private func createPrivateRule() { onCreatePrivateRule?() }

    private enum RuleDestination {
        case normal
        case privateBrowsing
    }

    private func updateRuleMenus() {
        privateButton?.menu = makeRuleMenu(for: .privateBrowsing)
    }

    private func makeRuleMenu(for destination: RuleDestination) -> NSMenu? {
        let action: Selector
        let title: String
        switch destination {
        case .normal:
            guard onCreateNormalRule != nil else { return nil }
            action = #selector(createNormalRule)
            let titleTemplate = AppLanguageStore.localizedText("Add Rule for %@…", for: language)
            title = String(format: titleTemplate, browser.name)
        case .privateBrowsing:
            guard onCreatePrivateRule != nil else { return nil }
            action = #selector(createPrivateRule)
            title = privateAdapter?.ruleMenuTitle(browserName: browser.name, language: language) ?? ""
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }
}

@MainActor
private final class PrivateModeButton: NSButton {
    var onFocusChanged: ((NSView, Bool) -> Void)?
    var isRowSelected = false {
        didSet { needsDisplay = true }
    }
    var isModeSelected = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var hoverTrackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        image = NSImage(
            systemSymbolName: "eyeglasses",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        imagePosition = .imageOnly
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("chooser.private")
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        needsDisplay = true
        onFocusChanged?(self, accessibilityFocused)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        needsDisplay = true
        onFocusChanged?(self, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        needsDisplay = true
        onFocusChanged?(self, false)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self || isAccessibilityFocused()
        if isModeSelected || isHovered || isHighlighted || isFocused {
            let color = NSColor.systemPurple.withAlphaComponent(
                isModeSelected ? 0.18 : (isHighlighted ? 0.15 : 0.10)
            )
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill()
        }
        contentTintColor = isRowSelected || isModeSelected || isHovered || isHighlighted || isFocused
            ? NSColor.systemPurple.withAlphaComponent(isModeSelected ? 1.0 : 0.82)
            : .secondaryLabelColor
        super.draw(dirtyRect)
    }
}

private extension ChooserView {
    /// Vertical space the source line occupies when present. Derived from
    /// LinkSourceView's shared constants so the two cannot silently drift apart.
    static let titleToSourceSpacing: CGFloat = 2
    static let sourceAreaHeight: CGFloat = titleToSourceSpacing + LinkSourceView.lineHeight

    /// 浏览器列表决定固定宽度，完整链接在独立浮层中换行。
    static func preferredWidth(browsers: [Browser]) -> CGFloat {
        let widestBrowserName = browsers
            .map { textWidth($0.name, font: .systemFont(ofSize: 13, weight: .regular)) }
            .max() ?? 0
        let hasPrivateAction = browsers.contains {
            BrowserDefinition.definition(for: $0.bundleIdentifier)?.privateLaunchAdapter != nil
        }
        let privateActionWidth: CGFloat = hasPrivateAction ? 53 : 0

        let horizontalChrome: CGFloat = 6 + 8 + ShortcutBadgeView.size + 9 + 24 + 9 + 8 + 8 + privateActionWidth
        let contentWidth = widestBrowserName + horizontalChrome
        return min(max(ceil(contentWidth), 268), 380)
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width
    }
}

private final class ChooserActionButton: NSButton {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        // NSButton may consume Return/Space before the panel sees them. Keep
        // chooser shortcuts (especially Shift+Enter) on the same dispatch path.
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class URLTitleView: NSView {
    private static let buttonWidth: CGFloat = 22
    let copyButton = ChooserActionButton()
    let expandButton = ChooserActionButton()
    private let fullURL: String
    private let language: AppLanguage
    private let pasteboard: NSPasteboard
    private let label: NSTextField
    private let warningIcon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var copyFeedbackTimer: Timer?
    private var optionHeld = false
    private var isHoveringURL = false
    private var isPinned = false
    private var preview: URLPreviewPanel?

    init(displayURL: String, fullURL: String, showsInsecureHTTPWarning: Bool,
         language: AppLanguage, pasteboard: NSPasteboard) {
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

    private func updateHover(at point: NSPoint) {
        let hovering = bounds.contains(point) && !copyButton.frame.contains(point) && !expandButton.frame.contains(point)
        guard hovering != isHoveringURL else { return }
        isHoveringURL = hovering
        hoverTimer?.invalidate()
        hoverTimer = nil
        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showPreview(pinned: false)
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
            let panel = URLPreviewPanel(fullURL: fullURL, language: language,
                onCopy: { [weak self] in self?.copyFullURL() },
                onClose: { [weak self] in _ = self?.dismissPreview() },
                onOptionChanged: { [weak self] in self?.setOptionHeld($0) })
            let visible = parent.screen?.visibleFrame ?? parent.frame.insetBy(dx: -100, dy: -200)
            let anchor = parent.convertToScreen(convert(bounds, to: nil))
            let size = NSSize(width: min(URLPreviewPanel.preferredSize.width, visible.width - 16),
                              height: min(URLPreviewPanel.preferredSize.height, visible.height - 16))
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(
                x: min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8),
                y: min(max(anchor.minY - size.height - 6, visible.minY + 8), visible.maxY - size.height - 8)
            ))
            panel.level = parent.level
            parent.addChildWindow(panel, ordered: .above)
            preview = panel
            panel.orderFront(nil)
        }
        expandButton.setAccessibilityValue(AppLanguageStore.localizedText("Expanded", for: language))
        if pinned { preview?.makeKeyAndOrderFront(nil) }
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
        pasteboard.clearContents()
        guard pasteboard.setString(fullURL, forType: .string) else {
            updateCopyFeedback(copied: false)
            NSSound.beep()
            return
        }
        updateCopyFeedback(copied: true)
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateCopyFeedback(copied: false) }
        }
    }

    private func updateCopyFeedback(copied: Bool) {
        copyButton.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let message = AppLanguageStore.localizedText(copied ? "Link copied" : "Copy Full Link", for: language)
        copyButton.toolTip = message
        copyButton.setAccessibilityValue(copied ? message : nil)
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

    init(fullURL: String, language: AppLanguage, onCopy: @escaping () -> Void,
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
        updateCopyFeedback(copied: false)
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
        copy.title = AppLanguageStore.localizedText(copied ? "Link copied" : "Copy Full Link", for: language)
        copy.image = copied ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
        copy.imagePosition = copied ? .imageLeading : .noImage
    }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func flagsChanged(with event: NSEvent) { onOptionChanged(event.modifierFlags.contains(.option)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() }
        else { super.keyDown(with: event) }
    }
}
