# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

## Unreleased

Planned first public release: **0.2.0**, distributed as source code. The release date will be recorded when the version is published.

### License

- Adopted the [Sustainable Use License, Version 1.0](LICENSE), allowing personal and internal business use while restricting distribution to free, non-commercial purposes.

### Features

- Native macOS menu bar app for choosing which browser opens HTTP, HTTPS and local HTML links.
- Domain Rules, Routing Scope and a Bypass Destination for automatic routing, with an Always Show Chooser override.
- Shared rule creation behavior in Settings and the Browser Chooser, with explicit reuse, updates, and scope expansion. Exact and subdomain rules can coexist with different destinations; list editing remains bound to the selected rule.
- The original link is retained while creating a rule from the Browser Chooser and opens once using the final destination after a successful save. Canceling or closing Settings returns to the original link's chooser, while existing editors and later queued links are preserved.
- Browser discovery, ordering, enablement and custom browser apps, with matching numeric shortcuts in Browsers Settings and the Browser Chooser.
- Full-link copying with brief confirmation. Hover or hold Option to preview the full URL in a separate popover; click expand to pin it, select text, and scroll. The host is emphasized in bold, and copying preserves the original URL.
- Typing a digit without Shift opens the corresponding browser's Normal destination. Shift + a number key requests its Private destination. On layouts that require Shift for top-row digits, use the numeric keypad or the arrow keys followed by Return for Normal mode.
- ⌘Return opens the rule editor with the current domain and highlighted destination filled in for review before saving. Return on a focused browser row opens that browser in Normal mode.
- With Always Show Chooser enabled, routing hints appear beside the matching Normal / Private destination, identifying the matched domain, browser, and mode, or the out-of-scope default destination. Recent Browser still determines the initial selection.
- Rule search by domain or browser name, browser filters, and inline destination editing. Rules retained for disabled browsers keep their browser names and unavailable labels; destination menus are grouped by Normal and Private mode.
- A chooser width determined by its browser list, independent of link and source-caption length; web titles show the scheme, host and non-default port by default.
- Foreground Normal opening, including selecting a newly opened Firefox Nightly tab, while preserving one URL delivery per request.
- Private destinations for supported browsers, neutral resting Private icons, and distinct hover and keyboard-focus states.
- Link Source captions, with Unknown source for unresolved senders and no source caption for local files.
- English and Simplified Chinese, a first-run setup guide, default-browser setup feedback, optional Launch at Login, and local support information.
- General / Browsers / Rules settings layout. General groups routing settings, language, and Launch at Login, with compact setup status and recovery actions for default-browser, available-browser, or configuration problems.
- Bulk Domain Rule editing, multi-selection and deletion, Routing Scope editing, and recovery guidance for unreadable saved routing preferences.

### Support scope

- Google Chrome, Zen Browser, Helium and stable Firefox have real-device Normal and Private verification under ordinary configurations. Brave and Microsoft Edge have declared Private support awaiting real-device verification.
- Firefox Nightly retains Normal and Private opening but is outside the formal real-device acceptance matrix and carries no stability commitment.
- Private restrictions imposed by browser policies are not detected. A restricted Chromium-based browser may handle a Private request in its Normal session; see the [README](README.md#features).
- No prebuilt application download or update-check service is included in this source release.
