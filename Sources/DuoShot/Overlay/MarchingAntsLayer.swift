import AppKit
import QuartzCore

/// The selection border.
///
/// A `CAShapeLayer` with an animated `lineDashPhase`: the animation runs on the
/// render server, so it costs zero CPU and no `setNeedsDisplay`. Doing this with
/// a `Timer` plus redraw is a measurable frame cost on a 5K display during an
/// interactive drag.
/// `nonisolated` because CALayer's designated initialisers are nonisolated in the
/// SDK; under the module's MainActor default isolation the overrides would
/// otherwise disagree with what they override. CALayer is not MainActor-bound.
nonisolated final class MarchingAntsLayer: CALayer {
    private let dark = CAShapeLayer()
    private let light = CAShapeLayer()

    private static let pattern: [NSNumber] = [6, 4]
    private static let period: CGFloat = 10

    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Two stacked strokes so the border stays visible over both light and
        // dark content: a solid dark line with a marching white dash on top.
        dark.fillColor = nil
        dark.strokeColor = NSColor.black.withAlphaComponent(0.85).cgColor
        dark.lineWidth = 1

        light.fillColor = nil
        light.strokeColor = NSColor.white.cgColor
        light.lineWidth = 1
        light.lineDashPattern = Self.pattern

        addSublayer(dark)
        addSublayer(light)

        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = 0
        march.toValue = Self.period
        march.duration = 0.5
        march.repeatCount = .infinity
        light.add(march, forKey: "march")
    }

    func update(rect: CGRect?, contentsScale: CGFloat) {
        guard let rect, rect.width >= 1, rect.height >= 1 else {
            dark.path = nil
            light.path = nil
            return
        }
        // Half-point inset so the 1pt stroke lands on the selection edge rather
        // than straddling it, which would make the capture look 1px off.
        let path = CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        for layer in [dark, light] {
            layer.contentsScale = contentsScale
            // No implicit animation: the border must track the pointer exactly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = path
            CATransaction.commit()
        }
    }
}
