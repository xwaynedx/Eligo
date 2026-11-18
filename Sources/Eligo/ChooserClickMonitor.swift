import AppKit

/// Only the AppKit event registration boundary is replaceable in tests.
struct ChooserMouseEvents {
    var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any? = {
        NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1)
    }
    var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
    }
    var remove: (Any) -> Void = { NSEvent.removeMonitor($0) }
}

/// A focus notification has no user-intent provenance. Observe actual clicks
/// instead, so a browser's delayed window activation cannot discard a URL.
/// The owner drops this observation before completing its presentation.
final class ChooserClickMonitor {
    private let tokens: [Any]
    private let remove: (Any) -> Void

    @MainActor
    init(
        panel: NSPanel,
        events: ChooserMouseEvents,
        startedAt: TimeInterval,
        onOutsideClick: @escaping @MainActor () -> Void
    ) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let local = events.addLocal(mask) { [weak panel] event in
            // NSEvent calls both monitor handlers on the main thread. Menu/control
            // tracking events bypass sendEvent and do not pass through this monitor.
            MainActor.assumeIsolated {
                if let panel, event.timestamp > startedAt, !Self.belongsToChooser(event.window, panel: panel) {
                    onOutsideClick()
                }
            }
            return event // Never swallow the user's click in another Eligo window.
        }
        let global = events.addGlobal(mask) { [weak panel] event in
            MainActor.assumeIsolated {
                // Real event streams can report the chooser's own click through
                // both monitors before a Private button sends its action. Check
                // the target window here too; the monitor source is not enough.
                // Older clicks still cannot dismiss a later presentation.
                if let panel, event.timestamp > startedAt, !Self.belongsToChooser(event.window, panel: panel) {
                    onOutsideClick()
                }
            }
        }
        tokens = [local, global].compactMap { $0 }
        remove = events.remove
        if local == nil || global == nil {
            AppLog.chooser.error("Could not install all chooser outside-click monitors; Escape remains available")
        }
    }

    deinit {
        tokens.forEach(remove)
    }

    @MainActor
    private static func belongsToChooser(_ window: NSWindow?, panel: NSPanel) -> Bool {
        var current = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return false
    }
}
