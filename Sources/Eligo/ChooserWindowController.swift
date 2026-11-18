import AppKit

@MainActor
struct ChooserRecoveryAction {
    let title: String
    let perform: @MainActor @Sendable () -> Void

    init(title: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.perform = perform
    }
}

@MainActor
final class ChooserWindowController: NSObject, NSWindowDelegate {
    private let appLanguageStore: AppLanguageStore
    private let displayPanel: (NSPanel) -> Void
    private let screenGeometry: () -> (visibleFrame: NSRect, mouseLocation: NSPoint)
    private let mouseEvents: ChooserMouseEvents
    private let now: () -> TimeInterval
    private let pasteboard: NSPasteboard
    private var clickMonitor: ChooserClickMonitor?
    private var panel: ChooserPanel?
    private var currentChooserView: ChooserView?
    private var selectionCompletion: ((OpenDestination?) -> Void)?
    private var recoveryCancelHandler: (@MainActor @Sendable () -> Void)?
    private var isCompleting = false

    init(
        appLanguageStore: AppLanguageStore,
        displayPanel: @escaping (NSPanel) -> Void = { panel in
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        },
        screenGeometry: @escaping () -> (visibleFrame: NSRect, mouseLocation: NSPoint) = {
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
            return (
                screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600),
                mouseLocation
            )
        },
        mouseEvents: ChooserMouseEvents = ChooserMouseEvents(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pasteboard: NSPasteboard = .general
    ) {
        self.appLanguageStore = appLanguageStore
        self.displayPanel = displayPanel
        self.screenGeometry = screenGeometry
        self.mouseEvents = mouseEvents
        self.now = now
        self.pasteboard = pasteboard
        super.init()
    }

    func present(
        link: IncomingLink,
        destinations: [OpenDestination],
        recentBrowserID: Browser.ID?,
        routingHint: ChooserRoutingHint? = nil,
        onCreateRule: ((String, OpenDestination) -> Void)? = nil,
        completion: @escaping (OpenDestination?) -> Void
    ) {
        cancelCurrentPresentation()
        selectionCompletion = completion
        recoveryCancelHandler = nil
        let chooserView = ChooserView(
            link: link,
            destinations: destinations,
            recentBrowserID: recentBrowserID,
            routingHint: routingHint,
            language: appLanguageStore.language,
            pasteboard: pasteboard
        )
        let size = chooserView.preferredSize
        let panel = ChooserPanel(contentRect: NSRect(origin: .zero, size: size))
        // ChooserView owns the Copy / Normal / Private order, including reverse Tab.
        panel.autorecalculatesKeyViewLoop = false
        panel.keyHandler = { [weak chooserView] event in
            chooserView?.handleKeyDown(event) ?? false
        }
        panel.flagsChangedHandler = { [weak chooserView] event in
            chooserView?.handleFlagsChanged(event) ?? false
        }

        chooserView.onSelect = { [weak self, weak panel] browser in
            guard let self, let panel, self.panel === panel else { return }
            self.finish(with: browser)
        }
        chooserView.onCancel = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.finish(with: nil)
        }
        if let onCreateRule {
            chooserView.onCreateRule = { [weak self, weak panel] host, destination in
                guard let self, let panel, self.panel === panel else { return }
                // The route still owns the link while Settings edits its rule.
                // Release the chooser without reporting cancellation to the queue.
                self.tearDownPanel()
                self.selectionCompletion = nil
                onCreateRule(host, destination)
            }
        }

