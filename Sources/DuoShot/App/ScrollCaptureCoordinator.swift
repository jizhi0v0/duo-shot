import AppKit
import Carbon.HIToolbox

/// Orchestrates a scrolling capture (长截图) from trigger to stitched result.
///
/// Like a recording — and unlike a screenshot — the session hands control back
/// to the user for its whole length: they scroll the content themselves while
/// this loop photographs the chosen region a few times a second and
/// `ScrollStitcher` grows the picture. So this is a state machine in the
/// `RecordingCoordinator` mould, not a linear `await` in the capture
/// coordinator's.
///
/// Nothing here scrolls anything. The one alternative — synthesising scroll
/// events — needs the Accessibility grant, which this app has twice refused to
/// take on (see `HotKeyManager`). The user's own scrolling is the input.
@MainActor
final class ScrollCaptureCoordinator {
    enum State {
        case idle
        /// The overlay is up, or the armed selection is waiting for Start.
        case selecting
        case capturing
        /// The loop is draining and the canvas is being finalised. A separate
        /// state for the same reason recording has one: until `finish` returns,
        /// a re-trigger must not start a second session on top of the first.
        case finishing
    }

    /// ~5 fps ceiling. Fast enough that ordinary scrolling leaves generous
    /// overlap between frames; slow enough that a session is a light load —
    /// each frame is one `SCScreenshotManager` call (~30-60 ms) plus a row-hash
    /// pass off the main thread.
    private static let frameInterval: Duration = .milliseconds(180)
    /// Below this there is no room for the stitcher's minimum overlap plus
    /// visible growth, and the armed toolbar would not fit under it either.
    private static let minimumSelection: CGFloat = 48

    private struct Session {
        let displayID: CGDirectDisplayID
        let rect: CGRect
        /// The first frame's answer, kept for turning canvas rows into the
        /// points the HUD displays.
        var scale: CGFloat = 1
    }

    private let engine: CaptureEngine
    private let overlay: OverlayController
    private let hud = ScrollCaptureHUD()
    private let regionOutline = RecordingRegionOutline()

    private(set) var state: State = .idle
    private var session: Session?
    private var stitcher: ScrollStitcher?
    private var loopTask: Task<Void, Never>?
    private var escapeID: UInt32?
    private var consecutiveFailures = 0
    private var consecutiveMisaligns = 0

    var onResult: ((CaptureResult) async -> Void)?
    var onStateChanged: (() -> Void)?
    var onAuthorisationLost: (() -> Void)?
    /// Windows of ours that must not be stitched in — a preview card left over
    /// from an earlier capture, sitting inside the region. Read per frame, not
    /// per session: unlike a stream's filter, each screenshot rebuilds its
    /// exclusion list, so a card that appears mid-session is still kept out.
    var additionalExcludedWindowIDs: () -> Set<CGWindowID> = { [] }

    init(engine: CaptureEngine, overlay: OverlayController) {
        self.engine = engine
        self.overlay = overlay
        hud.onDone = { [weak self] in Task { await self?.finish() } }
        hud.onCancel = { [weak self] in Task { await self?.cancel() } }
    }

    var isActive: Bool { state != .idle }
    var isCapturing: Bool { state == .capturing }

