import os

enum Log {
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let permission = Logger(subsystem: subsystem, category: "permission")
    nonisolated static let overlay = Logger(subsystem: subsystem, category: "overlay")
    nonisolated static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    nonisolated static let record = Logger(subsystem: subsystem, category: "record")
    nonisolated static let share = Logger(subsystem: subsystem, category: "share")

    nonisolated static let subsystem = "com.boli.duoshot"
}
