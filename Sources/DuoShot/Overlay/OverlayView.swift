import AppKit
import Carbon.HIToolbox

/// The dim, crosshair, rubber band, window highlight and readout for one screen.
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
    }

    /// Debug aid: draws a solid magenta block in the middle of the selection.
    /// Magenta surviving into a captured PNG means excluding our own panels from
    /// the SCContentFilter failed.
    static var drawsDebugSelectionBorder = false

    var mode: SelectionMode = .area {
        didSet { if mode != oldValue { refresh() } }
    }

    private let screenFrame: CGRect
    private let model: SelectionModel
    private let picker: WindowPickerModel
    private let callbacks: Callbacks
    private let ants = MarchingAntsLayer()
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
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : .arrow)
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

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else { return }
        guard let screen = window?.screen else { return }
        model.beginDrag(at: toGlobal(convert(event.locationInWindow, from: nil)), on: screen)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        model.updateDrag(to: toGlobal(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .window:
            if let hovered = picker.hovered { callbacks.confirmWindow(hovered.id) }
        case .area:
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
            callbacks.toggleMode()
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
        window?.invalidateCursorRects(for: self)
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
            drawBadge("\(Int(highlight.width)) × \(Int(highlight.height))", near: highlight)
        case .window:
            if let hovered = picker.hovered {
                drawBadge(hovered.displayName, near: highlight)
            }
        }
        drawHint()
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
        let text = mode == .area
            ? "Drag to select · Space for window · Esc to cancel"
            : "Click a window · Space for area · Esc to cancel"
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
