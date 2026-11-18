import OSLog

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.xwaynedx.eligo"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let browsers = Logger(subsystem: subsystem, category: "browsers")
    static let routing = Logger(subsystem: subsystem, category: "routing")
    static let chooser = Logger(subsystem: subsystem, category: "chooser")
}
