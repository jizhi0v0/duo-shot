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

    /// The overlay's own panels, which must never be pickable. Set by
    /// `OverlayController` once its panels exist.
    var excludedWindowIDs: Set<CGWindowID> = []

    /// Smaller than this and it is a shadow helper, a tooltip or a 1×1 spy
    /// window rather than something a user means to capture.
    private let minimumSize = CGSize(width: 40, height: 40)

    /// Whether the picker offers windows at this layer.
    ///
    /// Ordinary app windows run from 0 to `.modalPanel` (8), and that range is
    /// not optional: an app's floating panel sits at `.floating` (3) — a
    /// translator popup, an inspector palette, a mini player — and those are
    /// exactly what someone reaches for a window screenshot to capture.
    ///
    /// Then three more, because people screenshot those too: the Dock (20), the
    /// menu bar (24), and the pop-up menu layer (101), where a menu-bar app's
    /// popup panel lives — `MenuBarExtra`'s window style and an `NSPopover`
    /// anchored to a status item both land there. Measured 2026-08-04 on
    /// DuoUpdater: layer 101, alpha 1.00, 510×367, and still on screen at full
    /// opacity with the overlay up, so there was nothing wrong with the panel —
    /// the picker was simply refusing to offer it, and the hover fell through to
    /// the maximized window behind.
    ///
    /// 101 was previously excluded on the grounds that "menus and tooltips live
    /// at 101". Both do, and neither is a reason to keep the layer out: a
    /// tooltip is turned away by `isPickable(size:)`, and an open menu is a
    /// perfectly ordinary screenshot target.
    ///
    /// Deliberately *not* everything in between or above — Notification Center
    /// (21) is a full-screen window that would swallow the display, Control
    /// Center's status items (25) are a couple of dozen 32×30 tiles, and the
    /// levels above 101 are for overlays and help tags. Negative layers are the
    /// desktop and its icons.
    private func isPickable(layer: Int) -> Bool {
        (0...WindowInfo.topAppLayer).contains(layer)
            || layer == WindowInfo.dockLayer
            || layer == WindowInfo.menuBarLayer
            || layer == WindowInfo.popUpMenuLayer
    }

    /// Below this and it is a shadow helper, a tooltip or a 1×1 spy window.
    ///
    /// Either dimension may be under the minimum as long as the surface is
    /// plainly real, which is what lets the menu bar through: it is 1920×30, so
    /// a height rule excludes it, while Control Center's 32×30 status items —
    /// which must stay out — are two orders of magnitude smaller by area.
    private func isPickable(size frame: CGRect) -> Bool {
        (frame.width >= minimumSize.width && frame.height >= minimumSize.height)
            || frame.width * frame.height >= 20_000
    }

    /// Why a window is not offered to the picker, or nil if it is.
    ///
    /// A predicate that explains itself, rather than a chain of `guard`s: every
    /// one of these rules can drop the window the user is actually pointing at,
    /// and when that happens the hit-test falls through to whatever is behind it —
    /// typically a maximized window, so the highlight becomes a full-screen band
    /// and the pick looks broken. The reason string is what makes that
    /// diagnosable after the fact instead of a guessing game.
    func rejectionReason(for window: WindowInfo) -> String? {
        // The overlay's own panels would sit topmost over everything and make the
        // picker useless. They are normally invisible to the enumeration anyway
        // (sharingType = .none), so this is a second line of defence.
        //
        // By window ID, not by bundle: excluding everything DuoShot owns also
        // excluded its Settings window, which is an ordinary window a user has
        // every reason to want a screenshot of — and which is nothing like an
        // overlay panel. Reported 2026-07-30.
        if excludedWindowIDs.contains(window.id) { return "overlay panel" }
        // Stage Manager parks windows that are `isActive` but not on screen;
        // they are not pickable because they are not visible.
        if !window.isOnScreen { return "isOnScreen == false" }
        // And `isOnScreen` is not the whole of "visible": a window can be on
        // screen at zero opacity, which several menu-bar utilities keep parked
        // over the display. Measured on DuoPaste — alpha 0.000, 701×596, ranked
        // in front of Claude, and offered by the picker as though it were there.
        // You cannot be pointing at something you cannot see.
        if window.alpha < 0.05 { return "invisible (alpha \(window.alpha))" }
        if !isPickable(layer: window.layer) { return "layer \(window.layer)" }
        // The Dock's window is the whole screen, so it is only usable once
        // `ScreenIndex` has told us where the dock itself actually is. An
        // auto-hidden Dock reserves nothing, and offering a full-screen window
        // that hit-tests over everything would be far worse than not offering it.
        if window.layer == WindowInfo.dockLayer, window.visibleFrame == nil {
            return "dock strip unknown"
        }
        if !isPickable(size: window.pickFrame) {
            return "smaller than \(Int(minimumSize.width))×\(Int(minimumSize.height))"
        }
        return nil
    }

    /// Drops a window that is only another window's shadow host.
    ///
    /// A `MenuBarExtra` popup arrives as two windows, and offering both makes
    /// the result a coin toss. Measured 2026-08-05 on DuoUpdater:
    ///
    ///     13817  (1113, 35)  360x217   solid content 214x129
    ///     13818  (1038,-40)  510x367   solid content 361x217
    ///                left 75  right 75  top 75  bottom 75
    ///
    /// The outer window's solid content is the *whole* of the inner window,
    /// border and all, wrapped in another shadow — so picking it frames the
    /// panel in a wide dark surround, and which one the pointer resolved to was
    /// luck. Reported as "sometimes it works, sometimes it doesn't".
    ///
    /// Trimming cannot rescue this: the alpha ladder above shows the outer
    /// window's content is genuinely 361x217, not a transparent margin. Only
    /// declining to offer it makes the outcome the same every time.
    ///
    /// The test is a **uniform** inflation, not mere containment, and that is
    /// the whole safety of the rule: 75 points on all four sides is what a
    /// shadow host looks like, while a document window that happens to enclose
    /// an inspector of the same app has four margins that differ. Same
    /// application and same layer as well, so nothing is dropped on account of
    /// an unrelated window that happens to line up.
    private func shadowHostIDs(among candidates: [WindowInfo]) -> Set<CGWindowID> {
        var hosts: Set<CGWindowID> = []
        for outer in candidates {
            for inner in candidates where inner.id != outer.id {
                guard inner.bundleID == outer.bundleID, inner.layer == outer.layer,
                      Self.isUniformInflation(of: inner.pickFrame, to: outer.pickFrame)
                else { continue }
                hosts.insert(outer.id)
                Log.overlay.debug("""
                    picker dropped \(outer.displayName, privacy: .public) \
                    as a shadow host around window \(inner.id, privacy: .public)
                    """)
                break
            }
        }
        return hosts
    }

    /// Whether `outer` is `inner` grown by the same margin on every side.
    ///
    /// Two points of slack, because the frames come from the window server as
    /// CGFloat and a half-point of rounding on one edge should not decide this.
    private static func isUniformInflation(of inner: CGRect, to outer: CGRect) -> Bool {
        let margins = [inner.minX - outer.minX, outer.maxX - inner.maxX,
                       inner.minY - outer.minY, outer.maxY - inner.maxY]
        guard let smallest = margins.min(), let largest = margins.max() else { return false }
        // Strictly bigger on every side: equal frames are not a host, and a
        // window sticking out on one edge is a different window.
        return smallest > 1 && largest - smallest <= 2
    }

    /// Returns true if the pickable set changed, so a caller re-loading on a
    /// timer can skip the redraw — and the logging — when nothing moved.
    @discardableResult
    func load(_ candidates: [WindowInfo]) -> Bool {
        let previous = windows.map(\.id)
        let hosts = shadowHostIDs(among: candidates.filter { rejectionReason(for: $0) == nil })
        windows = candidates.filter {
            rejectionReason(for: $0) == nil && !hosts.contains($0.id)
        }
        guard windows.map(\.id) != previous else { return false }
        logRejectionsInFront(of: candidates)
        return true
    }

    /// Re-reads the window server's z-order and re-sorts. Returns true if the
    /// order actually moved, so the caller can skip a redraw when it did not.
    ///
    /// The list is enumerated once, when the overlay opens — but the *order* it
    /// captured does not survive the interaction. ⌘-Tab while the picker is up
    /// raises a different app, and the picker went on ranking by what had been
    /// frontmost a moment ago. That is not a cosmetic staleness: with a maximized
    /// window stuck at the head of the list, every point on screen hit-tests to
    /// it, so the highlight freezes into a full-screen band and *nothing else can
    /// be picked at all*. Measured 2026-07-30: 21 seconds inside the picker, one
    /// single hover change logged.
    ///
    /// Only the order is refreshed, not the frames or the set of windows — those
    /// need an SCK re-enumeration, and neither can change here anyway: the
    /// overlay has the mouse, so no window can be moved or resized behind it.
    @discardableResult
    func reRank() -> Bool {
        let reordered = WindowZOrder.sortedFrontToBack(windows)
        guard reordered.map(\.id) != windows.map(\.id) else { return false }
        windows = reordered
        Log.overlay.debug("""
            picker re-ranked, now fronted by \
            \(reordered.first?.displayName ?? "nothing", privacy: .public)
            """)
        return true
    }

    /// Logs every window the list ranks *in front of* the first pickable one,
    /// with the rule that dropped it.
    ///
    /// Debug level, so it costs nothing until someone asks for it with
    /// `log stream --level debug`. Worth having at all because the picker's state
    /// is invisible after the fact: the highlight is gone by the time anyone
    /// writes anything down, and "it highlighted the wrong window" is otherwise
    /// indistinguishable from "it highlighted the right window, which happens to
    /// be maximized".
    private func logRejectionsInFront(of candidates: [WindowInfo]) {
        Log.overlay.debug("""
            picker loaded \(self.windows.count, privacy: .public) of \
            \(candidates.count, privacy: .public): \
            \(self.windows.prefix(5).map(\.displayName).joined(separator: " | "), privacy: .public)
            """)
        guard let firstKept = windows.first,
              let cut = candidates.firstIndex(where: { $0.id == firstKept.id }), cut > 0
        else { return }
        for window in candidates[..<cut] {
            Log.overlay.debug("""
                picker dropped (in front of \(firstKept.displayName, privacy: .public)): \
                \(window.displayName, privacy: .public) \
                \(self.rejectionReason(for: window) ?? "?", privacy: .public)
                """)
        }
    }

    /// The first frame containing the point is the one the user is looking at —
    /// which holds only because `ShareableContentCache` has already sorted the
    /// list front-to-back. `SCShareableContent.windows` does NOT arrive that way;
    /// see `WindowZOrder` for the measurement and what it broke.
    func updateHover(atAppKitGlobal point: CGPoint) {
        let pointInCGGlobal = DisplayGeometry.flipped(point)
        let match = windows.first { $0.pickFrame.contains(pointInCGGlobal) }
        guard match?.id != hovered?.id else { return }
        hovered = match
        Log.overlay.debug("""
            hover \(pointInCGGlobal.x, privacy: .public),\(pointInCGGlobal.y, privacy: .public) \
            -> \(match?.displayName ?? "nothing", privacy: .public)
            """)
        onChange?()
    }

    /// The hovered window's frame in **AppKit global** points, for drawing.
    var hoveredFrameInAppKitGlobal: CGRect? {
        hovered.map { DisplayGeometry.flipped($0.pickFrame) }
    }

    func reset() {
        hovered = nil
        onChange?()
    }
}
