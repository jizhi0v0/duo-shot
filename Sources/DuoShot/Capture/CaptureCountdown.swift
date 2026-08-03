import AppKit
import Carbon.HIToolbox

/// The bar that counts down to a delayed capture: seconds left, and a way out.
///
/// Deliberately the same glass as every other bar in the app. A countdown is the
/// one moment the user is *not* looking at our UI — they are arranging something
/// in someone else's app — so it has to be recognisable at a glance and out of
/// the way the rest of the time.
final class CaptureCountdownView: NSView {
    struct Callbacks {
        var cancel: () -> Void = {}
    }

    private static let cancelTitle = "Cancel"
    /// Fixed, so the bar does not resize as the digits change. Wide enough for
    /// the longest thing that goes here, which is the hint rather than "10".
    private static let labelWidth: CGFloat = 132

    static var barSize: CGSize {
        let width = HUDMetrics.margin + labelWidth + HUDMetrics.groupGap
            + 1 + HUDMetrics.groupGap
            + HUDPill.width(for: cancelTitle) + HUDMetrics.margin
        return CGSize(width: width, height: HUDMetrics.height)
    }

    private let callbacks: Callbacks
    private let label = NSTextField(labelWithString: "")

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(frame: CGRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // The bar is over another app's window and that app is frontmost, so the
    // first click on Cancel has to count. Without this it would only focus us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildSubviews() {
        var x = HUDMetrics.margin

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        label.sizeToFit()
        label.frame = CGRect(
            x: x, y: ((HUDMetrics.height - label.frame.height) / 2).rounded(),
            width: Self.labelWidth, height: label.frame.height)
        addSubview(label)
        x += Self.labelWidth + HUDMetrics.groupGap

        addSubview(HUDMetrics.divider(x: x))
        x += 1 + HUDMetrics.groupGap

        let cancel = HUDPill(
            title: Self.cancelTitle, mark: .symbol("xmark"), tint: .secondaryLabelColor)
        cancel.setFrameOrigin(CGPoint(
            x: x, y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()))
        cancel.onClick = { [weak self] in self?.callbacks.cancel() }
        cancel.toolTip = "Cancel the capture  ⎋"
        addSubview(cancel)
    }

    /// Whole seconds, rounded **up**: at 2.4 s left the honest thing to show is
    /// "3", because the user is counting down with it and a "0" that lingers for
    /// most of a second reads as a hang.
    func update(remaining: TimeInterval) {
        let seconds = max(0, Int(remaining.rounded(.up)))
        label.stringValue = seconds == 0
            ? "Capturing…"
            : "Capturing in \(seconds)s"
    }
}

/// Runs the wait before a delayed capture.
///
/// The wait is the feature. Everything the selection overlay destroys by
/// existing — a hover state, an open menu, a popover — can be put back during
/// these few seconds, because nothing of ours is on screen except one small bar
/// that is excluded from the shot.
///
/// Escape is claimed the way the scrolling session claims it: a transient Carbon
/// binding, because the user's focus is in another app for the whole countdown
/// and a bar that cannot become key would never see a local monitor's keyDown.
/// It is released on every exit path — a stuck registration eats Escape globally.
@MainActor
final class CaptureCountdown {
    private var panel: FloatingBarPanel?
    private var view: CaptureCountdownView?
    private var ticker: Timer?
    private var escapeID: UInt32?
    private var cancelled = false

    var isVisible: Bool { panel != nil }

    /// For `CaptureOptions.excludedWindowIDs`. The bar is `.none` in the shipping
    /// configuration and so invisible to ScreenCaptureKit anyway; this is the
    /// second line of defence, and the only one when the preference makes our
    /// chrome visible to screen sharing.
    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    var frameForTest: CGRect? { panel?.frame }

    /// What the bar is telling ScreenCaptureKit. `.none` is the shipping answer
    /// and the first line of defence; the exclusion list is the second.
    var sharingTypeForTest: NSWindow.SharingType? { panel?.sharingType }

    /// The IDs the bar occupied, kept after it has gone.
    ///
    /// The capture happens in the turn after the bar is taken off screen, and the
    /// window server does not promise to have retired the window by then — so the
    /// shot still names them in its exclusion list. Naming a window that no
    /// longer exists costs nothing; photographing our own countdown bar into the
    /// user's screenshot is not recoverable.
    private(set) var lastWindowIDs: Set<CGWindowID> = []

    /// Waits `seconds`, showing the bar. Returns false if the user cancelled.
    ///
    /// A zero or negative delay returns true without putting anything on screen,
    /// so callers can hand the preference straight in.
    func wait(seconds: TimeInterval, on screen: NSScreen?) async -> Bool {
        guard seconds > 0 else { return true }
        cancelled = false
        show(on: screen)

        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !cancelled {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            view?.update(remaining: remaining)
            // Polled rather than driven by one long sleep, so Cancel and Escape
            // are answered within a frame or two instead of at the deadline.
            try? await Task.sleep(for: .milliseconds(80))
        }
        // Off screen before the shutter, and with no fade: a bar dissolving over
        // the next tenth of a second is a bar that can still be photographed, and
        // the whole point of the countdown is that the last frame belongs to the
        // user.
        hide(animated: false)
        if cancelled {
            Log.capture.notice("delayed capture cancelled")
            return false
        }
        return true
    }

    func cancel() {
        cancelled = true
    }

    private func show(on screen: NSScreen?) {
        guard panel == nil else { return }
        guard let home = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            // Same reasoning as the recording bar: a countdown with no bar is
            // survivable, and `screens[0]` on a sleeping display is not.
            Log.capture.error("no screen to place the countdown bar on; counting without it")
            return
        }
        let size = CaptureCountdownView.barSize
        var callbacks = CaptureCountdownView.Callbacks()
        callbacks.cancel = { [weak self] in self?.cancel() }
        let view = CaptureCountdownView(callbacks: callbacks)

        let panel = FloatingBarPanel(role: .recording, size: size)
        panel.setFrame(
            CGRect(origin: HUDPlacement.origin(for: size, atBottomOf: home), size: size),
            display: false)
        panel.setFace(view, animated: false)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        lastWindowIDs = [CGWindowID(panel.windowNumber)]
        view.update(remaining: 0)
        claimEscape()
    }

    private func hide(animated: Bool = true) {
        releaseEscape()
        ticker?.invalidate()
        ticker = nil
        guard let panel else { return }
        self.panel = nil
        view = nil
        if animated {
            panel.dismiss()
        } else {
            panel.orderOut(nil)
        }
    }

    private func claimEscape() {
        do {
            escapeID = try HotKeyManager.shared.registerTransient(
                KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [])
            ) { [weak self] in
                self?.cancel()
            }
        } catch {
            // Survivable: the bar's own Cancel still ends it.
            Log.hotkeys.error("could not claim Esc for the countdown: \(error, privacy: .public)")
        }
    }

    private func releaseEscape() {
        guard let escapeID else { return }
        HotKeyManager.shared.unregister(escapeID)
        self.escapeID = nil
    }
}
