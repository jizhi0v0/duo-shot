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

    /// The links this Mac has handed out lately.
    ///
    /// The menu bar rather than only the preview cards, because an upload
    /// outlives its card: a recording can still be transferring long after the
    /// six-second timer took the card away, and without this the link would have
    /// existed only on the clipboard until the next ⌘C overwrote it.
    ///
    /// Plain click copies. ⌥-click deletes — and it really deletes, server-side,
    /// which is why it is behind a modifier and says so.
    private func recentLinksItem() -> NSMenuItem? {
        let entries = ShareHistory.shared.entries
        guard !entries.isEmpty else { return nil }

        let submenu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(
                title: entry.name, action: #selector(copyRecentLink(_:)), keyEquivalent: "")
            item.target = self
            // The whole entry, not the URL string it used to carry: writing the
            // link as Markdown needs the name and the file URL as well, and a
            // row that carried only one of the two URLs could not honour the
            // format preference without going back to the history to find the
            // other.
            item.representedObject = entry
            item.toolTip = entry.link.pageURL.absoluteString

            // The alternate is the same row, shown only while ⌥ is held. A
            // separate always-visible "Delete" row per link would double the
            // length of a menu whose whole purpose is to be glanced at.
            let delete = NSMenuItem(
                title: "Delete \"\(entry.name)\" from the server",
                action: #selector(deleteRecentLink(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = entry.link.key
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = .option

            submenu.addItem(item)
            submenu.addItem(delete)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear This List", action: #selector(clearRecentLinks), keyEquivalent: "")
        clear.target = self
        clear.toolTip = "Only forgets them here. The links keep working."
        submenu.addItem(clear)

        let item = NSMenuItem(title: "Recent Links", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func copyRecentLink(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ShareHistory.Entry else { return }
        ShareService.copy(entry.link, name: entry.name, isImage: entry.isImage)
    }

    @objc private func deleteRecentLink(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        ShareService.shared.revoke(key)
    }

    @objc private func clearRecentLinks() {
        ShareHistory.shared.clear()
    }

    /// For `--selftest-share-flow`, which has no way to click a menu bar item.
    func menuForTest() -> NSMenu { buildMenu() }

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

        // `.captureWindow` is deliberately absent, and it is not an oversight:
        // it captures whatever is under the pointer, and choosing it from a menu
        // puts the pointer on the menu. The menu is layer 101 and so unpickable,
        // so the hit-test would fall through to whatever window happens to be
        // behind the status menu and capture *that* — a wrong answer delivered
        // silently, which is the one thing this shortcut is written to avoid.
        // It stays on its hotkey, where the pointer is wherever the user left it.
        var actions: [HotKeyAction] = [.captureArea, .captureFullscreen]
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

        if let recent = recentLinksItem() {
            menu.addItem(recent)
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
