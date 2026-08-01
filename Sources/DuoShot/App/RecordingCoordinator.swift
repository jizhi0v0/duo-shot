import AppKit

/// Orchestrates a recording from trigger to file.
///
/// The screenshot coordinator runs to completion inside one `await`; a recording
/// cannot, because it has to hand control back to the user for the length of the
/// take. So this one is a small state machine instead — `idle` / `arming` /
/// `recording` / `finishing`.
///
/// A take has three ways to end and each one has to leave the same world behind
/// it: `stop` (keep the file), `discard` (delete it), and `handleUnexpectedStop`
/// (the stream died on its own). All three clear the state, take the HUD down
/// and fire `onStateChanged`, because a HUD left on screen over a dead stream is
/// a control that lies about what it does.
@MainActor
final class RecordingCoordinator {
    enum State {
        case idle
        /// Selection is on screen, or the stream is starting.
        case arming
        case recording
        /// The stream is stopped and the file is being finalised.
        ///
        /// A separate state because finalising is not instant — `finish` waits
        /// on the writer and then reads the duration back out of the container,
        /// which is seconds for a long take — and until it returns the old
        /// stream is still tearing down. Going straight back to `idle` there let
        /// the next trigger through the guard in `perform` and start a second
        /// stream on top of the first.
        case finishing
    }

    private let engine: RecordingEngine
    private let overlay: OverlayController
    private let hud = RecordingHUD()
    private let regionOutline = RecordingRegionOutline()

    private(set) var state: State = .idle

    var onResult: ((OutputPipeline.RecordingOutput) -> Void)?
    var onStateChanged: (() -> Void)?
    var onAuthorisationLost: (() -> Void)?
    /// Raised for the length of a take so chrome of ours that is capturable —
    /// the menu bar item, which AppKit owns and which is `.readOnly` like any
    /// ordinary window — stays out of the video. Lowered again on every exit,
    /// including the failure ones: an icon left invisible to screenshots after a
    /// take that never started is a worse bug than the one this fixes.
    var onCaptureChromeHidden: ((Bool) -> Void)?
    /// A take that produced nothing at all. The only channel left: there is no
    /// file, so there is no preview card to carry the news, and saying nothing
    /// means the user recorded for a minute and got silence.
    var onRecordingLost: ((any Error) -> Void)?
    /// Other windows of ours that are on screen and must not reach the video —
    /// a preview card left over from an earlier capture, most of all. Only
    /// windows that exist before `engine.start` can be named in the filter, so
    /// this is read at exactly that moment.
    var additionalExcludedWindowIDs: (() -> Set<CGWindowID>)?
    /// The staging directory override, for self-tests that must not touch the
    /// user's save folder.
    var saveDirectoryOverride: URL?

    init(engine: RecordingEngine = RecordingEngine(), overlay: OverlayController) {
        self.engine = engine
        self.overlay = overlay
        hud.onStop = { [weak self] in Task { await self?.stop() } }
        hud.onDiscard = { [weak self] in Task { await self?.discard() } }
    }

    var isRecording: Bool { state == .recording }
    var elapsed: TimeInterval { engine.current?.elapsed ?? 0 }

    /// The HUD's window, so a *screenshot* taken mid-recording does not
    /// photograph it.
    ///
    /// Recordings are covered by a different mechanism, and it is worth being
    /// exact about which: `FloatingBarPanel` ships with `sharingType = .none`,
    /// which hides it from every ScreenCaptureKit path. NOT — as this comment
    /// claimed until 2026-07-31 — because a stream declines to render the
    /// capturing process's own windows. It does render them: measured with
    /// `--selftest-record-hud --plain-window --hud-first`, an ordinary titled
    /// window of this process, on screen before the stream was even built, came
    /// back in the video at 35525 px of its 36060.
    ///
    /// So any window of ours that is not `.none` lands in the take. That is why
    /// the status item is hidden for the length of one — see
    /// `onCaptureChromeHidden`.
    var excludedWindowIDs: Set<CGWindowID> { hud.windowIDs.union(regionOutline.windowIDs) }

    // MARK: - Triggering

    /// One entry point for both bindings. Pressing either while a take is
    /// running stops it, which is what makes ⇧⌘Y a toggle.
    func perform(_ action: HotKeyAction) async {
        guard action.isRecording else { return }
        if state == .recording {
            await stop()
            return
        }
        guard state == .idle else {
            let reason = state == .arming ? "already arming" : "still finishing the last take"
            Log.record.notice("recording trigger ignored; \(reason, privacy: .public)")
            return
        }
        switch action {
        case .recordArea: await startArea()
        case .recordFullscreen: await startFullscreen()
        default: break
        }
    }

