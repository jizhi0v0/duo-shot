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
        /// Recognise the text in this capture and put it on the clipboard. Only
        /// ever reached from the context menu, and only on a still.
        var copyText: () -> Void = {}
        /// Upload, or copy the link once there is one, or retry after a failure —
        /// the card decides which from its own share state, so the stack does not
        /// have to hand down three closures for one button.
        var share: () -> Void = {}
    }

    static let cardSize = CGSize(width: 208, height: 132)
    /// Past this much horizontal travel the card is thrown out of the stack.
    static let swipeThreshold: CGFloat = 70

    private static let cornerRadius: CGFloat = 9
    private static let barHeight: CGFloat = 26
    private static let barInset: CGFloat = 8
    static let gestureSlop: CGFloat = 4

    /// `var`, and the tile's view is kept, because the file can change under a
    /// card that is still on screen: a redaction rewrites the staged capture in
    /// place, and a card showing the pixels that were just destroyed — or
    /// carrying them as a drag image — is the one outcome that feature cannot
    /// have.
    private var image: NSImage
    private var thumbnailView: NSImageView?
    /// Non-nil turns this into a video card: a play glyph and this string as a
    /// duration pill. A still needs neither — its thumbnail already says what it
    /// is, whereas one frame of a recording is indistinguishable from a
    /// screenshot of the same screen.
    private let badge: String?
    /// Colours the duration pill and adds a warning glyph.
    private let isIncomplete: Bool
    /// The file never reached the save folder. Adds its own badge, because
    /// nothing else on the card distinguishes this from an ordinary capture.
    private let saveFailed: Bool
    /// Whether the share button's tooltip advertises the Option-click one-time
    /// link. The modifier is read by the stack when the button fires — this is
    /// only how anyone finds out it is there, and a hint for a thing the
    /// service would refuse is worse than no hint.
    private let allowsOneTimeShare: Bool
    private var callbacks: Callbacks
    private var isDraggingOut = false
    private var mouseDownGlobal: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    private var actionBar: NSVisualEffectView!
    /// Every button in the bar, in the order they were built. The bar is laid
    /// out from whichever of them are visible — see `layoutActionBar`.
    private var barButtons: [NSButton] = []
    private static let barButtonWidth: CGFloat = 30
    private var shareButton: NSButton?
    private var buttonRing: ButtonRingView?
    private var centerRing: ButtonRingView?
    /// Non-nil only while uploading. The two rings are derived from this and
    /// the hover state, never set directly — see `refreshUploadIndicator`.
    private var uploadFraction: Double?
    private var tickTask: Task<Void, Never>?
    private var shareBadge: NSView?
    private(set) var shareState: ShareService.State?
    private var closeButton: NSView!
    private var centerButton: CenterActionView!
    private var isHovering = false

    init(image: NSImage, badge: String? = nil, isIncomplete: Bool = false,
         saveFailed: Bool = false, allowsOneTimeShare: Bool = false, callbacks: Callbacks) {
        self.image = image
        self.badge = badge
        self.isIncomplete = isIncomplete
        self.saveFailed = saveFailed
        self.allowsOneTimeShare = allowsOneTimeShare
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
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The disc in the middle of the card.
    ///
    /// Deliberately not an `NSButton`, and not hit-testable at all: every mouse
    /// event still falls through to `PreviewCardView`, which owns the gestures. A
    /// real control here would swallow `mouseDown` and take drag-out away from
    /// the middle of the card — which is exactly where a pointer reaching for a
    /// small tile lands. The card decides on mouse-*up* whether the press was a
    /// click on this disc or the beginning of a drag, and that is the only
    /// reading that leaves both gestures available.
    ///
    /// It still gets its own tracking area, because tracking is geometric and
    /// does not consult `hitTest`: the disc can light up under the pointer while
    /// staying invisible to event routing.
    private final class CenterActionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var trackingAreaRef: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
            // `.activeAlways` for the reason the card's own area is: this panel
            // is never the key window.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) { applyHighlight(true) }
        override func mouseExited(with event: NSEvent) { applyHighlight(false) }

        /// The only thing that says this disc is a target rather than a badge.
        /// There is no pointing-hand cursor to lean on — cursor rects belong to
        /// the window, and this one is a non-activating panel that never becomes
        /// key.
        func applyHighlight(_ on: Bool) {
            layer?.backgroundColor = NSColor(white: 0.08, alpha: on ? 0.85 : 0.55).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: on ? 0.8 : 0.3).cgColor
        }
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
        thumbnailView = imageView

        buildCenterButton()
        if let badge { buildDurationPill(badge) }
        if saveFailed { buildSaveWarning() }

        // Viewing is not in this bar: it is the button in the middle of the card.
        // These two are the actions that consume the card and send the capture
        // somewhere else; opening it is what you do *before* deciding, so it gets
        // the position your eye is already on.
        let specs: [(symbol: String, tip: String, action: Selector)] = [
            ("doc.on.doc", "Copy", #selector(copyTapped)),
            ("folder", "Show in Finder", #selector(revealTapped)),
            ("square.and.arrow.up", "Upload and copy link", #selector(shareTapped)),
        ]
        let buttonWidth = Self.barButtonWidth
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
            barButtons.append(button)
            if spec.symbol == "square.and.arrow.up" { shareButton = button }
        }
        // One source of truth for how this button looks.
        //
        // It used to be set here at construction *and* in `setShareState`, and
        // the two disagreed: a fresh card has no share state, so nothing ever
        // pushes one and `setShareState` never ran — leaving whatever glyph was
        // hard-coded here. The card shipped showing a link before anything had
        // been uploaded. `--selftest-share-card` missed it because it reached
        // "idle" by pushing `nil` explicitly, which is the one way a real card
        // never gets there.
        setShareState(nil)

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

    /// The button in the middle of the card: open this capture in DuoShot's own
    /// window.
    ///
    /// Dead centre because it is the primary thing you do with a card, and
    /// because it is where the viewer will grow into an editor — a button that
    /// moves once annotation lands would cost the muscle memory it is building
    /// now.
    ///
    /// A recording gets the play glyph it already had rather than an eye. The
    /// mark that says "this is a recording" and the target that says "open it"
    /// want the same spot and mean the same thing, so they are one control.
    private func buildCenterButton() {
        let diameter: CGFloat = 36
        let well = CenterActionView(frame: CGRect(
            x: ((bounds.width - diameter) / 2).rounded(),
            y: ((bounds.height - diameter) / 2).rounded(),
            width: diameter, height: diameter))
        well.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        well.wantsLayer = true
        well.layer?.cornerRadius = diameter / 2
        well.layer?.borderWidth = 1
        well.applyHighlight(false)

        let isVideo = badge != nil
        let glyph = PassthroughImageView(frame: well.bounds)
        // Two point sizes for one disc, because SF Symbols are sized by cap
        // height rather than by how much room they take: `eye` is a wide, low
        // glyph and `play.fill` a narrow, tall one, so the same number leaves the
        // eye touching the ring while the triangle still has air around it.
        glyph.image = isVideo
            ? Self.symbol("play.fill", pointSize: 14, description: "Play")
            : Self.symbol("eye", pointSize: 12, description: "View")
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        well.addSubview(glyph)
        // A still's card is a picture, and a disc parked in the middle of it is
        // in the way of the one thing the card is for. A recording's is not: the
        // glyph is what distinguishes it from a screenshot of the same screen, so
        // it has to be there before the pointer arrives.
        well.alphaValue = isVideo ? 1 : 0
        addSubview(well)
        centerButton = well
    }

    /// The running time, top-right.
    ///
    /// That corner specifically: the bottom edge belongs to the action bar, the
    /// top-left to the close button and the middle to the open button, so it is
    /// the one place that is never occupied.
    private func buildDurationPill(_ duration: String) {
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
        topRightUsedWidth = pill.frame.width + Self.badgeGap
    }

    /// How much of the top-right corner the duration pill has already taken.
    var topRightUsedWidth: CGFloat = 0
    static let badgeInset: CGFloat = 6
    private static let badgeGap: CGFloat = 5

    /// Says the file is not where the user thinks it is.
    ///
    /// Top-right, the same corner the duration pill uses and for the same
    /// reason: the bottom edge belongs to the action bar and the top-left to the
    /// close button. On a recording card that already has a pill this sits to its
    /// left rather than under it — two rows of badges over a thumbnail reads as a
    /// dialog, and there is only ever one line to say.
    private func buildSaveWarning() {
        let label = NSTextField(labelWithString: "⚠ Not saved")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let padding = CGSize(width: 7, height: 3)
        let pill = PassthroughView(frame: CGRect(
            x: bounds.width - label.frame.width - padding.width * 2
                - Self.badgeInset - topRightUsedWidth,
            y: bounds.height - label.frame.height - padding.height * 2 - Self.badgeInset,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2))
        pill.autoresizingMask = [.minXMargin, .minYMargin]
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pill.frame.height / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        pill.toolTip = "Saving to your folder failed. The file is still in DuoShot's "
            + "staging folder — copy or drag it somewhere before it is pruned."
        label.setFrameOrigin(CGPoint(x: padding.width, y: padding.height))
        pill.addSubview(label)
        addSubview(pill)
    }

    // MARK: - Share state

    /// The card's appearance while its capture uploads, and after.
    ///
    /// Everything happens on the one button that started it: ring while
    /// uploading, tick when it lands, retry glyph when it does not. The
    /// alternative — a ring in the middle of the card — covered the open button,
    /// which is the primary thing a card is for.
    ///
    /// The tick is not decoration. Without it "done" and "never uploaded" look
    /// identical, so the one moment that confirms the link is on the clipboard
    /// would pass with no sign at all.
    ///
    /// The glyphs go `square.and.arrow.up` → ring → `checkmark` →
    /// `link.circle.fill`, and the last one is the interesting choice. "Copy the
    /// link" is two ideas and there is no glyph for both: `doc.on.clipboard`
    /// says copy but sits next to this bar's existing `doc.on.doc`, and two
    /// copy-ish glyphs side by side is the one arrangement guaranteed to
    /// confuse. So the button says *link* and lets **filled-vs-outline** carry
    /// the state — every other glyph in the bar is an outline, so the filled one
    /// reads as "this exists now", and pressing it is confirmed by the flash
    /// rather than by the icon.
    func setThumbnail(_ image: NSImage) {
        self.image = image
        thumbnailView?.image = image
    }

    /// Sizes the bar to the buttons that are actually in it.
    ///
    /// The share button is hidden until sharing is configured, and the bar used
    /// to keep its slot regardless: a pill wide enough for three buttons with
    /// two in it, so an unconfigured install got a permanent empty socket where
    /// the upload icon would have been. Reported as "the preview still shows the
    /// icon placeholder, but there is no upload icon".
    ///
    /// Re-run from `setShareState` rather than only at construction, because the
    /// answer changes under a card that is already on screen — configuring the
    /// endpoint mid-session is exactly when someone is looking at one.
    private func layoutActionBar() {
        guard let actionBar else { return }
        let visible = barButtons.filter { !$0.isHidden }
        let width = CGFloat(visible.count) * Self.barButtonWidth + 6
        actionBar.frame = CGRect(
            x: ((bounds.width - width) / 2).rounded(), y: Self.barInset,
            width: width, height: Self.barHeight)
        for (index, button) in visible.enumerated() {
            button.setFrameOrigin(
                CGPoint(x: 3 + CGFloat(index) * Self.barButtonWidth, y: 0))
        }
    }

    /// The bar's frame and how many buttons are standing in it, for
    /// `--selftest-share-card`.
    var actionBarLayoutForTest: (frame: CGRect, visibleButtons: Int) {
        (actionBar?.frame ?? .zero, barButtons.filter { !$0.isHidden }.count)
    }

    func setShareState(_ state: ShareService.State?) {
        shareState = state

        shareBadge?.removeFromSuperview()
        shareBadge = nil
        tickTask?.cancel()
        tickTask = nil

        switch state {
        case .uploading(let fraction):
            uploadFraction = fraction
            refreshUploadIndicator()
            shareButton?.isHidden = false
            shareButton?.isEnabled = false
            shareButton?.image = nil
            shareButton?.toolTip = "Uploading… \(Int(fraction * 100))%"

        case .done:
            uploadFraction = nil
            refreshUploadIndicator()
            shareButton?.isHidden = false
            shareButton?.isEnabled = true
            shareButton?.toolTip = "Copy link"
            shareButton?.image = Self.symbol(
                "checkmark", pointSize: 12, weight: .semibold, description: "Uploaded")
            shareButton?.contentTintColor = .systemGreen
            // Back to the link glyph after a beat: the tick answers "did it
            // work", and once answered the button should say what it does next.
            tickTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1600))
                guard !Task.isCancelled, let self else { return }
                self.shareButton?.contentTintColor = .white
                self.shareButton?.image = Self.symbol(
                    "link", pointSize: 12, description: "Copy link")
            }

        case .failed(let message, let retryable):
            uploadFraction = nil
            refreshUploadIndicator()
            shareButton?.isHidden = false
            shareButton?.isEnabled = retryable
            shareButton?.contentTintColor = .white
            shareButton?.toolTip = message
            shareButton?.image = Self.symbol(
                retryable ? "arrow.clockwise" : "square.and.arrow.up", pointSize: 12,
                description: retryable ? "Retry" : "Upload")
            buildShareWarning(message)

        case .none:
            uploadFraction = nil
            refreshUploadIndicator()
            shareButton?.isHidden = !ShareService.shared.isConfigured
            shareButton?.isEnabled = true
            shareButton?.contentTintColor = .white
            shareButton?.toolTip = allowsOneTimeShare
                ? "Upload and copy link\nOption-click: one-time link, deleted after it is opened"
                : "Upload and copy link"
            // The platform's own glyph for this action. `arrow.up.circle` says
            // "upload" to a developer; this says "share" to everyone, and that
            // is what the button does.
            shareButton?.image = Self.symbol(
                "square.and.arrow.up", pointSize: 12, description: "Upload")
        }

        // Last, and for every state: each branch above decides whether the share
        // button is on screen, and the bar has to be the width of what it ends up
        // holding.
        layoutActionBar()
    }

    /// Where the progress is shown depends on whether the pointer is here.
    ///
    /// **Not hovering: a ring in the middle of the card.** This is the case that
    /// matters most and the one the first design got wrong — the ring lived in
    /// the action bar, which is `alpha = 0` until the pointer arrives, so an
    /// automatic upload ran with nothing on screen to say so.
    ///
    /// **Hovering: a small ring on the share button, and the card's own controls
    /// back.** Hovering is the moment someone is reaching for open or copy, so
    /// the middle of the card has to be theirs again. The feedback moves to the
    /// button that started it and stops covering the primary action.
    ///
    /// Both are derived from `uploadFraction` + `isHovering` rather than set at
    /// the call sites, so the two ways in — a progress callback and the pointer
    /// crossing the edge — cannot disagree.
    private func refreshUploadIndicator() {
        guard let fraction = uploadFraction else {
            centerRing?.removeFromSuperview(); centerRing = nil
            buttonRing?.removeFromSuperview(); buttonRing = nil
            centerButton?.isHidden = false
            return
        }

        if isHovering {
            centerRing?.removeFromSuperview()
            centerRing = nil
            centerButton?.isHidden = false
            showButtonRing(fraction)
        } else {
            buttonRing?.removeFromSuperview()
            buttonRing = nil
            // The open button and the ring want the same disc, and while the
            // pointer is away the ring is the only thing worth saying.
            centerButton?.isHidden = true
            showCenterRing(fraction)
        }
    }

    private func showCenterRing(_ fraction: Double) {
        if centerRing == nil {
            let diameter: CGFloat = 36
            let ring = ButtonRingView(diameter: diameter)
            ring.setFrameOrigin(CGPoint(
                x: ((bounds.width - diameter) / 2).rounded(),
                y: ((bounds.height - diameter) / 2).rounded()))
            ring.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(ring)
            centerRing = ring
        }
        centerRing?.fraction = fraction
    }

    /// In the bar rather than on the button's own layer: `NSButton` manages that
    /// layer itself and things added to it do not reliably survive — the same
    /// reason the close button's circle is drawn by a container view.
    private func showButtonRing(_ fraction: Double) {
        guard let bar = actionBar, let button = shareButton else { return }
        if buttonRing == nil {
            let diameter: CGFloat = 20
            let ring = ButtonRingView(diameter: diameter)
            ring.setFrameOrigin(CGPoint(
                x: (button.frame.midX - diameter / 2).rounded(),
                y: (button.frame.midY - diameter / 2).rounded()))
            bar.addSubview(ring)
            buttonRing = ring
        }
        buttonRing?.fraction = fraction
    }

    /// Same corner and same shape as the "Not saved" badge, because it says the
    /// same class of thing: something you would otherwise believe worked did not.
    private func buildShareWarning(_ message: String) {
        let label = NSTextField(labelWithString: "⚠ Not shared")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let padding = CGSize(width: 7, height: 3)
        let pill = PassthroughView(frame: CGRect(
            x: bounds.width - label.frame.width - padding.width * 2
                - Self.badgeInset - topRightUsedWidth,
            y: bounds.height - label.frame.height - padding.height * 2 - Self.badgeInset,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2))
        pill.autoresizingMask = [.minXMargin, .minYMargin]
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pill.frame.height / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        pill.toolTip = message
        label.setFrameOrigin(CGPoint(x: padding.width, y: padding.height))
        pill.addSubview(label)
        addSubview(pill)
        shareBadge = pill
    }

    /// SF Symbols render at their natural size unless told otherwise, and
    /// `imageScaling` only ever scales *down*. Without an explicit point size the
    /// glyphs came out several times larger than their buttons.
    static func symbol(
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
        if badge == nil { centerButton.alphaValue = hovering ? 1 : 0 }
        refreshUploadIndicator()
        displayIfNeeded()
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            actionBar.animator().alphaValue = hovering ? 1 : 0
            closeButton.animator().alphaValue = hovering ? 1 : 0
            // A still's open button fades in with the rest of the controls. A
            // recording's is already there and stays: it used to recede on hover,
            // which made sense while it was only a marker, and is exactly
            // backwards now that it is the thing being reached for.
            if badge == nil { centerButton.animator().alphaValue = hovering ? 1 : 0 }
        }
        refreshUploadIndicator()
        callbacks.hoverChanged(hovering)
    }

    // MARK: - Context menu

    /// The card's only right-click menu, and for now it holds one thing.
    ///
    /// Everything else a card does is a button in the action bar, and Copy Text
    /// stays out of it: that bar is three buttons wide inside a 208 pt tile, and
    /// a fourth glyph for an action taken once in fifty would crowd the three
    /// that are not.
    ///
    /// A recording gets no menu at all rather than a disabled item. There is no
    /// third thing this menu could offer a video, so an empty grey rectangle is
    /// all a right-click would produce.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard badge == nil else { return nil }
        let menu = NSMenu()
        menu.addItem(.action("Copy Text") { [weak self] in self?.callbacks.copyText() })
        return menu
    }

    /// Raised by hand rather than left to `NSView`'s default handling.
    ///
    /// The card lives in a non-activating panel that never becomes key, and
    /// AppKit's default right-click path routes through the responder chain of a
    /// window that, here, is deliberately not in it. `popUpContextMenu` does not
    /// care.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
        // A single click on the disc in the middle. Decided here rather than by
        // making the disc a control — see `CenterActionView` for why.
        //
        // Unconditional on the disc's own visibility: on a still it only fades in
        // on hover, and you cannot click a card you are not hovering, so the two
        // can never disagree. A click in the middle means open either way.
        let point = convert(event.locationInWindow, from: nil)
        if centerButton.frame.contains(point) {
            callbacks.open()
            return
        }
        if event.clickCount >= 2 { callbacks.open() }
    }

    // MARK: - Actions

    @objc private func openTapped() { callbacks.open() }
    @objc private func shareTapped() {
        // The card confirms its own press. Copy and reveal get away without
        // this because they consume the card — the card vanishing *is* the
        // feedback. This one deliberately does not dismiss, so without a flash
        // a successful copy is indistinguishable from a dead button.
        if case .done = shareState { flashCopied() }
        callbacks.share()
    }

    /// A tick and a quick pulse, then back to the link glyph.
    private func flashCopied() {
        guard let button = shareButton else { return }
        tickTask?.cancel()

        button.contentTintColor = .systemGreen
        button.image = Self.symbol(
            "checkmark", pointSize: 12, weight: .semibold, description: "Copied")

        // Alpha rather than a layer transform: `NSButton` owns its layer and
        // things done to it do not reliably survive, which is the same reason
        // the close button's circle is drawn by a container view.
        button.alphaValue = 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            button.animator().alphaValue = 1
        }

        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self else { return }
            self.shareButton?.contentTintColor = .white
            self.shareButton?.image = Self.symbol(
                "link", pointSize: 12, description: "Copy link")
        }
    }

    @objc private func copyTapped() { callbacks.copy() }
    @objc private func revealTapped() { callbacks.reveal() }
    @objc private func closeTapped() { callbacks.close() }
}
