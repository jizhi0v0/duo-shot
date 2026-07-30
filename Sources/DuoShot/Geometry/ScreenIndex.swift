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
