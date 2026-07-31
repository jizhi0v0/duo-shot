import AppKit

/// One preview card inside the scrolling stack.
///
/// A view rather than a window: the stack used to be one `NSPanel` per capture,
/// which made "show more, and scroll" impossible and meant every arrival or
/// dismissal had to reposition live windows. Cards now live in a scroll view
/// inside a single panel.
///
/// The size is uniform. Sizing each card to its own capture made the column
/// ragged and made a card's position depend on what else was on screen; images
/// letterbox inside a constant tile instead.
final class PreviewCardView: NSView {
    struct Callbacks {
        var copy: () -> Void = {}
        var reveal: () -> Void = {}
        var close: () -> Void = {}
        var open: () -> Void = {}
        var hoverChanged: (Bool) -> Void = { _ in }
        var beginDrag: (NSEvent, NSImage) -> Void = { _, _ in }
    }

    static let cardSize = CGSize(width: 208, height: 132)
    /// Past this much horizontal travel the card is thrown out of the stack.
    static let swipeThreshold: CGFloat = 70

    private static let cornerRadius: CGFloat = 9
    private static let barHeight: CGFloat = 26
    private static let barInset: CGFloat = 8
    static let gestureSlop: CGFloat = 4

    private let image: NSImage
    /// Non-nil turns this into a video card: a play glyph and this string as a
    /// duration pill. A still needs neither — its thumbnail already says what it
    /// is, whereas one frame of a recording is indistinguishable from a
    /// screenshot of the same screen.
    private let badge: String?
    /// Colours the duration pill and adds a warning glyph.
    private let isIncomplete: Bool
    private var callbacks: Callbacks
    private var isDraggingOut = false
    private var mouseDownGlobal: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    private var actionBar: NSVisualEffectView!
    private var closeButton: NSView!
    private var playGlyph: NSView?
    private var isHovering = false

