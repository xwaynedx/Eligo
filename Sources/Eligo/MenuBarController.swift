import AppKit
import Combine

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let routingPreferencesStore: RoutingPreferencesStore
    private let appLanguageStore: AppLanguageStore
    private let settingsItem: NSMenuItem
    private let alwaysShowChooserItem: NSMenuItem
    private let rescanBrowsersItem: NSMenuItem
    private let helpSetDefaultBrowserItem: NSMenuItem
    private let aboutItem: NSMenuItem
    private let showWelcomeGuideItem: NSMenuItem
    private let quitItem: NSMenuItem
    private var settingsCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var confirmationPopover: NSPopover?

    init(
        onOpenSettings: @escaping () -> Void,
        onRescanBrowsers: @escaping () -> Void,
        onHelpSetDefaultBrowser: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void,
        onShowWelcomeGuide: @escaping () -> Void,
        routingPreferencesStore: RoutingPreferencesStore,
        appLanguageStore: AppLanguageStore,
        onQuit: @escaping () -> Void
    ) {
        self.routingPreferencesStore = routingPreferencesStore
        self.appLanguageStore = appLanguageStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        settingsItem = MenuActionItem(title: appLanguageStore.text("Settings"), actionHandler: onOpenSettings)
        alwaysShowChooserItem = NSMenuItem(title: appLanguageStore.text("Always Show Chooser"), action: nil, keyEquivalent: "")
        rescanBrowsersItem = MenuActionItem(title: appLanguageStore.text("Rescan Browsers"), actionHandler: onRescanBrowsers)
        helpSetDefaultBrowserItem = MenuActionItem(title: appLanguageStore.text("Help Set Default Browser"), actionHandler: onHelpSetDefaultBrowser)
        aboutItem = MenuActionItem(title: appLanguageStore.text("About Eligo"), actionHandler: onOpenAbout)
        showWelcomeGuideItem = MenuActionItem(title: appLanguageStore.text("Show Welcome Guide"), actionHandler: onShowWelcomeGuide)
        quitItem = MenuActionItem(title: appLanguageStore.text("Quit"), actionHandler: onQuit)

        let menu = NSMenu()
        menu.addItem(settingsItem)
        alwaysShowChooserItem.target = self
        alwaysShowChooserItem.action = #selector(toggleAlwaysShowChooser)
        menu.addItem(alwaysShowChooserItem)
        menu.addItem(rescanBrowsersItem)
        menu.addItem(helpSetDefaultBrowserItem)
        menu.addItem(aboutItem)
        menu.addItem(showWelcomeGuideItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        settingsCancellable = routingPreferencesStore.$settings.sink { [weak self] settings in
            self?.updateAlwaysShowChooserState(isEnabled: settings.alwaysShowChooser)
        }
        languageCancellable = appLanguageStore.$language.sink { [weak self] language in
            // @Published delivers the new value before the stored property is
            // updated. Use the emitted language instead of reading the store
            // again, otherwise the menu can remain in the previous language.
            self?.updateLocalizedMenuTitles(for: language)
        }
    }

    @objc private func toggleAlwaysShowChooser() {
        let settings = routingPreferencesStore.settings
        do {
            let isEnabled = !settings.alwaysShowChooser
            try routingPreferencesStore.replace(with: settings.replacing(alwaysShowChooser: isEnabled))
            showToggleConfirmation(isEnabled: isEnabled)
        } catch {
            AppLog.routing.error("Failed to update Always Show Chooser")
        }
    }

    private func updateAlwaysShowChooserState(isEnabled: Bool, language: AppLanguage? = nil) {
        alwaysShowChooserItem.state = isEnabled ? .on : .off
        statusItem.button?.image = EligoIcon.menuBarIcon(alwaysShowChooser: isEnabled)
        let language = language ?? appLanguageStore.language
        statusItem.button?.toolTip = isEnabled
            ? appLanguageStore.text("Always Show Chooser is On", for: language)
            : "Eligo"
    }

    private func showToggleConfirmation(isEnabled: Bool) {
        guard let button = statusItem.button else { return }

        let message = NSTextField(labelWithString: appLanguageStore.text(isEnabled ? "Always Show Chooser is On" : "Always Show Chooser is Off"))
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .labelColor
        message.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 38))
        contentView.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            message.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = contentView.frame.size
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = contentView
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        confirmationPopover = popover

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self, weak popover] in
            guard let self, self.confirmationPopover === popover else { return }
            popover?.close()
            self.confirmationPopover = nil
        }
    }

    private func updateLocalizedMenuTitles(for language: AppLanguage) {
        settingsItem.title = appLanguageStore.text("Settings", for: language)
        alwaysShowChooserItem.title = appLanguageStore.text("Always Show Chooser", for: language)
        rescanBrowsersItem.title = appLanguageStore.text("Rescan Browsers", for: language)
        helpSetDefaultBrowserItem.title = appLanguageStore.text("Help Set Default Browser", for: language)
        aboutItem.title = appLanguageStore.text("About Eligo", for: language)
        showWelcomeGuideItem.title = appLanguageStore.text("Show Welcome Guide", for: language)
        quitItem.title = appLanguageStore.text("Quit", for: language)
        updateAlwaysShowChooserState(
            isEnabled: routingPreferencesStore.settings.alwaysShowChooser,
            language: language
        )
    }
}

private final class MenuActionItem: NSMenuItem {
    private let actionHandler: () -> Void

    init(title: String, actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        actionHandler()
    }
}
