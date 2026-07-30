import AppKit
import CoreGraphics

// =============================================================================
// The ONLY file in this project permitted to write a y-flip.
//
// Four coordinate spaces are in play. The suffix convention is enforced by
// convention everywhere else in the codebase:
//
//   …InAppKitGlobal  origin bottom-left of NSScreen.screens[0], +y up,   points
//   …InCGGlobal      origin top-left of the main display,       +y down, points
//   …InDisplayPoints origin top-left of *that* display,         +y down, points
//   …InPixels        pixels
//
// NSScreen.screens[0] is by definition the screen whose frame origin is (0,0) —
// the menu-bar display. Its height is the flip pivot and the only value the
// AppKit<->CG conversion depends on.
// =============================================================================

enum DisplayGeometry {
    /// Height of the AppKit primary screen: the pivot for every y-flip.
    static var flipHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AppKit global (bottom-left, +y up) <-> CG global (top-left, +y down).
    ///
    /// The transform is an involution — the same formula converts both ways.
    ///
    /// Note this uses **maxY**, not minY. Using minY is the classic bug here: it
    /// silently yields a rect offset by exactly its own height, which looks
    /// almost right for small selections and is easy to miss.
    static func flipped(_ rect: CGRect, pivot: CGFloat? = nil) -> CGRect {
        let height = pivot ?? flipHeight
        return CGRect(x: rect.minX, y: height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    static func flipped(_ point: CGPoint, pivot: CGFloat? = nil) -> CGPoint {
        CGPoint(x: point.x, y: (pivot ?? flipHeight) - point.y)
    }

    /// CG global points -> that display's local points.
    ///
    /// `SCScreenshotConfiguration.sourceRect` is documented as "in points in the
    /// display's logical coordinate system", i.e. relative to the filter's
    /// `contentRect`, whose origin is (0,0). This is the step that is easy to
    /// forget and impossible to notice on a single-display machine, where the
    /// display bounds origin is (0,0) and the offset is a no-op.
    static func displayLocal(_ rectInCGGlobal: CGRect, on displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        return rectInCGGlobal.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }

    /// Full pipeline: a rect in AppKit global points -> a `sourceRect` for the
    /// given display.
    ///
    /// Integralised *before* flipping: screen origins are integral in points, so
    /// snapping in global space is equivalent to snapping per-display, and it
    /// avoids half-point sampling blur.
    static func sourceRect(
        fromAppKitGlobal rect: CGRect,
        on displayID: CGDirectDisplayID
    ) -> CGRect {
        displayLocal(flipped(rect.integral), on: displayID)
    }

    /// Pixel dimensions for a points rect at a given scale.
    ///
    /// The scale must come from `SCContentFilter.pointPixelScale`, not
    /// `NSScreen.backingScaleFactor`: the former is what SCK will actually
    /// render at, and it is correct per-display on mixed-DPI setups.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }
}
