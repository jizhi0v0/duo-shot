import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let coordinator: CaptureCoordinator
    private let recorder: RecordingCoordinator
    /// Just the URLs, not the `OutputPipeline.Output` they came in.
    ///
    /// That struct carries the whole `CaptureResult`, and with it the CGImage —
    /// ~59 MB for one 5K screen, held for the rest of the session by a menu that
    /// reads a last path component and reveals a file.
    private var lastOutputURL: URL?
    private var lastRecordingURL: URL?
    private var recordingTicker: Timer?
    /// What `setHiddenFromCapture` was last told, so an item installed part-way
    /// through a take is created in the state the take left the old one in.
    private var isHiddenFromCapture = false

    var onOpenSettings: () -> Void = {}

    init(coordinator: CaptureCoordinator, recorder: RecordingCoordinator) {
        self.coordinator = coordinator
        self.recorder = recorder
        super.init()
    }

    /// A fresh status item arrives capturable (`sharingType` defaults to
    /// `.readOnly`), clockless and with an idle menu, so installing one during a
    /// take — "Show menu bar icon" toggled off and back on mid-recording — used
    /// to put the ticking timer back into the video that `setHiddenFromCapture`
    /// exists to keep it out of. The running state is therefore re-applied here
    /// rather than only on the next `refreshRecordingState`.
    func install() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setHiddenFromCapture(isHiddenFromCapture)
        // Sets the image, the timer and the menu, for whichever state the
        // recorder is actually in.
        refreshRecordingState()
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Hides the menu bar item from ScreenCaptureKit, for the length of a
    /// recording.
    ///
    /// Its window belongs to AppKit and is `.readOnly` like any ordinary one, so
    /// it is recorded — a stream renders the capturing process's own windows
    /// (measured 2026-07-31; see `RecordingCoordinator.excludedWindowIDs`).
    /// During a take this item is showing the running timer, so leaving it
    /// visible puts a clock in the corner of every fullscreen recording.
    ///
    /// Only for the take, never permanently: a screenshot of one's own menu bar
    /// should still show DuoShot in it. That is also why the Settings window is
    /// left alone — it is deliberately capturable, and `--selftest-window`
    /// asserts as much.
    func setHiddenFromCapture(_ hidden: Bool) {
        isHiddenFromCapture = hidden
        statusItem?.button?.window?.sharingType = hidden ? .none : .readOnly
    }

    func noteOutput(_ output: OutputPipeline.Output) {
        lastOutputURL = output.url
        statusItem?.menu = buildMenu()
    }

    func noteRecording(_ output: OutputPipeline.RecordingOutput) {
        lastRecordingURL = output.url
        statusItem?.menu = buildMenu()
    }

    /// Reflects the recorder's state in the menu bar.
    ///
    /// The live timer up here is only safe because of `setHiddenFromCapture`.
    ///
    /// It was originally justified by M9 — "a stream never renders the capturing
    /// process's own windows" — which was withdrawn on 2026-07-31: this item is
    /// an ordinary `.readOnly` AppKit window and measured 2765 of its 2880 px
    /// came back inside a recording. So the clock is hidden from ScreenCaptureKit
    /// for the length of a take instead.
    func refreshRecordingState() {
        recordingTicker?.invalidate()
        recordingTicker = nil
        guard let button = statusItem?.button else { return }

        if recorder.isRecording {
            button.image = NSImage(
                systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.image?.isTemplate = true
            updateRecordingTitle()
            let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingTitle() }
            }
            // `.common`, or the clock freezes whenever a menu is open or a
            // window is being dragged — constantly, during a screen recording.
            RunLoop.main.add(ticker, forMode: .common)
            recordingTicker = ticker
        } else {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder", accessibilityDescription: "DuoShot")
            button.image?.isTemplate = true
            button.title = ""
        }
        statusItem?.menu = buildMenu()
    }

    private func updateRecordingTitle() {
        let total = Int(recorder.elapsed)
        statusItem?.button?.title = String(format: " %d:%02d", total / 60, total % 60)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // While a take is running the only thing worth offering is ending it.
        // A menu full of capture actions that all silently refuse is worse than
        // a short menu.
        if recorder.isRecording {
            let stop = NSMenuItem(
                title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            let discard = NSMenuItem(
                title: "Discard Recording", action: #selector(discardRecording), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
            menu.addItem(.separator())
            let quit = NSMenuItem(
                title: "Quit DuoShot", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
            menu.addItem(quit)
            return menu
        }

        var actions: [HotKeyAction] = [.captureArea, .captureWindow, .captureFullscreen]
        if coordinator.hasPreviousArea { actions.append(.captureLastArea) }
        actions.append(contentsOf: [.recordArea, .recordFullscreen])
        for action in actions {
            let item = NSMenuItem(
                title: action.title, action: #selector(trigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            if let combo = HotKeyManager.shared.combo(for: action) {
                item.keyEquivalent = ""
                item.toolTip = combo.displayString
                item.title = "\(action.title)  \(combo.displayString)"
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if let lastRecordingURL {
            let reveal = NSMenuItem(
                title: "Show \"\(lastRecordingURL.lastPathComponent)\" in Finder",
                action: #selector(revealLastRecording), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
        }

        if let lastOutputURL {
            let reveal = NSMenuItem(
                title: "Show \"\(lastOutputURL.lastPathComponent)\" in Finder",
                action: #selector(revealLast), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
        }

        let folder = NSMenuItem(
            title: "Open Save Folder", action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit DuoShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func trigger(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let action = HotKeyAction(rawValue: raw)
        else { return }
        Task { await self.perform(action) }
    }

    func perform(_ action: HotKeyAction) async {
        switch action {
        case .captureArea:
            await coordinator.captureArea()
        case .captureWindow:
            await coordinator.captureWindow()
        case .captureFullscreen:
            await coordinator.captureDisplay()
        case .captureLastArea:
            await coordinator.captureLastArea()
        case .recordArea, .recordFullscreen:
            await recorder.perform(action)
        }
    }

    @objc private func stopRecording() {
        Task { await self.recorder.stop() }
    }

    @objc private func discardRecording() {
        Task { await self.recorder.discard() }
    }

    @objc private func revealLastRecording() {
        guard let lastRecordingURL else { return }
        OutputPipeline.shared.reveal(lastRecordingURL)
    }

    @objc private func revealLast() {
        guard let lastOutputURL else { return }
        OutputPipeline.shared.reveal(lastOutputURL)
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(Preferences.shared.saveDirectory)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
