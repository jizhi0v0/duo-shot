import AppKit
import CoreGraphics

/// Front-to-back window order, straight from the window server.
///
/// **`SCShareableContent.windows` is not z-ordered.** That was assumed here for
/// a while and it is simply false. Measured 2026-07-30 with Claude frontmost:
///
///     SCShareableContent      CGWindowList (front-to-back)
///       0  WeChat               22  Claude
///       1  WeChat               …
///       2  App Store            31  WeChat
///       …                       32  WeChat
///      25  Claude               33  App Store
///
/// The window picker hit-tests by "first frame that contains the point", so with
/// SCK's order it reached past the window the user was looking at and highlighted
/// App Store from three layers behind it — the reported symptom exactly.
///
/// `CGWindowListCopyWindowInfo` *is* documented to return windows in front-to-back
/// order, and it needs no Screen Recording grant: it reads window geometry, not
/// pixels. So it costs nothing to consult and it is the only authority on depth.
enum WindowZOrder {
    /// What the window server says about an on-screen window.
    struct Entry: Sendable {
        /// 0 is frontmost.
        let depth: Int
        /// The window's own opacity, which ScreenCaptureKit does not report at
        /// all. A window can be `isOnScreen` and completely invisible.
        let alpha: Double
    }

    /// `CGWindowID` -> what the window server knows about it.
    static func entries() -> [CGWindowID: Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var entries: [CGWindowID: Entry] = [:]
        entries.reserveCapacity(list.count)
        for (depth, entry) in list.enumerated() {
            // Bridged CFNumber: it arrives as NSNumber, so a direct
            // `as? CGWindowID` (UInt32) cast fails and would silently drop every
            // window, leaving the order untouched.
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            entries[CGWindowID(number.uint32Value)] = Entry(depth: depth, alpha: alpha)
        }
        return entries
    }

    /// Sorts front-to-back.
    ///
    /// Windows the window server did not list keep their relative input order and
    /// go behind everything it did list: an unknown depth is not a reason to
    /// reshuffle, and `sorted(by:)` is not stable, hence the index tiebreak.
    static func sortedFrontToBack(
        _ windows: [WindowInfo], using entries: [CGWindowID: Entry]? = nil
    ) -> [WindowInfo] {
        let entries = entries ?? Self.entries()
        guard !entries.isEmpty else { return windows }
        return windows.enumerated().sorted { lhs, rhs in
            let left = entries[lhs.element.id]?.depth ?? Int.max
            let right = entries[rhs.element.id]?.depth ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}
