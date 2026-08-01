import Foundation
import os

/// The package's own loggers.
///
/// A library has no business borrowing its host's logging enum, and it should
/// not take a logger as a parameter on every call either. `os.Logger` is free
/// when nothing is subscribed, and the subsystem defaults to the embedding app's
/// bundle id so its lines land next to that app's own.
enum LinkdropLog {
    static let upload = Logger(subsystem: subsystem, category: "linkdrop.upload")
    static let keychain = Logger(subsystem: subsystem, category: "linkdrop.keychain")
    static let gate = Logger(subsystem: subsystem, category: "linkdrop.gate")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Linkdrop"
}
