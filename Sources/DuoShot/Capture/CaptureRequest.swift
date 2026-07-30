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
    /// Whether a window capture takes the window's whole group — its sheets and
    /// attached panels — or only the window that was picked.
    ///
    /// Off, because "on" does not mean what the name suggests. With a
    /// `desktopIndependentWindow` filter, ScreenCaptureKit composites the entire
    /// group and then crops to the picked window's rect, so picking a *child*
    /// drags its parent in behind it. Measured 2026-07-30 on WeChat's "Tip"
    /// alert: the file was 560×462, exactly the alert's bounds, with the login
    /// window's title bar and buttons showing through around it. The marching
    /// ants said "this alert" and the pixels said "the whole window", which is
    /// the one thing a selection UI must never do.
    var includeChildWindows = false
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
