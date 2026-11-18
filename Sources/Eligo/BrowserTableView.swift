import AppKit
import SwiftUI

struct BrowserTableView: NSViewRepresentable {
    let browsers: [ConfiguredBrowser]
    let acceptedBrowsers: () -> [ConfiguredBrowser]
    let language: AppLanguage
    let onToggle: (Browser.ID, Bool) -> Bool
    let onMove: (IndexSet, Int) -> Bool
    let onRemoveCustom: (Browser.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            browsers: browsers,
            acceptedBrowsers: acceptedBrowsers,
            language: language,
            onToggle: onToggle,
            onMove: onMove,
            onRemoveCustom: onRemoveCustom
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let column = NSTableColumn(identifier: .browserColumn)
        column.resizingMask = []
        column.minWidth = 0
        tableView.addTableColumn(column)

        let scrollView = BrowserTableScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.documentView = tableView
        scrollView.tableView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.browsers = browsers
        context.coordinator.acceptedBrowsers = acceptedBrowsers
        context.coordinator.language = language
        context.coordinator.onToggle = onToggle
        context.coordinator.onMove = onMove
        context.coordinator.onRemoveCustom = onRemoveCustom

        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let visibleWidth = scrollView.contentView.bounds.width
        if tableView.tableColumns.first?.width != visibleWidth {
            tableView.tableColumns.first?.width = visibleWidth
        }
        tableView.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var browsers: [ConfiguredBrowser]
        var acceptedBrowsers: () -> [ConfiguredBrowser]
        var language: AppLanguage
        var onToggle: (Browser.ID, Bool) -> Bool
        var onMove: (IndexSet, Int) -> Bool
        var onRemoveCustom: (Browser.ID) -> Void
        weak var tableView: NSTableView?
        private var draggingRowIndexes = IndexSet()

        init(
            browsers: [ConfiguredBrowser],
            acceptedBrowsers: @escaping () -> [ConfiguredBrowser],
            language: AppLanguage,
            onToggle: @escaping (Browser.ID, Bool) -> Bool,
            onMove: @escaping (IndexSet, Int) -> Bool,
            onRemoveCustom: @escaping (Browser.ID) -> Void
        ) {
            self.browsers = browsers
            self.acceptedBrowsers = acceptedBrowsers
            self.language = language
            self.onToggle = onToggle
            self.onMove = onMove
            self.onRemoveCustom = onRemoveCustom
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            browsers.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            42
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard browsers.indices.contains(row) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("BrowserCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserTableCellView
                ?? BrowserTableCellView(identifier: identifier)

            cell.configure(
                with: browsers[row],
                language: language,
                shortcut: browsers[row].isEnabled
                    ? ChooserKeyTranslator.shortcutText(forRowAt: browsers[..<row].filter(\.isEnabled).count)
                    : "",
                isDraggingSource: draggingRowIndexes.contains(row)
            )
            cell.toggleAction = { [weak self] browserID, isEnabled in
                guard let self else { return false }
                let accepted = self.onToggle(browserID, isEnabled)
                self.browsers = self.acceptedBrowsers()
                self.tableView?.reloadData()
                return accepted
            }
            cell.removeAction = { [weak self] browserID in
                self?.onRemoveCustom(browserID)
            }
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard browsers.indices.contains(row) else { return nil }
            return browsers[row].id as NSString
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            draggingRowIndexes = rowIndexes
            tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integer: 0))
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            draggingRowIndexes = IndexSet()
            browsers = acceptedBrowsers()
            tableView.reloadData()
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            defer {
                browsers = acceptedBrowsers()
                draggingRowIndexes = IndexSet()
                tableView.setDropRow(-1, dropOperation: .above)
                tableView.reloadData()
            }
            guard
                let item = info.draggingPasteboard.string(forType: .string),
                let sourceIndex = browsers.firstIndex(where: { $0.id == item })
            else {
                return false
            }

            let destination = min(max(row, 0), browsers.count)
            return onMove(IndexSet(integer: sourceIndex), destination)
        }
    }
}

private final class BrowserTableScrollView: NSScrollView {
    weak var tableView: NSTableView?

    override func layout() {
        super.layout()

        guard let tableView, let column = tableView.tableColumns.first else { return }
        let visibleWidth = contentView.bounds.width
        guard visibleWidth > 0, column.width != visibleWidth else { return }
        column.width = visibleWidth
        tableView.frame.size.width = visibleWidth
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let browserColumn = NSUserInterfaceItemIdentifier("BrowserColumn")
}

private final class BrowserTableCellView: NSTableCellView {
    var toggleAction: ((Browser.ID, Bool) -> Bool)?
    var removeAction: ((Browser.ID) -> Void)?

