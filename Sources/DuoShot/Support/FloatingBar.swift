import AppKit

/// The floating bar. Singular.
///
/// One window, one pane of glass, from the moment a selection is armed to the
/// end of the take. It changes level, width and contents along the way; it does
/// not change identity.
///
/// This started as two windows — a selection toolbar and a recording HUD —
/// crossfading at the same frame, which is close to the same thing and not the
/// same thing at all. Two panes of Liquid Glass stacked for a tenth of a second
/// sample each other, so the bar visibly thickens and then settles; any
/// disagreement between them about width reads as a second bar sliding out of
/// the first; and their contents are legibly two sets of controls superimposed.
/// Handing one window over can have none of those problems, because there is
/// only ever one thing on screen.
final class FloatingBarPanel: NSPanel {
    /// Test hook, mirroring `OverlayPanel` / `PreviewPanel`. With `.none` the
    /// panel is invisible to ScreenCaptureKit outright — which is what we ship,
    /// and which also makes an exclusion test unable to fail, so the self-test
    /// can turn it off to prove the test responds.
    static var usesSharingTypeNone = true

    /// What the bar is for. It is all that differs between the two ends of its
    /// life, which is the point.
    enum Role {
        /// Armed selection: above the overlay's shield, since the overlay covers
        /// everything and anything clickable has to be over it. Not draggable —
        /// a drag started on the bar would fight the drag that is still
        /// resizing the selection underneath it.
        case selection
        /// A running take: down at the preview stack's level, so beginning a new
        /// selection covers the bar rather than fighting it, and draggable, so
        /// it can be moved off whatever is being demonstrated.
        case recording

        var level: NSWindow.Level {
            switch self {
            case .selection: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            case .recording: .statusBar
            }
        }

        var isDraggable: Bool { self == .recording }
    }

    /// A plain dissolve: one face out, the other in, same clock, straight lines.
    ///
    /// Two earlier versions were worse in opposite directions, and both were
    /// visible to the eye before any test caught them.
    ///
    /// Strictly sequential — the arrival scheduled from the departure's
    /// completion handler — put a composited frame between them with the old face
    /// gone and the new one still at zero. A pane of Liquid Glass with nothing in
    /// it is unmistakable; it reads as the bar blanking out mid-hand-over.
    ///
    /// Mostly sequential, with the arrival delayed into the tail of the
    /// departure, closed the hole but left a stretch where both were at a third
    /// and the whole bar was faint — trading a blank frame for a dip.
    ///
    /// Linear and fully overlapped is the shape that has neither: the opacities
    /// are complements, so the total ink in the bar stays at 1 from the first
    /// frame to the last. The cost is a moment at 50/50 in the middle, which at
    /// this speed reads as a dissolve rather than as two sets of controls —
    /// eased curves are what make a double image legible, because both sides sit
    /// high at once. Kept short for the same reason: the faster the 50/50 moment
    /// goes by, the less there is to read in it.
    static let faceOut: TimeInterval = 0.14
    static let faceIn: TimeInterval = 0.14
    /// The width change, spanning both. Eased at each end so the bar is nearly
    /// still while the outgoing controls are still legible.
    static let morph: TimeInterval = 0.30

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Where faces live: the glass's content view, or the root view itself when
    /// there is no glass. Sized to the window; the face is centred inside it.
    private let stage: NSView
    private(set) var face: NSView?
    /// The face on its way out, kept until its fade is done — and so that the
    /// self-test can watch both opacities at once.
    private(set) var outgoingFace: NSView?
    private var outgoingRemoval: Timer?
    private(set) var role: Role

