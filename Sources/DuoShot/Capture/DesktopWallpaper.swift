import AppKit
import ScreenCaptureKit

/// The desktop wallpaper of a display, as the window server actually renders it.
///
/// Not `NSWorkspace.desktopImageURL(for:)`, which hands back the wallpaper *file*:
/// a dynamic `.heic` is a bundle of variants with no indication of which one is
/// showing, an aerial wallpaper is not a still image at all, and neither is
/// scaled or cropped the way the display is. Asking the window server for the
/// windows that draw the wallpaper gets it already composited, at the display's
/// own scale — no file formats, no special cases.
///
/// **This used to exclude every running application instead, and that never
/// worked.** The premise was that what remains is the wallpaper; the wallpaper
/// is drawn by an application too, so excluding them all excluded it as well.
/// Measured 2026-08-05: a completely black 3456×2234 image, every time — which
/// is why the padding around a window capture had always been a flat fill.
/// Worse, when the enumeration momentarily returned no applications the same
/// filter excluded *nothing* and the padding came back as a shrunken photograph
/// of the whole desktop. Reported as "the wallpaper has never worked, and the
/// padding is inconsistent"; one filter, two different wrong answers, held for
/// 30 seconds each by the cache below.
///
/// What actually draws it, measured on the same machine:
///
///     Finder            -2147483603   the desktop *icons*
///     kCGDesktopWindow  -2147483623   <- the line this class draws
///     WindowManager     -2147483624   "Wallpaper"
///     (none)            -2147483626   "Display 1 Backstop"
///
/// So: include the windows at or below `.desktopWindow`, and nothing else. The
/// icons sit *above* that line and stay out, which matters — a backdrop full of
/// the user's desktop clutter is not what anyone means by "the wallpaper" — and
/// they stay out by a documented constant rather than by an application name.
///
/// Cached because it is on the hot path of a window capture: the wallpaper grab
/// is a full-display screenshot (~115 ms measured) against a window capture's
/// ~60 ms, so paying it once per capture would triple the wait for a feature
/// that is pure decoration. The TTL is what keeps a rotating wallpaper honest.
@MainActor
final class DesktopWallpaper {
    private struct Entry {
        let image: CGImage
        let taken: ContinuousClock.Instant
    }

    private var cache: [CGDirectDisplayID: Entry] = [:]

    /// Long enough that a burst of captures pays for one grab, short enough that
    /// macOS's own wallpaper rotation (30 minutes at its fastest normal setting)
    /// can never be what a user notices.
    private static let ttl = Duration.seconds(30)

    /// Everything at or below this is wallpaper; the desktop icons are above it.
    private static let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

    func image(for displayID: CGDirectDisplayID) async -> CGImage? {
        if let entry = cache[displayID], entry.taken.duration(to: .now) < Self.ttl {
            return entry.image
        }

        // Its own enumeration, and the one place in the app that asks for
        // desktop windows: `ShareableContentCache` drops them
        // (`excludingDesktopWindows: true`) because the picker must never offer
        // the desktop, and they are exactly what is wanted here. Only on a cache
        // miss, so at worst once per 30 seconds.
        guard let filter = await Self.filter(for: displayID) else { return nil }

        let configuration = SCScreenshotConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let (width, height) = DisplayGeometry.pixelSize(of: filter.contentRect, scale: scale)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false

        do {
            let output = try await SCKBridge.captureScreenshot(
                filter: filter, configuration: configuration)
            guard let image = output.image else { return nil }
            cache[displayID] = Entry(image: image, taken: .now)
            return image
        } catch {
            // Never fatal: the caller falls back to a flat fill, so a failure
            // here costs the look of the padding and nothing else.
            Log.capture.error("""
                wallpaper capture failed for display \(displayID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    /// The same filter, for the self-test that asserts the menu bar stays out.
    static func filterForTest(for displayID: CGDirectDisplayID) async -> SCContentFilter? {
        await filter(for: displayID)
    }

    /// A filter holding the wallpaper windows of one display and nothing else.
    ///
    /// Nil when the display is gone or when nothing draws a wallpaper on it —
    /// and nil rather than a filter that would capture too much, because the
    /// caller falls back to a flat fill, and a flat fill is a far better wrong
    /// answer than a screenshot of the user's whole desktop.
    private static func filter(for displayID: CGDirectDisplayID) async -> SCContentFilter? {
        guard let content = try? await SCKBridge.shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: true).value,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }

        // Covering the display, because a desktop-level window that does not is
        // something else — a widget, a desktop-pinned utility — and would land
        // in the backdrop as a stray rectangle.
        let wallpaperWindows = content.windows.filter { window in
            window.windowLayer <= desktopLevel
                && window.frame.width >= display.frame.width * 0.9
                && window.frame.height >= display.frame.height * 0.9
        }
        guard !wallpaperWindows.isEmpty else { return nil }

        let filter = SCContentFilter(display: display, including: wallpaperWindows)
        // Defaults to true on some initialisers, and a menu bar across the top
        // of the padding backdrop is the bug this same flag already fixed once
        // on the excluding-applications filter.
        filter.includeMenuBar = false
        return filter
    }

    func invalidate() {
        cache.removeAll()
    }
}