    private func startArea() async {
        state = .arming
        onStateChanged?()
        defer { if state == .arming { state = .idle; onStateChanged?() } }

        do {
            try await engine.refreshContent()
        } catch {
            Log.record.error("could not refresh content: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Area only. A window moves, resizes and closes mid-take and none of
        // those have a defined answer yet, so no window is suggested rather than
        // suggested and then refused on the click.
        let outcome = await overlay.present(
            windows: [], suggestsWindows: false, requiresConfirmation: true)
        overlay.tearDown()

        guard case .area(let displayID, let rect) = outcome else { return }
        // Claimed before the overlay is gone for good: the bar the selection was
        // using becomes the recording's bar, window and all.
        adoptedBar = overlay.takeHandedOverBar()
        retriesLeft = 1
        await begin(.area(displayID: displayID, rectInAppKitGlobal: rect))
    }

    private func startFullscreen() async {
        state = .arming
        onStateChanged?()
        defer { if state == .arming { state = .idle; onStateChanged?() } }

        do {
            try await engine.refreshContent()
        } catch {
            Log.record.error("could not refresh content: \(error.localizedDescription, privacy: .public)")
            return
        }
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        retriesLeft = 1
        await begin(.display(displayID))
    }

    /// Reset for each trigger, so one bad take never uses up a later one's
    /// retry. Decremented only by the start path below.
    private var retriesLeft = 0
    /// The selection's bar, on its way to becoming the recording's. Consumed by
    /// the first `begin`, so a retry does not try to adopt it twice.
    private var adoptedBar: FloatingBarPanel?

    private func begin(_ request: RecordingRequest) async {
        var options = Preferences.shared.recordingOptions
        // Visible to screen sharing only if the user asked. Unlike the overlay,
        // these two CAN be visible during a take without ending up in it: both
        // exist before `engine.start` builds the filter, so their window IDs go
        // into `excludedWindowIDs` below and ScreenCaptureKit leaves them out.
        // The overlay cannot use that route — it is gone by the time the filter
        // is built, and an overlay raised later cannot be added to a fixed one.
        let hidden = !Preferences.shared.overlayVisibleToScreenSharing
        let url = StagingStore.shared.reserve(fileExtension: options.fileExtension)

        // Before the stream is built, not after: `SCContentFilter` is fixed at
        // start, and a sharingType flipped underneath a running stream is not a
        // documented way to change what it renders.
        onCaptureChromeHidden?(true)
        // Up before the stream, not after it. `startCapture` has been measured
        // at 3.8–4.3 s on this machine, and showing the HUD only once it
        // returned left the screen with the selection gone and nothing in its
        // place for that whole time.
        // Anchored to the region for an area take, so the bar stays where the
        // toolbar just was instead of jumping to the bottom of the screen.
        let region: CGRect? = if case .area(_, let rect) = request { rect } else { nil }
        // Asked before the stream exists because it changes the bar's width, and
        // the bar must not change width when the take begins. The engine applies
        // the same predicate to the same options, so the prediction and the
        // `ActiveRecording.microphoneDenied` it hands back cannot disagree.
        hud.showStarting(
            on: ScreenIndex.screen(for: request.displayID), under: region,
            adopting: adoptedBar, hiddenFromCapture: hidden,
            microphoneOff: RecordingEngine.microphoneWillBeDropped(options))
        adoptedBar = nil
        // Only for an area take. On a fullscreen one the answer to "what is
        // being recorded" is the whole screen, and a border round the edge of it
        // would be noise.
        if let region { regionOutline.show(around: region, hiddenFromCapture: hidden) }

        // Populated at last. The field has existed since the recorder was
        // written and was always empty, on the strength of M9's claim that a
        // stream never renders our own windows — which was withdrawn. With
        // `sharingType = .none` it was merely redundant; without it, it is the
        // only thing keeping this bar out of the take.
        options.excludedWindowIDs = excludedWindowIDs
            .union(additionalExcludedWindowIDs?() ?? [])

        do {
            let recording = try await engine.start(request, options: options, to: url)
            state = .recording
            hud.beginRecording(
                elapsed: { [weak self] in self?.elapsed ?? 0 },
                microphoneOff: recording.microphoneDenied)
            // A stream that dies on its own — display unplugged, disk full,
            // Screen Recording revoked — must not leave the HUD on screen and
            // the menu bar claiming to record.
            recording.onUnexpectedStop { [weak self] error in
                Task { @MainActor in await self?.handleUnexpectedStop(error) }
            }
            onStateChanged?()
        } catch {
            Log.record.error("""
                could not start \(request.kind, privacy: .public) recording: \
                \(error.localizedDescription, privacy: .public)\
                \(self.retriesLeft > 0 ? "; retrying once" : "")
                """)

            // Retried only here, at the start, and only once.
            //
            // The user has pressed a shortcut and is waiting; nothing has been
            // performed yet, so a second attempt costs them nothing and hides a
            // transient failure. The same retry *during* a take would be the
            // opposite of helpful: it would throw away the minute they had
            // already recorded and start a new take mid-sentence, without them
            // knowing either had happened.
            if retriesLeft > 0, CaptureFailure(error) != .authorisationLost {
                retriesLeft -= 1
                await begin(request)
                return
            }

            state = .idle
            // The starting HUD is up by now and there will be no take to attach
            // it to. Leaving it would be a bar that claims a recording is on its
            // way forever.
            hud.hide()
            regionOutline.hide()
            onCaptureChromeHidden?(false)
            onStateChanged?()
            if CaptureFailure(error) == .authorisationLost { onAuthorisationLost?() }
            NSSound.beep()
            onRecordingLost?(error)
        }
    }

    // MARK: - Ending

    /// `.finishing` for the whole of the await, `.idle` only once the file is
    /// closed. The state used to go to `.idle` first, which meant the seconds a
    /// finalise takes were seconds in which a hotkey could start a second stream
    /// while the first was still tearing down.
    func stop() async {
        guard state == .recording else { return }
        state = .finishing
        hud.hide()
        regionOutline.hide()
        onCaptureChromeHidden?(false)
        await deliver(await engine.finish())
        state = .idle
        onStateChanged?()
    }

    func discard() async {
        guard state == .recording else { return }
        // Same reason as `stop`: `cancel` clears the engine's own handle before
        // it awaits the stream's stop, so `.idle` here would let the next
        // trigger build a stream while this one is still going down.
        state = .finishing
        hud.hide()
        regionOutline.hide()
        onCaptureChromeHidden?(false)
        await engine.cancel()
        state = .idle
        onStateChanged?()
    }

    /// Ends whatever is in flight and does not return until the file is closed.
    ///
    /// For `applicationShouldTerminate`, which is the one caller that has to
    /// wait: quitting mid-take otherwise kills the writer with the file
    /// unfinalised. A stop already under way owns the finish, so this waits it
    /// out rather than starting a second one — `finish` on a cleared engine
    /// would report the take as lost and put an alert up on the way out.
    func settle() async {
        if state == .recording { await stop() }
        // `!Task.isCancelled` because a cancelled `Task.sleep` throws at once:
        // without it this becomes a hot loop the moment anyone cancels.
        while state == .finishing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A take that would be destroyed by quitting now.
    var hasTakeInFlight: Bool { state == .recording || state == .finishing }

    // MARK: - Test hooks

    var hudIsVisibleForTest: Bool { hud.isVisible }
    var stagedURLForTest: URL? { engine.current?.url }

    private func handleUnexpectedStop(_ error: any Error) async {
        // `.arming` counts. There is a window between `engine.start` returning
        // and the handler being attached in which the stream can die, and
        // `SCKRecordingSession` now replays such an error to whoever attaches
        // next — so it can legitimately land while this is still arming, and
        // returning here would leave the HUD stuck on "Starting…" and the menu
        // bar item hidden from capture for the rest of the session.
        //
        // `.finishing` does not count, though: the take is already being
        // finalised by `stop`, and a second `engine.finish()` on a cleared
        // engine reports the recording as lost and puts an alert in front of a
        // user whose file is fine.
        guard state == .arming || state == .recording else { return }
        Log.record.error("""
            recording stopped on its own: \(error.localizedDescription, privacy: .public)
            """)
        state = .idle
        hud.hide()
        regionOutline.hide()
        onCaptureChromeHidden?(false)
        // Salvage rather than discard: whatever was written before the stream
        // died is still a recording, and throwing it away is the one outcome
        // the user can never undo.
        await deliver(await engine.finish(), stopError: error)
        if CaptureFailure(error) == .authorisationLost { onAuthorisationLost?() }
        onStateChanged?()
    }

    /// Turns an outcome into exactly one user-visible consequence.
    ///
    /// The three cases are deliberately separate. A take that ended badly but
    /// left a file is still handed over — marked, so the preview card can say
    /// it is incomplete — because only the user can decide a partial recording
    /// is worthless. A take that left nothing has to speak up, since there will
    /// be no card to carry the news.
    private func deliver(_ outcome: RecordingEngine.Outcome, stopError: (any Error)? = nil) async {
        switch outcome {
        case .finished(let result):
            if let output = OutputPipeline.shared.process(
                result, saveDirectoryOverride: saveDirectoryOverride) {
                onResult?(output)
            }
        case .salvaged(let result, let failure):
            Log.record.error("""
                salvaged \(result.url.lastPathComponent, privacy: .public) \
                after \((failure ?? stopError)?.localizedDescription ?? "an unclean stop", privacy: .public)
                """)
            if var output = OutputPipeline.shared.process(
                result, saveDirectoryOverride: saveDirectoryOverride) {
                output.isIncomplete = true
                onResult?(output)
            }
        case .lost(let url, let failure):
            // The file is left where it is on purpose. It is the only sample of
            // a failure we cannot reproduce on demand, and deleting it is how
            // the last one was lost.
            Log.record.error("""
                recording lost, staged file left at \(url.path, privacy: .public): \
                \((failure ?? stopError)?.localizedDescription ?? "unknown", privacy: .public)
                """)
            NSSound.beep()
            onRecordingLost?(failure ?? stopError ?? RecordingError.fileMissing(url))
        }
    }
}
