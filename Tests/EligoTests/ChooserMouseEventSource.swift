import AppKit
@testable import Eligo

/// Captures the actual production event-monitor callbacks; no real global input
/// is observed by hidden-window tests. Emission also permits stale callbacks.
final class ChooserMouseEventSource {
    var now: TimeInterval = 100
    var localHandlers: [(NSEvent) -> NSEvent?] = []
    var globalHandlers: [(NSEvent) -> Void] = []
    var masks: [NSEvent.EventTypeMask] = []
    var removed: [Int] = []

    var events: ChooserMouseEvents {
        ChooserMouseEvents(
            addLocal: { mask, handler in
                self.masks.append(mask)
                self.localHandlers.append(handler)
                return self.masks.count
            },
            addGlobal: { mask, handler in
                self.masks.append(mask)
                self.globalHandlers.append(handler)
                return self.masks.count
            },
            remove: { self.removed.append($0 as! Int) }
        )
    }

    @MainActor
    func click(
        _ type: NSEvent.EventType = .leftMouseDown,
        in window: NSWindow? = nil,
        at timestamp: TimeInterval? = nil
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: timestamp ?? now + 1,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        )!
    }
}
