import CoreGraphics
import Foundation

/// The state of the window-server session we are attached to.
///
/// `nonisolated` so error descriptions, which are built wherever the error is
/// caught, can reach it.
nonisolated enum LoginSession {
    /// True while the screen is locked.
    ///
    /// Worth a dedicated check because of how the symptom presents: with the
    /// screen locked, ScreenCaptureKit reports **zero displays** while window
    /// enumeration keeps working normally — measured 2026-07-31, 402 windows and
    /// 0 displays, with a "Display N Shield" window and loginwindow's 30000×30000
    /// surface at the front. Every capture then fails with "no SCDisplay for
    /// display ID N", which reads exactly like the intermittent empty display
    /// list noted during M7 and sends you hunting for a bug in the wrong place.
    ///
    /// That earlier observation is very likely this: it "recovered on its own"
    /// the way a locked screen recovers on its own.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// A line to add to a "no displays" failure, or nil when the session looks
    /// healthy and the failure needs a different explanation.
    static var noDisplaysHint: String? {
        isScreenLocked
            ? "the screen is locked — ScreenCaptureKit reports no displays until it is unlocked"
            : nil
    }
}
