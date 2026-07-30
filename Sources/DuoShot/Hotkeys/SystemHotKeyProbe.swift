import AppKit
import Carbon.HIToolbox

/// Read-only detection of shortcuts macOS itself owns.
///
/// The nasty failure mode this exists for: when the system already owns a combo,
/// `RegisterEventHotKey` **succeeds** and then simply never fires. The system
/// wins silently, so the only way to warn the user is to look up the system's
/// own table before they commit to the binding.
///
/// Strictly reads `com.apple.symbolichotkeys`. Nothing here mutates system state
/// — rebinding the OS's shortcuts from an app is fragile and not something to
/// ship.
enum SystemHotKeyProbe {
    /// Human-readable name of the system function bound to `combo`, if any.
    static func systemBinding(matching combo: KeyCombo) -> String? {
        guard
            let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
            let table = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return nil }

        for (rawIdentifier, rawEntry) in table {
            guard
                let identifier = Int(rawIdentifier),
                let entry = rawEntry as? [String: Any],
                entry["enabled"] as? Bool == true,
                let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Any],
                parameters.count >= 3,
                let keyCode = (parameters[1] as? NSNumber)?.intValue,
                // parameters[2] is an **NSEvent.ModifierFlags raw value**, not a
                // Carbon modifier mask. Verified against this machine's own
                // table: entry 28 (⌘⇧3, "picture of screen to file") stores
                // 1179648 == 0x120000 == .command | .shift. Carbon's mask for
                // the same combo would be 0x300. Comparing against
                // `combo.carbonModifiers` here silently never matches, which
                // makes the whole probe — and the conflict warning it feeds —
                // decorative.
                let modifiers = (parameters[2] as? NSNumber)?.uintValue
            else { continue }

            guard keyCode >= 0, UInt16(keyCode) == combo.keyCode else { continue }
            let masked = NSEvent.ModifierFlags(rawValue: modifiers)
                .intersection(.deviceIndependentFlagsMask).rawValue
            guard masked == combo.modifiers else { continue }
            return name(for: identifier)
        }
        return nil
    }

    /// Whether the system's own screenshot shortcuts are currently enabled.
    ///
    /// Worth surfacing: if they are off, ⌘⇧3/4/5 are free for DuoShot to take.
    static var systemScreenshotShortcutsEnabled: Bool {
        guard
            let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
            let table = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return true }
        return [28, 29, 30, 31, 184].contains { identifier in
            (table["\(identifier)"] as? [String: Any])?["enabled"] as? Bool == true
        }
    }

    /// The handful of identifiers a screenshot app is likely to collide with.
    /// Anything else is reported generically rather than guessed at.
    private static func name(for identifier: Int) -> String {
        switch identifier {
        case 28: "Screenshot: picture of screen to file"
        case 29: "Screenshot: picture of screen to clipboard"
        case 30: "Screenshot: picture of selection to file"
        case 31: "Screenshot: picture of selection to clipboard"
        case 184: "Screenshot and recording options"
        case 60: "Select the previous input source"
        case 61: "Select the next input source"
        case 64, 65: "Spotlight"
        case 32, 33, 34, 35: "Mission Control"
        case 36, 37: "Application windows"
        case 79, 80, 81, 82: "Move to a Space"
        case 98: "Help menu"
        case 175: "Notification Centre"
        default: "a system shortcut (id \(identifier))"
        }
    }
}
