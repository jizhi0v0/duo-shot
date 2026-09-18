import AppKit
import Darwin

/// The freeze photograph by `CGWindowListCreateImage`: public, but marked
/// `SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)` in the 26.5 and 27.0 SDKs alike —
/// deprecated in 14, impossible to compile against since 15 — and still
/// answering at run time on 26.6 and 27.0. So it is looked up, never linked.
///
/// Wanted for one number: how old the frozen frame is by the time it can be
/// shown, which is how far the screen appears to jump back when the overlay
/// comes up over something moving. Reported 2026-09-11 as "在 2 处按了快捷键，
/// 但是从 3->2 然后冻结". Measured with a red panel sliding at 1000 pt/s as the
/// clock, 15 full-resolution shots each; "old on arrival" is return time minus
/// the moment the picture shows:
///
///                                              here (27.0)   mini (26.6)
///     SCScreenshotManager.captureScreenshot       50 ms         66 ms
///     CGWindowListCreateImage                     32 ms         42 ms
///
/// The ScreenCaptureKit call waits for the next frame; this one hands back the
/// last one composited.
///
/// **Not the same pixels.** On a still screen, two ScreenCaptureKit shots in a
/// row differed in 0.16% of pixels, all where something was moving; this call
/// against either differed in 0.6%, across 58 of 160 grid cells, the busiest in
/// the menu bar. Taken anyway, as a deliberate trade — so a screenshot taken
/// with freeze on can differ slightly from one taken with it off.
///
/// **It cannot leave a window out by ID**, only skip windows that decline
/// capture (`sharingType = .none`). So for the length of the photograph it has
/// our own excluded windows decline, and puts them back. Those are the preview
/// cards, which with "Show the selection UI to screen sharing" on do not decline
/// by themselves — and with one up, this used to give up and hand the freeze to
/// ScreenCaptureKit. Recorded 2026-09-12 00:23:48: that capture took 448 ms,
/// the window positions were read after it, and the outline landed 610 pt from
/// the window in the picture. A window to exclude that is not ours cannot be
/// hidden: nil then, and the caller falls back. Nil too if the call is gone.
enum LegacyDisplayCapture {
    private typealias WindowListCreateImage =
        @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: WindowListCreateImage? =
        // RTLD_DEFAULT, which Swift does not import: every loaded image.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
            .map { unsafeBitCast($0, to: WindowListCreateImage.self) }

    /// How long a window takes to drop out of this call's pictures once it
    /// declines capture. Measured 2026-09-12 on 27.0 and on 26.6 at 60 Hz:
    /// captured at once, the window was still there in 10 of 10; after 4, 8,
    /// 12, 16, 24 or 33 ms it was gone in 20 of 20 at every one. 16 ms is four
    /// times the shortest wait that never failed, and a frame at 60 Hz. Paid
    /// only while one of our excluded windows would otherwise show.
    static let sharingTypeSettles: Duration = .milliseconds(16)

    /// A photograph, and where the window server had every window the moment it
    /// came back.
    struct Photograph {
        let image: CGImage
        /// Read in the same turn the capture call returns, before anything else
        /// can run — `WindowZOrder.placed` puts the picker's outlines here.
        let windows: [CGWindowID: WindowZOrder.Entry]
    }

    /// The whole of `displayID` as last composited, at full resolution, with no
    /// cursor and none of the `excluded` windows — or nil, see above.
    static func photograph(
        display displayID: CGDirectDisplayID, excluding excluded: Set<CGWindowID>
    ) async -> Photograph? {
        guard let createImage else { return nil }
        var ours: [NSWindow] = []
        for id in excluded {
            // Compared as `Int`, never converted to `CGWindowID`: a window
            // without a window-server number reports a negative one, and
            // `CGWindowID(_:)` traps on it. That is how the first version
            // shipped — ⇧⌘A with a preview card up crashed DuoShot
            // (2026-09-12 00:12).
            guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(id) })
            else { return nil }
            ours.append(window)
        }
        let shown = ours.filter { $0.isVisible && $0.sharingType != .none }
        let restore = shown.map { ($0, $0.sharingType) }
        for window in shown { window.sharingType = .none }
        defer { for (window, type) in restore { window.sharingType = type } }
        if !shown.isEmpty { try? await Task.sleep(for: sharingTypeSettles) }
        guard let image = createImage(
            CGDisplayBounds(displayID), CGWindowListOption.optionOnScreenOnly.rawValue,
            kCGNullWindowID, CGWindowImageOption().rawValue
        )?.takeRetainedValue() else { return nil }
        // Before anything that can suspend. Read once this function had
        // returned and its caller had resumed — 21 and 22 ms later — the
        // outlines landed 56 and 53 pt from their windows mid-swipe (recorded
        // 2026-09-12 00:40:39 and 00:41:13; 1 ms later, 0 pt). Read at once, the
        // probe's window matched its photograph to 0.6 pt on average, 6 at worst.
        return Photograph(image: image, windows: WindowZOrder.entries())
    }
}
