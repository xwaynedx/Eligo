# Eligo Support

## Before reporting a problem

1. Confirm that Eligo is the default browser for HTTP and HTTPS links.
2. Open Settings and rescan browsers.
3. Confirm that at least one browser is enabled.
4. If the issue concerns a Domain Rule, check Routing Scope and the Bypass Destination.
5. If the issue concerns Private mode, identify whether the browser was stopped or already running.

## Include with a report

Open `About Eligo` → `Support Guide` and use `Copy Support Info`. Include that text together with:

- the exact steps to reproduce;
- the source application or file type that opened the link;
- the browser and browser version involved;
- whether the browser was already running;
- relevant screenshots or a short screen recording, if safe to share.

Do not include passwords, session tokens, full URLs containing secrets, or private browsing history in a report.

## Reset

Settings → Browsers → Reset restores Eligo preferences and routing configuration. It does not delete installed browser applications.

If saved routing settings cannot be read after adding equivalent domains such as
`example.com。` and `example.com`, follow the [routing preferences recovery guide](routing-preferences-recovery.md)
before resetting. It explains how to keep the original data, choose between
conflicting destinations and prepare a validated configuration without clearing
unrelated rules.
