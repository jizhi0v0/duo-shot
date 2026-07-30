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
