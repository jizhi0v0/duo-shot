import AppKit
import Carbon.HIToolbox

/// One screen's worth of selection UI: the dim, the crosshair, the rubber band,
/// the suggested window, the readout, the loupe and the armed rect's grips.
///
/// All geometry exchanged with `SelectionModel` and `WindowPickerModel` is in
/// AppKit global points; the only conversion here is the constant offset to the
/// panel's own screen, since the panel frame equals the screen frame.
final class OverlayView: NSView {
    struct Callbacks {
        var confirmArea: () -> Void = {}
        var confirmWindow: (CGWindowID) -> Void = { _ in }
        var cancel: () -> Void = {}
        /// A fresh drag has begun. Only meaningful when the caller asked for a
        /// confirmation step: it means the armed selection is being replaced and
        /// its toolbar has to go.
        var selectionRestarted: () -> Void = {}
    }

    /// Debug aid: draws a solid magenta block in the middle of the selection.
    /// Magenta surviving into a captured PNG means excluding our own panels from
    /// the SCContentFilter failed.
    static var drawsDebugSelectionBorder = false

    /// Whether hovering suggests the window under the pointer.
    ///
    /// Off for recordings. A window moves, resizes and closes while a take is
    /// running and none of those have a defined answer yet, so suggesting one
    /// would be offering something the recorder cannot deliver. The hint text
    /// follows this, because an affordance that silently does nothing is worse
    /// than one that is not advertised.
    var suggestsWindows = true {
        didSet { if suggestsWindows != oldValue { refresh() } }
    }
    /// The selection is committed and the toolbar is up. Only changes the hint —
    /// every other interaction stays live, which is the point: the rect can
    /// still be nudged and the whole thing still abandoned with Escape.
    var isArmed = false {
        didSet { if isArmed != oldValue { refresh() } }
    }

