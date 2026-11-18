import AppKit

/// Resolves the sender of a GetURL AppleEvent into a `LinkSource`.
///
/// Must run at event-receipt time: senders like `open` or scripts can exit within
/// milliseconds, after which `NSRunningApplication` can no longer resolve the PID.
enum LinkSourceResolver {
    static func source(for event: NSAppleEventDescriptor) -> LinkSource {
        guard let pidDescriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else {
            return .unknown
        }

        let pid = pid_t(pidDescriptor.int32Value)
        guard
            let application = NSRunningApplication(processIdentifier: pid),
            let name = application.localizedName
        else {
            return .unknown
        }

        return .app(AppSender(
            name: name,
            bundleIdentifier: application.bundleIdentifier,
            appURL: application.bundleURL
        ))
    }
}
