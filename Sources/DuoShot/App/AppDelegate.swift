import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = CaptureCoordinator()
    private let previews = PreviewStackController()
    private let settings = PreferencesWindowController()
    /// Shares the capture coordinator's overlay: only one selection can be on
    /// screen at a time, and two controllers each owning their own panels would
    /// be two ways to end up with a stranded one.
    private lazy var recorder = RecordingCoordinator(overlay: coordinator.overlay)
    private lazy var statusItem = StatusItemController(
        coordinator: coordinator, recorder: recorder)
    private var isReauthorising = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let granted = ScreenPermission.isGranted
        Log.app.notice("""
            launched screen-capture-access=\(granted ? "granted" : "denied", privacy: .public) \
            path=\(Bundle.main.bundleURL.path, privacy: .public)
            """)

        wireCoordinator()
        wireRecorder()
        wireSettings()

        previews.timeout = .seconds(Preferences.shared.previewTimeout)
        if Preferences.shared.showsMenuBarIcon { statusItem.install() }
        registerHotkeys()

        Task { await self.ensureScreenCaptureAccess() }
    }

    // MARK: - Wiring

    private func wireCoordinator() {
        coordinator.onResult = { [weak self] result in
            guard let self, let output = OutputPipeline.shared.process(result) else { return }
            self.statusItem.noteOutput(output)
            if Preferences.shared.showsPreviewOverlay {
                self.previews.timeout = .seconds(Preferences.shared.previewTimeout)
                self.previews.present(output)
            }
        }
        // A preview left over from the previous capture is on screen; keep it out
        // of the next one.
        // The recording HUD is on screen for the length of a take, and a
        // screenshot taken during one would otherwise photograph it. Recordings
        // are covered by `sharingType = .none` on the panels themselves rather
        // than by this list — NOT, as this comment claimed until 2026-07-31,
        // because a stream declines to render our own windows. It does render
        // them; see the M9 revision in the plan.
        coordinator.additionalExcludedWindowIDs = { [weak self] in
            guard let self else { return [] }
            return self.previews.panelWindowIDs.union(self.recorder.excludedWindowIDs)
        }
        // The overlay must know whether a take is being written; see
        // `OverlayController.isRecordingActive`.
        coordinator.overlay.isRecordingActive = { [weak self] in
            self?.recorder.isRecording ?? false
        }
        statusItem.onOpenSettings = { [weak self] in self?.settings.show() }
        coordinator.onAuthorisationLost = { [weak self] in
            Task { await self?.handleAuthorisationLost() }
        }
    }

    private func wireRecorder() {
        recorder.onStateChanged = { [weak self] in
            self?.statusItem.refreshRecordingState()
        }
        recorder.onCaptureChromeHidden = { [weak self] hidden in
            self?.statusItem.setHiddenFromCapture(hidden)
        }
        recorder.onResult = { [weak self] output in
            guard let self else { return }
            statusItem.noteRecording(output)
            guard Preferences.shared.showsPreviewOverlay else { return }
            // The poster frame is decoded off disk, so the card arrives a beat
            // after the take ends rather than with it. That beat is the reason
            // the preview is not presented synchronously here: blocking the main
            // actor on a decode would stall the HUD's own teardown.
            Task { [weak self] in
                let poster = await VideoPoster.frame(for: output.url)
                guard let self else { return }
                previews.timeout = .seconds(Preferences.shared.previewTimeout)
                previews.present(output, poster: poster ?? VideoPoster.placeholder())
            }
        }
        recorder.additionalExcludedWindowIDs = { [weak self] in
            self?.previews.panelWindowIDs ?? []
        }
        previews.isRecordingActive = { [weak self] in self?.recorder.isRecording ?? false }
        recorder.onRecordingLost = { [weak self] error in
            self?.reportRecordingLost(error)
        }
        recorder.onAuthorisationLost = { [weak self] in
            Task { await self?.handleAuthorisationLost() }
        }
    }

    /// The one case that has to interrupt: a take that produced no file.
    ///
    /// Everything else the recorder can say is carried by the preview card —
    /// the file is there, and a card marked incomplete is proportionate. When
    /// there is no file there is no card, and staying silent means the user
    /// recorded for a minute, watched the HUD disappear, and is left to work
    /// out on their own that nothing was kept.
    ///
    /// Deliberately not raised for `authorisationLost`, which has its own
    /// re-grant flow and would otherwise produce two dialogs for one cause.
    private func reportRecordingLost(_ error: any Error) {
        guard CaptureFailure(error) != .authorisationLost else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The recording could not be saved"
        alert.informativeText = """
            \(error.localizedDescription)

            Nothing was written, so there is no file to recover. If this keeps happening, Console shows the details under DuoShot.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// macOS 15+ expires the Screen Recording grant roughly monthly. When it
    /// does, ScreenCaptureKit fails rather than prompting, so the re-grant has
    /// to be driven from here — and, as on first run, the new grant only reaches
    /// us after a relaunch.
    private func handleAuthorisationLost() async {
        guard !isReauthorising else { return }
        isReauthorising = true
        defer { isReauthorising = false }

        Log.permission.error("screen capture authorisation lapsed; re-requesting")
        previews.dismissAll()
        NSApp.activate(ignoringOtherApps: true)
        _ = await ScreenPermission.request()

        if await ScreenPermission.waitForGrant(timeout: .seconds(180)) {
            ScreenPermission.relaunch()
        } else {
            ScreenPermission.openSystemSettings()
        }
    }

    private func wireSettings() {
        settings.onHotkeysChanged = { [weak self] in self?.registerHotkeys() }
        // While the recorder is armed, every global binding must be released or
        // Carbon consumes the combo before the local monitor can see it — which
        // would make it impossible to re-record an existing shortcut.
        settings.onRecordingChanged = { [weak self] isRecording in
            if isRecording {
                HotKeyManager.shared.unregisterAll()
            } else {
                self?.registerHotkeys()
            }
        }
        Preferences.shared.onMenuBarIconChanged = { [weak self] in
            guard let self else { return }
            if Preferences.shared.showsMenuBarIcon {
                self.statusItem.install()
            } else {
                self.statusItem.remove()
            }
        }
    }

    // MARK: - Hotkeys

    /// Registration order is `HotKeyAction.allCases`, not the dictionary's.
    ///
    /// `HotKeyManager.register` refuses a combo that is already bound, so with
    /// two actions holding one combo exactly one of them wins — and iterating
    /// `Preferences.hotkeys` directly meant *which* one varied from launch to
    /// launch, because a Dictionary's order depends on its seed. Settings now
    /// takes a duplicate off the other action (`Preferences.bind`), so this
    /// should never have to arbitrate; a fixed order is what makes that
    /// "should" verifiable rather than a hope.
    private func registerHotkeys() {
        let manager = HotKeyManager.shared
        manager.unregisterAll()

        let bindings = HotKeyAction.allCases.compactMap { action in
            Preferences.shared.hotkeys[action].map { (action, $0) }
        }
        for (action, combo) in bindings {
            do {
                try manager.register(action, combo: combo) { [weak self] in
                    Task { await self?.statusItem.perform(action) }
                }
            } catch {
                Log.hotkeys.error("""
                    could not bind \(combo.displayString, privacy: .public) to \
                    \(action.rawValue, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            if let owner = SystemHotKeyProbe.systemBinding(matching: combo) {
                // Registration will have *succeeded* and will silently never
                // fire, so this is worth saying out loud.
                Log.hotkeys.error("""
                    \(combo.displayString, privacy: .public) is owned by macOS \
                    (\(owner, privacy: .public)); it will never reach DuoShot
                    """)
            }
        }
    }

    // MARK: - Permission

    /// The load-bearing detail: a running process never observes a *newly*
    /// granted Screen Recording permission — macOS only hands it over on the
    /// next launch. A successful grant must therefore be followed by relaunching
    /// ourselves, or the user grants access and nothing works.
    private func ensureScreenCaptureAccess() async {
        guard !ScreenPermission.isGranted else {
            Log.permission.notice("screen capture already authorised")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        Log.permission.notice("requesting screen capture access")
        _ = await ScreenPermission.request()

        if await ScreenPermission.waitForGrant() {
            Log.permission.notice("screen capture granted; relaunching")
            ScreenPermission.relaunch()
        } else {
            Log.permission.error("screen capture still denied after request")
            ScreenPermission.openSystemSettings()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Termination

    /// Quitting mid-take must not cost the take.
    ///
    /// The status item offers Quit while a recording is running — deliberately,
    /// since it is also the menu that offers Stop — and terminating there kills
    /// the writer with the file unfinalised: an .mp4 with no moov atom, which is
    /// as good as lost to most players. So the quit is deferred and the take is
    /// ended through the coordinator's ordinary stop path, which finalises the
    /// file, moves it to the save folder and marks it incomplete if it is.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.hasTakeInFlight else { return .terminateNow }

        Log.app.notice("quit requested during a take; finalising before exit")
        Task {
            await recorder.settle()
            replyToTermination()
        }
        // A quit that can never complete is worse than a lost recording, and
        // this is a deadline nothing below it enforces end to end: the engine
        // caps its own finalise at 15 s, so this only fires when something under
        // that hangs. `.terminateLater` waits forever on its own.
        Task {
            try? await Task.sleep(for: .seconds(Self.terminationStopTimeout))
            if !hasRepliedToTermination {
                Log.app.error("""
                    the recording did not finish within \
                    \(Self.terminationStopTimeout, privacy: .public) s; quitting anyway
                    """)
            }
            replyToTermination()
        }
        return .terminateLater
    }

    private static let terminationStopTimeout: Int = 20
    private var hasRepliedToTermination = false

    /// `reply(toApplicationShouldTerminate:)` is answered exactly once — the
    /// stop and its deadline race, and both arrive.
    private func replyToTermination() {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
