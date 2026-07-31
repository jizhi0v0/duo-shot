import AppKit

/// A border drawn around the region an area recording is capturing.
///
/// Without it a take gives no indication of what it is recording: the overlay
/// tears down the moment the stream starts, and the HUD is a fixed bar at the
/// bottom of the screen that says nothing about which rectangle is live. For a
/// fullscreen take that is fine — the answer is "everything". For an area take
/// it left the user watching a timer with no idea what was inside the frame.
///
/// It is `sharingType = .none`, so it cannot appear in the recording it marks.
/// It also ignores mouse events entirely: it sits over whatever is being
/// demonstrated, and a border that ate clicks would break the demonstration.
final class RecordingRegionOutlinePanel: NSPanel {
    static var usesSharingTypeNone = true

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, view: NSView, hiddenFromCapture: Bool = true) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: `isFloatingPanel` resets `level`, so it goes first.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = (Self.usesSharingTypeNone && hiddenFromCapture) ? .none : .readOnly

        contentView = view
    }
}

/// The lit edge: warm light spilling outward from the recorded rectangle, the way
/// a make-up mirror lights what is in front of it.
///
/// It replaced a dark/light/dark sandwich of hairlines. That version was correct
/// and looked like a marquee: three crisp strokes read as a *border around a
/// screenshot*, not as a region that is live. Light does the same job with none
/// of that — it says "this rectangle is on" rather than "this rectangle is
/// selected" — and it stays outside the region entirely, so nothing being
/// demonstrated is covered or tinted.
///
/// Two properties of the old design are deliberately kept.
///
/// Nothing is sampled from the background. Picking a contrasting colour is the
/// obvious answer and does not survive the situation it is for: what is behind
/// the border is a *recording in progress*, so it changes continuously. A colour
/// sampled once is wrong as soon as the user scrolls, and re-sampling means a
/// screen capture on a timer for the length of every take.
///
/// And it cannot lose against the content. Warm light alone would vanish on a
/// white document — the same way the original solid-red border vanished on red —
/// so the light is backed by a soft shade further out. On dark content the glow
/// carries the edge; on pale content the shade does. Neither is a line, and
/// `--selftest-region-outline` measures both.
final class RecordingRegionOutlineView: NSView {
    /// How far the light reaches. The panel is grown by this on every side, so
    /// the whole effect lives outside the recorded rectangle.
    ///
    /// Wider than it needs to be for brightness, and that is the point: the same
    /// amount of light spread over more distance is diffuse rather than a band.
    static let outset: CGFloat = 28

    /// Warm white — tungsten pulled back towards daylight. The first version was
    /// amber enough to read as a colour rather than as light; at these lower
    /// opacities the hue barely shows anyway, and what is left is warmth.
    private static let bulb = NSColor(srgbRed: 1.0, green: 0.925, blue: 0.808, alpha: 1)

    /// One point of the falloff: how much of the colour survives `distance`
    /// points out from the recorded edge.
    private struct Stop {
        let distance: CGFloat
        let alpha: CGFloat
    }

    /// The light.
    ///
    /// Deliberately soft at the edge. The first version peaked at 0.95 and halved
    /// within two points, which put a bright two-point band right on the boundary
    /// — a neon tube, i.e. the line this was supposed to stop being. The peak is
    /// down by half and the falloff stretched over the whole reach, so there is
    /// no distance at which the light has an edge of its own.
    private static let glow: [Stop] = [
        Stop(distance: 0, alpha: 0.45),
        Stop(distance: 3, alpha: 0.34),
        Stop(distance: 8, alpha: 0.22),
        Stop(distance: 14, alpha: 0.12),
        Stop(distance: 21, alpha: 0.05),
        Stop(distance: outset, alpha: 0),
    ]

    /// The shade, and the reason the border survives a white document.
    ///
    /// It starts where the light is already fading and peaks well outside it, so
    /// the two never compete for the same pixels: nothing dark ever touches the
    /// bright edge. On dark content it is invisible and costs nothing; on pale
    /// content it is the whole border. Measured, not assumed — the first version
    /// of this file put the shade too close in and too faint, and
    /// `--selftest-region-outline` reported it as a difference of 6 luminance
    /// units against white, i.e. no border at all.
    private static let shade: [Stop] = [
        Stop(distance: 0, alpha: 0),
        Stop(distance: 5, alpha: 0.07),
        Stop(distance: 11, alpha: 0.17),
        Stop(distance: 18, alpha: 0.14),
        Stop(distance: 24, alpha: 0.06),
        Stop(distance: outset, alpha: 0),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let region = bounds.insetBy(dx: Self.outset, dy: Self.outset)
        guard region.width > 1, region.height > 1 else { return }

        // Two falloffs and nothing else. There was a hairline of "filament" along
        // the boundary as well, at 0.8: it was the single most line-like thing
        // left, and once the glow's peak came down to 0.45 it was also pointless
        // — a 1 pt stroke fainter than the light either side of it is invisible on
        // dark content and, being warm, invisible on pale content too. The
        // boundary is now where the light starts, which is what a lit edge is.
        halo(context, around: region, colour: Self.bulb, stops: Self.glow)
        halo(context, around: region, colour: .black, stops: Self.shade)
    }

