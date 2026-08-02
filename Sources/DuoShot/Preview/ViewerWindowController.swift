import AppKit
import ImageIO

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
    private var imageLoads: [URL: Task<Void, Never>] = [:]

    /// Self-tests set this to false, for the reason `PreferencesWindowController`
    /// gives: `NSApp.activate` takes the keyboard away from whatever the person
    /// running the test is typing in.
    var activatesOnShow = true

    /// Called with a capture's URL and a fresh thumbnail once a redaction has
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
        switch entry.kind {
        case .video(let result):
            guard let content = videoContent(for: entry.url, pointSize: result.pointSize) else {
                failToOpen(entry.url)
                return
            }
            show(entry, content: content)
        case .image:
            guard imageLoads[entry.url] == nil else { return }
            let url = entry.url
            imageLoads[url] = Task { [weak self] in
                guard let self else { return }
                let loaded = await Self.loadImage(at: url)
                // Before the table is touched, not after. Cancellation comes
                // only from `closeAll`, which has already emptied it -- and may
                // since have been followed by a fresh open for this same URL.
                // Clearing the slot unconditionally would delete *that* task's
                // registration, and the next open would start a second
                // concurrent load of the same file.
                guard !Task.isCancelled else { return }
                self.imageLoads[url] = nil
                // `Data(contentsOf:)` does not observe cancellation, so a load
                // torn down mid-flight usually still succeeds. Beeping about it
                // is the teardown's noise, not the user's problem -- which is
                // why this sits after the check above rather than beside it.
                guard let loaded else {
                    self.failToOpen(url)
                    return
                }
                guard self.windows[url] == nil,
                      let content = self.imageContent(for: url, loaded: loaded)
                else { return }
                self.show(entry, content: content)
            }
        }
    }

    private func failToOpen(_ url: URL) {
        // Nothing to show usually means the file moved or was pruned out from
        // under the card. Falling back to the system opener would be a worse
        // failure than saying so: it would either bounce the Dock or open a
        // second app on an empty file.
        Log.app.error("""
            viewer: cannot read \(url.lastPathComponent, privacy: .public)
            """)
        NSSound.beep()
    }

    private func show(_ entry: PreviewEntry, content: Content) {
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
        //
        // `isOpaque = false` afterwards, and it is not optional: setting an
        // opaque `backgroundColor` sets the flag, and an opaque window is drawn
        // by the window server without the rounded-corner mask. On screen that is
        // a window with square corners, which is odd; in a *capture* of that
        // window it is worse, because a window shot carries the window's own
        // alpha — so DuoShot's own viewer came out square-cornered inside the
        // rounded card `ImagePadding` draws around it. The window still paints
        // the same colour; it just no longer claims every pixel of its frame.
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.isOpaque = false
        window.setContentSize(content.size)
        // Space plays and pauses a recording, and the arrow keys step it — but
        // only while AVPlayerView holds the keyboard, and it does not take it on
        // its own.
        window.initialFirstResponder = content.keyView ?? content.view
        if let editor = content.view as? ImageEditor {
            editor.onPictureResized = { [weak self, weak window] size in
                guard let self, let window else { return }
                resize(window, toPicture: size)
            }
        }
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
        for task in imageLoads.values { task.cancel() }
        imageLoads.removeAll()
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

    private struct LoadedImage: Sendable {
        let data: Data
        let image: CGImage
        let pointSize: CGSize
    }

    @concurrent
    private nonisolated static func loadImage(at url: URL) async -> sending LoadedImage? {
        guard !Task.isCancelled,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let rawDPIWidth = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let rawDPIHeight = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        let dpiWidth = rawDPIWidth.isFinite && rawDPIWidth > 0 ? rawDPIWidth : 72
        let dpiHeight = rawDPIHeight.isFinite && rawDPIHeight > 0 ? rawDPIHeight : 72
        let pointSize = CGSize(
            width: CGFloat(image.width) * 72 / max(CGFloat(dpiWidth), 1),
            height: CGFloat(image.height) * 72 / max(CGFloat(dpiHeight), 1))
        // The guard the failable `ImageEditor.init` used to carry. It has to
        // live somewhere: a DPI large enough to put the picture under a point
        // leaves every zoom-to-fit ratio in the editor dividing by ~0, and the
        // window that opens is worse than the beep that says the file is bad.
        guard pointSize.width >= 1, pointSize.height >= 1 else { return nil }
        return LoadedImage(data: data, image: image, pointSize: pointSize)
    }

    private func imageContent(for url: URL, loaded: LoadedImage) -> Content? {
        let image = NSImage(cgImage: loaded.image, size: loaded.pointSize)

        // Recognition runs against `url`, not against `image`, so zoom cannot
        // affect it. `ImageEditor` puts the same menu on all three of its
        // views for the reason its comment gives.
        let menu = NSMenu()
        menu.addItem(.action("Copy Text") { CopyText.run(fileAt: url) })

        // The picture's own size, clamped into a band.
        //
        // Two failures to avoid, and they pull opposite ways. Sizing the window
        // to the capture makes the editor a different shape every time it opens:
        // a tall phone screenshot is a narrow column, the next one is a
        // letterbox, and the tools are somewhere else in both. Sizing it to a
        // fixed frame instead leaves a modest capture floating in the middle of a
        // window twice its size, because the fit refuses to scale a screenshot
        // *up* — magnifying pixels to fill a frame is the one thing a screenshot
        // viewer must not do.
        //
        // So: a floor wide enough for the toolbar, a ceiling that keeps a
        // full-screen grab inside the display, and the capture's own size plus
        // its margin in between.
        //
        // `NSImage.size` is in POINTS — the encoder stamps the DPI, so a 2× 5K
        // capture reports 2560×1440 here rather than 5120×2880 — and it still
        // decides how far the picture is scaled to fit inside that frame.
        let picture = fitted(Self.band(around: image.size), reserving: ImageEditor.chromeHeight)
        let size = CGSize(
            width: picture.width, height: picture.height + ImageEditor.chromeHeight)
        let editor = ImageEditor(
            url: url, image: image, originalData: loaded.data, menu: menu,
            frame: CGRect(origin: .zero, size: size))
        // Added after the editor exists rather than beside "Copy Text", because
        // this one needs it. `NSMenu` is a reference type and `ImageEditor` only
        // holds it, so the item is in every one of the three views that share it.
        menu.addItem(.action("Redact Sensitive Text") { [weak editor] in
            editor?.redactSensitive()
        })

        return Content(view: editor, size: size, onShown: { editor.zoomToFit() })
    }

    // MARK: - Geometry

    /// The largest the picture area gets before the screen has its say. A shade
    /// wider than tall because most captures are, and large enough that a
    /// full-screen grab is still legible inside it.
    static let standardPicture = CGSize(width: 1080, height: 720)

    /// The smallest it gets. Wide enough for the toolbar to sit in with room
    /// either side of it, since a bar that touched both edges of its own window
    /// would look like a mistake, and tall enough that the picture is the thing
    /// in the window rather than the thing between two bands.
    static let minimumPicture = CGSize(width: 560, height: 420)

    /// The largest window that shows the whole thing without covering the screen.
    ///
    /// A full-screen capture is by definition as big as the display it came from,
    /// so opening at natural size would produce a window that cannot fit —
    /// title bar off the top, and no way to see the bottom edge.
    /// The picture's own size with its margin, clamped into the band.
    private static func band(around picture: CGSize) -> CGSize {
        let margin = ZoomingScrollView.fitPadding * 2
        return CGSize(
            width: min(max(picture.width + margin, minimumPicture.width),
                       standardPicture.width),
            height: min(max(picture.height + margin, minimumPicture.height),
                        standardPicture.height))
    }

    /// Re-sizes a viewer around a picture that has just changed size, which only
    /// a crop does.
    ///
    /// Same rule as opening, applied again: a window that keeps the shape of the
    /// picture it *used* to hold leaves the cropped one floating in the middle of
    /// a frame two sizes too big, which is the state this whole band of sizes
    /// exists to avoid.
    ///
    /// The top left stays put. Growing or shrinking about the centre moves the
    /// title bar out from under the pointer that just finished a drag, and every
    /// other window on this system resizes downward and to the right.
    private func resize(_ window: NSWindow, toPicture size: CGSize) {
        let picture = fitted(Self.band(around: size), reserving: ImageEditor.chromeHeight)
        let content = CGSize(
            width: picture.width, height: picture.height + ImageEditor.chromeHeight)
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: content))
        guard abs(frame.width - window.frame.width) > 1
            || abs(frame.height - window.frame.height) > 1 else { return }
        window.setFrame(
            CGRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                   width: frame.width, height: frame.height),
            display: true, animate: false)
    }

    /// `reserving` is height the window needs for something that is not the
    /// picture, and comes off the screen's allowance before the ratio is taken.
    private func fitted(_ size: CGSize, reserving chrome: CGFloat = 0) -> CGSize {
        guard let visible = NSScreen.main?.visibleFrame else { return size }
        let cap = CGSize(
            width: visible.width * 0.85,
            height: max(120, visible.height * 0.85 - chrome))
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

    func editorForTest(_ url: URL) -> ImageEditor? {
        windows[url]?.contentView as? ImageEditor
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

/// The clip view that keeps a small picture in the middle.
///
/// `NSScrollView` pins its document to the bottom left when the document is
/// smaller than the clip — the scroll origin has nowhere to go, so it stays at
/// zero — which puts a fitted screenshot in the corner of its own viewer with all
/// the empty space on two sides. Constraining the proposed bounds is the only
/// hook that catches every way the origin can change: zooming, resizing, fitting,
/// and the scroll that follows each of them.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width {
            rect.origin.x = ((frame.width - rect.width) / 2).rounded()
        }
        if rect.height > frame.height {
            rect.origin.y = ((frame.height - rect.height) / 2).rounded()
        }
        return rect
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
/// Internal rather than private because `ImageEditor` is what holds one now:
/// the still viewer's content view is the editor, and the scroll view is the
/// layer of it that owns zoom.
final class ZoomingScrollView: NSScrollView {
    /// The document's size in points, which is what "actual size" means.
    var naturalSize: CGSize = .zero

    /// The gap left around the picture when it is fitted, so it reads as a thing
    /// on a surface rather than as the window's own contents. Only the fit uses
    /// it: zooming in is for looking at pixels and a margin there would be a
    /// margin taken out of them.
    ///
    /// Small on purpose. This is the breathing room around a picture, not a
    /// border — and `ViewerWindowController` sizes the window from the same
    /// number, so anything generous here is doubled into empty window.
    static let fitPadding: CGFloat = 10
    var padding: CGFloat = ZoomingScrollView.fitPadding

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
        // Never above 1: the window is a fixed frame now and a small capture
        // sits in the middle of it, so without this a 320-point window shot
        // would be blown up to fill the viewer and shown blurrier than it is.
        // Fitting means "no larger than it really is", not "as large as the
        // space allows".
        let ratio = min(
            max(box.width - padding * 2, 1) / naturalSize.width,
            max(box.height - padding * 2, 1) / naturalSize.height,
            1)
        magnification = min(max(Self.snapped(ratio), minMagnification), maxMagnification)
    }

    /// The largest 1/n at or below `ratio` — 1, ½, ⅓, ¼ …
    ///
    /// A picture shown at 0.62 has every one of its pixels resampled into a
    /// fraction of a screen pixel: fine for a photograph, visibly wrong for a
    /// screenshot, whose whole content is one-pixel lines and hinted text. At
    /// 1/n each screen pixel is a clean average of exactly n² image pixels, and
    /// glyph edges land where they were drawn.
    ///
    /// It matters most for the thing that is *not* in the picture: text being
    /// typed is drawn live at screen resolution while the same words already
    /// committed are image pixels being resampled. At a fraction like 0.62 the
    /// two land on different subpixel phases and the committed line reads as
    /// very slightly tighter — measured on a report of exactly that, one pixel
    /// per glyph, about one per cent over a line. At 1/n they agree.
    ///
    /// The cost is honest: a picture that would have fitted at 0.62 is shown at
    /// 0.5 instead. A capture is worth more sharp and smaller than fuzzy and
    /// larger.
    static func snapped(_ ratio: CGFloat) -> CGFloat {
        guard ratio > 0, ratio < 1 else { return min(ratio, 1) }
        let steps = (1 / ratio).rounded(.up)
        let clean = 1 / max(1, steps)
        // Only when it is nearly free. Snapping 0.9 down to 0.5 would halve the
        // picture to sharpen it, which is not a trade anyone asked for; snapping
        // 0.55 down to 0.5 costs nine per cent and buys a screenshot whose
        // one-pixel lines are still one pixel.
        return ratio / clean <= 1.15 ? clean : ratio
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
