# Eligo

Eligo decides whether a web link should open immediately or pass through a chooser, and which browser destination should receive it. These terms are the canonical language for product, code, tests, and documentation.

## Language

**Installed Browser**:
A browser application discovered on the Mac or added by the user.
_Avoid_: Destination, browser option

**Open Destination**:
A selectable way to open a link, combining an Installed Browser with an opening mode such as Normal or Private.
_Avoid_: Browser when the mode matters

**Normal Destination**:
An Open Destination that uses the Installed Browser's ordinary browsing session.
_Avoid_: Default destination

**Private Destination**:
An Open Destination that asks the Installed Browser to open the link in Private mode. Eligo does not retry a failed Private launch in Normal mode. A Chromium-based browser with Private browsing disabled by policy may handle the request in its Normal session. See the [browser support notes](README.md#features) for verification by browser.
_Avoid_: Incognito browser, anonymous destination

**Experimental Private Destination**:
A temporarily exposed Open Destination used for real-app validation before a browser's Private adapter is verified. It must be labelled as experimental and is not part of the verified support promise.
_Avoid_: Supported Private Destination

**Browser Chooser**:
The transient interface in which the user selects an Open Destination for one link.
_Avoid_: Browser list, picker popup

**Link Source**:
The application that sent a link into Eligo, resolved from the open-url event at receipt time and shown as a "From <app>" line in the Browser Chooser and recovery panels. A local file open has no Link Source; a sender that cannot be resolved (for example a short-lived script) is shown as Unknown source.
_Avoid_: Trigger source, sender app

**Routing Scope**:
The set of web domains whose links enter Eligo's domain-rule and chooser flow.
_Avoid_: Whitelist, blacklist, blocked domains

**Bypassed Link**:
A link outside the Routing Scope that opens directly in the Bypass Destination without evaluating Domain Rules.
_Avoid_: Blocked link, ignored link

**Bypass Destination**:
The normal Open Destination used for Bypassed Links.
_Avoid_: System default browser

**Domain Rule**:
A domain matcher that opens an Open Destination directly, unless Always Show Chooser is enabled.
_Avoid_: Routing Scope entry, browser default

**Always Show Chooser**:
A persistent user override that converts every direct-open decision into a Browser Chooser decision. The chooser selects the most recently used browser.
_Avoid_: Ask next time, pause once

**Recent Browser**:
The browser from the most recent successful choice made explicitly in the Browser Chooser. Domain Rule and Bypassed Link opens do not change it. The chooser always selects its Normal destination.
_Avoid_: Recent destination, rule preselection
