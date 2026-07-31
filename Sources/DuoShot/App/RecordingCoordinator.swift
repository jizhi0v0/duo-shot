import AppKit

/// Orchestrates a recording from trigger to file.
///
/// The screenshot coordinator runs to completion inside one `await`; a recording
/// cannot, because it has to hand control back to the user for the length of the
/// take. So this one is a small state machine instead — `idle` / `arming` /
/// `recording`.
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
    }

    private let engine: RecordingEngine
    private let overlay: OverlayController
    private let hud = RecordingHUD()

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
    /// exact about which: `RecordingHUDPanel` ships with `sharingType = .none`,
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
    var excludedWindowIDs: Set<CGWindowID> { hud.windowIDs }

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
            Log.record.notice("recording trigger ignored; already arming")
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
        // those have a defined answer yet, so Space is not offered rather than
        // offered and quietly ignored.
        let outcome = await overlay.present(
            mode: .area, windows: [], allowsWindowMode: false)
        overlay.tearDown()

        guard case .area(let displayID, let rect) = outcome else { return }
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
        await begin(.display(displayID))
    }

    private func begin(_ request: RecordingRequest) async {
        let options = Preferences.shared.recordingOptions
        let url = StagingStore.shared.reserve(fileExtension: options.fileExtension)

        // Before the stream is built, not after: `SCContentFilter` is fixed at
        // start, and a sharingType flipped underneath a running stream is not a
        // documented way to change what it renders.
        onCaptureChromeHidden?(true)
        // Up before the stream, not after it. `startCapture` has been measured
        // at 3.8–4.3 s on this machine, and showing the HUD only once it
        // returned left the screen with the selection gone and nothing in its
        // place for that whole time.
        hud.showStarting(on: ScreenIndex.screen(for: request.displayID))

        do {
            let recording = try await engine.start(request, options: options, to: url)
            state = .recording
            hud.beginRecording(elapsed: { [weak self] in
                self?.elapsed ?? 0
            })
            // A stream that dies on its own — display unplugged, disk full,
            // Screen Recording revoked — must not leave the HUD on screen and
            // the menu bar claiming to record.
            recording.onUnexpectedStop { [weak self] error in
                Task { @MainActor in await self?.handleUnexpectedStop(error) }
            }
            onStateChanged?()
        } catch {
            state = .idle
            // The starting HUD is up by now and there will be no take to attach
            // it to. Leaving it would be a bar that claims a recording is on its
            // way forever.
            hud.hide()
            onCaptureChromeHidden?(false)
            onStateChanged?()
            Log.record.error("""
                could not start \(request.kind, privacy: .public) recording: \
                \(error.localizedDescription, privacy: .public)
                """)
            if CaptureFailure(error) == .authorisationLost { onAuthorisationLost?() }
            NSSound.beep()
        }
    }

    // MARK: - Ending

    func stop() async {
        guard state == .recording else { return }
        state = .idle
        hud.hide()
        onCaptureChromeHidden?(false)
        do {
            let result = try await engine.stop()
            if let output = OutputPipeline.shared.process(
                result, saveDirectoryOverride: saveDirectoryOverride) {
                onResult?(output)
            }
        } catch {
            Log.record.error("stopping failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        onStateChanged?()
    }

    func discard() async {
        guard state == .recording else { return }
        state = .idle
        hud.hide()
        onCaptureChromeHidden?(false)
        await engine.cancel()
        onStateChanged?()
    }

    // MARK: - Test hooks

    var hudIsVisibleForTest: Bool { hud.isVisible }
    var stagedURLForTest: URL? { engine.current?.url }

    private func handleUnexpectedStop(_ error: any Error) async {
        guard state == .recording else { return }
        Log.record.error("""
            recording stopped on its own: \(error.localizedDescription, privacy: .public)
            """)
        state = .idle
        hud.hide()
        onCaptureChromeHidden?(false)
        // Salvage rather than discard: whatever was written before the stream
        // died is still a recording, and throwing it away is the one outcome
        // the user can never undo.
        if let result = try? await engine.stop(),
           let output = OutputPipeline.shared.process(
            result, saveDirectoryOverride: saveDirectoryOverride) {
            onResult?(output)
        } else {
            engine.forget()
        }
        if CaptureFailure(error) == .authorisationLost { onAuthorisationLost?() }
        onStateChanged?()
    }
}
