import AppKit

/// A determinate ring drawn around the share button while its capture uploads.
///
/// It used to be a 36pt ring in the middle of the card. That was wrong twice
/// over: it covered the open button — the primary thing a card is for — and it
/// put the feedback nowhere near the control that had just been pressed. This
/// sits on the button itself, so the answer to "did my click do anything" is
/// where the click was.
///
/// Not hit-testable, like everything else layered over a card: the button
/// underneath still takes the mouse, and the card still owns its gestures.
final class ButtonRingView: NSView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fraction: Double = 0 {
        didSet {
            // No implicit animation. Progress callbacks arrive many times a
            // second and Core Animation's default quarter-second interpolation
            // would leave the ring a beat behind the transfer and still moving
            // after it finished.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A hair of arc at zero, so the ring reads as "started" rather than
            // as a stalled empty circle.
            progress.strokeEnd = max(0.04, min(1, fraction))
            CATransaction.commit()
        }
    }

    init(diameter: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true

        let lineWidth: CGFloat = 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2 - lineWidth

        // The direction is built into the path rather than applied afterwards.
        //
        // The first version rotated and mirrored the layer with a
        // `CATransform3D` to get "starts at twelve, runs clockwise", and drew the
        // arc in the corner of the card instead. The reason: a `CAShapeLayer`
        // added as a sublayer has **zero bounds** unless given some, so every
        // `bounds.midX` in that transform was measured against a layer 0 pt wide
        // and the whole thing pivoted around a point that was not on the ring.
        // Found by looking at a screenshot, which is what `--selftest-share-card`
        // is for.
        track.path = CGPath(
            ellipseIn: bounds.insetBy(dx: lineWidth, dy: lineWidth), transform: nil)
        track.fillColor = .clear
        track.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor

        let arc = CGMutablePath()
        // AppKit's y grows upward, so twelve o'clock is +π/2 and `clockwise:
        // true` runs the way a clock does.
        arc.addArc(
            center: center, radius: radius,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        progress.path = arc
        progress.fillColor = .clear
        progress.strokeColor = NSColor.white.cgColor
        progress.strokeEnd = 0.04

        for shape in [track, progress] {
            shape.frame = bounds
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
