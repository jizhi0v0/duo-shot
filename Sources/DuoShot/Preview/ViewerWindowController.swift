import AppKit

/// DuoShot's own window for looking at a capture.
///
/// Exists so that "view this" does not mean `NSWorkspace.shared.open`, which is
/// what the card's double-click used to do. Handing the file to Preview.app is a
/// perfectly good way to lose the thread: it activates another application,
/// stacks a document window wherever that app last put one, and — for a
/// recording — hands over to QuickTime, so the two halves of DuoShot's own
/// output open in two different programs with two different sets of habits.
///
/// One window per file. Asking for a file that is already open raises the window
/// it already has rather than making a second one, because two windows of the
/// same screenshot is never what the second click meant.
@MainActor
final class ViewerWindowController {
    static let shared = ViewerWindowController()

    /// Live windows by the file they show. The key is the file URL, so a capture
    /// that has been re-opened after its card timed out finds its own window.
    private var windows: [URL: NSWindow] = [:]
    private var observers: [URL: any NSObjectProtocol] = [:]

    /// Self-tests set this to false, for the reason `PreferencesWindowController`
    /// gives: `NSApp.activate` takes the keyboard away from whatever the person
    /// running the test is typing in.
    var activatesOnShow = true

    /// Called with a capture's URL and a fresh thumbnail once a redaction has
    /// been written over its file.
    ///
    /// Injected by whoever owns the preview stack, the way
    /// `CaptureCoordinator.additionalExcludedWindowIDs` is. The viewer must not
    /// reach for the stack itself: a card is a thing that may or may not still be
    /// on screen six seconds after a capture, and a window that knew how to find
    /// one would also have to know when there is nothing to find.
    var onImageRedacted: ((URL, NSImage) -> Void)?

    /// The same for a recording that has been trimmed: the URL, and a poster
    /// frame decoded from the file as it is now. Separate from the still's hook
    /// rather than one "edited" callback, because the two are wired to the same
    /// place today and there is no reason a card must always treat them alike.
    var onVideoTrimmed: ((URL, NSImage) -> Void)?

    func show(_ entry: PreviewEntry) {
        if let existing = windows[entry.url] {
            bringToFront(existing)
            return
        }
        guard let content = makeContent(for: entry) else {
            // Nothing to show usually means the file moved or was pruned out from
            // under the card. Falling back to the system opener would be a worse
            // failure than saying so: it would either bounce the Dock or open a
            // second app on an empty file.
            Log.app.error("""
                viewer: cannot read \(entry.url.lastPathComponent, privacy: .public)
                """)
            NSSound.beep()
            return
        }

        let window = ViewerWindow(contentRect: CGRect(origin: .zero, size: content.size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = entry.url.lastPathComponent
        window.contentView = content.view
        // The window outlives its close — `windows` is what decides lifetime, and
        // a released-on-close window would be freed while this dictionary still
        // pointed at it.
        window.isReleasedWhenClosed = false
        // No subtitle. "DuoShot" next to the filename reads as belt-and-braces
        // identification for an LSUIElement app, right up until you see it: the
        // default filename template already begins with the app's name, so the
        // title bar said "DuoShot 2026-08-01 at 16.11.07.png — DuoShot".
        // Content is dark whatever the file is — a screenshot letterboxed against
        // a light window reads as part of the image.
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.setContentSize(content.size)
        // Space plays and pauses a recording, and the arrow keys step it — but
        // only while AVPlayerView holds the keyboard, and it does not take it on
        // its own.
        window.initialFirstResponder = content.keyView ?? content.view
        place(window, onDisplay: entry.sourceDisplayID)

        windows[entry.url] = window
        // The dictionary is the only thing keeping this window alive, so the
        // entry has to go when the window does — otherwise a closed window is
        // resurrected by the next click instead of a fresh one being built.
        observers[entry.url] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(entry.url) }
        }

        bringToFront(window)
        content.onShown?()
    }

    private func forget(_ url: URL) {
        if let observer = observers.removeValue(forKey: url) {
            NotificationCenter.default.removeObserver(observer)
        }
        // Stops playback and releases the decoder. A closed AVPlayerView whose
        // player is still running keeps decoding audio into a window nobody can
        // see — the file is a screen recording, so that is a real possibility
        // rather than a theoretical one.
        if let window = windows.removeValue(forKey: url) {
            (window.contentView as? VideoTrimEditor)?.playerView.player?.pause()
        }
    }