        AppLog.chooser.info("Showing chooser for URL: \(chooserView.displayURL, privacy: .private)")
        show(panel, contentView: chooserView, size: size)
    }

    func presentRecovery(
        message: String,
        source: LinkSource?,
        primaryAction: ChooserRecoveryAction,
        secondaryAction: ChooserRecoveryAction?,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        cancelCurrentPresentation()
        selectionCompletion = nil
        recoveryCancelHandler = onCancel
        let recoveryView = ChooserRecoveryView(
            message: message,
            source: source,
            language: appLanguageStore.language,
            primaryActionTitle: primaryAction.title,
            secondaryActionTitle: secondaryAction?.title,
            actionNeededAccessibilityDescription: appLanguageStore.text("Action needed")
        )
        let size = recoveryView.preferredSize
        let panel = ChooserPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.keyHandler = { [weak self, weak panel] event in
            guard event.keyCode == 53, let self, let panel, self.panel === panel else { return false }
            self.finishRecovery(executing: onCancel)
            return true
        }
        recoveryView.onPrimary = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.finishRecovery(executing: primaryAction.perform)
        }
        if let secondaryAction {
            recoveryView.onSecondary = { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                self.finishRecovery(executing: secondaryAction.perform)
            }
        }

        AppLog.chooser.info("Showing recovery action: \(message, privacy: .public)")
        show(panel, contentView: recoveryView, size: size)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isCompleting, let window = notification.object as? NSWindow,
              window === panel else { return }
        if recoveryCancelHandler != nil {
            cancelCurrentPresentation()
        } else {
            // An app can activate more than once while creating a Private window,
            // even after its initial handoff settled. Only an actual outside click
            // or explicit cancel may consume this chooser's pending link.
            AppLog.chooser.info("Chooser lost key without a dismissal action; retaining URL")
        }
    }

    private func cancelCurrentPresentation() {
        if selectionCompletion != nil {
            finish(with: nil)
        } else if let recoveryCancelHandler {
            finishRecovery(executing: recoveryCancelHandler)
        }
    }

    private func finish(with destination: OpenDestination?) {
        guard !isCompleting else { return }
        isCompleting = true
        tearDownPanel()

        let completion = selectionCompletion
        selectionCompletion = nil
        recoveryCancelHandler = nil

        if let destination {
            AppLog.chooser.info("Chooser selected destination: \(destination.browser.name, privacy: .public)")
        } else {
            AppLog.chooser.info("Chooser cancelled")
        }

        isCompleting = false
        completion?(destination)
    }

    private func finishRecovery(executing action: @MainActor @Sendable () -> Void) {
        guard !isCompleting else { return }
        isCompleting = true
        tearDownPanel()

        selectionCompletion = nil
        recoveryCancelHandler = nil

        isCompleting = false
        action()
    }

    private func tearDownPanel() {
        clickMonitor = nil
        if let chooserView = currentChooserView {
            chooserView.closeURLPreview()
            chooserView.onSelect = nil
            chooserView.onCancel = nil
            chooserView.onCreateRule = nil
        }
        currentChooserView = nil
        panel?.keyHandler = nil
        panel?.flagsChangedHandler = nil
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
    }

    private func show(_ panel: ChooserPanel, contentView: NSView, size: NSSize) {
        let geometry = screenGeometry()
        let maximumSize = NSSize(
            width: max(1, geometry.visibleFrame.width - 16),
            height: max(1, geometry.visibleFrame.height - 16)
        )
        let fittedSize = NSSize(width: min(size.width, maximumSize.width), height: min(size.height, maximumSize.height))
        panel.maxSize = maximumSize
        panel.setContentSize(fittedSize)
        contentView.setFrameSize(fittedSize)
        panel.delegate = self
        panel.contentView = RoundedClipView(contentView: contentView, cornerRadius: 14)
        panel.setFrameOrigin(Self.position(for: fittedSize, visibleFrame: geometry.visibleFrame, mouseLocation: geometry.mouseLocation))
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.alphaValue = 0
        self.panel = panel
        currentChooserView = contentView as? ChooserView
        isCompleting = false

        if selectionCompletion != nil {
            clickMonitor = ChooserClickMonitor(
                panel: panel, events: mouseEvents, startedAt: now()
            ) { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                AppLog.chooser.info("Chooser dismissed by outside click")
                self.cancelCurrentPresentation()
            }
        }
        displayPanel(panel)
        panel.makeFirstResponder(contentView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private static func position(for size: NSSize, visibleFrame: NSRect, mouseLocation: NSPoint) -> NSPoint {
        let margin: CGFloat = 8

        var x = mouseLocation.x + 12
        if x + size.width + margin > visibleFrame.maxX {
            x = mouseLocation.x - size.width - 12
        }

        var y = mouseLocation.y - size.height - 12
        if y < visibleFrame.minY + margin {
            y = mouseLocation.y + 12
        }

        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin)
        y = min(max(y, visibleFrame.minY + margin), visibleFrame.maxY - size.height - margin)

        return NSPoint(x: x, y: y)
    }
}

private final class ChooserRecoveryView: NSVisualEffectView {
    /// The source line's vertical footprint derives from LinkSourceView's shared
    /// constants so the two panels cannot silently drift apart.
    private static let baseHeight: CGFloat = 116
    private static let messageToSourceSpacing: CGFloat = 6

    let preferredSize: NSSize
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    init(
        message: String,
        source: LinkSource?,
        language: AppLanguage,
        primaryActionTitle: String,
        secondaryActionTitle: String?,
        actionNeededAccessibilityDescription: String
    ) {
        // The source line answers "who triggered this" on an unexpected recovery
        // panel; local-file opens carry no sender, so the panel keeps its compact size.
        self.preferredSize = NSSize(
            width: 360,
            height: source == nil
                ? Self.baseHeight
                : Self.baseHeight + Self.messageToSourceSpacing + LinkSourceView.lineHeight
        )
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        setup(
            message: message,
            source: source,
            language: language,
            primaryActionTitle: primaryActionTitle,
            secondaryActionTitle: secondaryActionTitle,
            actionNeededAccessibilityDescription: actionNeededAccessibilityDescription
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(
        message: String,
        source: LinkSource?,
        language: AppLanguage,
        primaryActionTitle: String,
        secondaryActionTitle: String?,
        actionNeededAccessibilityDescription: String
    ) {
        material = .popover
        blendingMode = .behindWindow
        state = .active

        let iconView = NSImageView(
            image: NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: actionNeededAccessibilityDescription
            ) ?? NSImage()
        )
        iconView.contentTintColor = .systemOrange
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false

        let primaryButton = NSButton(title: primaryActionTitle, target: self, action: #selector(runPrimaryAction))
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        var buttons: [NSView] = []
        if let secondaryActionTitle {
            let secondaryButton = NSButton(
                title: secondaryActionTitle,
                target: self,
                action: #selector(runSecondaryAction)
            )
            secondaryButton.bezelStyle = .rounded
            buttons.append(secondaryButton)
        }
        buttons.append(primaryButton)

        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .gravityAreas
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        addSubview(buttonStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])

        if let source {
            let sourceView = LinkSourceView(source: source, language: language, alignment: .leading)
            sourceView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sourceView)

            NSLayoutConstraint.activate([
                sourceView.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                sourceView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                sourceView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Self.messageToSourceSpacing),
                sourceView.heightAnchor.constraint(equalToConstant: LinkSourceView.lineHeight)
            ])
        }
    }

    @objc private func runPrimaryAction() {
        onPrimary?()
    }

    @objc private func runSecondaryAction() {
        onSecondary?()
    }
}

private final class ChooserPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var flagsChangedHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76,
           keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if flagsChangedHandler?(event) == true {
            return
        }

        super.flagsChanged(with: event)
    }
}

private final class RoundedClipView: NSView {
    init(contentView: NSView, cornerRadius: CGFloat) {
        super.init(frame: contentView.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.allowsEdgeAntialiasing = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