    private var browserID: Browser.ID?
    private var acceptedEnabledState = false
    private let rowStack = NSStackView()
    private let dragPlaceholderView = DragPlaceholderView()
    private let dragHandle = NSImageView()
    private let shortcutBadge = ShortcutBadgeView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let identifierLabel = NSTextField(labelWithString: "")
    private let customBadge = BadgeCapsuleView(
        icon: nil,
        tint: .secondaryLabelColor,
        fill: .quaternaryLabelColor,
        fillAlpha: 0.35
    )
    private let privateBadge = BadgeCapsuleView(
        icon: NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil),
        tint: .systemPurple,
        fill: .systemPurple,
        fillAlpha: 0.12
    )
    private let enabledSwitch = NSSwitch()
    private let removeButton = NSButton()
    private let removeSpacer = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with configuredBrowser: ConfiguredBrowser, language: AppLanguage, shortcut: String, isDraggingSource: Bool) {
        browserID = configuredBrowser.id
        acceptedEnabledState = configuredBrowser.isEnabled
        alphaValue = 1.0
        rowStack.isHidden = isDraggingSource
        dragPlaceholderView.isHidden = !isDraggingSource
        shortcutBadge.configure(shortcut: shortcut, language: language)
        iconView.image = NSWorkspace.shared.icon(forFile: configuredBrowser.browser.appURL.path)
        nameLabel.stringValue = configuredBrowser.browser.name
        identifierLabel.stringValue = configuredBrowser.browser.bundleIdentifier
        enabledSwitch.state = configuredBrowser.isEnabled ? .on : .off
        enabledSwitch.isEnabled = !isDraggingSource
        removeButton.isHidden = !configuredBrowser.isCustom
        removeSpacer.isHidden = configuredBrowser.isCustom
        removeButton.isEnabled = !isDraggingSource
        customBadge.isHidden = !configuredBrowser.isCustom
        customBadge.configure(text: AppLanguageStore.localizedText("Custom", for: language))
        let privateAdapter = BrowserDefinition.definition(for: configuredBrowser.browser.bundleIdentifier)?.privateLaunchAdapter
        privateBadge.isHidden = privateAdapter == nil
        privateBadge.configure(text: privateAdapter?.capabilityLabel(language: language) ?? "")
        let dragDescription = AppLanguageStore.localizedText("Drag to reorder", for: language)
        let removeDescription = AppLanguageStore.localizedText("Remove custom browser", for: language)
        dragHandle.toolTip = dragDescription
        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: dragDescription)
        dragHandle.setAccessibilityLabel(dragDescription)
        removeButton.toolTip = removeDescription
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: removeDescription)
        removeButton.setAccessibilityLabel(removeDescription)
        let enabledLabel = AppLanguageStore.localizedText("Enable or disable %@", for: language)
        enabledSwitch.setAccessibilityLabel(String(format: enabledLabel, configuredBrowser.browser.name))
    }

    private func setup() {
        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        dragHandle.contentTintColor = .tertiaryLabelColor
        dragHandle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        identifierLabel.font = .systemFont(ofSize: 11)
        identifierLabel.textColor = .secondaryLabelColor
        identifierLabel.lineBreakMode = .byTruncatingMiddle
        identifierLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        enabledSwitch.controlSize = .small
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleChanged)

        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.contentTintColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [nameLabel, customBadge, privateBadge])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.distribution = .gravityAreas
        titleStack.spacing = 6

        let textStack = NSStackView(views: [titleStack, identifierLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlStack = NSStackView(views: [enabledSwitch, removeButton, removeSpacer])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.distribution = .fill
        controlStack.spacing = 10
        controlStack.setContentHuggingPriority(.required, for: .horizontal)
        controlStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        rowStack.setViews([dragHandle, shortcutBadge, iconView, textStack, controlStack], in: .leading)
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.distribution = .fill
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        dragPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        dragPlaceholderView.isHidden = true

        addSubview(dragPlaceholderView)
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: 16),
            dragHandle.heightAnchor.constraint(equalToConstant: 16),

            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
            removeSpacer.widthAnchor.constraint(equalToConstant: 22),
            removeSpacer.heightAnchor.constraint(equalToConstant: 22),
            controlStack.widthAnchor.constraint(equalToConstant: 72),

            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            dragPlaceholderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dragPlaceholderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dragPlaceholderView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            dragPlaceholderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @objc private func toggleChanged() {
        guard let browserID else { return }
        let requestedState = enabledSwitch.state == .on
        let wasAccepted = toggleAction?(browserID, requestedState) ?? false
        if !wasAccepted {
            enabledSwitch.state = acceptedEnabledState ? .on : .off
        }
    }

    @objc private func removeClicked() {
        guard let browserID else { return }
        removeAction?(browserID)
    }
}

/// Small capsule tag for per-browser annotations such as "Custom" and the Private mode note.
/// Width follows its content; the fill color is re-resolved on every appearance change.
private final class BadgeCapsuleView: NSView {
    private static let horizontalPadding: CGFloat = 7

    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let fillColor: NSColor
    private let fillAlpha: CGFloat

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        let contentSize = stack.fittingSize
        return NSSize(width: contentSize.width + Self.horizontalPadding * 2, height: NSView.noIntrinsicMetric)
    }

    init(icon: NSImage?, tint: NSColor, fill: NSColor, fillAlpha: CGFloat) {
        self.fillColor = fill
        self.fillAlpha = fillAlpha
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8

        var arrangedViews: [NSView] = []
        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            iconView.contentTintColor = tint
            iconView.imageScaling = .scaleProportionallyUpOrDown
            arrangedViews.append(iconView)
        }

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        arrangedViews.append(label)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setViews(arrangedViews, in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        invalidateIntrinsicContentSize()
    }

    override func updateLayer() {
        super.updateLayer()
        // withAlphaComponent flattens dynamic colors against the current appearance,
        // so it must be applied here, on every appearance change, not once up front.
        layer?.backgroundColor = fillColor.withAlphaComponent(fillAlpha).cgColor
    }
}

private final class DragPlaceholderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}
