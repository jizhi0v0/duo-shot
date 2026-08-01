import AppKit

/// The bar's contents: a pulsing record dot, the elapsed time, Stop and Discard.
///
/// The second face of `FloatingBarPanel`, and built from the same `HUDMetrics`
/// and `HUDPill` pieces as the first. It replaces the selection toolbar's
/// controls inside the bar the user already had in front of them; the glass, the
/// width and the placement are the window's business.
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
    ///
    /// The two phases are the same bar: same width, same controls, in the same
    /// places. `starting` is that bar greyed out, and the take beginning colours
    /// it in. They used to disagree on both width and which controls existed,
    /// which — with the selection toolbar before them — made starting a
    /// recording look like three windows taking turns rather than one bar
    /// changing state.
    enum Phase {
        case starting
        case recording
    }

    private static let dotSize: CGFloat = 9
    private static let timeWidth: CGFloat = 46
    /// The mic-off indicator's slot. Present only in the takes that need it —
    /// see `microphoneOff`.
    private static let micWidth: CGFloat = 16
    /// The clock's slot borrows the gap before the divider when it has to say
    /// "Starting…" instead of a time. The bar's width is fixed by then, so the
    /// word has to fit in the space the clock already had.
    private static let slowStartWidth: CGFloat = 54
    private static let stopTitle = "Stop"
    /// How long a start has to take before the bar says so in words.
    ///
    /// Under this the grey is a blink, and a word flashing up inside it would be
    /// noise. Over it the user is waiting — and a start that is being retried
    /// can sit here for seconds — so a still bar needs to admit what it is
    /// doing.
    private static let slowStartDelay: TimeInterval = 1.2

    /// One size for both phases, so nothing about the window changes when the
    /// take begins.
    ///
    /// `microphoneOff` is decided before the bar appears — `showStarting` runs
    /// before `engine.start` — precisely so that it is *not* something that
    /// changes when the take begins.
    static func barSize(microphoneOff: Bool = false) -> CGSize {
        CGSize(width: width(microphoneOff: microphoneOff), height: HUDMetrics.height)
    }

    static func width(microphoneOff: Bool = false) -> CGFloat {
        HUDMetrics.margin + Self.dotSize + 8 + Self.timeWidth
            + (microphoneOff ? Self.micWidth + HUDMetrics.gap : 0)
            + HUDMetrics.groupGap + 1 + HUDMetrics.groupGap
            + HUDPill.width(for: Self.stopTitle) + HUDMetrics.gap
            + HUDMetrics.iconWidth + HUDMetrics.margin
    }

    private var callbacks = Callbacks()
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var micOffIcon: NSImageView?
    private var stopPill: HUDPill?
    private var discardButton: NSButton?
    private var timeOriginX: CGFloat = 0
    private var slowStartTimer: Timer?
    /// The take asked for the microphone and did not get it. Fixed for the life
    /// of the bar; it decides the bar's width.
    private let microphoneOff: Bool

    init(callbacks: Callbacks, microphoneOff: Bool = false) {
        self.callbacks = callbacks
        self.microphoneOff = microphoneOff
        super.init(frame: CGRect(origin: .zero, size: Self.barSize(microphoneOff: microphoneOff)))
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

        var x = HUDMetrics.margin
        dot.frame = CGRect(
            x: x, y: ((HUDMetrics.height - Self.dotSize) / 2).rounded(),
            width: Self.dotSize, height: Self.dotSize)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(dot)
        pulse(live: true)
        x += Self.dotSize + 8

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .left
        timeLabel.cell?.usesSingleLineMode = true
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.wantsLayer = true
        timeOriginX = x
        placeTimeLabel(width: Self.timeWidth)
        addSubview(timeLabel)
        x += Self.timeWidth

        // On the clock's side of the divider: it states something about the take
        // itself, like the dot, rather than offering an action. The slot exists
        // only when the take needs it — the bar is sized without it otherwise —
        // because `RecordingEngine.start` drops an ungranted microphone silently
        // and a log line is not a place the user will ever look.
        if microphoneOff {
            x += HUDMetrics.gap
            let mic = NSImageView(frame: CGRect(
                x: x, y: ((HUDMetrics.height - Self.micWidth) / 2).rounded(),
                width: Self.micWidth, height: Self.micWidth))
            mic.image = HUDMetrics.symbol("mic.slash.fill", pointSize: 12)
            mic.contentTintColor = .secondaryLabelColor
            mic.imageScaling = .scaleProportionallyDown
            mic.toolTip = "Recording without the microphone — DuoShot has no microphone access"
            addSubview(mic)
            micOffIcon = mic
            x += Self.micWidth
        }
        x += HUDMetrics.groupGap

        // Kept lit in both phases. It is part of the bar's shape rather than
        // one of its controls, and a rule that blinks out and back is one more
        // thing changing at the moment the take starts.
        addSubview(HUDMetrics.divider(x: x))
        x += 1 + HUDMetrics.groupGap

        let stop = HUDPill(title: Self.stopTitle, mark: .symbol("stop.fill"), tint: .systemRed)
        stop.setFrameOrigin(CGPoint(
            x: x, y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()))
        stop.onClick = { [weak self] in self?.callbacks.stop() }
        stop.toolTip = "Stop and keep the recording"
        addSubview(stop)
        stopPill = stop
        x += stop.frame.width + HUDMetrics.gap

        let discard = FirstMouseButton(frame: CGRect(
            x: x, y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded(),
            width: HUDMetrics.iconWidth, height: HUDMetrics.controlHeight))
        discard.bezelStyle = .accessoryBarAction
        discard.isBordered = false
        discard.image = HUDMetrics.symbol("trash", pointSize: 13)
        discard.contentTintColor = .secondaryLabelColor
        discard.imagePosition = .imageOnly
        discard.target = self
        discard.action = #selector(discardTapped)
        discard.toolTip = "Stop and discard"
        discard.wantsLayer = true
        addSubview(discard)
        discardButton = discard
    }

    /// Every control stays put and goes grey rather than disappearing.
    ///
    /// Neither button has anything to act on while the stream is starting —
    /// `RecordingCoordinator.stop()` and `discard()` both require
    /// `state == .recording`, so a press would silently do nothing — but hiding
    /// them was worse than dimming them: the bar then had to change shape twice
    /// in the half second between Record and the first frame. Grey is the state
    /// the user already understands, and it is also what a slow start or a retry
    /// looks like, so the same appearance covers all three.
    func setPhase(_ phase: Phase, animated: Bool) {
        guard !Self.debugFillsMagenta else { return }
        slowStartTimer?.invalidate()
        slowStartTimer = nil
        if animated {
            HUDMetrics.crossfade(timeLabel)
            if let discardButton { HUDMetrics.crossfade(discardButton) }
            if let micOffIcon { HUDMetrics.crossfade(micOffIcon) }
        }
        switch phase {
        case .starting:
            HUDMetrics.fill(dot, with: .tertiaryLabelColor, animated: animated)
            pulse(live: false)
            // The clock reads 0:00 rather than a placeholder: it is the time the
            // take will start from, so when it comes alive only its colour
            // changes. A dash here would be one more thing swapping.
            showTime("0:00")
            timeLabel.textColor = .tertiaryLabelColor
            stopPill?.setLive(false, animated: animated)
            discardButton?.isEnabled = false
            discardButton?.contentTintColor = .tertiaryLabelColor
            micOffIcon?.contentTintColor = .tertiaryLabelColor
            scheduleSlowStartText()
        case .recording:
            HUDMetrics.fill(dot, with: .systemRed, animated: animated)
            pulse(live: true)
            showTime("0:00")
            timeLabel.textColor = .labelColor
            stopPill?.setLive(true, animated: animated)
            discardButton?.isEnabled = true
            discardButton?.contentTintColor = .secondaryLabelColor
            micOffIcon?.contentTintColor = .secondaryLabelColor
        }
    }

    /// Says "Starting…" in the clock's place once a start has dragged on.
    private func scheduleSlowStartText() {
        let timer = Timer(timeInterval: Self.slowStartDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                HUDMetrics.crossfade(self.timeLabel)
                // 10 pt, not the 13 the clock uses: the word has to fit between
                // the dot and the divider, and it is a status line rather than
                // the bar's headline number. Measured, because at 11 pt it is
                // 53 pt wide plus a label cell's own insets and comes out as
                // "Startin…", which is worse than saying nothing.
                self.timeLabel.font = .systemFont(ofSize: 10, weight: .medium)
                self.showTime("Starting…", width: Self.slowStartWidth)
            }
        }
        // `.common`, like the tick timer: a menu tracking or a window drag must
        // not be able to hold the bar on a word it has outgrown.
        RunLoop.main.add(timer, forMode: .common)
        slowStartTimer = timer
    }

    private func showTime(_ text: String, width: CGFloat = RecordingHUDView.timeWidth) {
        if width == Self.timeWidth {
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        timeLabel.stringValue = text
        placeTimeLabel(width: width)
    }

    /// Centres the label on its own natural height.
    ///
    /// Giving it the full bar height instead is what broke the layout: an
    /// `NSTextField` draws its text at the TOP of a frame taller than the text,
    /// so the clock floated above centre while the dot, the divider and both
    /// buttons sat correctly centred around it. The frames all read as correct
    /// in a dump; only rendering it showed the problem.
    private func placeTimeLabel(width: CGFloat) {
        let height = ceil(timeLabel.font?.boundingRectForFont.height ?? 18)
        timeLabel.frame = CGRect(
            x: timeOriginX, y: ((HUDMetrics.height - height) / 2).rounded(),
            width: width, height: height)
    }

    /// The dot breathes in both phases, slower and shallower while starting.
    ///
    /// A dot that simply stops moving is indistinguishable from a bar that has
    /// hung, and hanging is exactly what the grey phase has to survive: the
    /// start being retried, or `startCapture` sitting there for four seconds.
    private func pulse(live: Bool) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = live ? 0.25 : 0.45
        animation.duration = live ? 0.8 : 1.1
        animation.autoreverses = true
        animation.repeatCount = .infinity
        // On the render server, like the marching ants: a Timer redrawing this
        // every frame would be measurable cost for the whole length of a take.
        dot.layer?.add(animation, forKey: "pulse")
    }

    /// The stream's verdict on the microphone, once there is a stream.
    ///
    /// Only ever *hides* a reserved slot: the bar's width was fixed when it
    /// appeared, so an indicator that was not asked for at that point has
    /// nowhere to go — see `barSize(microphoneOff:)`.
    func setMicrophoneOff(_ off: Bool) {
        micOffIcon?.isHidden = !off
    }

    func update(elapsed: TimeInterval) {
        guard !Self.debugFillsMagenta else { return }
        let total = Int(elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func discardTapped() { callbacks.discard() }
}

/// Drives the bar for the length of one recording.
///
/// It usually does not create a window. The selection hands one over, and this
/// class re-levels it, swaps its face and narrows it — so the bar the user
/// pressed Record on is, literally and not just apparently, the bar they then
/// press Stop on. A window is only made from scratch for a take that had no
/// selection in front of it: a whole display.
@MainActor
final class RecordingHUD {
    private var panel: FloatingBarPanel?
    private var view: RecordingHUDView?
    private var ticker: Timer?
    private var elapsedProvider: (() -> TimeInterval)?
    /// The recorded region, when there is one. The bar hangs off it exactly as
    /// the selection toolbar did, so starting a take does not teleport it to the
    /// bottom of the screen.
    private var anchor: (rect: CGRect, screen: NSScreen)?
    /// The take is running without the microphone it asked for. Read by
    /// `placedFrame`, which has to agree with the face about how wide the bar is.
    private var microphoneOff = false

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
    /// `adopting` is the bar the selection was just using. Given one, nothing
    /// appears and nothing is dismissed: that window stays exactly where it is,
    /// swaps its controls, and narrows to the width the take needs.
    /// `microphoneOff` is asked for here, before the stream exists, because it
    /// changes the bar's width — and the one thing this bar must not do is
    /// change width when the take begins.
    func showStarting(
        on screen: NSScreen?, under region: CGRect? = nil,
        adopting handedOver: FloatingBarPanel? = nil, hiddenFromCapture: Bool = true,
        microphoneOff: Bool = false
    ) {
        // A retried start re-enters here with the bar already up and already
        // grey. Replaying the entrance would make a retry — the one case the grey
        // phase exists to cover — flash.
        let isNew = panel == nil
        if isNew { self.microphoneOff = microphoneOff }
        show(on: screen, elapsed: nil, adopting: handedOver,
             hiddenFromCapture: hiddenFromCapture)
        if let region, let screen = panel?.screen ?? screen {
            anchor = (region, screen)
        }
        guard isNew, let panel, let view else { return }
        view.setPhase(.starting, animated: false)

        guard handedOver != nil else {
            // Nothing to grow out of: a fullscreen take has no bar before it.
            panel.morph(to: placedFrame(), animated: false)
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FloatingBarPanel.faceIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            return
        }
        // The face swap and the width change run together over the same 0.3 s:
        // the controls leave, the bar tightens around what is arriving, the new
        // controls land. One object, one movement.
        panel.morph(to: placedFrame(), animated: true)
    }

    /// Brings the bar to life where it stands: the dot reddens, the clock
    /// starts, Stop and Discard become real controls.
    ///
    /// Nothing moves and nothing resizes. The bar has been the size it will keep
    /// since it appeared, and a resize at this moment is what used to make the
    /// first second of a take read as a third, separate window.
    ///
    /// `microphoneOff` is the running stream's own answer. It can differ from
    /// what `showStarting` predicted only across a retried start, where the
    /// grant changed between attempts; the slot is already reserved either way,
    /// so this decides what is drawn in it and never the width.
    func beginRecording(elapsed: @escaping () -> TimeInterval, microphoneOff: Bool = false) {
        view?.setMicrophoneOff(microphoneOff)
        view?.setPhase(.recording, animated: true)
        elapsedProvider = elapsed
        startTicker()
    }

    /// Where the bar belongs: under the recorded region when there is one, and
    /// otherwise centred on wherever it already sits.
    private func placedFrame() -> CGRect {
        let size = RecordingHUDView.barSize(microphoneOff: microphoneOff)
        guard let panel else { return CGRect(origin: .zero, size: size) }
        let origin: CGPoint = if let anchor {
            HUDPlacement.origin(for: size, under: anchor.rect, on: anchor.screen)
        } else {
            CGPoint(x: (panel.frame.midX - size.width / 2).rounded(), y: panel.frame.minY)
        }
        return CGRect(origin: origin, size: size)
    }

    /// Bottom-centre of the recording's own screen, which is where the user is
    /// already looking when they go to stop.
    func show(
        on screen: NSScreen?, elapsed: (() -> TimeInterval)?,
        adopting handedOver: FloatingBarPanel? = nil,
        hiddenFromCapture: Bool = true
    ) {
        guard panel == nil else { return }
        let size = RecordingHUDView.barSize(microphoneOff: microphoneOff)

        var callbacks = RecordingHUDView.Callbacks()
        callbacks.stop = { [weak self] in self?.onStop() }
        callbacks.discard = { [weak self] in self?.onDiscard() }
        let view = RecordingHUDView(callbacks: callbacks, microphoneOff: microphoneOff)

        let panel: FloatingBarPanel
        if let handedOver {
            panel = handedOver
            // Re-levelled before the face lands: at the selection's level the bar
            // sits above every window on the display, which is right while an
            // overlay is shielding the screen and wrong for the next minute.
            panel.assume(.recording)
            panel.setHiddenFromCapture(hiddenFromCapture)
        } else {
            // `NSScreen.screens` is empty while every display is asleep and for
            // the moment a clamshell close takes effect, so the `screens[0]`
            // this used to fall through to was a trap on the path that runs at
            // the start of every take. A take with no bar on it is survivable —
            // the menu bar item still stops it — and a crash is not.
            guard let home = screen ?? NSScreen.main ?? NSScreen.screens.first else {
                Log.record.error("no screen to place the recording bar on; running without it")
                return
            }
            panel = FloatingBarPanel(
                role: .recording, size: size,
                usesGlass: !RecordingHUDView.debugFillsMagenta,
                hiddenFromCapture: hiddenFromCapture)
            panel.setFrame(
                CGRect(origin: HUDPlacement.origin(for: size, atBottomOf: home), size: size),
                display: false)
            panel.orderFrontRegardless()
        }
        panel.setFace(view, animated: handedOver != nil)
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

    /// Fades out rather than vanishing — the end of a take is the one place the
    /// bar genuinely goes away, so it is worth not cutting. The panel is dropped
    /// from `self` first, so everything that asks whether a take is on screen
    /// gets the answer straight away and the dying window cannot be reused.
    func hide() {
        ticker?.invalidate()
        ticker = nil
        elapsedProvider = nil
        microphoneOff = false
        guard let panel else { return }
        self.panel = nil
        view = nil
        anchor = nil
        panel.dismiss()
    }

    var isVisible: Bool { panel != nil }

    /// For `CaptureOptions.excludedWindowIDs`, so a screenshot taken during a
    /// recording does not photograph the HUD either.
    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    var frameForTest: CGRect? { panel?.frame }

    var debugSubviewFrames: [String] { panel?.debugSubviewFrames ?? [] }

    /// See `FloatingBarPanel.debugFaceInk`.
    var faceInkForTest: Float { panel?.debugFaceInk ?? 0 }
}
