import AppKit

/// A frozen frame of each display, captured while the selection is on screen, so
/// the loupe has pixels to magnify.
///
/// A window cannot read what is underneath it, and the selection overlay covers
/// the whole screen — so a pixel-level loupe needs a copy of the screen taken
/// *with our own panels excluded*. There were two ways to get one, and the choice
/// between them was made when this overlay was designed:
///
/// - Freeze first, Shottr style: capture the screen, show it as the overlay's
///   backdrop, and crop the final image out of it. The loupe is perfect and what
///   you see is exactly what you get, at the cost of 30–60 ms before anything
///   appears and ~59 MB on a 5K display.
/// - Stay live, CleanShot style: a transparent overlay that appears instantly and
///   captures only on confirm. Nothing to magnify.
///
/// This is the middle route the plan called for: the overlay is live and appears
/// with no delay, and the backdrop is fetched in the background for the loupe
/// alone. Filled per display and only on demand: a three-display machine should
/// not pay for three full-screen captures because the pointer visited one of
/// them.
///
/// A photograph goes stale, and the first version left it that way — a loupe over
/// a playing video showed the pixels as they were when the selection started.
/// So there are two tiers now:
///
/// - a **base** frame per display, the whole screen, taken once. It covers
///   wherever the pointer goes, immediately.
/// - one small **patch**, re-taken around the pointer every time it comes to
///   rest, which the loupe prefers whenever it covers what is being magnified.
///
/// The patch is what makes it live without making it expensive: a 5K base frame
/// is ~59 MB and 30-60 ms, while 160 pt square is under a megabyte. Re-taking the
/// base on a timer would have been the obvious fix and the wrong one — tens of
/// megabytes of churn per second, to refresh pixels nobody is looking at.
@MainActor
final class BackdropCache {
    /// A photograph, with everything needed to map a global point into it.
    ///
    /// `Equatable` so the overlay can tell a genuinely new frame from the same one
    /// being handed to it again, which happens on every pointer move that stays
    /// inside the current patch. `CGImage` has no `==`, and does not need one
    /// here: two frames are the same frame when they are the same object.
    struct Frame: Equatable {
        static func == (lhs: Frame, rhs: Frame) -> Bool {
            lhs.image === rhs.image && lhs.scale == rhs.scale && lhs.covers == rhs.covers
        }

        let image: CGImage
        /// Pixels per point, from the capture itself rather than from
        /// `NSScreen.backingScaleFactor` — on mixed-DPI setups only the capture
        /// knows what it actually rendered at.
        let scale: CGFloat
        /// The AppKit global rect the image covers: a whole screen for a base
        /// frame, a small square for a patch.
        let covers: CGRect
    }

    /// How big a patch is, and how far inside it the pointer has to be for the
    /// patch to be used.
    ///
    /// The margin is what stops a patch being used right at its own edge, where
    /// the loupe would magnify the void beyond it. It only has to cover the
    /// loupe's own window — 21 px, which is 21 pt on a 1x display — and the rest
    /// is slack so that small pointer movements do not fall back to the base.
    private static let patchSide: CGFloat = 160
    private static let patchMargin: CGFloat = 32

    /// Takes one photograph: a whole display when the rect is nil, that rect
    /// otherwise. Injected, since this layer owns no capture engine.
    typealias Capture = (CGDirectDisplayID, CGRect?, Set<CGWindowID>) async -> CaptureResult?

    /// Called when a frame lands, so the overlay can fade its loupe in.
    var onArrival: (() -> Void)?

    private var frames: [CGDirectDisplayID: Frame] = [:]
    private var inFlight: Set<CGDirectDisplayID> = []
    private var patch: (displayID: CGDirectDisplayID, frame: Frame)?
    private var patchInFlight = false
    /// Bumped on every teardown. A capture that returns after the selection has
    /// gone belongs to a presentation that no longer exists, and storing it would
    /// hand the *next* selection a photograph of the last one.
    private var generation = 0

