import AppKit

/// The floating control bar shown while a recording runs.
///
/// The one hard constraint that separates it from the selection overlay: it
/// **must never become key**. The overlay takes the keyboard because nothing
/// else needs it during a selection; a recording is the opposite situation —
/// the user is demonstrating an app and typing into it, and a HUD that steals
/// key status would break their typing for the length of the take. That is also
/// why `acceptsFirstMouse` is not optional here: in a non-key window the first
/// click on Stop would otherwise be swallowed as an activation click.
final class RecordingHUDPanel: NSPanel {
    /// Test hook, mirroring `OverlayPanel` / `PreviewPanel`. With `.none` the
    /// panel is invisible to ScreenCaptureKit outright — which is what we ship,
    /// and which also makes an exclusion test unable to fail, so the self-test
    /// can turn it off to prove the test responds.
    static var usesSharingTypeNone = true

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, view: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: isFloatingPanel resets `level`, so it goes first.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Same level as the preview stack: above ordinary floating windows, well
        // below the overlay's shielding level, so starting a new selection
        // covers the HUD rather than fighting it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        sharingType = Self.usesSharingTypeNone ? .none : .readOnly

        contentView = view
    }
}

/// The bar's contents: a pulsing record dot, the elapsed time, Stop and Discard.
///
/// Built from `HUDMetrics` and `HUDPill`, the same pieces the pre-record toolbar
/// uses. The two appear in sequence, in the same place, during one continuous
/// action — arm the selection, start the take — so they have to read as one bar
/// changing state rather than as two unrelated pieces of UI.
///
/// It carries no audio controls, and cannot: `SCStream.updateConfiguration`
/// during a recording ends it (see `RecordingEngine`). Those choices are made on
/// the toolbar, before the take starts.
final class RecordingHUDView: NSView {
    /// Fills the whole bar with flat magenta instead of drawing the real UI.
    ///
    /// The exclusion self-test needs a colour that cannot occur in a screenshot
    /// of an ordinary desktop. Same trick, and the same reason, as the overlay's
    /// debug border in M2 — with one lesson carried over: it is drawn as a solid
    /// fill rather than an outline, because the outline version was covered by
    /// another layer and produced a test that could never fail.
    static var debugFillsMagenta = false

    struct Callbacks {
        var stop: () -> Void = {}
        var discard: () -> Void = {}
    }

    /// What the bar is showing.
    ///
    /// `starting` exists because `SCStream.startCapture` is not reliably quick.
    /// Measured 2026-07-31 it is 190-340 ms, but three takes that day took
    /// 3.8-4.3 s inside that one call, with nothing logged anywhere in the
    /// system while it sat there. The HUD used to be shown only once the call
    /// returned, so those seconds had the selection gone and nothing in its
    /// place, which reads as "the app is broken" rather than "it is starting".
    enum Phase {
        case starting
        case recording
    }

    private static let dotSize: CGFloat = 9
    private static let timeWidth: CGFloat = 46
    private static let startingWidth: CGFloat = 78
    private static let stopTitle = "Stop"

    /// The running bar. Also the panel's size at creation, since that is the
    /// state it spends the take in.
    static var barSize: CGSize {
        CGSize(width: width(for: .recording), height: HUDMetrics.height)
    }

    /// Width per state, because the two states hold very different amounts.
    ///
    /// A bar sized for the running state and then emptied down to a dot and one
    /// word leaves two thirds of itself blank, which reads as broken rather than
    /// as waiting. Resizing once, at the moment the take actually begins, is a
    /// state change the user is expecting anyway.
    static func width(for phase: Phase) -> CGFloat {
        let lead = HUDMetrics.margin + Self.dotSize + 8
        switch phase {
        case .starting:
            return lead + Self.startingWidth + HUDMetrics.margin
        case .recording:
            return lead + Self.timeWidth
                + HUDMetrics.groupGap + 1 + HUDMetrics.groupGap
                + HUDPill.width(for: Self.stopTitle) + HUDMetrics.gap
                + HUDMetrics.iconWidth + HUDMetrics.margin
        }
    }

    private var callbacks = Callbacks()
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var glass: NSGlassEffectView!
    /// Where every control lives — see `HUDMetrics.chrome`.
    private var content: NSView!
    private var stopPill: HUDPill?
    private var discardButton: NSButton?
    private var divider: NSView?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(frame: CGRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard Self.debugFillsMagenta else {
            super.draw(dirtyRect)
            return
        }
        NSColor.magenta.setFill()
        bounds.fill()
    }

