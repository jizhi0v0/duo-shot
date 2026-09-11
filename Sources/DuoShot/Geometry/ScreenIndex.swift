import AppKit
import CoreGraphics

/// Joins the three ways macOS identifies a display.
///
/// `NSScreen` (AppKit, bottom-left global), `CGDirectDisplayID` (CoreGraphics,
/// top-left global) and `SCDisplay` (ScreenCaptureKit) all describe the same
/// hardware but are not interchangeable. The join key is the display ID, which
/// `NSScreen` hides in `deviceDescription`.
enum ScreenIndex {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[screenNumberKey] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }

    /// The display a point in AppKit global coordinates falls on.
    static func screen(containingAppKitGlobal point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func screenUnderMouse() -> NSScreen? {
        screen(containingAppKitGlobal: NSEvent.mouseLocation) ?? NSScreen.main
    }

    /// The strip the Dock reserves, in **CG global** points, or nil when it is
    /// hidden.
    ///
    /// The Dock's own window is the whole screen — measured 1920×1080 for a
    /// dock 90 pt tall — so its frame says nothing about where it actually is.
    /// What does say is the difference between `frame` and `visibleFrame`: macOS
    /// reserves exactly the Dock's strip out of the latter. The top difference
    /// is the menu bar, never the Dock, so it is not a candidate.
    static func dockStripInCGGlobal() -> CGRect? {
        for screen in NSScreen.screens {
            let full = screen.frame
            let visible = screen.visibleFrame
            let strip: CGRect? =
                if visible.minY > full.minY {
                    CGRect(x: full.minX, y: full.minY,
                           width: full.width, height: visible.minY - full.minY)
                } else if visible.minX > full.minX {
                    CGRect(x: full.minX, y: visible.minY,
                           width: visible.minX - full.minX, height: visible.height)
                } else if visible.maxX < full.maxX {
                    CGRect(x: visible.maxX, y: visible.minY,
                           width: full.maxX - visible.maxX, height: visible.height)
                } else {
                    nil
                }
            // An auto-hidden Dock leaves a few points behind rather than none.
            if let strip, strip.width >= 16, strip.height >= 16 {
                return DisplayGeometry.flipped(strip)
            }
        }
        return nil
    }

    /// The Dock's strip read off where its own window has pixels, for an
    /// auto-hidden Dock that has been revealed: it reserves nothing out of
    /// `visibleFrame`, so `dockStripInCGGlobal` cannot see it.
    ///
    /// Measured 2026-09-11, Dock at the bottom with auto-hide on:
    /// `visibleFrame` was (0,0 1728x1083) hidden and revealed alike. An
    /// isolated capture of the Dock's full-screen window, taken once the reveal
    /// had settled, had pixels at (82,1022 1563x90) — the strip a display
    /// capture of the same instant showed, to a couple of points. Taken the
    /// instant the window appeared, the same capture put them at
    /// (30,480 1667x203), mid-screen: the reveal is animated, and its first
    /// frames are not where the Dock ends up.
    ///
    /// So the drawn rect is believed only against an edge a Dock can live on,
    /// lying along it — wider than tall at the bottom, taller than wide at the
    /// left or right. A Dock floats a few points off its edge (5 pt here),
    /// hence the reach. Anything else is nil, which is what the picker already
    /// does with a Dock it cannot place. All rects CG global.
    nonisolated static func dockStrip(drawn: CGRect, in screen: CGRect) -> CGRect? {
        let reach: CGFloat = 16
        let bottom = drawn.width > drawn.height && screen.maxY - drawn.maxY <= reach
        let left = drawn.height > drawn.width && drawn.minX - screen.minX <= reach
        let right = drawn.height > drawn.width && screen.maxX - drawn.maxX <= reach
        return bottom || left || right ? drawn : nil
    }

    /// Describes a display for logging: both coordinate spaces plus the scale,
    /// because nearly every geometry bug is visible in this one line.
    static func describe(_ screen: NSScreen) -> String {
        let id = displayID(of: screen).map(String.init) ?? "?"
        let appKit = screen.frame
        let cg = displayID(of: screen).map(CGDisplayBounds) ?? .zero
        return String(
            format: "display %@ appkit=(%.0f,%.0f %.0fx%.0f) cg=(%.0f,%.0f %.0fx%.0f) scale=%.1f",
            id,
            appKit.minX, appKit.minY, appKit.width, appKit.height,
            cg.minX, cg.minY, cg.width, cg.height,
            screen.backingScaleFactor
        )
    }
}