    /// `usesGlass` is off only for the exclusion self-test, which paints the bar
    /// flat magenta and needs nothing drawing over the top of it — the lesson
    /// from M4, where a visual effect view hid the debug fill and produced a
    /// test that could not fail.
    init(role: Role, size: CGSize, usesGlass: Bool = true, hiddenFromCapture: Bool = true) {
        self.role = role
        let bounds = CGRect(origin: .zero, size: size)
        let root = BarRootView(frame: bounds)
        if usesGlass {
            let chrome = HUDMetrics.chrome(in: bounds)
            root.addSubview(chrome.glass)
            stage = chrome.content
        } else {
            stage = root
        }

        super.init(
            contentRect: bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: `isFloatingPanel` resets `level`, so it goes first or
        // the level set below is silently undone.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        // `.none`, not `.utilityWindow`. Every fade this window makes is written
        // out here, and AppKit's own order-in animation would run on top of them.
        animationBehavior = .none
        setHiddenFromCapture(hiddenFromCapture)
        assume(role)

        contentView = root
    }

    /// Re-purposes the window in place. This is the hand-over: the same glass,
    /// re-levelled, for the next part of the same continuous action.
    func assume(_ role: Role) {
        self.role = role
        level = role.level
        isMovableByWindowBackground = role.isDraggable
    }

    /// Whether screen sharing may see the bar. Read from the preference by each
    /// owner, so the answer has to be settable after the window exists.
    func setHiddenFromCapture(_ hidden: Bool) {
        sharingType = (Self.usesSharingTypeNone && hidden) ? .none : .readOnly
    }

    /// Swaps what the bar holds, leaving the bar itself alone.
    func setFace(_ next: NSView, animated: Bool) {
        next.autoresizingMask = [.minXMargin, .maxXMargin]
        retireOutgoingFace()
        guard animated, let current = face else {
            face?.removeFromSuperview()
            face = next
            stage.addSubview(next)
            centreFace()
            return
        }

        outgoingFace = current
        face = next
        // Above the outgoing face, so where they overlap the arriving controls
        // win rather than showing through each other.
        stage.addSubview(next, positioned: .above, relativeTo: current)
        centreFace()

        // Both fades are explicit Core Animation, added in the same turn, so they
        // share a clock. Nothing here waits for a run-loop callback — that wait
        // is what opened the hole.
        current.wantsLayer = true
        current.alphaValue = 0
        current.layer?.add(
            fade(from: 1, to: 0, duration: Self.faceOut), forKey: "faceOut")

        next.wantsLayer = true
        next.alphaValue = 1
        next.layer?.add(
            fade(from: 0, to: 1, duration: Self.faceIn), forKey: "faceIn")

        // The view itself is removed once it is invisible anyway; the exact
        // moment does not matter, only that it happens.
        let removal = Timer(timeInterval: Self.faceOut + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retireOutgoingFace() }
        }
        RunLoop.main.add(removal, forMode: .common)
        outgoingRemoval = removal
    }

    private func fade(from: Float, to: Float, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }

    private func retireOutgoingFace() {
        outgoingRemoval?.invalidate()
        outgoingRemoval = nil
        outgoingFace?.removeFromSuperview()
        outgoingFace = nil
    }

    /// Centres the current face in whatever width the bar has right now.
    ///
    /// The face keeps its own size while the window is still on its way to
    /// matching it, and content pinned to one edge would leave the surplus as a
    /// hole at the other. Flexible margins keep it centred through the
    /// animation; this sets the starting point they animate from.
    func centreFace() {
        guard let face else { return }
        let size = face.frame.size
        face.frame = CGRect(
            x: ((stage.bounds.width - size.width) / 2).rounded(),
            y: ((stage.bounds.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
    }

    func morph(to frame: CGRect, animated: Bool, duration: TimeInterval = FloatingBarPanel.morph) {
        guard animated else {
            setFrame(frame, display: true)
            centreFace()
            return
        }
        // The content view resizes with the window rather than being snapped to
        // the final size first: the glass has to actually narrow, or the "morph"
        // is a small bar sliding under a big one.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        }
    }

    /// Fades out and orders out. Callers drop their reference first, so anything
    /// asking whether a bar is on screen gets the answer immediately.
    func dismiss(duration: TimeInterval = 0.12) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [self] in
            MainActor.assumeIsolated {
                orderOut(nil)
                alphaValue = 1
            }
        }
    }

    /// How much of the bar's contents the render server is drawing right now,
    /// counting both faces: 1 when a single face is fully opaque, less than that
    /// mid-hand-over, and 0 for a bar that is nothing but glass.
    ///
    /// Read from the *presentation* layers, so this is what is actually on screen
    /// rather than what the model says it will be. It is the only way to catch a
    /// single-frame hole in the crossfade; screenshots are far too slow, and the
    /// one that shipped was reported by eye, not by a test.
    var debugFaceInk: Float {
        func ink(_ view: NSView?) -> Float {
            guard let view else { return 0 }
            guard let layer = view.layer else { return Float(view.alphaValue) }
            return (layer.presentation() ?? layer).opacity
        }
        return ink(face) + ink(outgoingFace)
    }

    /// Every subview's frame, for `--selftest-hud-appearance`. Layout bugs are
    /// far quicker to read as numbers than to squint at in a screenshot.
    var debugSubviewFrames: [String] {
        func describe(_ view: NSView, depth: Int) -> [String] {
            let line = String(repeating: "  ", count: depth)
                + "\(type(of: view)) \(Int(view.frame.minX)),\(Int(view.frame.minY)) "
                + "\(Int(view.frame.width))x\(Int(view.frame.height))"
            return [line] + view.subviews.flatMap { describe($0, depth: depth + 1) }
        }
        return (contentView?.subviews ?? []).flatMap { describe($0, depth: 0) }
    }
}

/// The window's content view. Exists for one override: in a window that never
/// becomes key, the first click on Stop would otherwise be swallowed as an
/// activation click.
private final class BarRootView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
