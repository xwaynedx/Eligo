import AppKit

@main
struct NSWorkspaceFixture {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = FixtureDelegate()
        application.delegate = delegate
        // A crashed test host must not leave a resident fixture behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { application.terminate(nil) }
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let record: [String: Any] = [
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "launchID": UUID().uuidString,
            "bundleIdentifier": Bundle.main.bundleIdentifier!,
            "arguments": Array(ProcessInfo.processInfo.arguments.dropFirst())
        ]
        let records = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("records", isDirectory: true)
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(
                to: records.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json"),
                options: .atomic
            )
        } catch {
            FileHandle.standardError.write(Data("NSWorkspace fixture could not record launch: \(error)\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }
}
