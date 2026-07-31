import Foundation
import ScreenCaptureKit

/// Classifies a ScreenCaptureKit failure into something the app can act on.
///
/// The case that matters operationally is `authorisationLost`: macOS 15+ re-asks
/// for Screen Recording roughly monthly, and when the grant lapses SCK does not
/// prompt on our behalf — it just fails. Without routing that back into the
/// permission flow, DuoShot would appear to break for no reason once a month.
nonisolated enum CaptureFailure: Sendable, Equatable {
    case authorisationLost
    case noCaptureSource
    case transient
    case other

    init(_ error: any Error) {
        // Our own errors first. ScreenCaptureKit has been observed returning an
        // empty display list for minutes at a stretch while `screencapture(1)`
        // and the window enumeration both keep working — so "no displays" is a
        // transient to retry through, not a hard failure.
        if let captureError = error as? CaptureError {
            switch captureError {
            case .noDisplays, .displayNotFound, .windowNotFound:
                self = .noCaptureSource
            case .emptyOutput, .noImageProduced, .recordingStartTimedOut:
                self = .transient
            case .encodingFailed:
                self = .other
            }
            return
        }

        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            self = .other
            return
        }
        switch nsError.code {
        case SCStreamError.Code.userDeclined.rawValue,
             SCStreamError.Code.missingEntitlements.rawValue:
            self = .authorisationLost
        case SCStreamError.Code.noCaptureSource.rawValue,
             SCStreamError.Code.noDisplayList.rawValue,
             SCStreamError.Code.noWindowList.rawValue:
            self = .noCaptureSource
        case SCStreamError.Code.internalError.rawValue,
             SCStreamError.Code.failedToStart.rawValue,
             SCStreamError.Code.attemptToStartStreamState.rawValue:
            self = .transient
        default:
            self = .other
        }
    }

    var isRecoverableByRetry: Bool {
        switch self {
        case .transient, .noCaptureSource: true
        case .authorisationLost, .other: false
        }
    }

    var summary: String {
        switch self {
        case .authorisationLost:
            "Screen Recording authorisation has lapsed (macOS re-asks about monthly)"
        case .noCaptureSource:
            "No capture source — the display or window went away"
        case .transient:
            "Transient ScreenCaptureKit failure"
        case .other:
            "Capture failed"
        }
    }
}
