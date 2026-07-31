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
/// alone. The cost is honest and worth stating — the frame is a *photograph*, so
/// a loupe over a playing video shows the pixels as they were when the selection
/// started. For placing an edge against static UI, which is what a loupe is for,
/// it is exact.
///
/// Filled per display and only on demand: a three-display machine should not pay
/// for three full-screen captures because the pointer visited one of them.
@MainActor
final class BackdropCache {
    /// One display's photograph, with everything needed to map a global point
    /// into it.
    struct Frame {
        let image: CGImage
        /// Pixels per point, from the capture itself rather than from
        /// `NSScreen.backingScaleFactor` — on mixed-DPI setups only the capture
        /// knows what it actually rendered at.
        let scale: CGFloat
        /// The AppKit global rect the image covers, i.e. the whole screen.
        let screenFrame: CGRect
    }

    /// Called when a frame lands, so the overlay can fade its loupe in.
    var onArrival: (() -> Void)?

    private var frames: [CGDirectDisplayID: Frame] = [:]
    private var inFlight: Set<CGDirectDisplayID> = []
    /// Bumped on every teardown. A capture that returns after the selection has
    /// gone belongs to a presentation that no longer exists, and storing it would
    /// hand the *next* selection a photograph of the last one.
    private var generation = 0

    func frame(for displayID: CGDirectDisplayID) -> Frame? { frames[displayID] }

    /// Starts fetching `screen`'s frame if it is not already here or on its way.
    ///
    /// `capture` is injected rather than reached for: the overlay layer owns no
    /// capture engine, and a self-test that leaves it nil must simply get no
    /// loupe rather than a crash.
    func warm(
        _ screen: NSScreen,
        using capture: @escaping (CGDirectDisplayID, Set<CGWindowID>) async -> CaptureResult?,
        excluding excludedWindowIDs: Set<CGWindowID>
    ) {
        guard let displayID = ScreenIndex.displayID(of: screen),
              frames[displayID] == nil,
              !inFlight.contains(displayID)
        else { return }
        inFlight.insert(displayID)
        let wanted = generation
        let frame = screen.frame
        Task { [weak self] in
            let result = await capture(displayID, excludedWindowIDs)
            guard let self else { return }
            inFlight.remove(displayID)
            guard generation == wanted, let result else { return }
            frames[displayID] = Frame(
                image: result.image, scale: result.scale, screenFrame: frame)
            onArrival?()
        }
    }

    /// Dropped on teardown, not kept for the next selection: these are tens of
    /// megabytes each, and a stale photograph is worse than no loupe.
    func clear() {
        generation += 1
        frames.removeAll()
        inFlight.removeAll()
    }
}
