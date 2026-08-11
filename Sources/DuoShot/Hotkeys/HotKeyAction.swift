import AppKit
import Carbon.HIToolbox

nonisolated enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureLastArea
    case recordArea
    case recordFullscreen
    case captureScrolling
    case captureAreaAnnotate

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window Under Pointer"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureLastArea: "Capture Previous Area"
        case .recordArea: "Record Area"
        case .recordFullscreen: "Record Fullscreen"
        case .captureScrolling: "Scrolling Capture"
        case .captureAreaAnnotate: "Capture Area and Annotate"
        }
    }

    /// True for the actions that toggle: pressing the same key while a recording
    /// runs stops it rather than starting a second one. `captureScrolling` also
    /// toggles, but its toggle lives in `ScrollCaptureCoordinator` — this flag
    /// doubles as "routes to `RecordingCoordinator`", which must keep refusing it.
    var isRecording: Bool {
        switch self {
        case .recordArea, .recordFullscreen: true
        case .captureArea, .captureWindow, .captureFullscreen, .captureLastArea,
             .captureScrolling, .captureAreaAnnotate: false
        }
    }

    /// Defaults mirror the user's existing CleanShot X bindings so muscle memory
    /// carries over. ⇧⌘Y was being held for recording and is now claimed; ⇧⌘W
    /// was being held for annotate, which the editor now provides, and is now
    /// claimed too. Reaching the editor used to mean waiting for the card to
    /// settle in a corner and clicking it inside its six-second timeout, which
    /// is a mouse trip paid on every capture that was only ever taken in order
    /// to draw on it.
    var defaultCombo: KeyCombo? {
        switch self {
        case .captureArea:
            KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command])
        case .captureWindow:
            KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.shift, .command])
        case .recordArea:
            KeyCombo(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.shift, .command])
        case .captureScrolling:
            KeyCombo(keyCode: UInt16(kVK_ANSI_L), modifiers: [.shift, .command])
        case .captureAreaAnnotate:
            KeyCombo(keyCode: UInt16(kVK_ANSI_W), modifiers: [.shift, .command])
        case .captureFullscreen, .captureLastArea, .recordFullscreen:
            nil
        }
    }
}
