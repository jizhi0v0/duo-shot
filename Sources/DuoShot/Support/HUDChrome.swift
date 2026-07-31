import AppKit

/// The metrics and controls shared by the two floating bars: the toolbar under
/// an armed selection, and the HUD that replaces it while the take runs.
///
/// They were built a week apart and looked it — different heights, different
/// corner radii, different button idioms, one using an `NSButton` with an image
/// and a title and the other hand-placing subviews. Two bars that appear in
/// sequence, in the same place, during one continuous action have to read as one
/// thing changing state rather than as two unrelated pieces of UI.
enum HUDMetrics {
    static let height: CGFloat = 40
    static let margin: CGFloat = 8
    static let controlHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 7
    /// Between controls that belong together.
    static let gap: CGFloat = 4
    /// Around the divider, between groups that do not.
    static let groupGap: CGFloat = 8
    static let iconWidth: CGFloat = 30
    /// One duration for every state change a bar makes, so the dot, the clock
    /// and both buttons come alive as a single movement rather than four.
    static let transition: CFTimeInterval = 0.28

    /// The bar's material, plus the container its controls belong in.
    ///
    /// Liquid Glass, via `NSGlassEffectView` — available from macOS 26.0, which
    /// is exactly this app's minimum, so there is no fallback path to keep.
    ///
    /// Controls go in the returned `content` view, not straight onto the bar.
    /// The header is explicit that only `contentView` is guaranteed to sit
    /// inside the effect: "arbitrary subviews aren't guaranteed specific
    /// behavior with regard to z-order in relation to the content view or glass
    /// effect." Adding them as siblings happens to look right and is not
    /// promised to keep doing so.
    ///
    /// `content` matches the bar's bounds and resizes with it, so every frame
    /// the callers compute stays in the same coordinate space it always was.
    static func chrome(in bounds: CGRect) -> (glass: NSGlassEffectView, content: NSView) {
        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        // macOS 27 only, and absent from the 26 SDK entirely — so the runtime
        // check is not enough on its own. Same trap as
        // `mixesAudioWithMicrophone`; see `make check-26`.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        #endif

        let content = NSView(frame: CGRect(origin: .zero, size: bounds.size))
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        return (glass, content)
    }

    static func divider(x: CGFloat) -> NSView {
        let view = NSView(frame: CGRect(
            x: x, y: (height - controlHeight) / 2 + 4, width: 1, height: controlHeight - 8))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        return view
    }

    /// Cross-dissolves whatever `view` draws, over its own previous contents.
    ///
    /// AppKit animates neither an `NSTextField`'s `textColor` nor an image's
    /// tint, and both change the moment a take begins. A `CATransition` on the
    /// view's own layer covers every kind of redraw in one line, where explicit
    /// animations would have to name each property — and a colour that snaps
    /// mid-transition is exactly the hard edge these bars are trying to lose.
    static func crossfade(_ view: NSView, duration: CFTimeInterval = transition) {
        view.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        view.layer?.add(fade, forKey: "crossfade")
    }

    /// Fills a layer-backed view, animating the change when asked.
    ///
    /// The colour is resolved inside the view's own appearance: the semantic
    /// greys used for the inert state are dynamic, and `cgColor` read outside a
    /// drawing appearance resolves against whatever is current — which on these
    /// panels is not the vibrant dark the bar is actually drawn in.
    static func fill(
        _ view: NSView, with color: NSColor, animated: Bool,
        duration: CFTimeInterval = transition
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        if animated, let from = layer.backgroundColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = from
            animation.toValue = resolved
            animation.duration = duration
            layer.add(animation, forKey: "fill")
        }
        layer.backgroundColor = resolved
    }

    static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }
}

/// Where a floating bar goes.
///
/// Shared because the toolbar and the HUD appear in the same place one after
/// the other, and the illusion that they are one bar changing state survives
/// exactly as long as they agree on position. They did not: the toolbar sat
/// under the selection and the HUD jumped to the bottom of the screen the
/// moment recording began.
enum HUDPlacement {
    private static let gap: CGFloat = 10
    private static let edgeInset: CGFloat = 8

    /// Just below `anchor`, or just above it when there is no room below — a
    /// selection dragged to the bottom of the screen is the common case, not an
    /// edge case. Always clamped inside the visible frame.
    static func origin(for size: CGSize, under anchor: CGRect, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        var origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - gap - size.height)
        if origin.y < visible.minY + edgeInset {
            origin.y = anchor.maxY + gap
        }
        // Still off? The anchor is taller than the screen's usable height, so
        // put the bar inside it rather than off-screen entirely.
        if origin.y + size.height > visible.maxY - edgeInset {
            origin.y = max(visible.minY + edgeInset, anchor.minY + gap)
        }
        origin.x = min(max(origin.x, visible.minX + edgeInset),
                       visible.maxX - size.width - edgeInset)
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// Bottom-centre, for a take with no anchor to speak of — a whole display.
    static func origin(for size: CGSize, atBottomOf screen: NSScreen) -> CGPoint {
        CGPoint(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (screen.visibleFrame.minY + 24).rounded())
    }
}