    /// The one entry point, and the toggle: pressing ⌘⇧L over a live session
    /// finishes it, exactly as the recording bindings stop a take.
    func perform(_ action: HotKeyAction) async {
        guard action == .captureScrolling else { return }
        switch state {
        case .capturing:
            await finish()
        case .selecting, .finishing:
            Log.capture.notice("scrolling trigger ignored; session is \(String(describing: self.state), privacy: .public)")
        case .idle:
            await start()
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        state = .selecting
        onStateChanged?()
        defer {
            if state == .selecting {
                state = .idle
                onStateChanged?()
            }
        }

        do {
            try await engine.refreshContent()
        } catch {
            Log.capture.error("could not refresh shareable content: \(error, privacy: .public)")
            return
        }

        // Area only, confirmed on the bar: the user has to position their
        // content *before* frames start landing, which is what the armed
        // selection is for. No window suggestions — a window resizes and
        // scrolls as one thing, and "the region" is the contract here.
        let outcome = await overlay.present(
            windows: [], suggestsWindows: false, requiresConfirmation: true,
            toolbarStyle: .scroll)
        overlay.tearDown()

        guard case .area(let displayID, let rect) = outcome else { return }
        let adopted = overlay.takeHandedOverBar()
        guard rect.width >= Self.minimumSelection, rect.height >= Self.minimumSelection,
              let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main else {
            NSSound.beep()
            adopted?.dismiss()
            return
        }

        beginSession(displayID: displayID, rect: rect, on: screen, adopting: adopted)
    }

    private func beginSession(
        displayID: CGDirectDisplayID, rect: CGRect, on screen: NSScreen,
        adopting adopted: FloatingBarPanel?
    ) {
        let hidden = !Preferences.shared.overlayVisibleToScreenSharing
        hud.show(under: rect, on: screen, adopting: adopted, hiddenFromCapture: hidden)
        regionOutline.show(around: rect, hiddenFromCapture: hidden)
        registerEscape()

        session = Session(displayID: displayID, rect: rect)
        stitcher = ScrollStitcher()
        consecutiveFailures = 0
        consecutiveMisaligns = 0
        state = .capturing
        onStateChanged?()
        Log.capture.notice("scrolling capture started \(Int(rect.width))x\(Int(rect.height))")
        startLoop()
    }

    /// For `--selftest-scroll-flow`: enters the capturing state on `rect`
    /// directly, without the overlay interaction — the armed selection and its
    /// toolbar are already covered by `--selftest-selection-toolbar`.
    func startForTest(displayID: CGDirectDisplayID, rectInAppKitGlobal rect: CGRect) {
        guard state == .idle,
              let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main else { return }
        beginSession(displayID: displayID, rect: rect, on: screen, adopting: nil)
    }

    var hudIsVisibleForTest: Bool { hud.isVisible }

    /// Lets the flow test wait for "this scroll position has been stitched"
    /// instead of guessing with sleeps.
    func stitchedRowsForTest() async -> Int {
        guard let stitcher else { return 0 }
        return await stitcher.totalRows
    }

    /// Keeps what has been stitched. Safe to call from anywhere *except* inside
    /// the frame loop — the loop schedules it through a fresh task instead,
    /// because awaiting `loopTask` from within `loopTask` never returns.
    func finish() async {
        guard state == .capturing else { return }
        state = .finishing
        onStateChanged?()
        teardownChrome()
        let task = loopTask
        loopTask = nil
        await task?.value

        let result: CaptureResult?
        if let stitcher, let session {
            result = await stitcher.finalize(
                sourceDisplayID: session.displayID, sourceDescription: "Scrolling Capture")
        } else {
            result = nil
        }
        stitcher = nil
        session = nil
        state = .idle
        onStateChanged?()

        if let result {
            Log.capture.notice("""
                scrolling capture finished: \
                \(Int(result.pointSize.width))x\(Int(result.pointSize.height)) pt
                """)
            await onResult?(result)
        } else {
            NSSound.beep()
        }
    }

    /// Discards everything. Same drain as `finish`, nothing delivered.
    func cancel() async {
        guard state == .capturing else { return }
        state = .finishing
        onStateChanged?()
        teardownChrome()
        let task = loopTask
        loopTask = nil
        await task?.value
        stitcher = nil
        session = nil
        state = .idle
        onStateChanged?()
        Log.capture.notice("scrolling capture cancelled")
    }

    /// Every exit path runs this exact method — chrome left on screen over a
    /// dead session is a control that lies about what it does, and a transient
    /// Escape left registered eats the key globally forever.
    private func teardownChrome() {
        hud.hide()
        regionOutline.hide()
        if let escapeID {
            HotKeyManager.shared.unregister(escapeID)
            self.escapeID = nil
        }
    }

    /// Esc must work while the user's focus is in *another* app — that is the
    /// whole session — and the bar cannot become key, so a local monitor would
    /// never see the key. Carbon again, for the same no-Accessibility reason as
    /// every other binding. Registered only for the capturing phase; during the
    /// selection the overlay owns Esc itself.
    private func registerEscape() {
        do {
            escapeID = try HotKeyManager.shared.registerTransient(
                KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [])
            ) { [weak self] in
                Task { await self?.cancel() }
            }
        } catch {
            // Survivable: the bar's Cancel and the status menu still end the
            // session. Most likely cause is the shortcut recorder having
            // released every binding.
            Log.hotkeys.error("could not claim Esc for the session: \(error, privacy: .public)")
        }
    }

