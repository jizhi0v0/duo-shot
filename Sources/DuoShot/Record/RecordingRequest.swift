import AVFoundation
import CoreGraphics
import Foundation

/// What to record. Deliberately narrower than `CaptureRequest`: a window moves,
/// resizes and closes while a recording is running, and none of those have a
/// defined answer yet.
nonisolated enum RecordingRequest: Sendable {
    /// Rect is in **AppKit global points**, as with `CaptureRequest.area` — the
    /// engine converts it, so `DisplayGeometry` keeps a single caller.
    case area(displayID: CGDirectDisplayID, rectInAppKitGlobal: CGRect)
    case display(CGDirectDisplayID)

    var kind: String {
        switch self {
        case .area: "area"
        case .display: "display"
        }
    }

    var displayID: CGDirectDisplayID {
        switch self {
        case .area(let id, _), .display(let id): id
        }
    }
}

nonisolated struct RecordingOptions: Sendable {
    /// The opposite default from `CaptureOptions.showsCursor`, on purpose: a
    /// recording with no pointer is unreadable, a screenshot with one is noise.
    var showsCursor = true
    /// ScreenCaptureKit draws its own ring around each click. The SDK notes it
    /// "currently applies when pixelFormat is set to BGRA" — which is the
    /// default and which we therefore leave alone.
    var showsMouseClicks = true
    var capturesSystemAudio = true
    var capturesMicrophone = false
    /// nil means the system default input device.
    var microphoneDeviceID: String?
    /// A ceiling, not a promise: it is applied as `minimumFrameInterval`, which
    /// throttles the *fastest* rate the stream will deliver.
    var frameRate = 60
    var includeMenuBar = true
    /// Our own windows to keep out of the recording — the HUD, and any preview
    /// left over from an earlier capture.
    var excludedWindowIDs: Set<CGWindowID> = []
    var videoCodec: AVVideoCodecType = .h264
    var fileType: AVFileType = .mp4

    static let `default` = RecordingOptions()

    var fileExtension: String {
        switch fileType {
        case .mov: "mov"
        case .m4v: "m4v"
        default: "mp4"
        }
    }
}
