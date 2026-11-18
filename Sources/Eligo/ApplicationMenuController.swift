import AppKit
import Combine

@MainActor
final class ApplicationMenuController {
    private let appLanguageStore: AppLanguageStore
    private var languageCancellable: AnyCancellable?
    private let editMenuItem: NSMenuItem
    private let editMenu: NSMenu
    private let cutItem: NSMenuItem
    private let copyItem: NSMenuItem
    private let pasteItem: NSMenuItem
    private let selectAllItem: NSMenuItem
    private var isInstalled = false

    init(appLanguageStore: AppLanguageStore) {
        self.appLanguageStore = appLanguageStore
        editMenuItem = NSMenuItem()
        editMenu = NSMenu()
        cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenuItem.submenu = editMenu
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(.separator())
        editMenu.addItem(selectAllItem)
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let mainMenu = NSApp.mainMenu ?? NSMenu()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        updateLocalizedTitles(for: appLanguageStore.language)
        languageCancellable = appLanguageStore.$language.sink { [weak self] language in
            self?.updateLocalizedTitles(for: language)
        }
    }

    private func updateLocalizedTitles(for language: AppLanguage) {
        editMenuItem.title = appLanguageStore.text("Edit", for: language)
        editMenu.title = appLanguageStore.text("Edit", for: language)
        cutItem.title = appLanguageStore.text("Cut", for: language)
        copyItem.title = appLanguageStore.text("Copy", for: language)
        pasteItem.title = appLanguageStore.text("Paste", for: language)
        selectAllItem.title = appLanguageStore.text("Select All", for: language)
    }
}
