import AppKit
import Carbon.HIToolbox

nonisolated enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureLastArea
    case recordArea
    case recordFullscreen

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureLastArea: "Capture Previous Area"
        case .recordArea: "Record Area"
        case .recordFullscreen: "Record Fullscreen"
        }
    }

    /// True for the actions that toggle: pressing the same key while a recording
    /// runs stops it rather than starting a second one.
    var isRecording: Bool {
        switch self {
        case .recordArea, .recordFullscreen: true
        case .captureArea, .captureWindow, .captureFullscreen, .captureLastArea: false
        }
    }

    /// Defaults mirror the user's existing CleanShot X bindings so muscle memory
    /// carries over. ⇧⌘W is still deliberately free — it is bound to annotate
    /// there, which does not exist yet, and taking it now would train the wrong
    /// reflex. ⇧⌘Y was being held for recording and is now claimed.
    var defaultCombo: KeyCombo? {
        switch self {
        case .captureArea:
            KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command])
        case .captureWindow:
            KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.shift, .command])
        case .recordArea:
            KeyCombo(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.shift, .command])
        case .captureFullscreen, .captureLastArea, .recordFullscreen:
            nil
        }
    }
}