    /// The photograph the loupe magnifies, once it arrives. Nil means no loupe:
    /// either the capture has not landed yet, or this is a screen the pointer has
    /// never visited.
    var backdrop: BackdropCache.Frame? {
        didSet {
            // Re-published on every pointer move, and usually unchanged: while the
            // pointer stays inside the current patch, the cache keeps handing back
            // the same frame. Redrawing a screen-sized view and rebuilding the
            // marching ants for that would be a second invalidation per move, on
            // top of the one the move itself already causes.
            guard backdrop != oldValue else { return }
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
        // The crosshair everywhere, including over a suggested window. Window
        // mode used to swap in the arrow, and losing that is deliberate: the
        // pointer now means the same thing everywhere on the overlay, because a
        // press everywhere on the overlay can start the same drag.
        let cursor: NSCursor = .crosshair
        // Over an armed selection the pointer says which of the three gestures a
        // press would start: a resize cursor on each edge and corner, an open
        // hand in the middle, the crosshair outside.
        guard isArmed, let rect = model.rectInAppKitGlobal else {
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
        model.pointerMoved(to: point)
        if isSuggesting { picker.updateHover(atAppKitGlobal: point) }
    }

    /// Whether a window is currently being offered under the pointer.
    ///
    /// Only while nothing else is going on: mid-drag the rubber band is the
    /// answer, and once armed the rect is already decided. Both are states in
    /// which a second highlight would be claiming to be the selection.
    private var isSuggesting: Bool {
        suggestsWindows && !isArmed && model.phase == .idle
    }

    /// The window a click would take, or nil.
    private var suggestedWindow: WindowInfo? {
        isSuggesting ? picker.hovered : nil
    }

    /// The same answer, for `--selftest-window`.
    var suggestedWindowForTest: WindowInfo? { suggestedWindow }

    /// Where a press landed, until it either travels far enough to be a drag or
    /// is released as a plain click.
    ///
    /// One property for both states, armed and not, because the two now decide
    /// the same question: this press is not yet anything, and committing to a
    /// reading of it before it has travelled would throw away whichever
    /// interpretation the user actually meant.
    private var pressOrigin: CGPoint?

    /// Below this a press is a click, not a selection.
    ///
    /// Without it, an armed selection was destroyed by any click anywhere:
    /// `SelectionModel.isUsable` passes at 1×1 pt, so the pixel of travel in an
    /// ordinary click was a complete, confirmable rect, and the toolbar
    /// re-armed itself wherever the pointer happened to be.
    ///
    /// The un-armed path had the same bug with a quieter symptom, and it is what
    /// the click gesture is now built on: a press with one point of hand-shake in
    /// it went all the way through `confirmArea` and saved a 1×1 PNG. A click is
    /// how you take the suggested window, so it had to stop being a selection
    /// first.
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
        let point = toGlobal(convert(event.locationInWindow, from: nil))
        // On an armed selection's edge or corner a press means "resize", and
        // elsewhere inside it means "move this". Which is the only reading that
        // leaves all three gestures available: before this, a press anywhere —
        // including on the selection the user had just carefully placed — could
        // only destroy it, so nudging a rect two points to the left meant
        // redrawing it.
        if isArmed, let rect = model.rectInAppKitGlobal {
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
        // Everything else is a press that is not yet anything. Deliberately no
        // `beginDrag` here: starting the drag on the press would put the model
        // into `.dragging` and take the suggested window's outline off screen
        // the instant the mouse went down, so a click — which is how you accept
        // that window — would flicker the thing it is accepting.
        pressOrigin = point
    }

    override func mouseDragged(with event: NSEvent) {
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

        if let origin = pressOrigin {
            guard hypot(point.x - origin.x, point.y - origin.y) > Self.restartSlop else { return }
            guard let screen = window?.screen else { return }
            pressOrigin = nil
            // Before `beginDrag`, so an armed toolbar is gone by the time the new
            // rect starts being drawn under where it used to be. A no-op when
            // nothing was armed.
            callbacks.selectionRestarted()
            // From the press, not from here: the rect the user drew starts where
            // they put the mouse down, not five points into the gesture.
            model.beginDrag(at: origin, on: screen)
        }

        model.updateDrag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = toGlobal(convert(event.locationInWindow, from: nil))

        // A press that moved or resized the armed selection rather than
        // replacing it. The rect stands and needs no confirming: it is still
        // armed, and the bar over it is still the thing that starts the take.
        if movePress != nil || resizePress != nil {
            movePress = nil
            resizePress = nil
            return
        }

        // A press that never travelled far enough to be a drag, so it is a
        // click: it takes the suggested window, or it does nothing at all.
        //
        // Doing nothing is the right answer for a click on bare desktop, and for
        // any click while armed. Dismissing on it would be a second,
        // undiscoverable way to lose a selection that Escape already handles
        // visibly.
        if pressOrigin != nil {
            pressOrigin = nil
            if isSuggesting { picker.updateHover(atAppKitGlobal: point) }
            if let suggested = suggestedWindow { callbacks.confirmWindow(suggested.id) }
            return
        }

        model.updateDrag(to: point)
        model.endDrag()
        if model.isUsable { callbacks.confirmArea() }
    }

    // MARK: - Keyboard

    override func cancelOperation(_ sender: Any?) {
        callbacks.cancel()
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let resizing = event.modifierFlags.contains(.option)

        switch Int(event.keyCode) {
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

    /// Return takes whichever of the two things is on offer.
    ///
    /// A drawn rect wins over a suggested window, and not by accident: the two
    /// are never both live (`isSuggesting` requires an idle model), so the order
    /// only decides the case where a rect exists and the pointer happens to be
    /// over a window — where the rect is plainly what the user has been working
    /// on.
    private func confirmFromKeyboard() {
        if model.isUsable {
            callbacks.confirmArea()
        } else if let suggested = suggestedWindow {
            callbacks.confirmWindow(suggested.id)
        } else {
            NSSound.beep()
        }
    }

    private func apply(_ delta: CGVector, resizing: Bool) {
        if resizing { model.resize(by: delta) } else { model.nudge(by: delta) }
    }

    // MARK: - Drawing

    /// Everything this view's appearance is a function of.
    ///
    /// The pointer is stored *local and only while it is over this screen*, which
    /// is what makes the early-out below work: a pointer moving on another
    /// display leaves this view's entry nil before and after.
    private struct DrawInputs: Equatable {
        var highlight: CGRect?
        var suggestion: CGRect?
        var pointer: CGPoint?
        var phase: SelectionModel.Phase
        var isArmed: Bool
        var suggestsWindows: Bool
        var badge: String?
        var hasBackdrop: Bool
        var backingScale: CGFloat
    }

    private var lastDrawn: DrawInputs?

    private var drawInputs: DrawInputs {
        let highlight = highlightRect
        let local = model.pointerInAppKitGlobal
            .map { toLocal(CGRect(origin: $0, size: .zero)).origin }
        // The rect's size while there is a rect, the window's name while there
        // is only a suggestion. Never both, and never nothing while something is
        // highlighted.
        let badge = highlight.map { "\(Int($0.width)) × \(Int($0.height))" }
            ?? suggestedWindow?.displayName
        return DrawInputs(
            highlight: highlight,
            suggestion: suggestionRect,
            // The same inset `placeLoupe` uses, so the two agree about which
            // screen the pointer is on.
            pointer: local.flatMap { bounds.insetBy(dx: -1, dy: -1).contains($0) ? $0 : nil },
            phase: model.phase,
            isArmed: isArmed,
            suggestsWindows: suggestsWindows,
            badge: badge,
            hasBackdrop: backdrop != nil,
            backingScale: window?.backingScaleFactor ?? 2)
    }

    /// Invalidates this screen's selection UI — but only when something it draws
    /// has actually changed.
    ///
    /// The controller's refresh closure is shared by every screen's view, so a
    /// single pointer move used to mark a screen-sized view dirty and rebuild its
    /// cursor rects on *every* display. Only the view under the pointer has
    /// anything new to show; on a three-display machine the other two were
    /// repainting a full screen of dim for nothing.
    func refresh() {
        let current = drawInputs
        guard current != lastDrawn else { return }
        lastDrawn = current

        needsDisplay = true
        ants.frame = bounds
        ants.update(rect: current.highlight, contentsScale: current.backingScale)
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
        guard !isArmed, backdrop != nil,
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

    /// The un-dimmed region: the rubber band, and only the rubber band.
    ///
    /// The suggested window deliberately does not come through here — see
    /// `drawSuggestion` for why it gets its own, much weaker treatment.
    private var highlightRect: CGRect? {
        model.rectInAppKitGlobal.map(toLocal)
    }

    /// The suggested window's frame in this view's coordinates, or nil.
    private var suggestionRect: CGRect? {
        guard suggestedWindow != nil else { return nil }
        return picker.hoveredFrameInAppKitGlobal.map(toLocal)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = highlightRect
        let hasHighlight = highlight.map { $0.width >= 1 && $0.height >= 1 } ?? false
        // Only ever one of the two, and the rect wins — see `drawSuggestion`.
        let suggestion = hasHighlight ? nil : suggestionRect

        NSColor(white: 0, alpha: 0.28).setFill()
        let path = NSBezierPath(rect: bounds)
        // Both holes are cut the same way, and the difference between "what you
        // have" and "what you would get" is how much dim goes back in after.
        if let hole = hasHighlight ? highlight : suggestion {
            path.appendRect(hole)
            path.windingRule = .evenOdd
        }
        path.fill()

        guard let highlight, hasHighlight else {
            // The press-but-not-yet-moved instant. Nothing else is on screen
            // yet, so this is the only frame where the crosshair stands alone.
            if let pointer = model.pointerInAppKitGlobal, model.phase == .dragging {
                drawCrosshair(at: toLocal(CGRect(origin: pointer, size: .zero)).origin)
            }
            if let suggestion, let suggested = suggestedWindow {
                drawSuggestion(suggestion)
                drawBadge(suggested.displayName, near: suggestion)
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

        // Through the drag, and clipped to outside the rect. The pointer *is* the
        // moving corner, so the two lines run along the two edges the user is
        // still placing and carry on to the screen edges — which is the whole
        // use of them: they say what those edges line up with out in the rest of
        // the screen. Letting them continue across the selection would draw a
        // cross over the one region that has to be shown untouched.
        if let pointer = model.pointerInAppKitGlobal, model.phase == .dragging {
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: bounds)
            outside.appendRect(highlight)
            outside.windingRule = .evenOdd
            outside.addClip()
            drawCrosshair(at: toLocal(CGRect(origin: pointer, size: .zero)).origin)
            NSGraphicsContext.restoreGraphicsState()
        }

        if isArmed { drawHandles(on: highlight) }
        drawBadge("\(Int(highlight.width)) × \(Int(highlight.height))", near: highlight)
        drawHint()
    }

    /// The window a click would take: a partial un-dim and an outline.
    ///
    /// Deliberately *not* the full un-dim a drawn selection gets, which is how
    /// window mode used to draw this. That treatment could not survive the
    /// merge for two reasons. It now fires on every hover as the pointer sweeps
    /// the screen, and a window flashing to full brightness under the cursor
    /// reads as the UI malfunctioning rather than as an offer. And it is the
    /// same treatment the committed selection gets — these are precisely the
    /// two states a user has to tell apart, since one is what they have and the
    /// other is only what they would get.
    ///
    /// So it lands between the two: `draw` cuts this rect out of the dim, and
    /// this puts back less than was taken. The first attempt did the arithmetic
    /// the other way round — full dim, plus a wash of white on top — which is
    /// not the same picture at all. Adding white lifts the black point without
    /// touching the white one, so it flattens contrast and pulls every colour
    /// towards grey: the window read as fogged rather than as lit, and a
    /// screenshot tool showing you a washed-out version of what you are about
    /// to shoot is lying about the shot. Removing dim instead leaves the
    /// window's own colours intact and only turns them down.
    private func drawSuggestion(_ rect: CGRect) {
        NSColor(white: 0, alpha: 0.12).setFill()
        NSBezierPath(rect: rect).fill()
        // A dark hairline outside a light one, the pairing the grips and the
        // badge already use: this lands on whatever the user happens to be
        // pointing at, which can be any colour at all.
        NSColor(white: 0, alpha: 0.45).setStroke()
        let shadow = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        shadow.lineWidth = 1
        shadow.stroke()
        NSColor(white: 1, alpha: 0.9).setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
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

    /// The two screen-spanning guide lines. Drawn only while the button is down.
    ///
    /// It used to be the other way round — shown while aiming, gone the moment a
    /// drag started — and that stopped working when hovering began offering
    /// windows. At idle the pointer now has something else to say: a window is
    /// outlined under it, and two lines running out of that outline to the screen
    /// edges break it up into four segments and read as clutter over a UI that is
    /// already showing you the answer. The cursor is still the crosshair
    /// everywhere (`resetCursorRects`), so "you can drag from here" has not gone
    /// anywhere; what has gone is the full-screen version of it, which was doing
    /// its real work — telling you what an edge lines up with — during the drag,
    /// the one time it was not on screen.
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
        } else if suggestsWindows {
            "Drag to select · click a window · Esc to cancel"
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
