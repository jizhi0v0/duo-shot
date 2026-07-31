import AppKit
import Carbon.HIToolbox

/// One screen's worth of selection UI: the dim, the crosshair, the rubber band,
/// the window highlight, the readout, the loupe and the armed rect's grips.
///
/// All geometry exchanged with `SelectionModel` and `WindowPickerModel` is in
/// AppKit global points; the only conversion here is the constant offset to the
/// panel's own screen, since the panel frame equals the screen frame.
final class OverlayView: NSView {
    struct Callbacks {
        var confirmArea: () -> Void = {}
        var confirmWindow: (CGWindowID) -> Void = { _ in }
        var cancel: () -> Void = {}
        var toggleMode: () -> Void = {}
        /// A fresh drag has begun. Only meaningful when the caller asked for a
        /// confirmation step: it means the armed selection is being replaced and
        /// its toolbar has to go.
        var selectionRestarted: () -> Void = {}
    }

    /// Debug aid: draws a solid magenta block in the middle of the selection.
    /// Magenta surviving into a captured PNG means excluding our own panels from
    /// the SCContentFilter failed.
    static var drawsDebugSelectionBorder = false

    /// Whether Space offers to switch into window mode.
    ///
    /// Off for recordings. A window moves, resizes and closes while a take is
    /// running and none of those have a defined answer yet, so offering the
    /// mode would be promising something the recorder cannot do. The hint text
    /// follows this, because a shortcut that silently does nothing is worse
    /// than one that is not advertised.
    var allowsWindowMode = true {
        didSet { if allowsWindowMode != oldValue { refresh() } }
    }
    /// The selection is committed and the toolbar is up. Only changes the hint —
    /// every other interaction stays live, which is the point: the rect can
    /// still be nudged and the whole thing still abandoned with Escape.
    var isArmed = false {
        didSet { if isArmed != oldValue { refresh() } }
    }

    var mode: SelectionMode = .area {
        didSet { if mode != oldValue { refresh() } }
    }

