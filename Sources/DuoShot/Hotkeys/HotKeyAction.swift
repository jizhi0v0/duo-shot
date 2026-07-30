import AppKit
import Carbon.HIToolbox

nonisolated enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureLastArea

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureLastArea: "Capture Previous Area"
        }
    }

    /// Defaults mirror the user's existing CleanShot X bindings so muscle memory
    /// carries over. ⇧⌘W and ⇧⌘Y are deliberately left free — they are bound to
    /// annotate and record there, neither of which exists yet, and taking them
    /// now would train the wrong reflex.
    var defaultCombo: KeyCombo? {
        switch self {
        case .captureArea:
            KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command])
        case .captureWindow:
            KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.shift, .command])
        case .captureFullscreen, .captureLastArea:
            nil
        }
    }
}
