import os

/// .error level on purpose: only those records persist, so `log show` finds them after the fact.
enum Log {
    private static let subsystem = "com.sava.MenuBarHider"
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let controller = Logger(subsystem: subsystem, category: "controller")
    static let bridge = Logger(subsystem: subsystem, category: "bridge")
}
