import AppKit

/// The rubber-band state machine. All rects are in **AppKit global points**.
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
