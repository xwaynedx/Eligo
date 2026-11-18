import AppKit
import Combine
import ServiceManagement
import SwiftUI
import XCTest
@testable import Eligo

@MainActor
final class BrowserSettingsIntegrationTests: XCTestCase {
    func testQueuedLinksWaitForNativeEditorHandoffAndRecovery() async throws {
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }

        for (editingScope, outcome) in [(false, "save"), (true, "cancel"), (false, "close"), (true, "recovery")] {
            let fixture = try BrowserSettingsFixture()
            defer { fixture.cleanup() }
            let settings = SettingsWindowController(
                browserRepository: fixture.repository, routingPreferencesStore: fixture.routing,
                appLanguageStore: fixture.language, launchAtLoginController: LaunchAtLoginController(service: fixture.launchService),
                defaultBrowserController: DefaultBrowserController(manager: fixture.defaultHandlers, bundleIdentifier: "test.eligo"),
                applicationPresentationController: ApplicationPresentationController(application: BrowserTestApplication())
            )
            let window = try XCTUnwrap(settings.window)
            settings.show()
            defer { window.close() }

            let rulesSession = settings.domainRuleSessionForTesting
            let scope: ScopeEditorPresentation.Item?
            if editingScope {
                scope = try XCTUnwrap(settings.scopePresentation.begin(
                    store: fixture.routing, editor: fixture.routingSettingsEditor, browserRepository: fixture.repository
                ))
                scope?.session.setMode(.onlyThese)
            } else {
                scope = nil
                settings.selectedSection = .rules
                rulesSession.send(.presentSingleRuleCreate)
            }
            let originalRuleEditor = rulesSession.state.presentation
            try await waitForSettingsUI { window.attachedSheet != nil }
            let originalSheet = try XCTUnwrap(window.attachedSheet)

            var panels: [NSPanel] = []
            let chooser = ChooserWindowController(appLanguageStore: fixture.language, displayPanel: { panels.append($0) })
            let launcher = RecordingDestinationLauncher(results: [true, true])
            let coordinator = LinkRoutingCoordinator(
                browserRepository: fixture.repository, destinationLauncher: launcher, chooser: chooser,
                routingPreferencesStore: fixture.routing, appLanguageStore: fixture.language, onOpenSettings: {},
                onCreateRule: { settings.requestRuleFromChooser(host: $0, destination: $1, completion: $2) }
            )
            let router = URLRouter()
            router.setHandler { coordinator.route($0, completion: $1) }
            let a = IncomingLink(url: try XCTUnwrap(URL(string: "https://first.example/original?x=1#anchor")))
            let b = IncomingLink(url: try XCTUnwrap(URL(string: "https://second.example/next")))

            router.route(a)
            try await waitForSettingsUI { panels.count == 1 }
            let first = try XCTUnwrap(panels.first)
            XCTAssertTrue(first.performKeyEquivalent(with: chooserKeyEvent(
                keyCode: 36, characters: "\r", modifiers: .command, windowNumber: first.windowNumber
            )))
            router.route(b)
            XCTAssertTrue(window.attachedSheet === originalSheet)
            XCTAssertEqual(rulesSession.state.presentation, originalRuleEditor)
            XCTAssertEqual(settings.scopePresentation.item?.id, scope?.id)
            if let scope { XCTAssertEqual(scope.session.mode, .onlyThese) }
            XCTAssertTrue(launcher.openedURLs.isEmpty)
            XCTAssertEqual(panels.count, 1)

            let originalCancel = try await accessibilityElement(in: originalSheet, text: "Cancel")
            XCTAssertTrue(originalCancel.accessibilityPerformPress?() ?? false)
            try await waitForSettingsUI { window.attachedSheet != nil && window.attachedSheet !== originalSheet }
            let handoffSheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertTrue(rulesSession.state.isEditingPendingLink)
            XCTAssertEqual(panels.count, 1)

            // Withdraw the destination on the successful write, before the sheet's dismissal receipt.
            let target = try XCTUnwrap(fixture.repository.enabledBrowsers.first)
            var lostDestination = false
            let subscription = fixture.routing.$settings.dropFirst().sink { _ in
                if outcome == "recovery" {
                    lostDestination = fixture.repository.setEnabled(false, for: target.id).wasAccepted
                }
            }
            defer { subscription.cancel() }
            if outcome == "close" {
                window.close()
            } else {
                let action = try await accessibilityElement(in: handoffSheet, text: outcome == "cancel" ? "Cancel" : "Save and Open")
                XCTAssertTrue(action.accessibilityPerformPress?() ?? false)
            }

            try await waitForSettingsUI { panels.count == 2 }
            let followUp = try XCTUnwrap(panels.last)
            if outcome == "recovery" {
                XCTAssertTrue(lostDestination)
                XCTAssertTrue(launcher.openedURLs.isEmpty)
                let recoveryView = try XCTUnwrap(followUp.contentView)
                let another = try XCTUnwrap(descendants(of: recoveryView).compactMap { $0 as? NSButton }
                    .first { $0.title == "Choose Another Browser" })
                XCTAssertTrue(another.isEnabled)
                another.performClick(nil)
                try await waitForSettingsUI { panels.count == 3 }
            }
            if outcome != "save" {
                XCTAssertTrue(launcher.openedURLs.isEmpty)
                let resumed = try XCTUnwrap(panels.last)
                resumed.sendEvent(chooserKeyEvent(keyCode: 36, characters: "\r", windowNumber: resumed.windowNumber))
                try await waitForSettingsUI { panels.count == (outcome == "recovery" ? 4 : 3) }
            }
            XCTAssertEqual(launcher.openedURLs, [a.url])
            let second = try XCTUnwrap(panels.last)
            second.sendEvent(chooserKeyEvent(keyCode: 36, characters: "\r", windowNumber: second.windowNumber))
            XCTAssertEqual(launcher.openedURLs, [a.url, b.url])
            XCTAssertEqual(fixture.routing.settings.rules.map(\.matcher.normalizedHost),
                           ["save", "recovery"].contains(outcome) ? ["first.example"] : [])
        }
    }

    func testGeneralRendersBrowserRepairWhenNoBrowserIsEnabled() async throws {
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let configured = fixture.repository.browsers.map { ConfiguredBrowser(browser: $0.browser, isEnabled: false) }
        try fixture.preferences.save(configured)
        fixture.defaultHandlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
        let controller = SettingsWindowController(
            browserRepository: fixture.repository, routingPreferencesStore: fixture.routing,
            appLanguageStore: fixture.language, launchAtLoginController: LaunchAtLoginController(service: fixture.launchService),
            defaultBrowserController: DefaultBrowserController(manager: fixture.defaultHandlers, bundleIdentifier: "test.eligo"),
            applicationPresentationController: ApplicationPresentationController(application: BrowserTestApplication())
        )
        controller.show()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        try await waitForSettingsUI {
            self.accessibilityElements(in: window).contains {
                self.accessibilityText(of: $0).contains { $0.contains("Enable at least one") }
            }
        }
        let add = try await accessibilityElement(in: window, text: "Add App")
        XCTAssertEqual(add.isAccessibilityEnabled?(), true)
        XCTAssertTrue(fixture.repository.enabledBrowsers.isEmpty)
    }

    func testUnavailableCustomManagementSupportsRecoveryBothLanguagesRemovalAndReload() async throws {
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }
        let (oldURL, cleanupOld) = try makeApplicationBundle(name: "Unavailable Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
        let (newURL, cleanupNew) = try makeApplicationBundle(name: "Replacement Chrome", bundleIdentifier: "com.google.Chrome", urlSchemes: ["https"])
        defer { cleanupOld(); cleanupNew() }
        let scanner = BrowserScanner(searchRoots: [newURL.deletingLastPathComponent()], registeredApplicationURLs: { [oldURL] })
        let fixture = try BrowserSettingsFixture(scanner: scanner)
        defer { fixture.cleanup() }
        let scanned = Browser(name: "Replacement Chrome", bundleIdentifier: "com.google.Chrome", appURL: newURL, priority: 1)
        let settings = fixture.settings
        settings.browserSettings.onAddBrowser()
        fixture.picker.complete(with: oldURL)
        try fixture.preferences.saveScannedBrowsers([scanned], at: Date())
        try fixture.preferences.saveRecentBrowserIdentifier(scanned.id)
        let id = OpenDestinationID(browserID: scanned.id, mode: .normal)
        try fixture.routing.replace(with: RoutingSettings(
            scope: .onlyThese(matchers: [try DomainMatcher(host: "inside.example", includesSubdomains: false)], bypassDestinationID: id),
            rules: [DomainRule(matcher: try DomainMatcher(host: "inside.example", includesSubdomains: false), destinationID: id)],
            alwaysShowChooser: true
        ))
        let routingBytes = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let executable = oldURL.appendingPathComponent("Contents/MacOS/TestExecutable")
        let executableData = try Data(contentsOf: executable)
        try FileManager.default.removeItem(at: executable)
        let controller = SettingsWindowController(
            browserRepository: fixture.repository, routingPreferencesStore: fixture.routing,
            appLanguageStore: fixture.language, launchAtLoginController: LaunchAtLoginController(service: fixture.launchService),
            defaultBrowserController: DefaultBrowserController(manager: fixture.defaultHandlers, bundleIdentifier: "test.eligo"),
            applicationPresentationController: ApplicationPresentationController(application: BrowserTestApplication())
        )
        controller.selectedSection = .browsers
        controller.show()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        try await waitForSettingsUI { !fixture.repository.isScanning }
        XCTAssertEqual(fixture.repository.unavailableCustomBrowsers.map(\.appURL), [oldURL])
        XCTAssertEqual(fixture.repository.enabledBrowsers.map { $0.appURL.resolvingSymlinksInPath() }, [newURL.resolvingSymlinksInPath()])
        _ = try await accessibilityElement(in: window, text: "Unavailable Custom Apps")
        _ = try await accessibilityElement(in: window, text: oldURL.path)

        // File restoration becomes visible only at the next named checkpoint.
        try executableData.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(fixture.repository.unavailableCustomBrowsers.isEmpty)
        controller.selectedSection = .general
        try await waitForSettingsUI {
            !self.accessibilityElements(in: window).contains { self.accessibilityText(of: $0).contains("Unavailable Custom Apps") }
        }
        XCTAssertFalse(fixture.repository.unavailableCustomBrowsers.isEmpty)
        controller.selectedSection = .browsers
        try await waitForSettingsUI { fixture.repository.unavailableCustomBrowsers.isEmpty }
        XCTAssertEqual(fixture.repository.enabledBrowsers.first?.appURL, oldURL)
        try FileManager.default.removeItem(at: executable)
        XCTAssertTrue(fixture.repository.unavailableCustomBrowsers.isEmpty)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        try await waitForSettingsUI { !fixture.repository.isScanning && !fixture.repository.unavailableCustomBrowsers.isEmpty }

        for language in [AppLanguage.english, .simplifiedChinese] {
            fixture.language.select(language)
            let title = language == .english ? "Unavailable Custom Apps" : "不可用的自定义应用"
            _ = try await accessibilityElement(in: window, text: title)
            let removeLabel = language == .english
                ? "Remove unavailable custom app Unavailable Chrome (com.google.Chrome)"
                : "移除不可用的自定义应用 Unavailable Chrome（com.google.Chrome）"
            let remove = try await accessibilityElement(in: window, text: removeLabel)
            let before = fixture.defaults.data(forKey: BrowserPreferences.storageKey)
            XCTAssertTrue(remove.accessibilityPerformPress?() ?? false)
            try await waitForSettingsUI { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let message = language == .english
                ? "The unavailable custom entry for Unavailable Chrome will be removed. Browser order, enabled states, Recent Browser, and routing settings are kept."
                : "将移除 Unavailable Chrome 的不可用自定义记录。浏览器排序、启用状态、最近使用的浏览器和路由设置会保留。"
            _ = try await accessibilityElement(in: sheet, text: message)
            if language == .english {
                let cancelCell = try XCTUnwrap(sheet.accessibilityCancelButton() as? NSButtonCell)
                let cancel = try XCTUnwrap(descendants(of: XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.cell === cancelCell })
                cancel.performClick(nil)
                try await waitForSettingsUI { window.attachedSheet == nil }
                XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), before)
                XCTAssertEqual(try fixture.preferences.customBrowsers().count, 1)
            } else {
                let confirm = try XCTUnwrap(descendants(of: XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == fixture.language.text("Remove") })
                confirm.performClick(nil)
                try await waitForSettingsUI { window.attachedSheet == nil }
            }
        }
        XCTAssertTrue(fixture.repository.unavailableCustomBrowsers.isEmpty)
        try await waitForSettingsUI {
            !self.accessibilityElements(in: window).contains { self.accessibilityText(of: $0).contains("不可用的自定义应用") }
        }
        XCTAssertTrue(try fixture.preferences.customBrowsers().isEmpty)
        XCTAssertEqual(fixture.repository.recentBrowserIdentifier, scanned.id)
        XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), routingBytes)
        XCTAssertNotNil(try fixture.repository.currentNormalDestination(for: id))
        let reloaded = BrowserRepository(scanner: scanner, preferences: BrowserPreferences(userDefaults: fixture.defaults))
        XCTAssertEqual(reloaded.browsers, fixture.repository.browsers)
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testAppDelegateActivationRefreshesRestoredAndMissingInstallations() async throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let (url, remove) = try makeApplicationBundle(name: "Activation", bundleIdentifier: "test.activation", urlSchemes: ["https"])
        defer { remove() }
        XCTAssertNotNil(Browser.application(at: url))
        _ = fixture.repository.addCustomBrowser(appURL: url)
        let executable = url.appendingPathComponent("Contents/MacOS/TestExecutable")
        let data = try Data(contentsOf: executable)
        try FileManager.default.removeItem(at: executable)
        XCTAssertTrue(fixture.repository.unavailableCustomBrowsers.isEmpty)
        let delegate = AppDelegate(
            browserRepository: fixture.repository, routingPreferencesStore: fixture.routing,
            setupGuideStore: SetupGuideStore(userDefaults: fixture.defaults), appLanguageStore: fixture.language,
            launchAtLoginController: LaunchAtLoginController(service: fixture.launchService),
            defaultBrowserController: DefaultBrowserController(manager: fixture.defaultHandlers, bundleIdentifier: "test.eligo"),
            urlRouter: URLRouter(), replyToOpenOrPrint: { _, _ in XCTFail("Activation must not reply to a file event") }
        )
        // Invoke the production delegate event; never launch/register the actual app.
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        await waitForBrowserCondition { !fixture.repository.isScanning }
        XCTAssertEqual(fixture.repository.unavailableCustomBrowsers.map(\.appURL), [url])
        try data.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(fixture.repository.unavailableCustomBrowsers.isEmpty)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(fixture.repository.unavailableCustomBrowsers.isEmpty)
        XCTAssertTrue(fixture.repository.enabledBrowsers.contains { $0.appURL == url })
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testMountedSettingsAppearanceAndKeyNotificationRefreshInstallations() async throws {
        _ = NSApplication.shared
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let (url, remove) = try makeApplicationBundle(name: "View Checkpoint", bundleIdentifier: "test.view-checkpoint", urlSchemes: ["https"])
        defer { remove() }
        _ = fixture.repository.addCustomBrowser(appURL: url)
        let executable = url.appendingPathComponent("Contents/MacOS/TestExecutable")
        let data = try Data(contentsOf: executable)
        try FileManager.default.removeItem(at: executable)
        XCTAssertTrue(fixture.repository.unavailableCustomBrowsers.isEmpty)
        let host = NSHostingController(rootView: fixture.settings)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await waitForSettingsUI { !fixture.repository.isScanning && !fixture.repository.unavailableCustomBrowsers.isEmpty }
        try data.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(fixture.repository.unavailableCustomBrowsers.isEmpty)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await waitForSettingsUI { fixture.repository.unavailableCustomBrowsers.isEmpty }
        XCTAssertTrue(fixture.repository.enabledBrowsers.contains { $0.appURL == url })
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testUnavailableAppsWithSameNameHaveDistinctLocalizedAccessibilityLabels() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(wasEnhanced, forAttribute: attribute) }
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        for id in ["test.same.one", "test.same.two"] {
            let (url, remove) = try makeApplicationBundle(name: "Same", bundleIdentifier: id, urlSchemes: ["https"])
            _ = fixture.repository.addCustomBrowser(appURL: url)
            remove()
        }
        fixture.section.section = .browsers
        let window = NSWindow(contentViewController: NSHostingController(rootView: fixture.settings))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await waitForSettingsUI { !fixture.repository.isScanning && fixture.repository.unavailableCustomBrowsers.count == 2 }
        for language in [AppLanguage.english, .simplifiedChinese] {
            fixture.language.select(language)
            for id in ["test.same.one", "test.same.two"] {
                let label = language == .english
                    ? "Remove unavailable custom app Same (\(id))" : "移除不可用的自定义应用 Same（\(id)）"
                _ = try await accessibilityElement(in: window, text: label)
            }
        }
    }

    func testCanceledAddClearsPreviousOperationFeedbackWithoutChangingBrowsers() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        _ = fixture.repository.addCustomBrowser(appURL: URL(fileURLWithPath: "/nonexistent/EligoTest.app"))
        XCTAssertNotNil(settings.browserFeedback.message)
        let browsers = fixture.repository.browsers
        let saved = fixture.defaults.data(forKey: BrowserPreferences.storageKey)

        settings.generalSettings.setupGuide.onAddBrowser()
        XCTAssertNil(settings.browserFeedback.message)
        fixture.picker.complete(with: nil)

        XCTAssertNil(settings.browserFeedback.message)
        XCTAssertEqual(fixture.repository.browsers, browsers)
        XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), saved)
        XCTAssertEqual(fixture.section.section, .general)
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testBothAddAppEntrypointsDisplayValidationAndNamedResultsInCurrentLanguage() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let (unsupported, cleanupUnsupported) = try makeApplicationBundle(
            name: "Notes Test", bundleIdentifier: "test.notes", urlSchemes: nil
        )
        defer { cleanupUnsupported() }
        let (currentApp, cleanupCurrent) = try makeApplicationBundle(
            name: "Eligo Test", bundleIdentifier: LaunchServicesBrowserManager.bundleIdentifier, urlSchemes: ["http"]
        )
        defer { cleanupCurrent() }
        let (browser, cleanupBrowser) = try makeApplicationBundle(
            name: "Browser 名称", bundleIdentifier: "test.custom", urlSchemes: ["https"]
        )
        defer { cleanupBrowser() }
        let settings = fixture.settings
        let routing = fixture.routing.settings

        for section in [SettingsSection.general, .browsers] {
            fixture.section.section = section
            let add = section == .general
                ? settings.generalSettings.setupGuide.onAddBrowser : settings.browserSettings.onAddBrowser
            let cases: [(url: URL, english: String, chinese: String)] = [
                (unsupported, "That app does not declare support for HTTP or HTTPS links.", "该应用未声明支持 HTTP 或 HTTPS 链接。"),
                (currentApp, "Eligo cannot be added as a browser destination.", "不能将 Eligo 添加为浏览器目标。"),
                (URL(fileURLWithPath: "/nonexistent/EligoTest.app"),
                 "That app could not be added. Choose a valid .app bundle with an executable.",
                 "无法添加该应用。请选择包含可执行文件的有效 .app 应用包。")
            ]
            for testCase in cases {
                let accepted = fixture.repository.browsers
                add()
                fixture.picker.complete(with: testCase.url)
                for language in [AppLanguage.english, .simplifiedChinese, .english] {
                    fixture.language.select(language)
                    XCTAssertEqual(settings.browserFeedback.message, language == .english ? testCase.english : testCase.chinese)
                    XCTAssertEqual(fixture.repository.browsers, accepted)
                    XCTAssertEqual(fixture.section.section, section)
                }
            }
            add()
            // The result uses the language at presentation, even if it changed while picking.
            fixture.language.select(.simplifiedChinese)
            fixture.picker.complete(with: browser)
            XCTAssertEqual(settings.browserFeedback.message, "已添加 Browser 名称。")
            let accepted = fixture.repository.browsers
            let saved = fixture.defaults.data(forKey: BrowserPreferences.storageKey)
            fixture.language.select(.english)
            XCTAssertEqual(settings.browserFeedback.message, "Added Browser 名称.")
            XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), saved)
            add()
            fixture.picker.complete(with: browser)
            XCTAssertEqual(fixture.repository.browsers, accepted)
            XCTAssertEqual(settings.browserFeedback.message, "Added Browser 名称.")
            add()
            fixture.picker.complete(with: nil)
            XCTAssertNil(settings.browserFeedback.message)
            XCTAssertEqual(fixture.repository.browsers, accepted)
        }
        XCTAssertEqual(fixture.routing.settings, routing)
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testLastEnabledBrowserFeedbackChangesLanguageWithoutRepeatingTheRejectedAction() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        XCTAssertTrue(settings.browserSettings.onToggle("com.example.a", false))
        XCTAssertFalse(settings.browserSettings.onToggle("com.example.b", false))
        let accepted = fixture.repository.browsers
        let saved = fixture.defaults.data(forKey: BrowserPreferences.storageKey)

        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            XCTAssertEqual(settings.browserFeedback.message, language == .english
                ? "At least one browser must stay enabled." : "必须至少保留一个已启用的浏览器。")
            XCTAssertEqual(fixture.repository.browsers, accepted)
            XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), saved)
        }
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
    }

    func testCancelingAnAddKeepsUnresolvedPersistenceFeedbackInTheCurrentLanguage() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        fixture.failEncoding = true
        fixture.repository.recordSelection(try XCTUnwrap(fixture.repository.enabledBrowsers.first))
        settings.generalSettings.setupGuide.onAddBrowser()
        fixture.picker.complete(with: nil)
        fixture.language.select(.simplifiedChinese)
        XCTAssertEqual(settings.browserFeedback.message,
                       "链接已打开，但无法记录最近使用的浏览器。 无法保存浏览器配置。此前的设置保持不变，请重试。")
        XCTAssertEqual(fixture.repository.operationFeedback, .recentSaveFailed(.encodingFailed))
    }

    func testRoutingFailureReachesGeneralAndChangesLanguageWithoutSavingAgain() throws {
        let fixture = try BrowserSettingsFixture(routingValue: Data("broken routing".utf8))
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let originalData = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let originalBrowsers = fixture.repository.browsers
        settings.generalSettings.onSetAlwaysShowChooser(true)

        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            XCTAssertEqual(settings.generalSettings.routingMessage, language == .english
                ? "Always Show Chooser could not be updated." : "无法更新“始终显示选择器”。")
            XCTAssertEqual(fixture.routing.settings, .default)
            XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), originalData)
            XCTAssertEqual(fixture.repository.browsers, originalBrowsers)
        }
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)

        settings.routingSettingsEditor.reset()
        XCTAssertNil(settings.generalSettings.routingMessage)
        settings.generalSettings.onSetAlwaysShowChooser(true)
        XCTAssertTrue(fixture.routing.settings.alwaysShowChooser)
        XCTAssertNil(settings.generalSettings.routingMessage)
    }

    func testReplacingSettingsRootWithTheSameOwnersPreservesRoutingFailure() throws {
        let fixture = try BrowserSettingsFixture(routingValue: Data("broken routing".utf8))
        defer { fixture.cleanup() }
        let original = fixture.settings
        original.generalSettings.onSetAlwaysShowChooser(true)
        let saved = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let rebuilt = fixture.settings

        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            let message = language == .english
                ? "Always Show Chooser could not be updated." : "无法更新“始终显示选择器”。"
            XCTAssertEqual(original.generalSettings.routingMessage, message)
            XCTAssertEqual(rebuilt.generalSettings.routingMessage, message)
            XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), saved)
        }
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
    }

    func testScopeSaveOfCorruptRoutingSettingsShowsRepairReasonAndPreservesBytes() throws {
        let fixture = try BrowserSettingsFixture(routingValue: Data("broken routing".utf8))
        defer { fixture.cleanup() }
        let saved = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let session = ScopeEditorSession(store: fixture.routing, editor: fixture.routingSettingsEditor, browserRepository: fixture.repository)
        defer { session.end() }
        XCTAssertFalse(session.save())
        let feedback = try XCTUnwrap(session.saveFeedback)
        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            XCTAssertEqual(feedback.text(using: fixture.language), language == .english
                ? "Saved routing settings could not be read. The original data is preserved. Reset Settings will discard it."
                : "无法读取已保存的路由设置，原始数据已保留。重置设置会丢弃这些数据。")
            XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), saved)
            XCTAssertEqual(fixture.routing.settings, .default)
        }
    }

    func testScopeSystemFailureKeepsDiagnosticDetailsSeparateFromCurrentLanguageSummary() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let feedback = ScopeSaveFeedback(error: NSError(
            domain: "EligoTests.ScopeSave.IO", code: 513,
            userInfo: [NSLocalizedDescriptionKey: "Fixture write permission denied"]
        ))
        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            fixture.language.select(language)
            XCTAssertEqual(feedback.text(using: fixture.language), language == .english
                ? "Routing Scope could not be updated.\nSystem error (EligoTests.ScopeSave.IO, code 513): Fixture write permission denied"
                : "无法更新路由范围。\n系统错误（EligoTests.ScopeSave.IO，代码 513）：Fixture write permission denied")
        }
    }

    func testScopeSaveFailurePresentationRetainsAppReasonAcrossLanguageChanges() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        XCTAssertTrue(settings.setBrowserEnabled("com.example.a", false))
        let session = ScopeEditorSession(store: fixture.routing, editor: fixture.routingSettingsEditor, browserRepository: fixture.repository)
        defer { session.end() }
        session.setMode(.onlyThese)
        session.selectBypassDestination(OpenDestinationID(browserID: "com.example.a", mode: .normal))
        let row = try XCTUnwrap(session.addDomain())
        session.editHost(rowID: row, text: "example.com")
        session.setIncludesSubdomains(rowID: row, enabled: false)
        let expected = [
            "Bypass Destination is no longer available. Choose an enabled normal browser and try again.",
            "Browser configuration could not be read. Resolve the browser settings issue before saving Routing Scope."
        ]
        let chinese = [
            "绕过目标已不可用，请选择已启用的普通浏览器后重试。",
            "无法读取浏览器配置，请先解决浏览器设置问题，再保存路由范围。"
        ]
        for index in expected.indices {
            if index == 1 {
                fixture.defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey)
            }
            let saved = fixture.defaults.data(forKey: BrowserPreferences.storageKey)
            XCTAssertFalse(session.save())
            let feedback = try XCTUnwrap(session.saveFeedback)
            for language in [AppLanguage.english, .simplifiedChinese, .english] {
                fixture.language.select(language)
                XCTAssertEqual(feedback.text(using: fixture.language), language == .english ? expected[index] : chinese[index])
                XCTAssertEqual(fixture.routing.settings, .default)
                XCTAssertEqual(fixture.defaults.data(forKey: BrowserPreferences.storageKey), saved)
            }
        }
        let systemFailure = ScopeSaveFeedback(error: CocoaError(.fileWriteUnknown))
        fixture.language.select(.simplifiedChinese)
        XCTAssertTrue(systemFailure.text(using: fixture.language).hasPrefix("无法更新路由范围。\n系统错误（"))
        fixture.language.select(.english)
        XCTAssertTrue(systemFailure.text(using: fixture.language).hasPrefix("Routing Scope could not be updated.\nSystem error ("))
    }

    func testSingleAndBulkRuleSaveFailuresRelocalizeWithoutRetryOrDiscardingTheEditor() throws {
        let fixture = try BrowserSettingsFixture(routingValue: Data("broken routing".utf8))
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let session = settings.domainRuleSession
        let saved = fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey)
        let browsers = fixture.repository.browsers
        let destination = OpenDestinationID(browserID: "com.example.a", mode: .normal)
        let matchers = [try DomainMatcher(host: "example.com", includesSubdomains: false)]

        for isBulk in [false, true] {
            fixture.language.select(isBulk ? .simplifiedChinese : .english)
            DomainRuleSettingsAdapter.send(isBulk ? .addRulesInBulk : .addRule, to: session)
            var relay = DomainRuleSettingsPresentationRelay()
            _ = relay.synchronize(with: session.state.presentation, rules: [], destinations: settings.availableDestinations)
            let presentationID = try XCTUnwrap(session.state.presentation?.id)
            do {
                switch relay.item {
                case let .single(item):
                    try DomainRuleSettingsAdapter.commitSingle(
                        item: item, draft: RuleEditorDraft(destinationID: destination, host: "example.com"), session: session
                    )
                case let .bulk(item):
                    try DomainRuleSettingsAdapter.commitBulk(
                        item: item, matchers: matchers,
                        destinationID: destination, replaceExisting: false, session: session
                    )
                default: return XCTFail("Expected an active rule editor")
                }
                XCTFail("Expected unreadable routing settings to reject the commit")
            } catch {
                let failure: DomainRuleSettingsDisplayError = error
                let bulkFeedback = DomainRuleBulkFeedback.saveFailed(failure)
                for language in [AppLanguage.english, .simplifiedChinese, .english] {
                    fixture.language.select(language)
                    let message = isBulk ? bulkFeedback.text(using: fixture.language) : failure.text(using: fixture.language)
                    XCTAssertEqual(message, language == .english ? "The rules could not be saved." : "规则保存失败。")
                    XCTAssertEqual(session.state.presentation?.id, presentationID)
                    XCTAssertEqual(fixture.defaults.data(forKey: RoutingPreferencesStore.storageKey), saved)
                    XCTAssertEqual(fixture.repository.browsers, browsers)
                    XCTAssertEqual(fixture.routing.settings, .default)
                }
            }
            _ = session.send(.presentationEnded(id: presentationID))
        }
        let invalidInputs = DomainRuleBulkFeedback.invalidInputs(["bad-input/路径", "??"])
        fixture.language.select(.simplifiedChinese)
        XCTAssertEqual(invalidInputs.text(using: fixture.language), "无法识别：bad-input/路径, ??")
        fixture.language.select(.english)
        XCTAssertEqual(invalidInputs.text(using: fixture.language), "Could not recognize: bad-input/路径, ??")
        XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
    }

    func testNativeToggleAndDropRejectFailedWritesAndRestoreAcceptedRows() throws {
        _ = NSApplication.shared
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let accepted = fixture.repository.browsers
        let coordinator = BrowserTableView.Coordinator(
            browsers: accepted, acceptedBrowsers: { fixture.repository.browsers }, language: .english,
            onToggle: settings.setBrowserEnabled, onMove: settings.moveBrowser,
            onRemoveCustom: settings.requestCustomBrowserRemoval
        )
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        table.addTableColumn(NSTableColumn(identifier: .init("browser")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.tableView = table
        table.reloadData()
        func shortcutTexts() throws -> [String] {
            try coordinator.browsers.indices.map { row in
                let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: row))
                let badge = try XCTUnwrap(descendants(of: cell).first { $0.accessibilityIdentifier() == "browser.shortcut" })
                return try XCTUnwrap(badge.accessibilityValue() as? String)
            }
        }
        XCTAssertEqual(try shortcutTexts(), ["1", "2"])
        let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let toggle = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? NSSwitch }.first)
        fixture.failEncoding = true
        toggle.state = .off
        XCTAssertTrue(toggle.sendAction(toggle.action, to: toggle.target))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(fixture.repository.browsers, accepted)
        XCTAssertEqual(coordinator.browsers, accepted)
        XCTAssertEqual(try shortcutTexts(), ["1", "2"])
        XCTAssertEqual(fixture.repository.operationFeedback, .storageFailure(.encodingFailed))

        let drag = BrowserTestDraggingInfo(browserID: accepted[0].id)
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(drag.draggingPasteboard.string(forType: .string), accepted[0].id)
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: drag, row: 2, dropOperation: .above))
        XCTAssertEqual(coordinator.browsers, accepted)
        XCTAssertEqual(table.numberOfRows, 2)
        fixture.failEncoding = false
        XCTAssertTrue(coordinator.tableView(table, acceptDrop: drag, row: 2, dropOperation: .above))
        XCTAssertEqual(coordinator.browsers.map(\.id), accepted.reversed().map(\.id))
        XCTAssertEqual(coordinator.browsers, fixture.repository.browsers)
        XCTAssertEqual(try shortcutTexts(), ["1", "2"])

        let reorderedCell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let reorderedToggle = try XCTUnwrap(descendants(of: reorderedCell).compactMap { $0 as? NSSwitch }.first)
        reorderedToggle.state = .off
        XCTAssertTrue(reorderedToggle.sendAction(reorderedToggle.action, to: reorderedToggle.target))
        XCTAssertEqual(try shortcutTexts(), ["", "1"])
        let disabledCell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let disabledToggle = try XCTUnwrap(descendants(of: disabledCell).compactMap { $0 as? NSSwitch }.first)
        disabledToggle.state = .on
        XCTAssertTrue(disabledToggle.sendAction(disabledToggle.action, to: disabledToggle.target))
        XCTAssertEqual(try shortcutTexts(), ["1", "2"])

        fixture.defaults.set(Data("broken".utf8), forKey: BrowserPreferences.storageKey)
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
        XCTAssertTrue(coordinator.browsers.isEmpty)
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testSettingsResetClearsItsEstablishedScopeAndPreservesOtherState() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences
        let custom = makeBrowser(name: "Custom", bundleIdentifier: "com.example.custom", isCustom: true)
        try preferences.saveCustomBrowser(custom)
        try preferences.saveRecentBrowserIdentifier(custom.id)
        fixture.language.select(.simplifiedChinese)
        let guide = SetupGuideStore(userDefaults: fixture.defaults)
        guide.markSetupAutoShown()
        try fixture.routing.replace(with: RoutingSettings(
            scope: .allDomains, rules: [], alwaysShowChooser: true
        ))
        let cached = try preferences.cachedScannedBrowsers()

        fixture.settings.confirmPendingDestructiveAction(.reset)

        XCTAssertTrue(try preferences.customBrowsers().isEmpty)
        XCTAssertNil(try preferences.recentBrowserIdentifier())
        XCTAssertEqual(try preferences.cachedScannedBrowsers(), cached)
        XCTAssertEqual(fixture.routing.settings, .default)
        XCTAssertNil(fixture.defaults.object(forKey: AppLanguageStore.preferencesKey))
        XCTAssertTrue(guide.hasAutoShownSetup)
        XCTAssertEqual(fixture.launchService.mutationCount, 0)
        XCTAssertEqual(fixture.repository.operationFeedback, .settingsReset)
    }

    func testWrongTypeRoutingSettingsShowWarningAndRequireConfirmedFullReset() async throws {
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        // SwiftUI creates its AX tree only after accessibility is enabled for this process.
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }
        let json = #"{"scope":{"kind":"allDomains"},"rules":[],"alwaysShowChooser":true}"#
        let values: [NSObject] = [json as NSString, 42 as NSNumber, ["keep": ["all", "values"]] as NSDictionary]
        let warning = "Saved routing settings could not be read. The original data is preserved. Reset Settings will discard it."

        for value in values {
            let fixture = try BrowserSettingsFixture(routingValue: value)
            defer { fixture.cleanup() }
            let custom = makeBrowser(name: "Custom", bundleIdentifier: "com.example.custom", isCustom: true)
            try fixture.preferences.saveCustomBrowser(custom)
            let cached = try fixture.preferences.cachedScannedBrowsers()
            try fixture.preferences.save([
                ConfiguredBrowser(browser: custom, isEnabled: true),
                ConfiguredBrowser(browser: cached[1], isEnabled: true),
                ConfiguredBrowser(browser: cached[0], isEnabled: false)
            ])
            fixture.defaultHandlers.handlers = ["http": "test.eligo", "https": "test.eligo"]
            try fixture.preferences.saveRecentBrowserIdentifier(custom.id)
            fixture.defaults.set(AppLanguage.english.rawValue, forKey: AppLanguageStore.preferencesKey)
            let guide = SetupGuideStore(userDefaults: fixture.defaults)
            guide.markSetupAutoShown()
            fixture.defaults.set(["preserve": 23], forKey: "UnrelatedSetting")
            let original = fixture.persistentDomainSnapshot
            let repository = BrowserRepository(scanner: StubBrowserScanner(result: []), preferences: fixture.preferences)
            XCTAssertEqual(repository.browsers.map(\.id), [custom.id, cached[1].id, cached[0].id])
            let controller = SettingsWindowController(
                browserRepository: repository, routingPreferencesStore: fixture.routing,
                appLanguageStore: fixture.language,
                launchAtLoginController: LaunchAtLoginController(service: fixture.launchService),
                defaultBrowserController: DefaultBrowserController(manager: fixture.defaultHandlers, bundleIdentifier: "test.eligo"),
                applicationPresentationController: ApplicationPresentationController(application: BrowserTestApplication())
            )
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            controller.show()

            _ = try await accessibilityElement(in: window, text: warning)
            XCTAssertFalse(accessibilityElements(in: window).contains { accessibilityText(of: $0).contains("Welcome to Eligo") })
            let reset = try await accessibilityElement(in: window, text: "Reset Settings")
            XCTAssertTrue(reset.accessibilityPerformPress?() ?? false)
            try await waitForSettingsUI { window.attachedSheet != nil }
            let cancelSheet = try XCTUnwrap(window.attachedSheet)
            _ = try await accessibilityElement(in: cancelSheet, text: "Reset Eligo Settings?")
            let cancelCell = try XCTUnwrap(cancelSheet.accessibilityCancelButton() as? NSButtonCell)
            let cancel = try XCTUnwrap(descendants(of: XCTUnwrap(cancelSheet.contentView)).compactMap { $0 as? NSButton }
                .first { $0.cell === cancelCell })
            cancel.performClick(nil)
            try await waitForSettingsUI { window.attachedSheet == nil }

            let chooserToggle = try await accessibilityElement(in: window, text: "Always Show Chooser")
            XCTAssertTrue(chooserToggle.accessibilityPerformPress?() ?? false)
            _ = try await accessibilityElement(in: window, text: "Always Show Chooser could not be updated.")
            XCTAssertEqual(fixture.routing.settings, .default)
            XCTAssertEqual(fixture.persistentDomainSnapshot, original)

            controller.selectedSection = .browsers
            XCTAssertEqual(fixture.persistentDomainSnapshot, original)
            let reloaded = RoutingPreferencesStore(userDefaults: fixture.defaults)
            XCTAssertNotNil(reloaded.configurationIssueMessage)
            XCTAssertThrowsError(try reloaded.replace(with: .default))

            let confirmSheet = try await presentResetConfirmation(in: window)
            _ = try await accessibilityElement(in: confirmSheet, text: PendingDestructiveAction.reset.message(using: fixture.language))
            let confirm = try XCTUnwrap(descendants(of: XCTUnwrap(confirmSheet.contentView)).compactMap { $0 as? NSButton }
                .first { $0.title == "Reset" })
            confirm.performClick(nil)
            try await waitForSettingsUI { window.attachedSheet == nil }

            XCTAssertNil(fixture.defaults.object(forKey: RoutingPreferencesStore.storageKey))
            XCTAssertEqual(fixture.routing.settings, .default)
            XCTAssertNil(fixture.routing.configurationIssueMessage)
            XCTAssertTrue(try fixture.preferences.customBrowsers().isEmpty)
            XCTAssertNil(try fixture.preferences.recentBrowserIdentifier())
            XCTAssertEqual(try fixture.preferences.cachedScannedBrowsers(), cached)
            XCTAssertEqual(try fixture.preferences.apply(to: cached).map(\.id), cached.map(\.id))
            XCTAssertTrue(try fixture.preferences.apply(to: cached).allSatisfy(\.isEnabled))
            XCTAssertNil(fixture.defaults.object(forKey: AppLanguageStore.preferencesKey))
            XCTAssertTrue(guide.hasAutoShownSetup)
            XCTAssertEqual(fixture.defaults.object(forKey: "UnrelatedSetting") as? [String: Int], ["preserve": 23])
            XCTAssertTrue(fixture.defaultHandlers.writes.isEmpty)
            XCTAssertEqual(fixture.launchService.mutationCount, 0)

            let root = try XCTUnwrap(controller.contentViewController as? NSHostingController<SettingsView>).rootView
            XCTAssertNil(root.generalSettings.routingMessage)
            root.generalSettings.onSetAlwaysShowChooser(true)
            XCTAssertTrue(RoutingPreferencesStore(userDefaults: fixture.defaults).settings.alwaysShowChooser)
            XCTAssertNil(root.generalSettings.routingMessage)
        }
    }

    private func presentResetConfirmation(in window: NSWindow) async throws -> NSWindow {
        let reset = try await accessibilityElement(in: window, text: "Reset")
        XCTAssertTrue(reset.accessibilityPerformPress?() ?? false)
        try await waitForSettingsUI { window.attachedSheet != nil }
        return try XCTUnwrap(window.attachedSheet)
    }

    private func accessibilityElement(in window: NSWindow, text: String) async throws -> AnyObject {
        var match: NSObject?
        try await waitForSettingsUI {
            window.contentView?.layoutSubtreeIfNeeded()
            match = self.accessibilityElements(in: window).first {
                self.accessibilityText(of: $0).contains(text)
            }
            return match != nil
        }
        let tree = accessibilityElements(in: window).map {
            "\(type(of: $0)): \(accessibilityText(of: $0))"
        }.joined(separator: "\n")
        return try XCTUnwrap(match, "Missing Settings element: \(text)\n\(tree)")
    }

    private func accessibilityText(of element: NSObject) -> [String] {
        let label = (element as AnyObject).accessibilityLabel?()
        let valueSelector = #selector(NSAccessibilityProtocol.accessibilityValue)
        let value = element.responds(to: valueSelector)
            ? element.perform(valueSelector)?.takeUnretainedValue() as? String : nil
        return [label, value].compactMap { $0 }
    }

    private func accessibilityElements(in root: NSObject) -> [NSObject] {
        var elements: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            elements.append(element)
            for child in (element as AnyObject).accessibilityChildren?() ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
        }
        visit(root)
        return elements
    }

    private func waitForSettingsUI(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Settings UI did not reach the expected state")
    }

    func testFeedbackRendersWithCurrentLanguageAndSurvivesReopeningSettings() throws {
        let fixture = try BrowserSettingsFixture()
        defer { fixture.cleanup() }
        fixture.failEncoding = true
        fixture.repository.recordSelection(try XCTUnwrap(fixture.repository.enabledBrowsers.first))
        // A fresh Settings root consumes the same session-owned feedback.
        let reopened = fixture.settings
        XCTAssertEqual(reopened.browserRepository.operationFeedback, .recentSaveFailed(.encodingFailed))
        let english = try XCTUnwrap(reopened.browserRepository.operationFeedback).text(using: fixture.language)
        fixture.language.select(.simplifiedChinese)
        let chinese = try XCTUnwrap(reopened.browserRepository.operationFeedback).text(using: fixture.language)
        XCTAssertTrue(english.contains("The link opened, but Recent Browser could not be saved."))
        XCTAssertTrue(chinese.contains("链接已打开，但无法记录最近使用的浏览器。"))
        XCTAssertFalse(chinese.contains("The link opened"))
        XCTAssertEqual(reopened.browserRepository.availability, .ready)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class BrowserSettingsFixture {
    private let suiteName = "EligoTests.BrowserSettings.\(UUID().uuidString)"
    let defaults: UserDefaults
    let cleanup: () -> Void
    let preferences: BrowserPreferences
    let repository: BrowserRepository
    let routing: RoutingPreferencesStore
    let routingSettingsEditor: RoutingSettingsEditor
    let language: AppLanguageStore
    let launchService = BrowserTestLaunchService()
    let picker = BrowserTestAppPicker()
    let section = SettingsSectionSelection()
    let defaultHandlers = ControlledDefaultBrowserHandlers()
    private let encoder = BrowserTestEncoder()
    var failEncoding: Bool {
        get { encoder.fail }
        set { encoder.fail = newValue }
    }

    var persistentDomainSnapshot: NSDictionary {
        NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
    }

    init(routingValue: Any? = nil, scanner: any BrowserScanning = StubBrowserScanner(result: [])) throws {
        (defaults, cleanup) = makeIsolatedUserDefaults(suiteName: suiteName)
        let encoder = encoder
        preferences = BrowserPreferences(userDefaults: defaults, encode: {
            if encoder.fail { throw CocoaError(.fileWriteUnknown) }
            return try JSONEncoder().encode($0)
        })
        let a = makeBrowser(name: "A", bundleIdentifier: "com.example.a")
        let b = makeBrowser(name: "B", bundleIdentifier: "com.example.b")
        try preferences.saveScannedBrowsers([a, b], at: Date())
        repository = BrowserRepository(scanner: scanner, preferences: preferences)
        if let routingValue {
            defaults.set(routingValue, forKey: RoutingPreferencesStore.storageKey)
        }
        routing = RoutingPreferencesStore(userDefaults: defaults)
        routingSettingsEditor = RoutingSettingsEditor(store: routing)
        language = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
    }

    var settings: SettingsView {
        SettingsView(
            browserRepository: repository, routingPreferencesStore: routing,
            routingSettingsEditor: routingSettingsEditor,
            appLanguageStore: language, launchAtLoginController: LaunchAtLoginController(service: launchService),
            defaultBrowserController: DefaultBrowserController(manager: defaultHandlers, bundleIdentifier: "test.eligo"),
            domainRuleSession: DomainRuleSettingsSession(store: routing), sectionSelection: section,
            scopePresentation: ScopeEditorPresentation(),
            browserAppPicker: picker
        )
    }
}

@MainActor
private final class BrowserTestAppPicker: BrowserAppPicking {
    private var completion: (@MainActor @Sendable (URL?) -> Void)?

    func chooseBrowserApp(using store: AppLanguageStore, completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        self.completion = completion
    }

    func complete(with url: URL?) {
        let callback = completion
        completion = nil
        callback?(url)
    }
}

private final class BrowserTestEncoder { var fail = false }
private final class BrowserTestLaunchService: LaunchItemService {
    var status: SMAppService.Status { .enabled }
    var mutationCount = 0
    func register() throws { mutationCount += 1 }
    func unregister() throws { mutationCount += 1 }
}

@MainActor
private final class BrowserTestApplication: ApplicationActivationPolicyControlling {
    func activationPolicy() -> NSApplication.ActivationPolicy { .regular }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool { true }
    func activate() {}
}

@MainActor
private final class BrowserTestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .init("EligoTests.Drop.\(UUID().uuidString)"))
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(browserID: Browser.ID) {
        super.init()
        draggingPasteboard.declareTypes([.string], owner: nil)
        draggingPasteboard.setString(browserID, forType: .string)
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