    init(image: NSImage, badge: String? = nil, isIncomplete: Bool = false,
         callbacks: Callbacks) {
        self.image = image
        self.badge = badge
        self.isIncomplete = isIncomplete
        self.callbacks = callbacks
        super.init(frame: CGRect(origin: .zero, size: Self.cardSize))
        wantsLayer = true
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The callbacks close over the card's own `Item`, so they can only be built
    /// once the card exists. Installed in a second step rather than through the
    /// initialiser to avoid a chicken-and-egg dance at the call site.
    func apply(_ callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // No `isFlipped` override — NSView already returns false, and the @objc
    // getter sits in AppKit's layout hot path.

    // MARK: - Subviews

    private final class PassthroughImageView: NSImageView {
        /// Every mouse event falls through to `PreviewCardView`, which owns the
        /// gestures.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Same contract for the decoration that is not a control. An `NSTextField`
    /// answers `hitTest` with itself even when it is a plain label, which would
    /// leave a corner of the card where drag and double-click quietly stop
    /// working.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func buildSubviews() {
        let imageView = PassthroughImageView(frame: bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        // Aspect-fit inside the constant tile; the backing shows as letterboxing.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        imageView.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.96).cgColor
        addSubview(imageView)

        if let badge { buildVideoDecoration(duration: badge) }

        let specs: [(symbol: String, tip: String, action: Selector)] = [
            ("doc.on.doc", "Copy", #selector(copyTapped)),
            ("folder", "Show in Finder", #selector(revealTapped)),
        ]
        let buttonWidth: CGFloat = 30
        let barWidth = CGFloat(specs.count) * buttonWidth + 6
        let bar = NSVisualEffectView(frame: CGRect(
            x: ((bounds.width - barWidth) / 2).rounded(),
            y: Self.barInset,
            width: barWidth,
            height: Self.barHeight))
        bar.autoresizingMask = [.minXMargin, .maxXMargin]
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = Self.barHeight / 2
        bar.layer?.cornerCurve = .continuous
        bar.layer?.masksToBounds = true
        bar.alphaValue = 0
        addSubview(bar)
        actionBar = bar

        for (index, spec) in specs.enumerated() {
            let button = FirstMouseButton(frame: CGRect(
                x: 3 + CGFloat(index) * buttonWidth, y: 0,
                width: buttonWidth, height: Self.barHeight))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = Self.symbol(spec.symbol, pointSize: 12, description: spec.tip)
            button.contentTintColor = .white
            button.toolTip = spec.tip
            button.target = self
            button.action = spec.action
            bar.addSubview(button)
        }

        // Dismiss, top-left, the way CleanShot places it. The circle is drawn by
        // a container rather than the button's own layer: NSButton manages that
        // layer itself and a background set on it does not survive.
        let closeSize: CGFloat = 18
        let closeWell = NSView(frame: CGRect(
            x: 6, y: bounds.height - closeSize - 6, width: closeSize, height: closeSize))
        closeWell.autoresizingMask = [.minYMargin]
        closeWell.wantsLayer = true
        closeWell.layer?.cornerRadius = closeSize / 2
        closeWell.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.75).cgColor
        // A hairline so the circle reads as a control against a dark screenshot,
        // where a black disc on black is invisible.
        closeWell.layer?.borderWidth = 1
        closeWell.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        closeWell.alphaValue = 0

        let close = FirstMouseButton(frame: CGRect(
            origin: .zero, size: CGSize(width: closeSize, height: closeSize)))
        close.bezelStyle = .accessoryBarAction
        close.isBordered = false
        close.image = Self.symbol("xmark", pointSize: 8, weight: .bold, description: "Dismiss")
        close.contentTintColor = .white
        close.toolTip = "Dismiss"
        close.target = self
        close.action = #selector(closeTapped)
        closeWell.addSubview(close)

        addSubview(closeWell)
        closeButton = closeWell
    }

    /// The two marks that separate a recording from a screenshot: a play glyph
    /// in the middle and the running time in the top-right.
    ///
    /// Top-right for the pill specifically — the bottom edge belongs to the
    /// action bar and the top-left to the close button, so it is the one corner
    /// that is never occupied.
    private func buildVideoDecoration(duration: String) {
        let diameter: CGFloat = 34
        let well = PassthroughView(frame: CGRect(
            x: ((bounds.width - diameter) / 2).rounded(),
            y: ((bounds.height - diameter) / 2).rounded(),
            width: diameter, height: diameter))
        well.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        well.wantsLayer = true
        well.layer?.cornerRadius = diameter / 2
        well.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        well.layer?.borderWidth = 1
        well.layer?.borderColor = NSColor(white: 1, alpha: 0.3).cgColor

        let glyph = PassthroughImageView(frame: well.bounds)
        glyph.image = Self.symbol("play.fill", pointSize: 14, description: "Recording")
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        well.addSubview(glyph)
        addSubview(well)
        playGlyph = well

        let label = NSTextField(labelWithString: isIncomplete ? "⚠ \(duration)" : duration)
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let padding = CGSize(width: 7, height: 3)
        let pill = PassthroughView(frame: CGRect(
            x: bounds.width - label.frame.width - padding.width * 2 - 6,
            y: bounds.height - label.frame.height - padding.height * 2 - 6,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2))
        pill.autoresizingMask = [.minXMargin, .minYMargin]
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pill.frame.height / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = isIncomplete
            ? NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            : NSColor(white: 0.08, alpha: 0.72).cgColor
        pill.toolTip = isIncomplete
            ? "This take ended unexpectedly. The file holds what was written before it stopped."
            : nil
        label.setFrameOrigin(CGPoint(x: padding.width, y: padding.height))
        pill.addSubview(label)
        addSubview(pill)
    }

    /// SF Symbols render at their natural size unless told otherwise, and
    /// `imageScaling` only ever scales *down*. Without an explicit point size the
    /// glyphs came out several times larger than their buttons.
    private static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium,
        description: String
    ) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        return image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        // `.activeAlways`: the panel is never key, so `.activeInKeyWindow` would
        // never fire. `.inVisibleRect` keeps the area correct as the card scrolls.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        // The buttons install their own tracking areas, so moving onto one
        // delivers a spurious exit for this view. Ignore it while the pointer is
        // still within our bounds, or the action bar flickers away under the
        // cursor that is reaching for it.
        let location = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(location) else { return }
        setHovering(false)
    }

    /// For `--selftest-preview`, which has no pointer to move.
    func setHoverForTest(_ hovering: Bool) {
        setHovering(hovering)
        actionBar.alphaValue = hovering ? 1 : 0
        closeButton.alphaValue = hovering ? 1 : 0
        displayIfNeeded()
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            actionBar.animator().alphaValue = hovering ? 1 : 0
            closeButton.animator().alphaValue = hovering ? 1 : 0
            // Recedes rather than disappears: it is what marks the card as a
            // recording, and hovering is exactly when you are deciding what the
            // card is.
            playGlyph?.animator().alphaValue = hovering ? 0.35 : 1
        }
        callbacks.hoverChanged(hovering)
    }

    // MARK: - Gestures

    override func mouseDown(with event: NSEvent) {
        mouseDownGlobal = NSEvent.mouseLocation
        isDraggingOut = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownGlobal, !isDraggingOut else { return }
        let current = NSEvent.mouseLocation
        guard hypot(current.x - start.x, current.y - start.y) > Self.gestureSlop else { return }
        // A mouse drag is now unambiguously "take this file somewhere". Dismissal
        // is a trackpad swipe, which arrives as a scroll event and never as a
        // drag — trying to serve both from `mouseDragged` meant one of them had
        // to lose, and the swipe is what the user actually reaches for.
        isDraggingOut = true
        callbacks.beginDrag(event, image)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownGlobal = nil
            isDraggingOut = false
        }
        guard !isDraggingOut, mouseDownGlobal != nil else { return }
        if event.clickCount >= 2 { callbacks.open() }
    }

    // MARK: - Actions

    @objc private func copyTapped() { callbacks.copy() }
    @objc private func revealTapped() { callbacks.reveal() }
    @objc private func closeTapped() { callbacks.close() }
}
