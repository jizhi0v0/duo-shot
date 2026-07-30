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
    /// Windows to keep out of the shot — our own overlay panels, by CGWindowID.
    var excludedWindowIDs: Set<CGWindowID> = []

    static let `default` = CaptureOptions()
}
