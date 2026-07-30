import AppKit

/// Hit-tests the window under the pointer for window-capture mode.
///
/// Works entirely off `WindowInfo` projections, so nothing here touches a live
/// SCK object. `SCWindow.frame` is **CG global** (top-left origin, +y down)
/// while the pointer arrives in AppKit global, hence the flip on every query.
@MainActor
final class WindowPickerModel {
    private(set) var windows: [WindowInfo] = []
    private(set) var hovered: WindowInfo?

    var onChange: (() -> Void)?

    /// Smaller than this and it is a shadow helper, a tooltip or a 1×1 spy
    /// window rather than something a user means to capture.
    private let minimumSize = CGSize(width: 40, height: 40)

    func load(_ candidates: [WindowInfo]) {
        let ownBundleID = Bundle.main.bundleIdentifier
        windows = candidates.filter { window in
            // Our own overlay panels would sit topmost over everything and make
            // the picker useless. They are normally invisible to the enumeration
            // anyway (sharingType = .none), so this is a second line of defence.
            guard window.bundleID != ownBundleID else { return false }
            // Stage Manager parks windows that are `isActive` but not on screen;
            // they are not pickable because they are not visible.
            guard window.isOnScreen else { return false }
            guard window.layer == 0 else { return false }
            return window.frame.width >= minimumSize.width
                && window.frame.height >= minimumSize.height
        }
    }

    /// `SCShareableContent.windows` comes back in front-to-back z-order, so the
    /// first frame containing the point is the one the user is looking at.
    func updateHover(atAppKitGlobal point: CGPoint) {
        let pointInCGGlobal = DisplayGeometry.flipped(point)
        let match = windows.first { $0.frame.contains(pointInCGGlobal) }
        guard match?.id != hovered?.id else { return }
        hovered = match
        onChange?()
    }

    /// The hovered window's frame in **AppKit global** points, for drawing.
    var hoveredFrameInAppKitGlobal: CGRect? {
        hovered.map { DisplayGeometry.flipped($0.frame) }
    }

    func reset() {
        hovered = nil
        onChange?()
    }
}