    /// The photograph the loupe magnifies, once it arrives. Nil means no loupe:
    /// either the capture has not landed yet, or this is a screen the pointer has
    /// never visited.
    var backdrop: BackdropCache.Frame? {
        didSet {
            loupe.backdrop = backdrop
            // Fades in rather than appearing. It lands 30–60 ms after the overlay
            // does, and at that distance a hard cut reads as a glitch in a UI the
            // user is already interacting with.
            if oldValue == nil, backdrop != nil {
                loupe.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    loupe.animator().alphaValue = 1
                }
            }
            refresh()
        }
    }

    /// The loupe's frame in this view's coordinates, or nil when it is hidden.
    var loupeFrameForTest: CGRect? { loupe.isHidden ? nil : loupe.frame }

    private let screenFrame: CGRect
    private let model: SelectionModel
    private let picker: WindowPickerModel
    private let callbacks: Callbacks
    private let ants = MarchingAntsLayer()
    private let loupe = SelectionLoupeView()
    private var trackingAreaRef: NSTrackingArea?

    init(
        screen: NSScreen,
        model: SelectionModel,
        picker: WindowPickerModel,
        callbacks: Callbacks
    ) {
        self.screenFrame = screen.frame
        self.model = model
        self.picker = picker
        self.callbacks = callbacks
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.addSublayer(ants)
        loupe.isHidden = true
        addSubview(loupe)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Responder

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // No `isFlipped` override: NSView already returns false, and an @objc
    // MainActor-isolated getter sits in AppKit's hottest layout path — every
    // call performs an executor check that dereferences the object. That is
    // exactly where a dangling view segfaulted (see PreviewStackController.retire).

    override func resetCursorRects() {
        let cursor: NSCursor = mode == .area ? .crosshair : .arrow
        // Over an armed selection the pointer says which of the three gestures a
        // press would start: a resize cursor on each edge and corner, an open
        // hand in the middle, the crosshair outside.
        guard mode == .area, isArmed, let rect = model.rectInAppKitGlobal else {
            addCursorRect(bounds, cursor: cursor)
            return
        }
        let zones = SelectionZones(rect: toLocal(rect))
        let interior = zones.interior.intersection(bounds)
        guard !interior.isEmpty else {
            addCursorRect(bounds, cursor: cursor)
            return
        }
        addCursorRect(interior, cursor: .openHand)
        for handle in SelectionZones.Handle.allCases {
            let zone = zones.zone(handle).intersection(bounds)
            guard !zone.isEmpty else { continue }
            addCursorRect(zone, cursor: handle.cursor)
        }
        // The four slabs around the whole ring, rather than `bounds` plus
        // overlapping rects on top: AppKit does not define which cursor wins
        // where two cursor rects overlap, and "it looked right on my machine" is
        // not a specification. `SelectionZones` guarantees the ring's own pieces
        // do not overlap either.
        let ring = zones.interior.insetBy(dx: -zones.grab * 2, dy: -zones.grab * 2)
        for slab in [
            CGRect(x: bounds.minX, y: ring.maxY,
                   width: bounds.width, height: bounds.maxY - ring.maxY),
            CGRect(x: bounds.minX, y: bounds.minY,
                   width: bounds.width, height: ring.minY - bounds.minY),
            CGRect(x: bounds.minX, y: ring.minY,
                   width: ring.minX - bounds.minX, height: ring.height),
            CGRect(x: ring.maxX, y: ring.minY,
                   width: bounds.maxX - ring.maxX, height: ring.height),
        ] where slab.width > 0 && slab.height > 0 {
            addCursorRect(slab.intersection(bounds), cursor: cursor)
        }
    }

    /// Unhooks the view from the two AppKit registries that hold it *unretained*:
    /// the tracking-area manager and the cursor-rect list.
    ///
    /// Both are walked from the display cycle (`displayCycleUpdateStructuralRegions`
    /// -> `updateTrackingAreasWithInvalidCursorRects:` -> `resetCursorRects`), and
    /// neither keeps the view alive. A view freed with an entry still in them is a
    /// segfault one CATransaction later — which is exactly the crash of
    /// 2026-07-30 17:46:59.
    func detachFromDisplayCycle() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
            self.trackingAreaRef = nil
        }
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        // `.activeAlways`, not `.activeInKeyWindow`: only one panel is key, and
        // the others still need to track the pointer.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    // MARK: - Coordinates

    private func toGlobal(_ pointInView: CGPoint) -> CGPoint {
        CGPoint(x: pointInView.x + screenFrame.minX, y: pointInView.y + screenFrame.minY)
    }

    private func toLocal(_ rectInGlobal: CGRect) -> CGRect {
        rectInGlobal.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = toGlobal(convert(event.locationInWindow, from: nil))
        switch mode {
        case .area: model.pointerMoved(to: point)
        case .window: picker.updateHover(atAppKitGlobal: point)
        }
    }

    /// Where a press landed while the selection was armed, until it either
    /// travels far enough to be a new drag or is released as a plain click.
    private var armedPressOrigin: CGPoint?

    /// Below this a press is a click, not a new selection.
    ///
    /// Without it, an armed selection was destroyed by any click anywhere:
    /// `SelectionModel.isUsable` passes at 1×1 pt, so the pixel of travel in an
    /// ordinary click was a complete, confirmable rect, and the toolbar
    /// re-armed itself wherever the pointer happened to be.
    private static let restartSlop: CGFloat = 5

    /// A press inside the armed selection: where it started, and where the rect
    /// was at the time. Both, so the move can be computed absolutely — see
    /// `SelectionModel.move(originTo:)`.
    private var movePress: (pointer: CGPoint, origin: CGPoint)?

    /// A press on one of the armed selection's edges or corners, and the rect it
    /// started from. Absolute for the same reason a move is: the sides that are
    /// not being dragged come from the rect as it was at press, so they cannot
    /// drift over a long gesture.
    private var resizePress: (handle: SelectionZones.Handle, rect: CGRect)?

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else { return }
        guard let screen = window?.screen else { return }
        let point = toGlobal(convert(event.locationInWindow, from: nil))
        // Armed, so this press is not yet anything. Deciding here would throw
        // the selection away before knowing whether the user meant to.
        if isArmed {
            // On an edge or corner it means "resize", elsewhere inside it means
            // "move this", outside it means "start again". Which is the only
            // reading that leaves all three available: before this, a press
            // anywhere — including on the selection the user had just carefully
            // placed — could only destroy it, so nudging a rect two points to
            // the left meant redrawing it.
            if let rect = model.rectInAppKitGlobal {
                let zones = SelectionZones(rect: rect)
                if let handle = zones.handle(at: point) {
                    resizePress = (handle: handle, rect: rect)
                    return
                }
                if rect.contains(point) {
                    movePress = (pointer: point, origin: rect.origin)
                    return
                }
            }
            armedPressOrigin = point
            return
        }
        model.beginDrag(at: point, on: screen)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let point = toGlobal(convert(event.locationInWindow, from: nil))

        if let press = resizePress {
            model.resize(to: SelectionZones.resized(press.rect, by: press.handle, to: point))
            model.pointerMoved(to: point)
            return
        }

        if let press = movePress {
            model.move(originTo: CGPoint(
                x: press.origin.x + (point.x - press.pointer.x),
                y: press.origin.y + (point.y - press.pointer.y)))
            model.pointerMoved(to: point)
            return
        }

        if let origin = armedPressOrigin {
            guard hypot(point.x - origin.x, point.y - origin.y) > Self.restartSlop else { return }
            guard let screen = window?.screen else { return }
            armedPressOrigin = nil
            // Before `beginDrag`, so the toolbar is gone by the time the new
            // rect starts being drawn under where it used to be.
            callbacks.selectionRestarted()
            model.beginDrag(at: origin, on: screen)
        }

        model.updateDrag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .window:
            if let hovered = picker.hovered { callbacks.confirmWindow(hovered.id) }
        case .area:
            // A press that never travelled, or one that moved or resized the
            // selection rather than replacing it. Either way the armed rect stands and the
            // click is discarded — clicking the dim to dismiss would be a second,
            // undiscoverable way to lose a selection that Escape already handles
            // visibly. The moved rect needs no confirming: it is still armed, and
            // the bar over it is still the thing that starts the take.
            if armedPressOrigin != nil || movePress != nil || resizePress != nil {
                armedPressOrigin = nil
                movePress = nil
                resizePress = nil
                return
            }
            model.updateDrag(to: toGlobal(convert(event.locationInWindow, from: nil)))
            model.endDrag()
            if model.isUsable { callbacks.confirmArea() }
        }
    }

    // MARK: - Keyboard

    override func cancelOperation(_ sender: Any?) {
        callbacks.cancel()
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let resizing = event.modifierFlags.contains(.option)

        switch Int(event.keyCode) {
        case kVK_Space:
            // Matches the system screenshot UI, where Space swaps between
            // dragging a region and picking a window.
            if allowsWindowMode { callbacks.toggleMode() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirmFromKeyboard()
        case kVK_Escape:
            callbacks.cancel()
        case kVK_LeftArrow:
            apply(CGVector(dx: -step, dy: 0), resizing: resizing)
        case kVK_RightArrow:
            apply(CGVector(dx: step, dy: 0), resizing: resizing)
        case kVK_UpArrow:
            apply(CGVector(dx: 0, dy: step), resizing: resizing)
        case kVK_DownArrow:
            apply(CGVector(dx: 0, dy: -step), resizing: resizing)
        default:
            super.keyDown(with: event)
        }
    }

    private func confirmFromKeyboard() {
        switch mode {
        case .area:
            if model.isUsable { callbacks.confirmArea() } else { NSSound.beep() }
        case .window:
            if let hovered = picker.hovered { callbacks.confirmWindow(hovered.id) } else { NSSound.beep() }
        }
    }

    private func apply(_ delta: CGVector, resizing: Bool) {
        guard mode == .area else { return }
        if resizing { model.resize(by: delta) } else { model.nudge(by: delta) }
    }

    // MARK: - Drawing

    func refresh() {
        needsDisplay = true
        ants.frame = bounds
        ants.update(rect: highlightRect, contentsScale: window?.backingScaleFactor ?? 2)
        placeLoupe()
        window?.invalidateCursorRects(for: self)
    }

    /// Keeps the loupe beside the pointer, on this screen, out of its own way.
    ///
    /// Shown while aiming and while dragging — the moving corner *is* the pointer,
    /// so it is the same question either way — and not once the selection is
    /// armed: by then the rect is decided and the bar over it is what the user is
    /// reading.
    private func placeLoupe() {
        guard mode == .area, !isArmed, backdrop != nil,
              let pointer = model.pointerInAppKitGlobal
        else {
            loupe.isHidden = true
            return
        }
        let local = toLocal(CGRect(origin: pointer, size: .zero)).origin
        guard bounds.insetBy(dx: -1, dy: -1).contains(local) else {
            loupe.isHidden = true
            return
        }
        loupe.isHidden = false
        loupe.pointInAppKitGlobal = pointer

        // Below-right by default, and flipped to whichever side has room. The
        // offset is deliberately more than the cursor's own size: a loupe touching
        // the pointer covers the pixels either side of the one being aimed at.
        let size = SelectionLoupeView.size
        let gap: CGFloat = 18
        var origin = CGPoint(x: local.x + gap, y: local.y - gap - size.height)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = local.x - gap - size.width }
        if origin.y < bounds.minY + 8 { origin.y = local.y + gap }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        loupe.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    /// The un-dimmed region: the rubber band in area mode, the hovered window in
    /// window mode.
    private var highlightRect: CGRect? {
        switch mode {
        case .area:
            model.rectInAppKitGlobal.map(toLocal)
        case .window:
            picker.hoveredFrameInAppKitGlobal.map(toLocal)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = highlightRect

        NSColor(white: 0, alpha: 0.28).setFill()
        let path = NSBezierPath(rect: bounds)
        if let highlight, highlight.width >= 1, highlight.height >= 1 {
            path.appendRect(highlight)
            path.windingRule = .evenOdd
        }
        path.fill()

        guard let highlight, highlight.width >= 1, highlight.height >= 1 else {
            if mode == .area, let pointer = model.pointerInAppKitGlobal, model.phase == .idle {
                drawCrosshair(at: toLocal(CGRect(origin: pointer, size: .zero)).origin)
            }
            drawHint()
            return
        }

        if Self.drawsDebugSelectionBorder {
            // A solid block in the *centre*, not a border: the marching-ants
            // CAShapeLayer sits on top of this view's drawing and covers the
            // selection edge exactly, which silently turned the exclusion test
            // into one that could never fail.
            NSColor.magenta.setFill()
            let side: CGFloat = min(24, highlight.width / 2, highlight.height / 2)
            NSBezierPath(rect: CGRect(
                x: highlight.midX - side / 2, y: highlight.midY - side / 2,
                width: side, height: side
            )).fill()
        }

        switch mode {
        case .area:
            if isArmed { drawHandles(on: highlight) }
            drawBadge("\(Int(highlight.width)) × \(Int(highlight.height))", near: highlight)
        case .window:
            if let hovered = picker.hovered {
                drawBadge(hovered.displayName, near: highlight)
            }
        }
        drawHint()
    }

    /// Four corner grips, drawn only once the selection is armed.
    ///
    /// They are the affordance for a gesture that would otherwise be invisible:
    /// a settled rect that can be resized has to look like one. Corners only —
    /// eight grips read as a diagram, and the edges announce themselves through
    /// the cursor.
    ///
    /// Dark ring under a light fill, the pairing used everywhere else here, since
    /// these land on whatever the user is about to record.
    private func drawHandles(on highlight: CGRect) {
        let side: CGFloat = 7
        for centre in SelectionZones(rect: highlight).cornerPoints {
            let grip = CGRect(
                x: (centre.x - side / 2).rounded(), y: (centre.y - side / 2).rounded(),
                width: side, height: side)
            NSColor(white: 0, alpha: 0.5).setStroke()
            let ring = NSBezierPath(roundedRect: grip.insetBy(dx: -0.5, dy: -0.5),
                                    xRadius: 2, yRadius: 2)
            ring.lineWidth = 1
            ring.stroke()
            NSColor(white: 1, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawCrosshair(at point: CGPoint) {
        guard bounds.contains(point) else { return }
        NSColor(white: 1, alpha: 0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        path.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        path.stroke()
    }

    private func drawHint() {
        let text = if isArmed {
            "⏎ to record · drag to move, edges to resize · drag outside to reselect · Esc"
        } else if mode != .area {
            "Click a window · Space for area · Esc to cancel"
        } else if allowsWindowMode {
            "Drag to select · Space for window · Esc to cancel"
        } else {
            "Drag to select an area to record · Esc to cancel"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.75),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 10,
            y: bounds.minY + 24,
            width: size.width + 20,
            height: size.height + 10
        )
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attributes)
    }

    private func drawBadge(_ text: String, near highlight: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        var truncated = text
        while (truncated as NSString).size(withAttributes: attributes).width > bounds.width - 80,
              truncated.count > 4 {
            truncated = String(truncated.dropLast(2)) + "…"
        }

        let size = (truncated as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        let boxSize = CGSize(width: size.width + padding.width * 2,
                             height: size.height + padding.height * 2)

        // Below the highlight by default; above it when there is no room.
        var origin = CGPoint(x: highlight.midX - boxSize.width / 2,
                             y: highlight.minY - boxSize.height - 6)
        if origin.y < bounds.minY + 4 { origin.y = highlight.maxY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - boxSize.width - 4)

        let box = CGRect(origin: origin, size: boxSize)
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (truncated as NSString).draw(
            at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height),
            withAttributes: attributes)
    }
}