    /// Closes every viewer. Used by the self-tests, and by nothing else: a user
    /// closes these one at a time like any other window.
    func closeAll() {
        for window in windows.values { window.close() }
        windows.removeAll()
        for observer in observers.values { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: - Content

    private struct Content {
        var view: NSView
        /// The size the window should open at, in points.
        var size: CGSize
        /// What the window should hand the keyboard to, when that is not the
        /// content view itself: a recording's player is inside a container now,
        /// and Space and the arrow keys are the player's, not the container's.
        var keyView: NSView?
        /// Run once the window is on screen. Playback starts here rather than at
        /// build time so the first frame is not decoded into an unmapped window.
        var onShown: (() -> Void)?
    }

    private func makeContent(for entry: PreviewEntry) -> Content? {
        switch entry.kind {
        case .video(let result):
            return videoContent(for: entry.url, pointSize: result.pointSize)
        case .image:
            return imageContent(for: entry.url)
        }
    }

    /// `pointSize` comes from the `RecordingResult` rather than from the file.
    ///
    /// Reading it back off the asset would mean `AVAsset`'s async track loading,
    /// and awaiting it here would open the window at a placeholder size and then
    /// resize it under the user a moment later. The recorder already knows the
    /// answer — it chose the frame size — and a viewer that opens at the right
    /// size immediately is worth more than one that re-derives it.
    private func videoContent(for url: URL, pointSize: CGSize) -> Content? {
        let size = pointSize.width >= 1 && pointSize.height >= 1
            ? pointSize
            : CGSize(width: 960, height: 540)
        let editor = VideoTrimEditor(
            url: url, frame: CGRect(origin: .zero, size: fitted(size)))
        editor.onTrimmed = { [weak self] poster in
            self?.onVideoTrimmed?(url, poster)
        }

        // Exactly the video's aspect, with no allowance for the transport
        // controls. Reserving 40 pt for them was the obvious guess and it was
        // wrong: `.inline` controls are an auto-hiding overlay over the bottom of
        // the picture, not a strip that takes layout space, so the extra height
        // bought nothing but a black band above and below the video. Caught by
        // looking at `--selftest-viewer`'s screenshot; every number in that test
        // was green.
        return Content(
            view: editor, size: fitted(size), keyView: editor.playerView,
            onShown: { editor.play() })
    }

    private func imageContent(for url: URL) -> Content? {
        guard let image = NSImage(contentsOf: url), image.size.width >= 1,
              image.size.height >= 1
        else { return nil }

        // Recognition runs against `url`, not against `image`, so zoom cannot
        // affect it. `RedactionEditor` puts the same menu on all three of its
        // views for the reason its comment gives.
        let menu = NSMenu()
        menu.addItem(.action("Copy Text") { CopyText.run(fileAt: url) })

        // `NSImage.size` is in POINTS — the encoder stamps the DPI, so a 2× 5K
        // capture reports 2560×1440 here, not 5120×2880. That is the right unit
        // for a window: it makes "actual size" mean the size the thing was on
        // screen when it was taken.
        let size = fitted(image.size)
        guard let editor = RedactionEditor(
            url: url, image: image, menu: menu,
            frame: CGRect(origin: .zero, size: size))
        else { return nil }
        editor.onRedacted = { [weak self] thumbnail in
            self?.onImageRedacted?(url, thumbnail)
        }

        return Content(view: editor, size: size, onShown: { editor.zoomToFit() })
    }

    // MARK: - Geometry

    /// The largest window that shows the whole thing without covering the screen.
    ///
    /// A full-screen capture is by definition as big as the display it came from,
    /// so opening at natural size would produce a window that cannot fit —
    /// title bar off the top, and no way to see the bottom edge.
    private func fitted(_ size: CGSize) -> CGSize {
        guard let visible = NSScreen.main?.visibleFrame else { return size }
        let cap = CGSize(width: visible.width * 0.85, height: visible.height * 0.85)
        let ratio = min(cap.width / size.width, cap.height / size.height, 1)
        return CGSize(
            width: max(320, (size.width * ratio).rounded()),
            height: max(200, (size.height * ratio).rounded()))
    }

    /// Centres the window on the display the capture came from.
    ///
    /// Not `window.center()`, which uses the main screen: on a two-display
    /// machine that puts the picture of your second monitor on your first one.
    /// Cascaded slightly per open window so a second viewer does not land exactly
    /// on top of the first.
    private func place(_ window: NSWindow, onDisplay displayID: CGDirectDisplayID) {
        let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let offset = CGFloat(windows.count % 5) * 22
        var origin = CGPoint(
            x: visible.midX - window.frame.width / 2 + offset,
            y: visible.midY - window.frame.height / 2 - offset)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - window.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - window.frame.height)
        window.setFrameOrigin(origin)
    }

    private func bringToFront(_ window: NSWindow) {
        // Same reasoning as the Settings window: the app is LSUIElement, so it
        // does not come forward on its own, and a viewer the user cannot type
        // Escape into is not a viewer.
        if activatesOnShow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    // MARK: - Test hooks

    var openWindowCount: Int { windows.count }

    func windowForTest(_ url: URL) -> NSWindow? { windows[url] }

    /// The magnification a still's viewer is currently at, or nil for a video.
    func magnificationForTest(_ url: URL) -> CGFloat? {
        editorForTest(url)?.magnification
    }

    func editorForTest(_ url: URL) -> RedactionEditor? {
        windows[url]?.contentView as? RedactionEditor
    }

    func trimEditorForTest(_ url: URL) -> VideoTrimEditor? {
        windows[url]?.contentView as? VideoTrimEditor
    }
}

/// Carries the two keystrokes every window on this system closes with.
///
/// Both have to be handled here because DuoShot is `LSUIElement` and has **no
/// main menu at all**. A key equivalent that nothing in the window claims is
/// normally caught by the menu bar's Close item; with no menu there is nothing
/// behind it, so ⌘W simply did nothing. Escape had the same shape of problem in
/// a different place: the still viewer's scroll view answered `cancelOperation`,
/// so Escape worked there and silently did not work on a recording, whose first
/// responder is an `AVPlayerView`.
///
/// At the window rather than in either content view, so the answer cannot depend
/// on what is being shown.
private final class ViewerWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The content gets first refusal — AVPlayerView has its own equivalents,
        // and a viewer that swallowed them would be worse than one that cannot
        // be closed with the keyboard.
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return false }
        performClose(nil)
        return true
    }
}

