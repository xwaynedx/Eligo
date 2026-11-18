import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english
    case simplifiedChinese

    var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let preferencesKey = "AppLanguage.v1"

    @Published private(set) var language: AppLanguage
    private let userDefaults: UserDefaults
    private let systemPreferredLanguages: [String]

    /// With no stored preference, use the first supported language in the
    /// system's ordered list (`en` or the `zh` family). Unsupported languages
    /// are skipped; no match falls back to English. Detection never overrides
    /// an explicit choice and is not persisted — only `select()` writes it.
    init(userDefaults: UserDefaults = .standard, systemPreferredLanguages: [String] = Locale.preferredLanguages) {
        self.userDefaults = userDefaults
        self.systemPreferredLanguages = systemPreferredLanguages
        language = AppLanguage(rawValue: userDefaults.string(forKey: Self.preferencesKey) ?? "")
            ?? Self.detectedLanguage(systemPreferredLanguages: systemPreferredLanguages)
    }

    nonisolated static func detectedLanguage(systemPreferredLanguages: [String]) -> AppLanguage {
        for identifier in systemPreferredLanguages {
            // Match the language subtag, not an arbitrary string prefix.
            switch identifier.split(separator: "-", omittingEmptySubsequences: false).first?.lowercased() {
            case "en": return .english
            case "zh": return .simplifiedChinese
            default: continue
            }
        }
        return .english
    }

    func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        userDefaults.set(language.rawValue, forKey: Self.preferencesKey)
    }

    func reset() {
        userDefaults.removeObject(forKey: Self.preferencesKey)
        language = Self.detectedLanguage(systemPreferredLanguages: systemPreferredLanguages)
    }

    func text(_ english: String) -> String {
        text(english, for: language)
    }

    func text(_ english: String, for language: AppLanguage) -> String {
        Self.localizedText(english, for: language)
    }

    nonisolated static func localizedText(_ english: String, for language: AppLanguage) -> String {
        guard language == .simplifiedChinese else { return english }
        return Self.simplifiedChinese[english] ?? english
    }

    func format(_ english: String, _ arguments: CVarArg...) -> String {
        String(format: text(english), arguments: arguments)
    }

    nonisolated private static let simplifiedChinese: [String: String] = [
        "Normal": "普通",
        "The rule destination could not be saved.": "无法保存规则的打开目标，请重试。",
        "Save and Open": "保存并打开",
        "Cancel returns to the chooser.": "取消会返回选择器。",
        "Use Existing Rule and Open": "使用已有规则并打开",
        "Update Rule and Open": "更新规则并打开",
        "Update Existing Rule": "更新已有规则",
        "Expand Rule and Open": "扩展规则并打开",
        "Expand Existing Rule": "扩展现有规则",
        "This rule already exists: %@ → %@. No duplicate will be created.": "该规则已存在：%@ → %@，无需重复创建。",
        "The existing rule for %@ and its subdomains already uses %@. No new rule is needed.": "已有规则将 %@ 及其子域名交给 %@，已覆盖当前范围，无需新增。",
        "A rule with this scope already exists. Update its destination: %@ → %@.": "相同范围的规则已存在，将更新打开目标：%@ → %@。",
        "The existing rule opens only %@ in %@. Expand it to include subdomains.": "已有规则仅将 %@ 交给 %@，将扩展为包含子域名。",
        "Both scopes will be kept. %@ uses %@; its subdomains default to %@. More specific rules take precedence.": "将保留两种范围：%@ 使用 %@；子域名默认使用 %@。更具体的规则优先。",
        "Create rule for this site…": "为此网站创建规则…",
        "Command-Return: create a rule and open this link": "Command-Return：创建规则并打开当前链接",
        "Out-of-scope default destination: %@ (%@)": "范围外默认目标：%@（%@）",
        "Rule target: %@ → %@ (%@)": "规则目标：%@ → %@（%@）",
        "Inspect Full Link (hold Option to preview)": "查看完整链接（按住 Option 预览）",
        "Expanded": "已展开",
        "Full Link": "完整链接",
        "Close": "关闭",
        "Search domains or browsers": "搜索域名或浏览器",
        "Clear search": "清除搜索",
        "Target browser": "目标浏览器",
        "All browsers": "全部浏览器",
        "%@ of %@ rules · %@ selected": "显示 %@ / %@ 条规则 · 已选 %@ 条",
        "No matching rules": "没有匹配的规则",
        "Try another search or browser filter.": "请更换搜索词或浏览器筛选条件。",
        "Destination for %@": "%@ 的打开目标",
        "Eligo is ready": "Eligo 已就绪",
        "Hide setup details": "收起设置状态",
        "View setup status": "查看设置状态",
        "Preferences": "常规偏好",
        "Set Eligo as the default browser and enable at least one browser to get started.": "将 Eligo 设为默认浏览器，并启用至少一个浏览器即可开始使用。",
        "Unavailable Custom Apps": "不可用的自定义应用",
        "Browser discovery timed out. Rescan or add a browser in Settings.": "浏览器发现超时。请重新扫描，或在设置中添加浏览器。",
        "Remove unavailable custom app %@ (%@)": "移除不可用的自定义应用 %@（%@）",
        "The unavailable custom entry for %@ will be removed. Browser order, enabled states, Recent Browser, and routing settings are kept.": "将移除 %@ 的不可用自定义记录。浏览器排序、启用状态、最近使用的浏览器和路由设置会保留。",
        "Retry": "重试",
        "The change is not confirmed. You can retry or choose Eligo in System Settings.": "更改尚未确认。你可以重试，或在系统设置中选择 Eligo。",
        "Automatic setup did not complete. You can retry or choose Eligo in System Settings.": "自动设置未完成。你可以重试，或在系统设置中选择 Eligo。",
        "Automatic setup did not complete. Your default browser settings are unchanged.": "自动设置未完成。默认浏览器设置未改变。",
        "Automatic setup did not complete. Your previous default browser settings were restored.": "自动设置未完成。此前的默认浏览器设置已恢复。",
        "Automatic setup did not complete, and the previous defaults could not be fully restored. Check the current HTTP and HTTPS defaults in System Settings.": "自动设置未完成，且未能完整恢复此前的默认设置。请在系统设置中检查当前 HTTP 和 HTTPS 的默认目标。",
        "Browser Settings Need Repair": "浏览器配置需要修复",
        "Browser settings could not be saved. Your previous settings are unchanged. Try again.": "无法保存浏览器配置。此前的设置保持不变，请重试。",
        "The link opened, but Recent Browser could not be saved.": "链接已打开，但无法记录最近使用的浏览器。",
        "Browser scan was superseded by a settings change. Try again.": "设置变化已使此次浏览器扫描失效，请重试。",
        "Open Settings and confirm Reset to repair browser settings.": "请打开设置并确认重置，以修复浏览器配置。",
        "This clears custom browsers, browser order and enabled states, Recent Browser, Domain Rules, Routing Scope, Bypass Destination, Always Show Chooser, and language preferences. Readable scan results are kept; otherwise browsers are scanned again. Installed apps, the system default browser, Launch at Login, and Welcome Guide history are unchanged.": "这将清除自定义浏览器、浏览器排序及启用状态、最近使用的浏览器、域名规则、路由范围、绕过目标、始终显示选择器及语言偏好。可读取的扫描结果会保留，否则将重新扫描浏览器。已安装应用、系统默认浏览器、登录时启动及欢迎向导展示记录保持不变。",
        "General": "通用",
        "Browsers": "浏览器",
        "Rules": "规则",
        "Language": "语言",
        "Settings section": "设置分区",
        "Choose the language used throughout Eligo. The change takes effect immediately.": "选择 Eligo 全局使用的语言。切换会立即生效。",
        "The rule for %@ will be removed.": "规则 %@ 将被删除。",
        "The selected rule will be removed.": "所选规则将被删除。",
        "Ready": "已就绪",
        "Set Eligo as default": "将 Eligo 设为默认浏览器",
        "Set": "设置",
        "No browsers detected": "未检测到浏览器",
        "%@ detected": "已检测到 %@ 个",
        "%@ detected, %@ available": "已检测到 %@ 个，%@ 个可用",
        "Add App": "添加应用",
        "Enable at least one": "请至少启用一个",
        "%@ available": "%@ 个可用",
        "Eligo": "Eligo",
        "Eligo Settings": "Eligo 设置",
        "About Eligo": "关于 Eligo",
        "Eligo app icon": "Eligo 应用图标",
        "Version %@ (Build %@)": "版本 %@（构建 %@）",
        "A menu bar app that routes links to the browser destination you choose.": "一款位于菜单栏中的应用，可将链接路由到你选择的浏览器目标。",
        "Privacy": "隐私",
        "Eligo does not collect accounts, browsing history, analytics, or remote telemetry. URLs are passed only to the browser you choose, and local preferences stay on this Mac.": "Eligo 不收集账户、浏览历史、分析数据或远程遥测。URL 只会传递给你选择的浏览器，本地偏好设置保留在这台 Mac 上。",
        "Support": "支持",
        "When reporting a problem, include the copied support information and the steps needed to reproduce it.": "报告问题时，请附上复制的支持信息以及能够复现问题的步骤。",
        "Copy Support Info": "复制支持信息",
        "Support Guide": "支持指南",
        "Support info copied.": "支持信息已复制。",
        "Eligo Support": "Eligo 支持",
        "Include the app version, macOS version, steps to reproduce, and the browser involved.": "请提供应用版本、macOS 版本、复现步骤以及涉及的浏览器。",
        "Choose Browser App": "选择浏览器应用",
        "Choose a browser app to show in Eligo.": "选择要在 Eligo 中显示的浏览器应用。",
        "Add": "添加",
        "Reset Eligo Settings?": "重置 Eligo 设置？",
        "Remove %@?": "移除 %@？",
        "Remove": "移除",
        "%@ will be removed from Eligo. The app itself will not be deleted.": "%@ 将从 Eligo 中移除，不会删除应用本身。",
        "Open System Settings": "打开系统设置",
        "In System Settings, choose Eligo as the default web browser for HTTP and HTTPS links.": "请在系统设置中将 Eligo 设为 HTTP 和 HTTPS 链接的默认浏览器。",
        "Add App...": "添加应用…",
        "Rescan": "重新扫描",
        "Reset": "重置",
        "Reset Settings": "重置设置",
        "Looking for browsers…": "正在查找浏览器…",
        "No Browsers Found": "未找到浏览器",
        "Install a supported browser in /Applications or ~/Applications, then rescan.": "请在 /Applications 或 ~/Applications 安装受支持的浏览器，然后重新扫描。",
        "Routing Scope": "路由范围",
        "Routing": "路由",
        "Edit Scope…": "编辑范围…",
        "Always Show Chooser": "始终显示选择器",
        "Always Show Chooser could not be updated.": "无法更新“始终显示选择器”。",
        "Add Rule…": "添加规则…",
        "Add Rules in Bulk…": "批量添加规则…",
        "Add Domain Rules in Bulk": "批量添加域名规则",
        "Paste domains or URLs separated by spaces, commas, or new lines.": "粘贴域名或 URL，可使用空格、逗号或换行分隔。",
        "Enter a host, or an absolute HTTP/HTTPS URL. Paths, queries, fragments, and ports are ignored after extracting the host.": "请输入主机名，或完整的 HTTP/HTTPS URL。提取主机名后会忽略路径、查询、片段和端口。",
        "Replace existing rules for matching domains": "替换相同域名的现有规则",
        "Existing rules are skipped unless replacement is enabled.": "默认跳过现有规则；开启替换后才会覆盖。",
        "Add at least one valid domain.": "请至少添加一个有效域名。",
        "%@ valid domains": "%@ 个有效域名",
        "Skipped %@ duplicate inputs": "已跳过 %@ 个重复输入",
        "No Domain Rules": "没有域名规则",
        "Add a rule to always open a website in a browser.": "添加规则，始终使用指定浏览器打开某个网站。",
        "and subdomains": "及其子域名",
        "Inactive": "未生效",
        "Partially active": "部分生效",
        "Only some matching hosts are within Routing Scope. More specific rules and Always Show Chooser still apply.": "仅部分匹配的主机位于路由范围内。更具体的规则和始终显示选择器仍然适用。",
        "Matching hosts are outside Routing Scope. This rule is kept for future scope changes.": "匹配的主机位于路由范围之外。此规则会保留，以便将来调整范围时使用。",
        "Matching links within Routing Scope follow the most specific rule. Always Show Chooser pauses direct opening.": "路由范围内的匹配链接遵循最具体的规则。始终显示选择器会暂停直接打开。",
        "Open directly": "直接打开",
        "Add Domain to Routing Scope": "将域名加入路由范围",
        "Edit Routing Scope…": "编辑路由范围…",
        "Edit": "编辑",
        "Delete": "删除",
        "Delete Rules": "删除规则",
        "Delete Selected Rules": "删除选中规则",
        "Select rule %@": "选择规则 %@",
        "Clear All Rules": "清空全部规则",
        "Delete selected rules?": "删除选中的规则？",
        "Clear all rules?": "清空全部规则？",
        "This will remove %@ selected rules.": "将移除 %@ 条选中的规则。",
        "This will remove all %@ rules.": "将移除全部 %@ 条规则。",
        "The rules could not be deleted.": "规则删除失败。",
        "Delete Rule": "删除规则",
        "Delete this rule?": "删除此规则？",
        "Setup": "设置",
        "Default Browser": "默认浏览器",
        "Enabled": "已启用",
        "Only enabled browsers appear in the chooser. Changes are saved automatically.": "只有已启用的浏览器会显示在选择器中。更改会自动保存。",
        "All domains": "所有域名",
        "Only these domains": "仅这些域名",
        "All domains except these": "除这些域名外的所有域名",
        "Only matching domains show Eligo rules and the chooser.": "只有匹配的域名会使用 Eligo 规则和选择器。",
        "Matching domains bypass Eligo rules and the chooser.": "匹配的域名会绕过 Eligo 规则和选择器。",
        "Links managed by Eligo": "由 Eligo 管理的链接",
        "Domains": "域名",
        "Added Domains": "已添加域名",
        "Add Domain": "添加域名",
        "Clear All Domains": "清空全部域名",
        "Clear all routing scope domains?": "清空路由范围中的全部域名？",
        "This will remove all %@ domains from the routing scope.": "将从路由范围中移除全部 %@ 个域名。",
        "Remove Domain": "移除域名",
        "Add All Rule Domains": "加入所有规则域名",
        "Could not recognize: %@": "无法识别：%@",
        "No domains added yet.": "尚未添加域名。",
        "Paste Domains…": "粘贴域名…",
        "Paste Domains": "粘贴域名",
        "Added %@ domains": "已添加 %@ 个域名",
        "Added %@ domains, skipped %@ duplicates": "已添加 %@ 个域名，跳过 %@ 个重复项",
        "Removed %@": "已移除 %@",
        "Cleared %@ domains": "已清空 %@ 个域名",
        "Undo": "撤销",
        "Duplicate domain": "域名重复",
        "Resolve the highlighted domain issues before saving.": "请先解决标红的域名问题，再保存。",
        "Include subdomains": "包含子域名",
        "Include subdomains applies only to DNS names. IP addresses always match exactly.": "包含子域名仅适用于 DNS 名称。IP 地址始终精确匹配。",
        "IP addresses cannot include subdomains. Turn off Include subdomains.": "IP 地址不支持子域名，请关闭“包含子域名”。",
        "Bypass Destination": "绕过目标",
        "Bypass Destination is no longer available. Choose an enabled normal browser and try again.": "绕过目标已不可用，请选择已启用的普通浏览器后重试。",
        "Browser configuration could not be read. Resolve the browser settings issue before saving Routing Scope.": "无法读取浏览器配置，请先解决浏览器设置问题，再保存路由范围。",
        "Bypass Destination: %@": "绕过目标：%@",
        "Bypassed links open directly in this normal browser destination.": "被绕过的链接会直接在这个普通浏览器目标中打开。",
        "Cancel": "取消",
        "Save": "保存",
        "Done": "完成",
        "Add Domain Rule": "添加域名规则",
        "Edit Domain Rule": "编辑域名规则",
        "Host": "主机名",
        "Enter a domain such as example.com.": "请输入域名，例如 example.com。",
        "Enter a valid host or an absolute HTTP/HTTPS URL.": "请输入有效的主机名或完整的 HTTP/HTTPS URL。",
        "Open Destination": "打开目标",
        "Choose a destination": "选择目标",
        "Private": "隐私",
        "Private ✓": "隐私 ✓",
        "%@ (Experimental)": "%@（试验）",
        "%@ ✓": "%@ ✓",
        "Private mode": "隐私模式",
        "Privacy mode (Experimental)": "隐私模式（试验）",
        "Open %@ in %@": "以%2$@打开 %1$@",
        "Open in Private mode": "以隐私模式打开",
        "Open in Private mode (Experimental)": "以隐私模式（试验）打开",
        "Add %@ Rule for %@…": "为 %2$@ 添加%1$@规则…",
        "Cut": "剪切",
        "Copy": "复制",
        "Paste": "粘贴",
        "Select All": "全选",
        "Settings": "设置",
        "Rescan Browsers": "重新扫描浏览器",
        "Help Set Default Browser": "帮助设置默认浏览器",
        "Launch at Login": "登录时启动",
        "Keep Eligo available in the menu bar after you sign in.": "登录后让 Eligo 保持在菜单栏中可用。",
        "Open Login Items Settings": "打开登录项设置",
        "macOS requires approval for this login item.": "macOS 需要你批准这个登录项。",
        "Launch at Login is unavailable in this app bundle.": "当前应用包不支持登录时启动。",
        "Could not update Launch at Login.": "无法更新登录时启动。",
        "Quit": "退出",
        "Always Show Chooser is On": "始终显示选择器已开启",
        "Always Show Chooser is Off": "始终显示选择器已关闭",
        "Choose Another Browser": "选择其他浏览器",
        "Try Again": "重试",
        "Open Settings": "打开设置",
        "Unavailable destination": "不可用的目标",
        "%@ (unavailable)": "%@（不可用）",
        "Custom": "自定义",
        "Private supported": "支持隐私模式",
        "Eligo is the default browser for HTTP and HTTPS.": "Eligo 是 HTTP 和 HTTPS 的默认浏览器。",
        "Unknown": "未知",
        "Current default browser: %@": "当前默认浏览器：%@",
        "Current defaults: HTTP %@; HTTPS %@": "当前默认浏览器：HTTP %@；HTTPS %@",
        "No browser apps were found. Rescan or add one in Settings.": "未找到浏览器应用。请重新扫描或在设置中添加浏览器。",
        "Saved destination %@ is unavailable.": "已保存的目标 %@ 不可用。",
        "%@ could not be opened.": "无法打开 %@。",
        "%@ could not be opened in Private mode.": "无法以隐私模式打开 %@。",
        "Enable %@": "启用 %@",
        "No browsers are enabled. Enable %@ to continue.": "没有启用的浏览器。请启用 %@ 以继续。",
        "Saved routing settings could not be read. The original data is preserved. Reset Settings will discard it.": "无法读取已保存的路由设置，原始数据已保留。重置设置会丢弃这些数据。",
        "Saved browser settings could not be read. Reset Settings to repair them.": "无法读取已保存的浏览器设置。请重置设置以修复。",
        "At least one browser must stay enabled.": "必须至少保留一个已启用的浏览器。",
        "That browser is no longer available. Open Settings to rescan and try again.": "该浏览器已不可用。请打开设置，重新扫描后重试。",
        "Routing Scope could not be updated.": "无法更新路由范围。",
        "System error (%@, code %@): %@": "系统错误（%@，代码 %@）：%@",
        "Added %@.": "已添加 %@。",
        "That app could not be added. Choose a valid .app bundle with an executable.": "无法添加该应用。请选择包含可执行文件的有效 .app 应用包。",
        "That app does not declare support for HTTP or HTTPS links.": "该应用未声明支持 HTTP 或 HTTPS 链接。",
        "Eligo cannot be added as a browser destination.": "不能将 Eligo 添加为浏览器目标。",
        "Eligo settings were reset.": "Eligo 设置已重置。",
        "Removed %@ from Eligo.": "已从 Eligo 移除 %@。",
        "Choose a normal Bypass Destination before saving a limited scope.": "保存受限范围前请选择普通模式的绕过目标。",
        "Choose an enabled Open Destination before saving this rule.": "保存此规则前请选择一个已启用的打开目标。",
        "IP addresses cannot include subdomains.": "IP 地址不能包含子域名。",
        "A rule with this domain and subdomain setting already exists.": "已存在域名和子域名设置相同的规则。",
        "This rule no longer exists. Close the editor and try again.": "此规则已不存在。请关闭编辑器后重试。",
        "The rules could not be saved.": "规则保存失败。",
        "This editor is no longer active. Close it and try again.": "此编辑器已失效。请关闭后重试。",
        "Another Domain Rule request is waiting and will open after this editor closes.": "另一个域名规则请求正在等待，将在此编辑器关闭后打开。",
        "Action needed": "需要处理",
        "Selected": "已选择",
        "Not selected": "未选择",
        "Insecure HTTP": "不安全的 HTTP",
        "From %@": "来自 %@",
        "Unknown source": "来源未知",
        "Drag to reorder": "拖动以重新排序",
        "Remove custom browser": "移除自定义浏览器",
        "Enable or disable %@": "启用或停用 %@",
        "Open %@ normally": "以普通模式打开 %@",
        "Add Rule for %@…": "为 %@ 添加规则…",
        "Welcome to Eligo": "欢迎使用 Eligo",
        "Links you click open through Eligo: automatically via domain rules, or by choosing a browser each time. Complete the three steps below to get started.": "你点击的链接都会经由 Eligo 打开：按域名规则自动路由，或每次手动选择浏览器。完成下面三步即可开始使用。",
        "Only links in the Routing Scope use Domain Rules and the chooser.": "只有路由范围内的链接会使用域名规则和选择器。",
        "When off, links within Routing Scope follow Domain Rules, or show the chooser if no rule matches; links outside the scope use the Bypass Destination. When on, every link shows the chooser.": "关闭时，路由范围内的链接按域名规则打开，未匹配的显示选择器；范围外使用绕过目标。开启时，所有链接都显示选择器。",
        "Copy Full Link": "复制完整链接",
        "Link copied": "已复制链接",
        "Chooser shortcut %@": "选择器快捷键 %@",
        "Show Welcome Guide": "显示欢迎引导",
        "Skip": "跳过",
        "Back": "上一步",
        "Next": "下一步",
        "Start Using Eligo": "开始使用",
        "Links you click open through Eligo: automatically via domain rules, or by choosing a browser each time.": "你点击的链接都会经由 Eligo 打开：按域名规则自动路由，或每次手动选择浏览器。",
        "How Eligo Routes Your Links": "Eligo 如何路由链接",
        "Route Automatically": "自动路由",
        "Choose Each Time": "每次选择",
        "Matching links open directly in the destination your rules choose.": "匹配的链接会直接在规则指定的目标中打开。",
        "Every link waits for you to pick a browser.": "每个链接都等你手动选择浏览器。",
        "Link": "链接",
        "Chooser": "选择器",
        "Browser": "浏览器",
        "Make Eligo the Default Browser": "将 Eligo 设为默认浏览器",
        "Set Up Later": "稍后再说",
        "You're All Set": "一切就绪",
        "Ready When You Are": "随时可以继续",
        "Links you click will now open through Eligo.": "你点击的链接现在都会经由 Eligo 打开。",
        "You can finish setup anytime from the menu bar: choose Help Set Default Browser, or open Settings.": "你可以随时完成设置：在菜单栏选择“帮助设置默认浏览器”，或打开设置。",
        "Rules and Routing Scope": "规则与路由范围",
        "Pin a domain to a browser so matching links open there directly. Without rules, every link shows the chooser.": "把域名固定到浏览器，匹配的链接就会直接打开。没有规则时，每个链接都会弹出选择器。",
        "Decide which links Eligo manages. The default covers every domain.": "决定哪些链接由 Eligo 管理，默认管理所有域名。",
        "You can configure both anytime in Settings.": "你可以随时在设置中配置规则和范围。",
        "Add Your First Rule": "添加第一条规则"
    ]
}

/// Localization shorthand shared by views that hold an `AppLanguageStore`.
@MainActor
protocol AppLocalizing {
    var appLanguageStore: AppLanguageStore { get }
}

extension AppLocalizing {
    func t(_ english: String) -> String {
        appLanguageStore.text(english)
    }
}
