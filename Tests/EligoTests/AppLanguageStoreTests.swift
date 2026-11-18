import Combine
import XCTest
@testable import Eligo

@MainActor
final class AppLanguageStoreTests: XCTestCase {
    func testDefaultsToEnglishAndPersistsSelectedLanguage() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        XCTAssertEqual(store.language, .english)
        XCTAssertEqual(store.text("Settings"), "Settings")

        store.select(.simplifiedChinese)
        XCTAssertEqual(store.text("Settings"), "设置")
        XCTAssertEqual(AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"]).language, .simplifiedChinese)
    }

    func testFormatsTranslatedTemplate() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(store.format("Enable %@", "Firefox"), "启用 Firefox")
        XCTAssertEqual(store.format("%@ valid domains", String(3)), "3 个有效域名")
    }

    func testLanguagePublisherCanRefreshMenuUsingItsEmittedValue() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        var settingsTitle = ""
        let cancellable = store.$language.sink { language in
            settingsTitle = store.text("Settings", for: language)
        }

        store.select(.simplifiedChinese)

        XCTAssertEqual(settingsTitle, "设置")
        _ = cancellable
    }

    func testUsesPrivacyInsteadOfPrivateForSimplifiedChinese() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(store.text("Private"), "隐私")
        XCTAssertEqual(store.text("Private ✓"), "隐私 ✓")
        XCTAssertEqual(store.format("%@ could not be opened in Private mode.", "Dia"), "无法以隐私模式打开 Dia。")
    }

    func testResetRestoresEnglishAndClearsPersistence() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        store.reset()

        XCTAssertEqual(store.language, .english)
        XCTAssertNil(defaults.string(forKey: AppLanguageStore.preferencesKey))
    }

    // MARK: - System language detection (welcome guide)

    func testDetectionUsesTheFirstSupportedLanguageInSystemPreferenceOrder() {
        let cases: [(languages: [String], expected: AppLanguage)] = [
            (["en-US", "zh-Hans-SG"], .english),
            (["zh-Hans", "en-US"], .simplifiedChinese),
            (["fr-FR", "zh-Hans"], .simplifiedChinese),
            (["fr-FR", "en-Latn-GB", "zh-Hant-TW"], .english),
            (["ZH-Hant-HK", "en-SG"], .simplifiedChinese),
            (["english", "zhfake", "enochian", "zh-Hans-CN"], .simplifiedChinese),
            (["zhfake", "fr-FR"], .english),
            ([], .english),
            (["fr-FR", "ja-JP"], .english)
        ]
        for testCase in cases {
            XCTAssertEqual(
                AppLanguageStore.detectedLanguage(systemPreferredLanguages: testCase.languages),
                testCase.expected,
                "System language order: \(testCase.languages)"
            )
        }
    }

    func testOrderedDetectionDoesNotPersistAndResetClearsTheExplicitOverride() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let languages = ["fr-FR", "en-Latn-GB", "zh-Hans-SG"]
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: languages)
        XCTAssertEqual(store.language, .english)
        XCTAssertNil(defaults.string(forKey: AppLanguageStore.preferencesKey))
        store.select(.simplifiedChinese)
        XCTAssertEqual(AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: languages).language, .simplifiedChinese)

        store.reset()

        XCTAssertEqual(store.language, .english)
        XCTAssertNil(defaults.string(forKey: AppLanguageStore.preferencesKey))
        XCTAssertEqual(AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["fr-FR", "zh-Hant-TW", "en-US"]).language,
                       .simplifiedChinese)
    }

    func testFollowsSystemPreferredLanguageWhenNoPreferenceStored() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        XCTAssertEqual(
            AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["zh-Hans-SG", "en-SG"]).language,
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"]).language,
            .english
        )
        XCTAssertEqual(
            AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: []).language,
            .english
        )
    }

    func testDetectionMapsAnyChineseVariantToSimplifiedChinese() {
        XCTAssertEqual(AppLanguageStore.detectedLanguage(systemPreferredLanguages: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguageStore.detectedLanguage(systemPreferredLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguageStore.detectedLanguage(systemPreferredLanguages: ["ja-JP"]), .english)
    }

    func testStoredPreferenceWinsOverSystemDetection() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        // select() only persists a real change, so start from a detected
        // Chinese default and switch away from it.
        AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["zh-Hans-CN"]).select(.english)

        XCTAssertEqual(
            AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["zh-Hans-CN"]).language,
            .english
        )
    }

    func testDetectionIsNotPersisted() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }

        _ = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["zh-Hans-CN"])

        XCTAssertNil(defaults.string(forKey: AppLanguageStore.preferencesKey))
    }

    func testResetReturnsToDetectedSystemLanguage() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["zh-Hans-CN"])
        store.select(.english)

        store.reset()

        XCTAssertEqual(store.language, .simplifiedChinese)
    }

    func testTranslatesReleaseCriticalErrorsAndAccessibilityText() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(store.text("Saved browser settings could not be read. Reset Settings to repair them."), "无法读取已保存的浏览器设置。请重置设置以修复。")
        XCTAssertEqual(store.text("Action needed"), "需要处理")
        XCTAssertEqual(store.text("Selected"), "已选择")
        XCTAssertEqual(store.format("Added %@.", "Safari"), "已添加 Safari。")
        XCTAssertEqual(store.format("Remove %@?", "Safari"), "移除 Safari？")
        XCTAssertEqual(
            DefaultBrowserState(
                observation: .init(http: "com.apple.Safari", https: "com.google.Chrome"),
                bundleIdentifier: "test.eligo"
            ).statusText(using: store),
            "当前默认浏览器：HTTP com.apple.Safari；HTTPS com.google.Chrome"
        )
    }

    func testTranslatesTerminologyAnnotations() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(
            store.text("Only links in the Routing Scope use Domain Rules and the chooser."),
            "只有路由范围内的链接会使用域名规则和选择器。"
        )
        XCTAssertEqual(
            store.text("When off, links within Routing Scope follow Domain Rules, or show the chooser if no rule matches; links outside the scope use the Bypass Destination. When on, every link shows the chooser."),
            "关闭时，路由范围内的链接按域名规则打开，未匹配的显示选择器；范围外使用绕过目标。开启时，所有链接都显示选择器。"
        )
        XCTAssertEqual(store.text("Routing"), "路由")
    }

    func testTranslatesSetupGuideWelcome() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(store.text("Welcome to Eligo"), "欢迎使用 Eligo")
        XCTAssertEqual(
            store.text("Links you click open through Eligo: automatically via domain rules, or by choosing a browser each time. Complete the three steps below to get started."),
            "你点击的链接都会经由 Eligo 打开：按域名规则自动路由，或每次手动选择浏览器。完成下面三步即可开始使用。"
        )
    }

    func testTranslatesDomainRuleAdapterFailuresAndDeferredNotice() {
        let (defaults, cleanup) = makeIsolatedUserDefaults()
        defer { cleanup() }
        let store = AppLanguageStore(userDefaults: defaults, systemPreferredLanguages: ["en-US"])
        store.select(.simplifiedChinese)

        XCTAssertEqual(store.text("IP addresses cannot include subdomains."), "IP 地址不能包含子域名。")
        XCTAssertEqual(
            store.text("A rule with this domain and subdomain setting already exists."),
            "已存在域名和子域名设置相同的规则。"
        )
        XCTAssertEqual(store.text("The rules could not be saved."), "规则保存失败。")
        XCTAssertEqual(
            store.text("This editor is no longer active. Close it and try again."),
            "此编辑器已失效。请关闭后重试。"
        )
        XCTAssertEqual(
            store.text("Another Domain Rule request is waiting and will open after this editor closes."),
            "另一个域名规则请求正在等待，将在此编辑器关闭后打开。"
        )
    }
}
