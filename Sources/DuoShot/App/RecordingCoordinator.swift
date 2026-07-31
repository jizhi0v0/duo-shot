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
    /// photograph it. Recordings do not need this — a stream never renders our
    /// own windows (M9) — but screenshots very much do.
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

        do {
            let recording = try await engine.start(request, options: options, to: url)
            state = .recording
            hud.show(on: ScreenIndex.screen(for: request.displayID), elapsed: { [weak self] in
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