    /// The freshest frame that actually covers `point`: the patch when it does,
    /// the base otherwise.
    func frame(for displayID: CGDirectDisplayID, showing point: CGPoint) -> Frame? {
        if let patch, patch.displayID == displayID,
           patch.frame.covers.insetBy(dx: Self.patchMargin, dy: Self.patchMargin).contains(point) {
            return patch.frame
        }
        return frames[displayID]
    }


    /// The whole-screen frame for a display, never a patch.
    ///
    /// What freeze mode shows and cuts from: a patch covers 160 pt around the
    /// pointer, so handing one to either would paint — or save — a postage stamp.
    func baseFrame(for displayID: CGDirectDisplayID) -> Frame? { frames[displayID] }

    /// Installs frames captured before the overlay existed, for freeze mode.
    ///
    /// The same storage the loupe reads, deliberately: in freeze mode the loupe
    /// must magnify the photograph the user is selecting against and not the live
    /// screen behind it, or it would be answering a different question from every
    /// other pixel on screen. Seeding also means `warm` finds the display already
    /// filled and never re-takes it, which is what keeps the frozen picture
    /// frozen.
    func seed(_ frame: Frame, for displayID: CGDirectDisplayID) {
        frames[displayID] = frame
        isFrozen = true
    }

    /// Whether these frames were seeded rather than fetched — freeze mode.
    ///
    /// It turns off both refresh paths. A patch re-taken during a frozen
    /// selection would put live pixels under the loupe while the rest of the
    /// screen holds still, and the loupe is the one part of the UI whose job is
    /// to tell you exactly what you are about to save.
    private(set) var isFrozen = false

    /// Starts fetching `screen`'s frame if it is not already here or on its way.
    ///
    /// `capture` is injected rather than reached for: the overlay layer owns no
    /// capture engine, and a self-test that leaves it nil must simply get no
    /// loupe rather than a crash.
    func warm(
        _ screen: NSScreen,
        using capture: @escaping Capture,
        excluding excludedWindowIDs: Set<CGWindowID>
    ) {
        guard !isFrozen,
              let displayID = ScreenIndex.displayID(of: screen),
              frames[displayID] == nil,
              !inFlight.contains(displayID)
        else { return }
        inFlight.insert(displayID)
        let wanted = generation
        let covers = screen.frame
        Task { [weak self] in
            let result = await capture(displayID, nil, excludedWindowIDs)
            guard let self else { return }
            inFlight.remove(displayID)
            guard generation == wanted, let result else { return }
            frames[displayID] = Frame(image: result.image, scale: result.scale, covers: covers)
            onArrival?()
        }
    }

    /// Re-photographs a small square around the pointer.
    ///
    /// Called when the pointer comes to rest, which is the only moment it is both
    /// worth doing and free: nobody is watching the loupe mid-sweep, and by the
    /// time they look at it the patch has landed. One at a time — a second
    /// request while one is in flight is dropped rather than queued, since what
    /// it would fetch is already superseded.
    func refreshPatch(
        around point: CGPoint, on screen: NSScreen,
        using capture: @escaping Capture, excluding excludedWindowIDs: Set<CGWindowID>
    ) {
        guard !isFrozen, !patchInFlight, let displayID = ScreenIndex.displayID(of: screen)
        else { return }
        let side = Self.patchSide
        let wanted = CGRect(
            x: (point.x - side / 2).rounded(), y: (point.y - side / 2).rounded(),
            width: side, height: side
        ).intersection(screen.frame)
        guard wanted.width > Self.patchMargin * 2, wanted.height > Self.patchMargin * 2
        else { return }
        patchInFlight = true
        let generationAtRequest = generation
        Task { [weak self] in
            let result = await capture(displayID, wanted, excludedWindowIDs)
            guard let self else { return }
            patchInFlight = false
            guard generation == generationAtRequest, let result else { return }
            patch = (displayID, Frame(
                image: result.image, scale: result.scale, covers: wanted))
            onArrival?()
        }
    }

    /// Dropped on teardown, not kept for the next selection: these are tens of
    /// megabytes each, and a stale photograph is worse than no loupe.
    func clear() {
        generation += 1
        frames.removeAll()
        inFlight.removeAll()
        patch = nil
        patchInFlight = false
        isFrozen = false
    }
}