    /// Paints one falloff all the way round `region`, outward.
    ///
    /// Gradients rather than a blurred rectangle's shadow, which is what this
    /// started as: a Core Graphics shadow gives no say over the profile, and
    /// measured, it put nearly all of its energy in the first two points and
    /// nothing past six — a hairline with a halo, which is the look being
    /// replaced. Four edges plus four corners is more code and the only way to
    /// state the curve.
    private func halo(
        _ context: CGContext, around region: CGRect, colour: NSColor, stops: [Stop]
    ) {
        let reach = Self.outset
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colours = stops.compactMap {
            colour.withAlphaComponent($0.alpha).usingColorSpace(.sRGB)?.cgColor
        }
        guard colours.count == stops.count,
              let gradient = CGGradient(
                colorsSpace: space, colors: colours as CFArray,
                locations: stops.map { $0.distance / reach })
        else { return }

        // Edges: the gradient runs straight out from each side, clipped to that
        // side's own strip so it stops where the corner takes over.
        let edges: [(clip: CGRect, from: CGPoint, to: CGPoint)] = [
            (CGRect(x: region.minX, y: region.maxY, width: region.width, height: reach),
             CGPoint(x: region.midX, y: region.maxY), CGPoint(x: region.midX, y: region.maxY + reach)),
            (CGRect(x: region.minX, y: region.minY - reach, width: region.width, height: reach),
             CGPoint(x: region.midX, y: region.minY), CGPoint(x: region.midX, y: region.minY - reach)),
            (CGRect(x: region.minX - reach, y: region.minY, width: reach, height: region.height),
             CGPoint(x: region.minX, y: region.midY), CGPoint(x: region.minX - reach, y: region.midY)),
            (CGRect(x: region.maxX, y: region.minY, width: reach, height: region.height),
             CGPoint(x: region.maxX, y: region.midY), CGPoint(x: region.maxX + reach, y: region.midY)),
        ]
        for edge in edges {
            context.saveGState()
            context.clip(to: edge.clip)
            context.drawLinearGradient(gradient, start: edge.from, end: edge.to, options: [])
            context.restoreGState()
        }

        // Corners: out there the distance from the region is radial, so a linear
        // gradient would leave a visible seam along each diagonal.
        let corners: [(clip: CGRect, centre: CGPoint)] = [
            (CGRect(x: region.minX - reach, y: region.maxY, width: reach, height: reach),
             CGPoint(x: region.minX, y: region.maxY)),
            (CGRect(x: region.maxX, y: region.maxY, width: reach, height: reach),
             CGPoint(x: region.maxX, y: region.maxY)),
            (CGRect(x: region.minX - reach, y: region.minY - reach, width: reach, height: reach),
             CGPoint(x: region.minX, y: region.minY)),
            (CGRect(x: region.maxX, y: region.minY - reach, width: reach, height: reach),
             CGPoint(x: region.maxX, y: region.minY)),
        ]
        for corner in corners {
            context.saveGState()
            context.clip(to: corner.clip)
            context.drawRadialGradient(
                gradient, startCenter: corner.centre, startRadius: 0,
                endCenter: corner.centre, endRadius: reach, options: [])
            context.restoreGState()
        }
    }

    /// Layout changes the geometry every control point is derived from, and a
    /// layer-backed view is not obliged to redraw on resize by itself.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// A slow breath, so the light reads as switched on rather than painted on.
    ///
    /// Long and shallow on purpose — 2.6 s between extremes and never below 84%.
    /// This sits at the edge of whatever the user is demonstrating for the entire
    /// length of a take, and anything faster or deeper becomes the thing you
    /// notice instead of the thing being recorded. The bar's own red dot carries
    /// the urgent rhythm at 0.8 s; two of those on screen would compete.
    ///
    /// On the render server, like the marching ants and that dot: an opacity
    /// animation on the layer costs nothing per frame, where a `Timer` redrawing
    /// four gradients would be measurable for minutes on end.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        wantsLayer = true
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1.0
        breath.toValue = 0.84
        breath.duration = 1.3
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(breath, forKey: "breath")
    }
}

/// Owns the outline for the length of one area recording.
@MainActor
final class RecordingRegionOutline {
    private var panel: RecordingRegionOutlinePanel?

    var isVisible: Bool { panel != nil }

    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    /// `rect` is the recorded region in AppKit global points. The panel is grown
    /// outwards from it so the light lives entirely outside the region rather
    /// than lying over the edges of what is being demonstrated.
    func show(around rect: CGRect, hiddenFromCapture: Bool = true) {
        let outset = RecordingRegionOutlineView.outset
        let frame = rect.insetBy(dx: -outset, dy: -outset)
        if let panel {
            panel.setFrame(frame, display: true)
            panel.contentView?.needsDisplay = true
            return
        }
        let view = RecordingRegionOutlineView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        let created = RecordingRegionOutlinePanel(
            contentRect: frame, view: view, hiddenFromCapture: hiddenFromCapture)
        created.orderFrontRegardless()
        panel = created
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var frameForTest: CGRect? { panel?.frame }
}