/// A scroll view that knows how to frame the thing inside it.
///
/// Zoom-to-fit has to live here rather than at the call site because it is
/// needed again on every live resize: `NSScrollView` keeps the magnification it
/// was given, so a window dragged wider leaves the image at its old scale with
/// a growing margin around it, which reads as the window and the picture coming
/// apart.
///
/// Internal rather than private because `RedactionEditor` is what holds one now:
/// the still viewer's content view is the editor, and the scroll view is the
/// layer of it that owns zoom.
final class ZoomingScrollView: NSScrollView {
    /// The document's size in points, which is what "actual size" means.
    var naturalSize: CGSize = .zero

    /// True while the magnification is whatever it takes to fit, false once the
    /// user has zoomed. Only the fitting state follows a resize — chasing the
    /// window with a magnification the user chose by hand would be undoing their
    /// input.
    private var isFitting = true

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if isFitting { zoomToFit() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // During the live resize too, not only at the end: a window that only
        // catches up on mouse-up looks broken for the length of the drag.
        if isFitting { applyFitMagnification() }
    }

    func zoomToFit() {
        isFitting = true
        applyFitMagnification()
        guard let document = documentView else { return }
        // Centred, which is not what `NSScrollView` does on its own: it keeps the
        // scroll origin, so an image that was scrolled and then re-fitted sits
        // against whichever edge it was last pushed to.
        let visible = documentVisibleRect
        document.scroll(CGPoint(
            x: (document.frame.width - visible.width) / 2,
            y: (document.frame.height - visible.height) / 2))
    }

    private func applyFitMagnification() {
        guard naturalSize.width >= 1, naturalSize.height >= 1 else { return }
        let available = contentView.bounds.size
        guard available.width >= 1, available.height >= 1 else { return }
        // `contentView.bounds` is already in magnified units, so the ratio has to
        // be taken against the *frame* — using bounds here makes the fit depend
        // on the magnification it is trying to compute.
        let box = contentSize
        let ratio = min(box.width / naturalSize.width, box.height / naturalSize.height)
        magnification = min(max(ratio, minMagnification), maxMagnification)
    }

    /// Double-click toggles between fitting and actual size, zooming about the
    /// point that was clicked rather than the middle — when you double-click a
    /// detail you mean *that* detail, and re-centring would send it off screen at
    /// anything above a modest magnification.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        if isFitting {
            isFitting = false
            let point = documentView?.convert(event.locationInWindow, from: nil)
            setMagnification(1, centeredAt: point ?? .zero)
        } else {
            zoomToFit()
        }
    }

    /// A pinch or a smart-zoom means the user has taken over.
    override func magnify(with event: NSEvent) {
        isFitting = false
        super.magnify(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}
