import CoreGraphics
import Foundation

nonisolated enum CaptureRequest: Sendable {
    /// Rect is in **AppKit global points** — the engine converts it. Keeping the
    /// conversion inside `CaptureEngine` means `DisplayGeometry` has exactly one
    /// caller for the sourceRect pipeline.
    case area(displayID: CGDirectDisplayID, rectInAppKitGlobal: CGRect)
    case window(CGWindowID)
    case display(CGDirectDisplayID)

    var kind: String {
        switch self {
        case .area: "area"
        case .window: "window"
        case .display: "display"
        }
    }
}

nonisolated struct CaptureOptions: Sendable {
    var showsCursor = false
    var ignoreShadows = true
    var includeChildWindows = true
    var includeMenuBar = true
    /// Margin in points added around a **window** capture, filled with the
    /// desktop wallpaper. Zero disables it.
    ///
    /// Window captures only, deliberately: padding exists to give a window a
    /// backdrop, and an area or fullscreen shot already has one.
    var windowPadding: CGFloat = 0
    /// Windows to keep out of the shot — our own overlay panels, by CGWindowID.
    var excludedWindowIDs: Set<CGWindowID> = []

    static let `default` = CaptureOptions()
}
