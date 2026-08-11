import AppKit

/// The metrics and controls shared by the bar's two faces: the selection toolbar
/// and the recording HUD.
///
/// They started as two separate windows, built a week apart and looking it —
/// different heights, corner radii and button idioms, one using an `NSButton`
/// with an image and a title and the other hand-placing subviews. Sharing these
/// pieces is what made them agree; `FloatingBarPanel` then made them the same
/// window, which is why nothing here owns a panel or a position any more.
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
    /// Whatever is drawn goes in the returned `content` view — for the bar, that
    /// is the face — and not straight onto the glass as a sibling. The header is
    /// explicit that only `contentView` is guaranteed to sit inside the effect:
    /// "arbitrary subviews aren't guaranteed specific behavior with regard to
    /// z-order in relation to the content view or glass effect." Siblings happen
    /// to look right and are not promised to keep doing so.
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

    /// How big a pill is inside, which is not the same question as how tall it
    /// is.
    ///
    /// The overlay's toolbar and the recording HUD are bars that appear over
    /// someone's screen for a few seconds and are sized to stay out of the way.
    /// The image editor's bar is furniture in a window that is looked at for
    /// minutes, and it was sized like the other two — a 37-point square with a
    /// 10-point glyph in the middle of it, nine of them in a row. Reported as
    /// the whole thing being 小气: cramped, and not obviously pressable.
    ///
    /// One struct rather than a second pill class, because everything else about
    /// the two is identical and a fork would drift.
    struct Sizing: Sendable {
        var horizontalPadding: CGFloat = 13
        var markSize: CGFloat = 11
        var markTextGap: CGFloat = 7
        var fontSize: CGFloat = 13
        var symbolPointSize: CGFloat = 10
        var cornerRadius: CGFloat = HUDMetrics.controlRadius

        var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

        static let standard = Sizing()
        /// The image editor's: a wider target, a glyph big enough to read as the
        /// thing it depicts, and a corner that matches a 36-point control.
        static let editor = Sizing(
            horizontalPadding: 15, markSize: 16, markTextGap: 8, fontSize: 13.5,
            symbolPointSize: 14, cornerRadius: 10)
    }

    private let sizing: Sizing
    private static let horizontalPadding: CGFloat = 13
    private static let markSize: CGFloat = 11
    private static let markTextGap: CGFloat = 7
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Deliberately not the tint at a low alpha: a faint red Stop still reads as
    /// a red button, and this one must not be pressed yet.
    private static let inertFill = NSColor(white: 1, alpha: 0.10)

    /// An empty title is a pill that is only its mark — what a bar full of tools
    /// needs, where four words would be wider than the window and the four marks
    /// read as one control. Such a pill carries its meaning in a `toolTip`.
    static func width(for title: String, sizing: Sizing = .standard) -> CGFloat {
        guard !title.isEmpty else { return sizing.horizontalPadding * 2 + sizing.markSize }
        let text = (title as NSString)
            .size(withAttributes: [.font: sizing.font]).width.rounded(.up)
        return sizing.horizontalPadding * 2 + sizing.markSize + sizing.markTextGap + text
    }

    private let tint: NSColor
    private let label: NSTextField
    /// Kept so the mark can be dimmed with the rest of the pill; a dot and a
    /// glyph are tinted through different properties.
    private var markDot: NSView?
    private var markGlyph: NSImageView?

    init(
        title: String, mark: Mark, tint: NSColor,
        height: CGFloat = HUDMetrics.controlHeight, sizing: Sizing = .standard,
        minimumWidth: CGFloat = 0
    ) {
        self.tint = tint
        self.sizing = sizing
        self.label = NSTextField(labelWithString: title)
        let width = max(minimumWidth, Self.width(for: title, sizing: sizing))
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = sizing.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.cgColor

        let markY = ((height - sizing.markSize) / 2).rounded()
        // Centred when there is no title to sit beside.
        let markX = title.isEmpty
            ? ((width - sizing.markSize) / 2).rounded() : sizing.horizontalPadding
        switch mark {
        case .dot:
            let dot = NSView(frame: CGRect(
                x: markX, y: markY,
                width: sizing.markSize, height: sizing.markSize))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.cgColor
            dot.layer?.cornerRadius = sizing.markSize / 2
            addSubview(dot)
            markDot = dot
        case .symbol(let name):
            let glyph = NSImageView(frame: CGRect(
                x: markX, y: markY,
                width: sizing.markSize, height: sizing.markSize))
            glyph.image = HUDMetrics.symbol(
                name, pointSize: sizing.symbolPointSize, weight: .bold)
            glyph.contentTintColor = .white
            glyph.imageScaling = .scaleProportionallyDown
            addSubview(glyph)
            markGlyph = glyph
        }

        label.font = sizing.font
        label.textColor = .white
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(
            x: sizing.horizontalPadding + sizing.markSize + sizing.markTextGap,
            y: ((height - label.frame.height) / 2).rounded()))
        addSubview(label)
    }

    /// Whether this pill is the chosen one of a set — the tool in force in
    /// `EditToolbar`, where four pills are one control and three of them have to
    /// look like the road not taken.
    ///
    /// Starts true because the constructor fills with `tint`, and the two must
    /// agree or the first `setSelected(false)` would be a no-op against a pill
    /// that is already coloured in. Distinct from `isLive`: an unselected tool is
    /// perfectly pressable, and keeps its white ink to say so.
    private(set) var isSelected = true

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        guard isLive else { return }
        HUDMetrics.fill(self, with: selected ? tint : Self.inertFill, animated: animated)
    }

    /// Changes the word without changing the pill's width.
    ///
    /// Only for a control whose titles are all the same length — the text tool's
    /// point sizes are two digits apiece — because a pill that resized itself
    /// would move everything to its right, and `EditToolbar` is built on its
    /// geometry being a constant.
    func setTitle(_ title: String) {
        guard label.stringValue != title else { return }
        label.stringValue = title
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(
            x: sizing.horizontalPadding + sizing.markSize + sizing.markTextGap,
            y: ((bounds.height - label.frame.height) / 2).rounded()))
    }

    func setLive(_ live: Bool, animated: Bool) {
        guard live != isLive else { return }
        isLive = live
        let ink: NSColor = isLive ? .white : .tertiaryLabelColor
        HUDMetrics.fill(
            self, with: isLive && isSelected ? tint : Self.inertFill, animated: animated)
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
    ///
    /// `isHidden` has to be answered here, because the check that normally makes
    /// a hidden view untouchable lives in `NSView`'s own `hitTest` — the one this
    /// replaces. `EditToolbar` keeps every pill it has and hides the ones its
    /// state does not use, and without this an invisible pill parked at the
    /// container's origin sat over the visible one and ate every click on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
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
