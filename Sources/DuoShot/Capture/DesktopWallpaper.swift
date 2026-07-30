import AppKit
import ScreenCaptureKit

/// The desktop wallpaper of a display, as the window server actually renders it.
///
/// Not `NSWorkspace.desktopImageURL(for:)`, which hands back the wallpaper *file*:
/// a dynamic `.heic` is a bundle of variants with no indication of which one is
/// showing, an aerial wallpaper is not a still image at all, and neither is
/// scaled or cropped the way the display is. Excluding every running application
/// from a display filter leaves exactly the wallpaper, already composited, at the
/// display's own scale — no file formats, no special cases.
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

    func image(for displayID: CGDirectDisplayID, filter: SCContentFilter) async -> CGImage? {
        if let entry = cache[displayID], entry.taken.duration(to: .now) < Self.ttl {
            return entry.image
        }

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

    func invalidate() {
        cache.removeAll()
    }
}
