import AppKit
import SwiftUI

/// Hosts the first-run Welcome Guide, a fixed-size, titleless
/// window with the standard close button (closing means skip). The root view
/// is recreated on every `show()` so a guide re-opened from the menu bar
/// starts fresh from the first step.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let appLanguageStore: AppLanguageStore
    private let browserRepository: BrowserRepository
    private let defaultBrowserController: DefaultBrowserController
    private let onOpenSettings: () -> Void
    private let onAddFirstRule: () -> Void

    init(
        appLanguageStore: AppLanguageStore,
        browserRepository: BrowserRepository,
        defaultBrowserController: DefaultBrowserController,
        onOpenSettings: @escaping () -> Void,
        onAddFirstRule: @escaping () -> Void
    ) {
        self.appLanguageStore = appLanguageStore
        self.browserRepository = browserRepository
        self.defaultBrowserController = defaultBrowserController
        self.onOpenSettings = onOpenSettings
        self.onAddFirstRule = onAddFirstRule

        let window = NSWindow()
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Eligo"
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 640, height: 420))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        defaultBrowserController.beginObserving(for: window)
        window.contentViewController = NSHostingController(
            rootView: WelcomeGuideView(
                appLanguageStore: appLanguageStore,
                browserRepository: browserRepository,
                defaultBrowserController: defaultBrowserController,
                onClose: { [weak window] in window?.close() },
                onOpenSettings: { [weak window, onOpenSettings] in
                    window?.close()
                    onOpenSettings()
                },
                onAddFirstRule: { [weak window, onAddFirstRule] in
                    window?.close()
                    onAddFirstRule()
                }
            )
        )
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        defaultBrowserController.endObserving(for: window)
    }

}
