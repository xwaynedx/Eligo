# Eligo Privacy

Last updated: 2026-07-13

Eligo is a local menu bar utility. It does not require an account and does not send browsing data to an Eligo server.

## Data handling

- Eligo does not include analytics, advertising, remote telemetry, or an update-check service.
- Web URLs are passed to the browser destination selected by the user. Eligo does not alter or upload the URL.
- Browser preferences, routing rules, language choice, and recent-browser state are stored in local macOS preferences.
- Browser discovery reads installed application metadata and LaunchServices registrations on the Mac.
- Diagnostic information copied from the About window contains only the app version/build, macOS version, and CPU architecture.

Eligo may write operational messages to the local macOS unified log. URL values used for routing are marked private where they are logged; the chooser displays only a shortened host-oriented representation by default.

## Permissions

Eligo does not request Accessibility, Automation, Contacts, Photos, Location, or other personal-data permissions. Launch at Login uses the macOS Login Items service and may require approval in System Settings.

## Changes

If a future release adds update checks, analytics, accounts, or another network feature, this notice must be updated before that feature is distributed.