    private func buildSubviews() {
        // In debug-fill mode the real chrome is left off entirely: a
        // NSVisualEffectView on top of `draw(_:)` would hide the fill, which is
        // exactly how the M4 preview panel came out blank.
        if Self.debugFillsMagenta { return }

        let chrome = HUDMetrics.chrome(in: bounds)
        glass = chrome.glass
        content = chrome.content
        addSubview(glass)

        var x = HUDMetrics.margin
        dot.frame = CGRect(
            x: x, y: ((Self.barSize.height - Self.dotSize) / 2).rounded(),
            width: Self.dotSize, height: Self.dotSize)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2
        content.addSubview(dot)
        pulse()
        x += Self.dotSize + 8

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .left
        timeLabel.cell?.usesSingleLineMode = true
        placeTimeLabel(x: x, width: Self.timeWidth)
        content.addSubview(timeLabel)
        x += Self.timeWidth + HUDMetrics.groupGap

        let line = HUDMetrics.divider(x: x)
        content.addSubview(line)
        divider = line
        x += 1 + HUDMetrics.groupGap

        let stop = HUDPill(title: Self.stopTitle, mark: .symbol("stop.fill"), tint: .systemRed)
        stop.setFrameOrigin(CGPoint(
            x: x, y: ((Self.barSize.height - HUDMetrics.controlHeight) / 2).rounded()))
        stop.onClick = { [weak self] in self?.callbacks.stop() }
        stop.toolTip = "Stop and keep the recording"
        content.addSubview(stop)
        stopPill = stop
        x += stop.frame.width + HUDMetrics.gap

        let discard = FirstMouseButton(frame: CGRect(
            x: x, y: ((Self.barSize.height - HUDMetrics.controlHeight) / 2).rounded(),
            width: HUDMetrics.iconWidth, height: HUDMetrics.controlHeight))
        discard.bezelStyle = .accessoryBarAction
        discard.isBordered = false
        discard.image = HUDMetrics.symbol("trash", pointSize: 13)
        discard.contentTintColor = .secondaryLabelColor
        discard.imagePosition = .imageOnly
        discard.target = self
        discard.action = #selector(discardTapped)
        discard.toolTip = "Stop and discard"
        content.addSubview(discard)
        discardButton = discard
    }

    /// Both controls are hidden rather than disabled while starting.
    ///
    /// Neither has anything to act on yet — `RecordingCoordinator.stop()` and
    /// `discard()` both require `state == .recording`, so a press would silently
    /// do nothing, which is worse than no button.
    func setPhase(_ phase: Phase) {
        guard !Self.debugFillsMagenta else { return }
        switch phase {
        case .starting:
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            dot.layer?.removeAnimation(forKey: "pulse")
            timeLabel.stringValue = "Starting…"
            timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
            placeTimeLabel(x: timeLabel.frame.minX, width: Self.startingWidth)
            timeLabel.textColor = .secondaryLabelColor
            stopPill?.isHidden = true
            discardButton?.isHidden = true
            divider?.isHidden = true
        case .recording:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            pulse()
            timeLabel.stringValue = "0:00"
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            placeTimeLabel(x: timeLabel.frame.minX, width: Self.timeWidth)
            timeLabel.textColor = .labelColor
            stopPill?.isHidden = false
            discardButton?.isHidden = false
            divider?.isHidden = false
        }
    }

    /// Centres the label on its own natural height.
    ///
    /// Giving it the full bar height instead is what broke the layout: an
    /// `NSTextField` draws its text at the TOP of a frame taller than the text,
    /// so the clock floated above centre while the dot, the divider and both
    /// buttons sat correctly centred around it. The frames all read as correct
    /// in a dump; only rendering it showed the problem.
    private func placeTimeLabel(x: CGFloat, width: CGFloat) {
        let height = ceil(timeLabel.font?.boundingRectForFont.height ?? 18)
        timeLabel.frame = CGRect(
            x: x, y: ((Self.barSize.height - height) / 2).rounded(),
            width: width, height: height)
    }