    // MARK: - The frame loop

    private func startLoop() {
        loopTask = Task { [weak self] in
            while true {
                guard let self, self.state == .capturing else { break }
                let started = ContinuousClock.now
                await self.step()
                let spent = started.duration(to: .now)
                if spent < Self.frameInterval {
                    try? await Task.sleep(for: Self.frameInterval - spent)
                }
            }
        }
    }

    private func step() async {
        guard state == .capturing, let session, let stitcher else { return }
        var options = CaptureOptions.default
        // Forced off, never the preference: a frozen arrow stitched twenty
        // times is twenty arrows (the loupe backdrop learned this first).
        options.showsCursor = false
        options.excludedWindowIDs = hud.windowIDs
            .union(regionOutline.windowIDs)
            .union(additionalExcludedWindowIDs())

        let frame: CaptureResult
        do {
            frame = try await engine.capture(
                .area(displayID: session.displayID, rectInAppKitGlobal: session.rect),
                options: options)
        } catch {
            let failure = CaptureFailure(error)
            Log.capture.error("scroll frame failed: \(failure.summary, privacy: .public)")
            if case .authorisationLost = failure {
                let callback = onAuthorisationLost
                Task {
                    await self.cancel()
                    callback?()
                }
                return
            }
            consecutiveFailures += 1
            if consecutiveFailures >= 5 {
                // Salvage beats loss: keep what was stitched before the
                // display went away.
                Task { await self.finish() }
            }
            return
        }

        consecutiveFailures = 0
        if self.session?.scale == 1 { self.session?.scale = frame.scale }
        await handle(await stitcher.append(frame))
    }

    private func handle(_ verdict: ScrollStitcher.Verdict) async {
        switch verdict {
        case .seeded, .appended, .repositioned:
            consecutiveMisaligns = 0
            if let stitcher, let session {
                let rows = await stitcher.totalRows
                hud.setHeight(points: Int(Double(rows) / session.scale))
            }
        case .skippedIdentical:
            consecutiveMisaligns = 0
        case .rejected(.cannotAlign):
            consecutiveMisaligns += 1
            // Two in a row, not one: a single miss is usually the frame that
            // straddled a fling. Two means the user genuinely outran the
            // overlap. If it *keeps* not aligning, the thread is lost — new
            // frames share nothing with the stitch — and the honest remedy is
            // to scroll back into captured content, where the stitcher
            // relocates and resumes.
            if consecutiveMisaligns == 2 {
                hud.flashHint("Scroll slower")
            } else if consecutiveMisaligns >= 8, consecutiveMisaligns.isMultiple(of: 8) {
                hud.flashHint("Scroll back")
            }
        case .rejected(.mismatchedFrame):
            // The display was rescaled or replugged under the session; no
            // further frame will ever align. Keep what there is.
            Task { await self.finish() }
        case .canvasFull:
            Task { await self.finish() }
        }
    }
}
