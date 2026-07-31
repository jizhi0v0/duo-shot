import AppKit

/// The selection's state: dragged out, then moved, resized or nudged. All rects
/// are in **AppKit global points**.
///
/// v1 rule: the selection is clamped to the display where the drag started.
/// `sourceRect` is inherently per-filter/per-display, and a rect spanning a 2×
/// and a 1× display has no single correct pixel size — you would have to pick
/// one and resample the other half. CleanShot X has the same restriction.
final class SelectionModel {
    enum Phase {
        case idle
        case dragging
        case settled
    }

    private(set) var phase: Phase = .idle
    private(set) var originDisplayID: CGDirectDisplayID?
    private(set) var pointerInAppKitGlobal: CGPoint?

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var clampFrame: CGRect?

    var onChange: (() -> Void)?

    /// The live selection, or nil when nothing has been dragged yet.
    var rectInAppKitGlobal: CGRect? {
        guard let anchor, let current else { return nil }
        let rect = CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        ).integral
        guard let clampFrame else { return rect }
        let clamped = rect.intersection(clampFrame)
        return clamped.isNull ? nil : clamped
    }

    var isUsable: Bool {
        guard let rect = rectInAppKitGlobal else { return false }
        return rect.width >= 1 && rect.height >= 1
    }

    // MARK: - Pointer

    func pointerMoved(to point: CGPoint) {
        pointerInAppKitGlobal = point
        onChange?()
    }

    func beginDrag(at point: CGPoint, on screen: NSScreen) {
        anchor = point
        current = point
        clampFrame = screen.frame
        originDisplayID = ScreenIndex.displayID(of: screen)
        phase = .dragging
        onChange?()
    }

    func updateDrag(to point: CGPoint) {
        guard phase == .dragging else { return }
        current = point
        pointerInAppKitGlobal = point
        onChange?()
    }

    func endDrag() {
        guard phase == .dragging else { return }
        phase = isUsable ? .settled : .idle
        if phase == .idle { reset() }
        onChange?()
    }

    /// Arrow-key nudge of the whole selection, in points.
    func nudge(by delta: CGVector) {
        guard anchor != nil, current != nil else { return }
        anchor = anchor.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        current = current.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        onChange?()
    }

    /// Puts the selection's origin somewhere else, keeping its size. The gesture
    /// behind it is dragging a settled selection around by its middle.
    ///
    /// Absolute rather than incremental, and clamped as a *translation* rather
    /// than by letting `rectInAppKitGlobal` intersect the result. Both matter for
    /// the same reason: the size the user chose is the one thing a move must never
    /// change. Intersecting would shave the rect against the screen edge, and
    /// feeding it per-event deltas would let those clamped points accumulate, so
    /// dragging into the edge and back would leave the rect lagging behind the
    /// pointer by however far it was pushed.
    func move(originTo newOrigin: CGPoint) {
        guard let anchor, let current, let rect = rectInAppKitGlobal else { return }
        var origin = newOrigin
        if let clampFrame {
            origin.x = min(max(origin.x, clampFrame.minX), clampFrame.maxX - rect.width)
            origin.y = min(max(origin.y, clampFrame.minY), clampFrame.maxY - rect.height)
        }
        let delta = CGVector(dx: origin.x - rect.minX, dy: origin.y - rect.minY)
        guard delta.dx != 0 || delta.dy != 0 else { return }
        self.anchor = CGPoint(x: anchor.x + delta.dx, y: anchor.y + delta.dy)
        self.current = CGPoint(x: current.x + delta.dx, y: current.y + delta.dy)
        onChange?()
    }

    /// Below this the selection stops shrinking. A rect the user cannot see is
    /// one they cannot grab an edge of either, and letting a resize run through
    /// zero would flip it inside out mid-drag.
    static let minimumSide: CGFloat = 8

    /// Replaces the rect outright, keeping the display it belongs to. The gesture
    /// behind it is dragging one edge or corner of a settled selection.
    ///
    /// Clamped by *intersection* with the display, unlike `move(originTo:)`,
    /// because here that is the right answer: the edge being dragged should stop
    /// at the screen border, and the opposite edge is not supposed to follow it.
    /// The minimum is enforced here as a backstop only: `SelectionZones.resized`
    /// has already stopped the dragged side short of its opposite, so what this
    /// guard catches is a rect the *display* clamp squeezed below it. Dropped
    /// rather than clamped, so the rect stops where it last made sense instead of
    /// snapping to a size nobody asked for.
    func resize(to rect: CGRect) {
        guard anchor != nil, current != nil else { return }
        var target = rect
        if let clampFrame {
            target = target.intersection(clampFrame)
            guard !target.isNull else { return }
        }
        guard target.width >= Self.minimumSide, target.height >= Self.minimumSide else { return }
        anchor = CGPoint(x: target.minX, y: target.minY)
        current = CGPoint(x: target.maxX, y: target.maxY)
        onChange?()
    }

    /// Arrow-key resize of the trailing corner, in points.
    func resize(by delta: CGVector) {
        guard current != nil else { return }
        current = current.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        onChange?()
    }

    /// Sets a selection outright, bypassing the drag gestures. Used by
    /// `--selftest-overlay`, which must exercise the real overlay without a
    /// human at the mouse.
    func setSelection(_ rect: CGRect, on screen: NSScreen) {
        anchor = CGPoint(x: rect.minX, y: rect.minY)
        current = CGPoint(x: rect.maxX, y: rect.maxY)
        clampFrame = screen.frame
        originDisplayID = ScreenIndex.displayID(of: screen)
        phase = .settled
        onChange?()
    }

    func reset() {
        anchor = nil
        current = nil
        clampFrame = nil
        originDisplayID = nil
        phase = .idle
        onChange?()
    }
}
