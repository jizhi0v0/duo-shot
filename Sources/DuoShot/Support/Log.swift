import os

enum Log {
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let permission = Logger(subsystem: subsystem, category: "permission")
    nonisolated static let overlay = Logger(subsystem: subsystem, category: "overlay")
    nonisolated static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    nonisolated static let record = Logger(subsystem: subsystem, category: "record")
    nonisolated static let share = Logger(subsystem: subsystem, category: "share")

    /// Deliberately the same string as the Makefile's `BUNDLE_ID`: every log
    /// predicate in the Makefile and in `Scripts/` is built from that variable,
    /// so changing one without the other turns `make logs` into silence -- which
    /// reads as "the app logged nothing" rather than "you asked the wrong
    /// question".
    nonisolated static let subsystem = "com.jizhiovo.duoshot"
}