/// A filled action button carrying a mark and a word — Record, then Stop.
///
/// Hand-drawn rather than an `NSButton`. Getting predictable padding out of a
/// borderless button carrying both an image and a title means guessing at
/// AppKit's own insets and at the rendered width of an SF Symbol, and the guess
/// was wrong the first time: the dot came out flush against the left edge.
/// A view that places its own two subviews cannot be wrong about that.
final class HUDPill: NSView {
    enum Mark {
        /// A filled circle, drawn rather than a symbol so its size is exact.
        case dot
        case symbol(String)
    }

    var onClick: () -> Void = {}

    /// Whether the pill is the live control or a placeholder for one.
    ///
    /// Stop exists from the moment the bar appears, but for as long as
    /// `SCStream.startCapture` takes there is nothing to stop —
    /// `RecordingCoordinator.stop()` requires `state == .recording`, so a press
    /// would silently do nothing. It used to be hidden for that window, which
    /// meant the bar changed shape twice inside half a second. Grey and inert
    /// keeps the shape and still says "not yet".
    /// Set through `setLive(_:animated:)`, because whether the change animates
    /// is the caller's business: colouring in when the take starts must fade,
    /// and going grey as the bar first appears must not — a Stop button
    /// crossfading out of red while the bar is still arriving is a red button
    /// nobody asked for.
    private(set) var isLive = true

    private static let horizontalPadding: CGFloat = 13
    private static let markSize: CGFloat = 11
    private static let markTextGap: CGFloat = 7
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Deliberately not the tint at a low alpha: a faint red Stop still reads as
    /// a red button, and this one must not be pressed yet.
    private static let inertFill = NSColor(white: 1, alpha: 0.10)

    static func width(for title: String) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return horizontalPadding * 2 + markSize + markTextGap + text
    }

    private let tint: NSColor
    private let label: NSTextField
    /// Kept so the mark can be dimmed with the rest of the pill; a dot and a
    /// glyph are tinted through different properties.
    private var markDot: NSView?
    private var markGlyph: NSImageView?

    init(title: String, mark: Mark, tint: NSColor, height: CGFloat = HUDMetrics.controlHeight) {
        self.tint = tint
        self.label = NSTextField(labelWithString: title)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width(for: title), height: height))
        wantsLayer = true
        layer?.cornerRadius = HUDMetrics.controlRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.cgColor

        let markY = ((height - Self.markSize) / 2).rounded()
        switch mark {
        case .dot:
            let dot = NSView(frame: CGRect(
                x: Self.horizontalPadding, y: markY,
                width: Self.markSize, height: Self.markSize))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.cgColor
            dot.layer?.cornerRadius = Self.markSize / 2
            addSubview(dot)
            markDot = dot
        case .symbol(let name):
            let glyph = NSImageView(frame: CGRect(
                x: Self.horizontalPadding, y: markY,
                width: Self.markSize, height: Self.markSize))
            glyph.image = HUDMetrics.symbol(name, pointSize: 10, weight: .bold)
            glyph.contentTintColor = .white
            glyph.imageScaling = .scaleProportionallyDown
            addSubview(glyph)
            markGlyph = glyph
        }

        label.font = Self.font
        label.textColor = .white
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(
            x: Self.horizontalPadding + Self.markSize + Self.markTextGap,
            y: ((height - label.frame.height) / 2).rounded()))
        addSubview(label)
    }

    func setLive(_ live: Bool, animated: Bool) {
        guard live != isLive else { return }
        isLive = live
        let ink: NSColor = isLive ? .white : .tertiaryLabelColor
        HUDMetrics.fill(self, with: isLive ? tint : Self.inertFill, animated: animated)
        if animated {
            HUDMetrics.crossfade(label)
            if let markGlyph { HUDMetrics.crossfade(markGlyph) }
        }
        label.textColor = ink
        markGlyph?.contentTintColor = ink
        if let markDot { HUDMetrics.fill(markDot, with: ink, animated: animated) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The subviews are decoration; the pill owns the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isLive else { return }
        layer?.backgroundColor = tint.blended(withFraction: 0.2, of: .black)?.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        guard isLive else { return }
        layer?.backgroundColor = tint.cgColor
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}