    private func pulse() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.25
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        // On the render server, like the marching ants: a Timer redrawing this
        // every frame would be measurable cost for the whole length of a take.
        dot.layer?.add(animation, forKey: "pulse")
    }

    func update(elapsed: TimeInterval) {
        guard !Self.debugFillsMagenta else { return }
        let total = Int(elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func discardTapped() { callbacks.discard() }
}

/// Owns the HUD panel for the length of one recording.
@MainActor
final class RecordingHUD {
    private var panel: RecordingHUDPanel?
    private var view: RecordingHUDView?
    private var ticker: Timer?
    private var elapsedProvider: (() -> TimeInterval)?
    /// The recorded region, when there is one. The bar hangs off it exactly as
    /// the selection toolbar did, so starting a take does not teleport it to the
    /// bottom of the screen.
    private var anchor: (rect: CGRect, screen: NSScreen)?

    var onStop: () -> Void = {}
    var onDiscard: () -> Void = {}

    /// Puts the bar on screen in its `starting` state, before the stream exists.
    ///
    /// Called the moment the selection is committed so the gap between "the
    /// selection disappeared" and "the recording is running" is never empty —
    /// see `RecordingHUDView.Phase`. The panel is `sharingType = .none`, so
    /// existing before the `SCContentFilter` is built costs nothing: it is
    /// invisible to the stream either way.
    /// `under` is the recorded region for an area take, and nil for a whole
    /// display — where there is no anchor and the bottom of the screen is the
    /// only sensible home.
    func showStarting(on screen: NSScreen?, under region: CGRect? = nil) {
        show(on: screen, elapsed: nil)
        if let region, let screen = panel?.screen ?? screen {
            anchor = (region, screen)
        }
        view?.setPhase(.starting)
        resize(to: .starting)
    }

    /// Switches the bar to its running state and starts the clock. The panel is
    /// already up by now; nothing moves, the contents change.
    func beginRecording(elapsed: @escaping () -> TimeInterval) {
        view?.setPhase(.recording)
        resize(to: .recording)
        elapsedProvider = elapsed
        startTicker()
    }

    /// Keeps the bar centred on its screen as it changes width, so it grows
    /// from the middle rather than sliding sideways.
    private func resize(to phase: RecordingHUDView.Phase) {
        guard let panel else { return }
        let size = CGSize(
            width: RecordingHUDView.width(for: phase),
            height: RecordingHUDView.barSize.height)
        let origin: CGPoint = if let anchor {
            HUDPlacement.origin(for: size, under: anchor.rect, on: anchor.screen)
        } else {
            // No anchor: keep it where it is and grow from the centre.
            CGPoint(x: (panel.frame.midX - size.width / 2).rounded(), y: panel.frame.minY)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        view?.frame = CGRect(origin: .zero, size: size)
    }

    /// Bottom-centre of the recording's own screen, which is where the user is
    /// already looking when they go to stop.
    func show(on screen: NSScreen?, elapsed: (() -> TimeInterval)?) {
        guard panel == nil else { return }
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let size = RecordingHUDView.barSize
        let frame = CGRect(
            origin: HUDPlacement.origin(for: size, atBottomOf: screen), size: size)

        var callbacks = RecordingHUDView.Callbacks()
        callbacks.stop = { [weak self] in self?.onStop() }
        callbacks.discard = { [weak self] in self?.onDiscard() }

        let view = RecordingHUDView(callbacks: callbacks)
        let panel = RecordingHUDPanel(contentRect: frame, view: view)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view

        // Held on `self` rather than captured by the timer block. `Timer`'s
        // block is not MainActor-isolated, so capturing a non-Sendable closure
        // into it is a data race the compiler correctly refuses; reaching it
        // back through MainActor-isolated `self` keeps it in one region.
        elapsedProvider = elapsed
        // No provider means the caller is `showStarting`: there is no stream to
        // ask for an elapsed time yet, so there is nothing for a ticker to do.
        if elapsed != nil { startTicker() }
    }

    private func startTicker() {
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common`, or the timer stops the moment a menu is tracking or a
        // window is being dragged — both of which happen constantly during a
        // screen recording.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        guard let elapsedProvider else { return }
        view?.update(elapsed: elapsedProvider())
    }

    func hide() {
        ticker?.invalidate()
        ticker = nil
        elapsedProvider = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    var isVisible: Bool { panel != nil }

    /// For `CaptureOptions.excludedWindowIDs`, so a screenshot taken during a
    /// recording does not photograph the HUD either.
    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    var frameForTest: CGRect? { panel?.frame }

    /// Every subview's frame, for `--selftest-hud-appearance`. Layout bugs are
    /// far quicker to read as numbers than to squint at in a screenshot.
    var debugSubviewFrames: [String] {
        guard let content = panel?.contentView else { return [] }
        return content.subviews.flatMap { $0.subviews.isEmpty ? [$0] : $0.subviews }.map { view in
            let kind = "\(type(of: view))"
            return "\(kind) \(Int(view.frame.minX)),\(Int(view.frame.minY)) "
                + "\(Int(view.frame.width))x\(Int(view.frame.height))"
        }
    }
}
