import AppKit

/// The still viewer's contents: the picture, and everything you are allowed to
/// do to it before it leaves.
///
/// Editing lives in the viewer rather than on the preview card because it is the
/// only place the capture is shown large enough to point at. The card is a
/// 208-point tile — a rectangle drawn on it would be four points wide where it
/// mattered — and the overlay is long gone by the time anyone has read what they
/// just took a picture of.
///
/// Three rules shape the whole thing:
///
/// 1. **The capture is never modified.** Editing produces a copy: Copy puts the
///    edited picture on the clipboard and writes it beside the original as
///    "name (edited).png". Nothing this window does can damage the file it
///    opened, which is what makes an accidental redaction cost nothing.
/// 2. **The edits are a list and ⌘Z walks it.** There is no Apply and no Cancel
///    — there is nothing to confirm when nothing is being overwritten, and undo
///    is a better Cancel than Cancel was.
/// 3. **What is on screen is what comes out.** The picture shown is
///    `ImageEdit.render` of the list, and Copy exports the same call. The mosaic
///    being looked at is the mosaic the recipient gets.
///
/// The trade this makes is in `ImageEdit.export`, and it is worth knowing about:
/// the original keeps its pixels and stays where the preview card, the share
/// button and the drag-out all still point.
///
/// The tools are always there and none of them is armed — the bar is a fixture
/// across the top and the viewer opens holding the pointer, so a click still
/// zooms and a drag still scrolls until a tool is picked; Escape puts the
/// pointer back.
@MainActor
final class ImageEditor: NSView {
    /// What a click or a drag on the picture means. One at a time, chosen in the
    /// toolbar, because they are all gestures over the same pixels and a
    /// modifier-key scheme would be invisible rules instead of buttons.
    ///
    /// `pointer` is what makes a toolbar that is always on screen possible: the
    /// bar is a permanent fixture now, so there has to be a way for a click to
    /// mean what it meant before there was one — zoom, scroll, drag. It is the
    /// tool the viewer opens in, and the one Escape goes back to.
    enum Tool: CaseIterable {
        case pointer
        case redact
        case marker
        case text
        case crop

        var draws: Bool { self != .pointer }
    }

    /// The staged file, which is both what is being shown and what will be
    /// overwritten. Every consumer of this capture reads this URL.
    private let url: URL
    /// The image's size in pixels, which is not its size in points: a 2× capture
    /// carries a DPI tag and `NSImage.size` honours it. This is what the drawn
    /// edits are scaled into, because they are applied to the bitmap and the
    /// bitmap has no idea what a point is.
    private var pixelSize: CGSize
    /// The canvas's coordinate space, and the space every `ImageEdit` is in.
    private var pointSize: CGSize
    /// The capture's own bytes, read once when the window opened. Every preview
    /// and every export is flattened from these, so the list is the only state
    /// there is and nothing accumulates.
    private let originalData: Data
    /// The point size of those bytes. The canvas's size follows the crop; this
    /// one never changes, and every `ImageEdit` is in its coordinates.
    private let originalPointSize: CGSize

    private let scrollView: ZoomingScrollView
    private let imageView: NSImageView
    private let canvas: EditCanvas
    private let bar: EditToolbar
    /// The one thing that leaves this window: the strip under the picture, with
    /// Copy in it. Below rather than beside the tools because it is not one of
    /// them — the tools change the picture, this one takes it away.
    private let footer: EditFooter
    private let notice: ViewerNotice

    /// True while an export is in flight, so a second press cannot race it.
    private var isExporting = false
    private var renderTask: Task<Void, Never>?
    private var stack = EditList()
    private var tool: Tool = .pointer
    /// Bumped on every re-render so a slow one cannot land on top of a newer one:
    /// an undo races the render it is undoing, and losing that race would leave
    /// the picture showing an edit the list no longer has.
    private var renderGeneration = 0

    init?(url: URL, image: NSImage, menu: NSMenu, frame: CGRect) {
        guard image.size.width >= 1, image.size.height >= 1,
              // Read once, here, rather than per write: this is the capture as it
              // was before anything in this window touched it, and after the first
              // write the file is no longer a copy of it.
              let data = try? Data(contentsOf: url)
        else { return nil }
        self.url = url
        self.originalData = data
        self.originalPointSize = image.size
        self.pointSize = image.size
        // `representations` rather than a second decode: the image was just read
        // from this file and the rep carries the real pixel counts. Falling back
        // to the point size means an edit on an image with no rep at all is
        // still applied in the right place, at 1×.
        let rep = image.representations.first
        self.pixelSize = CGSize(
            width: rep.map { CGFloat($0.pixelsWide) }.flatMap { $0 >= 1 ? $0 : nil }
                ?? image.size.width,
            height: rep.map { CGFloat($0.pixelsHigh) }.flatMap { $0 >= 1 ? $0 : nil }
                ?? image.size.height)

        let bounds = CGRect(origin: .zero, size: image.size)
        imageView = NSImageView(frame: bounds)
        canvas = EditCanvas(frame: bounds)
        scrollView = ZoomingScrollView(frame: CGRect(origin: .zero, size: frame.size))
        bar = EditToolbar()
        footer = EditFooter()
        notice = ViewerNotice()
        super.init(frame: frame)

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        imageView.autoresizingMask = [.width, .height]
        // Underneath everything the canvas draws, and explicitly so: the canvas
        // builds its marks layer in its own initialiser, so an ordinary
        // `addSubview` here would put the picture on top of the crop's dimmed
        // margin and the rectangle being dragged, and neither would ever be seen.
        canvas.addSubview(imageView, positioned: .below, relativeTo: nil)

        // On all four, and on purpose. The image view is the hit view over the
        // picture itself, the canvas over it while editing, the scroll view over
        // the letterboxing around both, and this view is the window's content
        // view; a right-click that works on one but not the others reads as the
        // menu being broken rather than as a boundary anyone can see.
        imageView.menu = menu
        canvas.menu = menu
        scrollView.menu = menu
        self.menu = menu

        scrollView.contentView = CenteringClipView(frame: scrollView.bounds)
        scrollView.documentView = canvas
        scrollView.naturalSize = image.size
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        // 0.05 rather than something tidier so a full-screen capture can still be
        // zoomed *out* to fit inside a small window; the ceiling is where a
        // screenshot's own pixels turn into visible squares, which is the point
        // of zooming into one.
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        canvas.onEdit = { [weak self] edit in self?.add(edit) }
        canvas.markerCount = { [weak self] in
            self?.stack.edits.count { if case .marker = $0 { true } else { false } } ?? 0
        }
        canvas.onFocusReturn = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        bar.onTool = { [weak self] tool in self?.choose(tool) }
        bar.onUndo = { [weak self] in self?.undo() }
        footer.onCopy = { [weak self] in self?.copyOut() }

        addSubview(bar)
        addSubview(footer)
        addSubview(notice)
        notice.isHidden = true
        refreshBar()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    private static let barInset: CGFloat = 12
    private static let noticeGap: CGFloat = 8

    /// One band: a bar and the space around it.
    private static let bandHeight: CGFloat = barInset * 2 + HUDMetrics.height

    /// The height of both bands together — the tools above the picture and Copy
    /// below it.
    ///
    /// Public because the window has to be built this much taller than the
    /// picture it is opening — see `ViewerWindowController.imageContent`. Bands
    /// that took their height out of the picture's would mean opening a capture
    /// at less than actual size for the sake of a toolbar, which is the thing a
    /// toolbar is least entitled to. It is `layout`'s number as well, so the two
    /// cannot drift: they did, once, and every viewer window opened a band short
    /// with the picture squeezed into what was left.
    ///
    /// The file's name is in neither. It is in the window's title bar, where
    /// every other document on this system keeps it, and a second copy of it two
    /// centimetres below was one label too many.
    static let chromeHeight: CGFloat = bandHeight * 2

    /// Two bands, top to bottom: the tools, and the picture.
    ///
    /// The bar was a floating strip over the image and is now a fixture above it.
    /// Overlaying was fine while it appeared only on demand; a permanent bar over
    /// the picture is a permanent hole in the picture, and the top of a
    /// screenshot is where its title bar, its tabs and its address bar are — the
    /// part most worth reading and most often the reason for the capture.
    ///
    /// Nothing here depends on the state of anything: the bar's size is a
    /// constant and so is this header, so the picture never moves except when the
    /// window does.
    override func layout() {
        super.layout()
        let band = Self.bandHeight
        scrollView.frame = CGRect(
            x: 0, y: band, width: bounds.width, height: max(0, bounds.height - band * 2))

        let barSize = bar.fittingSize
        bar.frame = CGRect(
            x: ((bounds.width - barSize.width) / 2).rounded(),
            y: bounds.height - Self.barInset - barSize.height,
            width: barSize.width, height: barSize.height)
        let footerSize = footer.fittingSize
        footer.frame = CGRect(
            x: ((bounds.width - footerSize.width) / 2).rounded(), y: Self.barInset,
            width: footerSize.width, height: footerSize.height)

        guard !notice.isHidden else { return }
        // Capped to the window so a long sentence in a narrow viewer wraps
        // instead of hanging off both sides of it. It hangs into the picture
        // rather than pushing it down: a sentence that appears after a copy must
        // not resize what has just been copied.
        let noticeSize = notice.fittingSize(inWidth: bounds.width - Self.barInset * 2)
        notice.frame = CGRect(
            x: ((bounds.width - noticeSize.width) / 2).rounded(),
            y: scrollView.frame.minY + Self.noticeGap,
            width: noticeSize.width, height: noticeSize.height)
    }

    /// The bands above and below the picture, in the same grey the scroll view
    /// puts behind it — one shade, so the chrome reads as the window's edge
    /// rather than as a second surface.
    ///
    /// Drawn rather than filled with `layer.backgroundColor`, and that is the
    /// whole point: an opaque layer on the content view paints into the corners
    /// of the window and squares off the rounding AppKit masks the frame with.
    /// It shows up as a window whose corners are sharp — and then as a *capture*
    /// of that window with sharp corners, since a window shot carries the
    /// window's own alpha. `draw` is clipped by that mask; a layer is not.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        dirtyRect.fill()
    }

    /// What the still viewer opens at, and what the window's Escape handler and
    /// the self-tests reach for.
    func zoomToFit() { scrollView.zoomToFit() }

    var magnification: CGFloat { scrollView.magnification }

    // MARK: - The mode

    private var isEditing: Bool { tool.draws }

    /// Puts the pointer back. Answers whether there was a tool to put down,
    /// because Escape means "close the window" when there is not — see
    /// `ViewerWindow.cancelOperation`.
    @discardableResult
    func disarm() -> Bool {
        guard tool.draws else { return false }
        choose(.pointer)
        return true
    }

    private func choose(_ tool: Tool) {
        self.tool = tool
        canvas.tool = tool
        canvas.isActive = tool.draws
        if tool.draws { window?.makeFirstResponder(self) }
        refreshBar()
    }

    /// Takes a gesture in the canvas's coordinates and stores it in the
    /// original's.
    ///
    /// A crop takes effect immediately, so after one the canvas is the cropped
    /// picture and its origin is somewhere inside the capture. Everything in the
    /// list has to stay in one space — the original's — because that is the image
    /// every write is flattened onto, and because undoing the crop must leave the
    /// marks where they were drawn rather than shifted by the crop that no longer
    /// exists.
    private func add(_ edit: ImageEdit) {
        let offset = stack.crop?.origin ?? .zero
        stack.push(edit.moved(by: offset))
        scheduleRender()
        refreshBar()
    }

    private func undo() {
        guard stack.undo() else { return }
        scheduleRender()
        refreshBar()
    }

    private func redo() {
        guard stack.redo() else { return }
        scheduleRender()
        refreshBar()
    }

    private func refreshBar() {
        bar.setState(
            tool: tool, canUndo: stack.canUndo, canRedo: stack.canRedo, isBusy: isExporting)
        footer.setState(hasEdits: !stack.isEmpty, isBusy: isExporting)
        needsLayout = true
    }

    // MARK: - The preview

    /// Redraws the picture from the capture's bytes and the list.
    ///
    /// Nothing is written here. This is the whole of what an edit does until
    /// Copy is pressed, which is why an accidental redaction costs nothing: the
    /// file on disk has not been touched, and ⌘Z has nothing to repair.
    ///
    /// Cropping is applied, so a crop takes effect the moment the drag stops
    /// rather than showing a dimmed margin until something is confirmed.
    ///
    /// Debounced, because a marker dropped five times in two seconds is five
    /// renders of a 5K bitmap and only the last one is worth doing.
    private static let renderDelay = Duration.milliseconds(120)

    private func scheduleRender() {
        canvas.crop = nil
        renderTask?.cancel()
        let edits = stack.edits
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.renderDelay)
            guard !Task.isCancelled else { return }
            await self?.rerender(edits)
        }
    }

    private func rerender(_ edits: [ImageEdit]) async {
        renderGeneration += 1
        let token = renderGeneration
        let result = await Self.preview(
            edits, of: originalData, pointSize: originalPointSize)
        guard token == renderGeneration, let result else {
            canvas.clearPending()
            return
        }
        adopt(result.image, pointSize: result.pointSize)
    }

    @concurrent
    private nonisolated static func preview(
        _ edits: [ImageEdit], of original: Data, pointSize: CGSize
    ) async -> sending (image: CGImage, pointSize: CGSize)? {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        guard !edits.isEmpty else { return (image, pointSize) }
        guard let rendered = ImageEdit.render(
            image, edits: edits, pointSize: pointSize, cropping: true) else { return nil }
        // A crop is the one edit that changes what "the picture" is, so the point
        // size has to follow it or the window would show the smaller bitmap
        // stretched back over the old one's frame.
        let size = edits.compactMap(\.cropRect).last.map(\.size) ?? pointSize
        return (rendered, size)
    }

    private func adopt(_ image: CGImage, pointSize size: CGSize) {
        let resized = size != pointSize
        // The *point* size, not the pixel size: the capture's DPI is what makes a
        // 2× picture the size it was on screen rather than twice that.
        imageView.image = NSImage(cgImage: image, size: size)
        pointSize = size
        pixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        canvas.clearPending()
        if resized {
            // A crop takes effect the moment the drag ends, so the canvas is a
            // different size now and everything drawn on it from here is in the
            // new picture's coordinates — see `add`, which puts them back into
            // the original's before they reach the list.
            let box = CGRect(origin: .zero, size: size)
            canvas.frame = box
            imageView.frame = box
            scrollView.naturalSize = size
            zoomToFit()
        }
        refreshBar()
    }

    // MARK: - Copying out

    /// The only thing that leaves this window.
    ///
    /// Both halves at once, and on purpose: the clipboard is what the edit was
    /// made for, and the file beside the original is what makes it survive the
    /// next copy. Doing only the first would mean an edit that exists until
    /// something else is copied, which is a good way to lose ten minutes of
    /// annotation to a stray ⌘C.
    private func copyOut() {
        guard !isExporting else { return }
        isExporting = true
        refreshBar()

        let edits = stack.edits
        let destination = ImageEdit.exportURL(besides: url)
        Task { [originalData, originalPointSize, weak self] in
            defer {
                self?.isExporting = false
                self?.refreshBar()
            }
            do {
                let size = try await Self.exportAndCopy(
                    edits, of: originalData, pointSize: originalPointSize, to: destination)
                self?.announce(destination, pointSize: size)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The edited picture could not be written."
                Log.app.error("copy out: \(reason, privacy: .public)")
                NSSound.beep()
                self?.notice.show(message: reason, action: nil)
                self?.showNotice()
            }
        }
    }

    /// Writes the file off the main actor and returns only its point size, so no
    /// bitmap has to cross back.
    @concurrent
    private nonisolated static func exportAndCopy(
        _ edits: [ImageEdit], of original: Data, pointSize: CGSize, to url: URL
    ) async throws -> CGSize {
        _ = try await ImageEdit.export(edits, of: original, pointSize: pointSize, to: url)
        return edits.compactMap(\.cropRect).last.map(\.size) ?? pointSize
    }

    private func announce(_ file: URL, pointSize size: CGSize) {
        // The clipboard is written from the file rather than from the bitmap: it
        // is what `Clipboard.write(fileAt:pointSize:)` already does for the
        // capture path, and it puts the file's URL on the pasteboard too, so a
        // paste into Finder or Mail attaches the edited picture rather than
        // nothing.
        Clipboard.write(fileAt: file, pointSize: size)
        notice.show(
            message: "Copied. Saved as \(file.lastPathComponent) — the capture itself "
                + "is untouched.",
            action: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([file]) }),
            symbol: "folder")
        showNotice()
    }

    private func showNotice() {
        notice.isHidden = false
        needsLayout = true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// ⌘Z and ⇧⌘Z, which nothing else in this app can provide.
    ///
    /// DuoShot is `LSUIElement` and has **no main menu at all**, so there is no
    /// Edit menu behind these and no `undo:` for the responder chain to find —
    /// the same problem `ViewerWindow` solves for ⌘W. Claimed after `super`
    /// rather than before it so the text field being typed into keeps its own
    /// undo, which is a different thing being undone.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !canvas.isTyping,
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else { return false }
        switch flags {
        case [.command]: undo()
        case [.command, .shift]: redo()
        default: return false
        }
        return true
    }

    /// One letter per tool, in the order they sit in the bar. The only way to
    /// change tool without taking the pointer off the thing being annotated.
    ///
    /// Not gated on a tool already being armed — that gate is what would make
    /// the letters unreachable from the state the viewer opens in, which is the
    /// state they exist to get you out of.
    override func keyDown(with event: NSEvent) {
        guard !canvas.isTyping,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case "v": choose(.pointer)
        case "r": choose(.redact)
        case "n": choose(.marker)
        case "t": choose(.text)
        case "c": choose(.crop)
        default: super.keyDown(with: event)
        }
    }

    /// Escape unwinds one layer at a time: the text being typed, then the tool,
    /// then the window. Handled here rather than in `ViewerWindow` so neither of
    /// the first two has to be visible from the window.
    ///
    /// It never throws edits away. Escape is the key people press to get out of
    /// something, and a list of edits is not something to lose to a reflex —
    /// that is Cancel's job, which says what it does.
    override func cancelOperation(_ sender: Any?) {
        if canvas.cancelTyping() { return }
        guard !disarm() else { return }
        window?.performClose(nil)
    }

    // MARK: - Test hooks

    /// Adds an edit in the canvas's own coordinates — image points, origin
    /// bottom left — the way a completed gesture would.
    func addEditForTest(_ edit: ImageEdit) {
        add(edit)
    }

    /// Where a tool's button is, in this view's coordinates, so a test can press
    /// the real one rather than a point the bar happens to occupy today.
    func pillFrameForTest(_ tool: Tool) -> CGRect? {
        bar.pillFrame(for: tool).map { convert($0, from: bar) }
    }

    func undoForTest() { undo() }
    func redoForTest() { redo() }

    /// Skips the debounce and waits for the picture to catch up with the list.
    func flushForTest() async {
        renderTask?.cancel()
        await rerender(stack.edits)
    }

    /// Presses Copy and waits for the file and the clipboard.
    func copyForTest() async {
        copyOut()
        while isExporting { await Task.yield() }
    }

    /// What `--selftest-redact` measures: the point-to-pixel conversion, which is
    /// the one piece of this that a 2× capture can silently get wrong.
    var pixelRegionsForTest: [CGRect] {
        ImageEdit.regions(
            stack.edits.compactMap { if case .redact(let rect) = $0 { rect } else { nil } },
            atPointSize: pointSize, inPixels: pixelSize)
    }

    var editsForTest: [ImageEdit] { stack.edits }

    /// Where the open field's baseline is meant to land, which is not the point
    /// that was clicked — see `beginTyping`.
    var typingAnchorForTest: CGPoint { canvas.typingAnchorForTest }
    var pixelSizeForTest: CGSize { pixelSize }
    var pointSizeForTest: CGSize { pointSize }
    var toolForTest: Tool { tool }

    /// The two the toolbar's own test needs: where to click, and whether the
    /// click arrived. Nothing else can see the mode from outside, which is how an
    /// Edit button that did nothing at all once passed every other check here.
    var barFrameForTest: CGRect { bar.frame }

    /// Where the picture actually is, which is the half of the layout the bar's
    /// own frame cannot answer.
    var pictureFrameForTest: CGRect { scrollView.frame }


    var isEditingForTest: Bool { isEditing }

    func chooseForTest(_ tool: Tool) { choose(tool) }
}

/// The scroll view's document: the picture, plus whatever is being drawn on it
/// right now.
///
/// Everything already committed is in the bitmap the image view is showing —
/// `ImageEdit.render` put it there — so this draws only the gesture in progress
/// and the crop's dimmed margin. That is the point of rendering the preview
/// through the same function as the output: there is no second drawing of a
/// redaction here to disagree with the real one.
///
/// Invisible to event routing unless an edit is in progress. That is what keeps
/// the viewer's existing behaviour intact — `hitTest` answering nil sends every
/// click, drag and scroll straight through to the scroll view, which is where
/// double-click-to-zoom and pinch-to-magnify already live.
private final class EditCanvas: NSView, NSTextFieldDelegate {
    var isActive = false {
        didSet {
            marks.isHidden = !isActive
            marks.needsDisplay = true
            if !isActive { cancelTyping() }
            window?.invalidateCursorRects(for: self)
        }
    }

    var tool: ImageEditor.Tool = .pointer {
        didSet {
            guard tool != oldValue else { return }
            cancelTyping()
            draft = nil
            showCropFrame()
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The crop in force, from the list.
    var crop: CGRect? {
        didSet { showCropFrame() }
    }

    /// The frame while it is being dragged, which is not an edit yet: a corner
    /// dragged across the picture would otherwise push a hundred entries onto the
    /// undo stack, and ⌘Z would take a hundred presses to get back.
    private var draft: CGRect?

    /// The crop frame is the crop tool's own affordance and disappears with it.
    /// With no crop made yet it is the whole picture, so the first thing the tool
    /// offers is four corners to pull in rather than a blank canvas to guess at.
    private func showCropFrame() {
        let frame = tool == .crop ? (draft ?? crop ?? bounds) : nil
        marks.crop = frame
        // Nothing is being thrown away while the frame is still the whole
        // picture, and dimming a margin of zero width just darkens the edges for
        // no reason.
        marks.dimsOutsideCrop = frame.map { $0.insetBy(dx: -1, dy: -1) != bounds } ?? false
        marks.needsDisplay = true
    }

    /// Where a finished gesture goes. The editor turns it into an entry in the
    /// list; this view never holds one.
    var onEdit: (ImageEdit) -> Void = { _ in }
    /// How many markers are already down, so the one being placed can be drawn
    /// with the number it is about to be given.
    var markerCount: () -> Int = { 0 }
    /// Called when the text field goes away, so the keyboard goes back to the
    /// editor rather than to whichever of the scroll view's parts happens to be
    /// next in the chain — the tool letters are the editor's.
    var onFocusReturn: () -> Void = {}

    /// Below the smallest rectangle worth having. A click with a pixel of travel
    /// is a click, and a one-point redaction would be an invisible mark on the
    /// file that nobody could see they had made.
    private static let minimumSide: CGFloat = 4

    private var anchor: CGPoint?
    private let marks = EditMarks()
    private var field: NSTextField?
    /// Where the pointer was when the field opened, which is where the baseline
    /// of the finished text goes. Kept rather than read back off the field: the
    /// field grows as it is typed into, and its frame is not the anchor.
    private var typingAnchor: CGPoint = .zero

    /// What a crop drag is doing to the frame: pulling one corner, sliding the
    /// whole thing, or drawing a new one where there was nothing.
    private enum CropGrab {
        case corner(atMinX: Bool, atMinY: Bool)
        case move(from: CGPoint, origin: CGPoint)
        case fresh
    }

    private var cropGrab: CropGrab?

    /// How close to a corner counts as grabbing it. In image points, so it grows
    /// and shrinks with the zoom the way the corner mark itself does.
    private static let cornerGrab: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        marks.frame = bounds
        marks.autoresizingMask = [.width, .height]
        marks.isHidden = true
        addSubview(marks)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive else { return nil }
        // The text field is a real control and has to keep receiving clicks:
        // selecting what has been typed is the one interaction inside this view
        // that is not a gesture on the picture.
        if let field, let inside = field.hitTest(convert(point, from: superview)) {
            return inside
        }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard isActive else { return }
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    /// Cleared by the editor once the re-render has landed, so a committed mark
    /// does not blink out of existence for the length of a decode.
    func clearPending() {
        marks.pending = nil
        marks.pendingMarker = nil
        marks.needsDisplay = true
    }

    // MARK: - Gestures

    override func mouseDown(with event: NSEvent) {
        guard isActive else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pointer:
            // Unreachable while `isActive` tracks `tool.draws`, and handled
            // rather than asserted: the view stays out of the way when the
            // pointer is the tool, and passing the click on is what "out of the
            // way" means.
            super.mouseDown(with: event)
        case .redact:
            anchor = point
            marks.pending = nil
        case .crop:
            beginCrop(at: point)
        case .marker:
            marks.pendingMarker = (point, markerCount() + 1)
            onEdit(.marker(point))
        case .text:
            beginTyping(at: point)
        }
        marks.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if cropGrab != nil {
            dragCrop(to: point)
            return
        }
        guard let anchor else {
            super.mouseDragged(with: event)
            return
        }
        marks.pending = rect(from: anchor, to: point)
        marks.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cropGrab != nil {
            endCrop()
            return
        }
        guard let anchor else {
            super.mouseUp(with: event)
            return
        }
        self.anchor = nil
        let drawn = rect(from: anchor, to: convert(event.locationInWindow, from: nil))
        guard drawn.width >= Self.minimumSide, drawn.height >= Self.minimumSide else {
            marks.pending = nil
            marks.needsDisplay = true
            return
        }
        // Left on screen until the render lands, because a redaction that
        // disappears for a decode and comes back as a mosaic reads as a bug.
        marks.pending = drawn
        marks.needsDisplay = true
        onEdit(.redact(drawn))
    }

    /// Clamped to the image, because a drag that leaves the window is the normal
    /// way to redact something touching an edge and a rectangle hanging off the
    /// side would be silently trimmed later anyway.
    private func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
            .intersection(bounds)
    }

    // MARK: - The crop frame

    /// A crop is adjusted, not re-drawn.
    ///
    /// Dragging a fresh rectangle every time is how the first version worked, and
    /// it makes "a bit more off the left" into "draw the whole thing again, and
    /// hope the other three edges land where they were". The frame starts as the
    /// whole picture and every corner stays draggable afterwards, which is what
    /// makes trimming one side a gesture instead of a redo.
    private func beginCrop(at point: CGPoint) {
        let frame = draft ?? crop ?? bounds
        let grab = Self.cornerGrab
        let nearMinX = abs(point.x - frame.minX) <= grab
        let nearMaxX = abs(point.x - frame.maxX) <= grab
        let nearMinY = abs(point.y - frame.minY) <= grab
        let nearMaxY = abs(point.y - frame.maxY) <= grab

        draft = frame
        if (nearMinX || nearMaxX) && (nearMinY || nearMaxY) {
            cropGrab = .corner(atMinX: nearMinX, atMinY: nearMinY)
        } else if frame.contains(point) {
            cropGrab = .move(from: point, origin: frame.origin)
        } else {
            // Outside the frame entirely: that is a new one, drawn from here.
            cropGrab = .fresh
            anchorForFreshCrop = point
            draft = CGRect(origin: point, size: .zero)
        }
        showCropFrame()
    }

    private var anchorForFreshCrop: CGPoint = .zero

    private func dragCrop(to point: CGPoint) {
        guard let grab = cropGrab, let frame = draft else { return }
        switch grab {
        case .corner(let atMinX, let atMinY):
            let fixed = CGPoint(x: atMinX ? frame.maxX : frame.minX,
                                y: atMinY ? frame.maxY : frame.minY)
            draft = rect(from: fixed, to: point)
        case .move(let from, let origin):
            // Slid, and stopped at the edges rather than clipped by them: a frame
            // that shrank when it hit the side of the picture would be a resize
            // nobody asked for.
            let moved = CGRect(
                origin: CGPoint(x: origin.x + point.x - from.x,
                                y: origin.y + point.y - from.y),
                size: frame.size)
            draft = CGRect(
                x: min(max(moved.minX, 0), max(0, bounds.width - moved.width)),
                y: min(max(moved.minY, 0), max(0, bounds.height - moved.height)),
                width: moved.width, height: moved.height)
        case .fresh:
            draft = rect(from: anchorForFreshCrop, to: point)
        }
        showCropFrame()
    }

    private func endCrop() {
        cropGrab = nil
        guard let frame = draft else { return }
        guard frame.width >= Self.minimumSide, frame.height >= Self.minimumSide,
              frame.insetBy(dx: -1, dy: -1) != bounds
        else {
            // Back to whatever the list says. A tap on the picture with the crop
            // tool is not a crop of nothing.
            draft = nil
            showCropFrame()
            return
        }
        draft = nil
        onEdit(.crop(frame))
    }

    // MARK: - Typing

    var isTyping: Bool { field != nil }

    var typingAnchorForTest: CGPoint { typingAnchor }

    /// The field is a real `NSTextField` sitting in the document view, so it is
    /// magnified along with the picture and what is typed is the size it will be
    /// — the font and the padding come from `ImageEdit`, shared with the renderer
    /// for exactly that reason.
    private func beginTyping(at point: CGPoint) {
        commitTyping()
        let font = NSFont.boldSystemFont(ofSize: ImageEdit.textSize)
        let metrics = TextFieldInk.metrics(for: font)
        let box = NSTextField(frame: CGRect(
            x: 0, y: 0, width: 150, height: metrics.height))
        // The click lands in the middle of the line, not on its baseline.
        //
        // The baseline is what the model stores and what the renderer draws
        // from, and anchoring the click straight onto it is the arithmetically
        // tidy thing — but a line of text sits *on* its baseline, so the whole
        // line, and the caret with it, appears above the pointer. Half a cap
        // height down puts the click through the middle of the letters, which is
        // where a pointer feels like it is.
        typingAnchor = CGPoint(x: point.x, y: point.y - font.capHeight / 2)
        box.font = font
        box.textColor = NSColor(cgColor: ImageEdit.inkColor) ?? .systemRed
        // No plate behind it. A white box is the size of the *field* rather than
        // of the words, so before anything is typed it is a large grey slab
        // sitting on the picture — and it makes the moment of committing look
        // like a change of style rather than the same text staying put. The
        // dashed frame in `EditMarks` is what says where the typing is going.
        box.backgroundColor = .clear
        box.drawsBackground = false
        box.isBordered = false
        box.isBezeled = false
        box.focusRingType = .none
        box.delegate = self
        // Small and grey, against the annotation's own 20-point bold: a
        // placeholder set in the text's font is a line of shouting grey letters
        // the size of the thing you are about to write, and it reads as content.
        box.placeholderAttributedString = NSAttributedString(
            string: "Type, then ⏎",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor(white: 0.75, alpha: 0.9),
            ])
        // Placed by where the field actually puts ink, not by where its metrics
        // suggest it might. `TextFieldInk` draws a probe glyph and looks — see
        // the comment there for why every arithmetic version of this was wrong.
        box.setFrameOrigin(CGPoint(
            x: typingAnchor.x - metrics.inkLeft,
            y: typingAnchor.y - metrics.baselineFromBottom))
        addSubview(box)
        field = box
        window?.makeFirstResponder(box)
        marks.typing = box.frame
        marks.needsDisplay = true
    }

    /// Pushes what has been typed into the list, if anything has been.
    private func commitTyping() {
        guard let box = field else { return }
        field = nil
        marks.typing = nil
        marks.needsDisplay = true
        let string = box.stringValue
        box.removeFromSuperview()
        onFocusReturn()
        guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onEdit(.text(typingAnchor, string))
    }

    /// Answers whether there was any typing to cancel, because Escape means
    /// something else entirely when there is not.
    @discardableResult
    func cancelTyping() -> Bool {
        guard let box = field else { return false }
        field = nil
        marks.typing = nil
        marks.needsDisplay = true
        box.removeFromSuperview()
        onFocusReturn()
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let box = field else { return }
        // Grown to fit rather than scrolled: the field is standing in for the
        // finished annotation, and text that scrolls out of a fixed box is not
        // standing in for anything.
        let width = max(120, box.fittingSize.width + ImageEdit.textSize)
        box.setFrameSize(CGSize(width: width, height: box.frame.height))
        marks.typing = box.frame
        marks.needsDisplay = true
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTyping()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return cancelTyping()
        default:
            return false
        }
    }
}

/// Where an `NSTextField` actually puts its ink, measured rather than derived.
///
/// The text has to start at the point that was clicked, because that is where
/// `ImageEdit.render` will draw it when ⏎ turns the field into an edit — and any
/// difference between the two is a line of text that jumps as you commit it.
///
/// Three arithmetic versions of this were wrong before it was measured. A cell
/// insets its title horizontally by an amount it does not publish; it centres a
/// single line vertically inside whatever height the field has, so the baseline
/// depends on the *field's* height and not only on the font's; and
/// `titleRect(forBounds:)` on a borderless cell hands back the full bounds, so
/// asking politely gets an answer that is not the one being drawn. Rendering one
/// glyph into a bitmap and finding its edges answers all three at once, on any
/// macOS, for any font — "H" has no descender and no left side-bearing to speak
/// of, so its lowest ink row *is* the baseline and its leftmost column *is* the
/// inset.
///
/// Cached per font size: it costs one 150×30 offscreen draw, and the answer
/// cannot change while the app is running.
@MainActor
private enum TextFieldInk {
    struct Metrics {
        /// The field's height, which is what the vertical centring is measured
        /// against — so the field must be created at exactly this height.
        let height: CGFloat
        /// How far in from the field's left edge the first glyph starts.
        let inkLeft: CGFloat
        /// How far up from the field's bottom edge the baseline sits.
        let baselineFromBottom: CGFloat
    }

    private static var cache: [CGFloat: Metrics] = [:]

    static func metrics(for font: NSFont) -> Metrics {
        if let known = cache[font.pointSize] { return known }
        let height = (font.ascender - font.descender).rounded(.up)
        var measured = Metrics(
            height: height, inkLeft: 2,
            baselineFromBottom: (height - (font.ascender - font.descender)) / 2
                + abs(font.descender))

        let probe = NSTextField(frame: CGRect(x: 0, y: 0, width: 120, height: height))
        probe.font = font
        probe.textColor = .white
        probe.backgroundColor = .clear
        probe.drawsBackground = false
        probe.isBordered = false
        probe.isBezeled = false
        probe.stringValue = "H"
        if let rep = probe.bitmapImageRepForCachingDisplay(in: probe.bounds) {
            probe.cacheDisplay(in: probe.bounds, to: rep)
            let width = rep.pixelsWide, tall = rep.pixelsHigh
            let scale = CGFloat(tall) / max(height, 1)
            var left = Int.max
            var bottom = -1
            for row in 0..<tall {
                for column in 0..<width {
                    // Any ink at all: the probe is white on nothing, so alpha is
                    // the whole test and antialiasing counts.
                    guard (rep.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.35 else {
                        continue
                    }
                    left = min(left, column)
                    bottom = max(bottom, row)
                }
            }
            if left < Int.max, bottom >= 0 {
                // `colorAt` counts rows from the top; the frame counts from the
                // bottom.
                measured = Metrics(
                    height: height,
                    inkLeft: CGFloat(left) / scale,
                    baselineFromBottom: CGFloat(tall - bottom - 1) / scale)
            }
        }
        cache[font.pointSize] = measured
        return measured
    }
}

/// Draws the gesture in progress over the picture.
///
/// A separate view above the image rather than the canvas's own `draw` because
/// subviews are composited on top of their superview's drawing: marks drawn by
/// the canvas would be underneath the image and therefore invisible.
private final class EditMarks: NSView {
    /// The rectangle being dragged, or the one just committed and not yet
    /// rendered.
    var pending: CGRect?
    var pendingMarker: (centre: CGPoint, number: Int)?
    /// The crop frame, when the crop tool is holding one.
    var crop: CGRect?
    /// Whether anything is actually being thrown away yet.
    var dimsOutsideCrop = false
    /// The box being typed into. Drawn as a dashed outline rather than filled,
    /// because what goes into the file is the words and not a plate behind them.
    var typing: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let crop { drawCrop(crop) }
        if let pending {
            // Nearly opaque, not a light wash. The rectangle is a promise that
            // whatever is under it will be destroyed, and a tint you can still
            // read through invites the reading that it is a highlight. It stands
            // in for the real mosaic for one render and no longer.
            NSColor(white: 0.06, alpha: 0.88).setFill()
            NSColor(red: 1, green: 0.45, blue: 0.3, alpha: 0.9).setStroke()
            let path = NSBezierPath(rect: pending)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
        if let pendingMarker { drawMarker(pendingMarker) }
        if let typing {
            NSColor.controlAccentColor.setStroke()
            let frame = NSBezierPath(rect: typing.insetBy(dx: -2, dy: -2))
            frame.lineWidth = 1
            frame.setLineDash([4, 3], count: 2, phase: 0)
            frame.stroke()
        }
    }

    /// The crop frame: a hairline rectangle, four corner brackets to pull, and
    /// everything outside it dimmed once there is an outside.
    ///
    /// The brackets are what say the corners are draggable. A plain rectangle
    /// says a region has been chosen; ⌐ ¬ at the corners says the region is a
    /// handle — and it is the only affordance in this editor that is not a
    /// button, so it has to carry that on its own.
    private func drawCrop(_ rect: CGRect) {
        if dimsOutsideCrop {
            NSColor(white: 0, alpha: 0.55).setFill()
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: rect))
            outside.windingRule = .evenOdd
            outside.fill()
        }
        NSColor(white: 1, alpha: 0.75).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        // Never longer than a third of the side, so a small crop gets small
        // brackets instead of four overlapping ones that read as a solid frame.
        let arm = min(22, rect.width / 3, rect.height / 3)
        let thickness: CGFloat = 3
        NSColor.white.setStroke()
        let corners = NSBezierPath()
        corners.lineWidth = thickness
        corners.lineCapStyle = .square
        for x in [rect.minX, rect.maxX] {
            for y in [rect.minY, rect.maxY] {
                let inX: CGFloat = x == rect.minX ? 1 : -1
                let inY: CGFloat = y == rect.minY ? 1 : -1
                let anchor = CGPoint(x: x + inX * thickness / 2, y: y + inY * thickness / 2)
                corners.move(to: CGPoint(x: anchor.x + inX * arm, y: anchor.y))
                corners.line(to: anchor)
                corners.line(to: CGPoint(x: anchor.x, y: anchor.y + inY * arm))
            }
        }
        corners.stroke()
    }

    /// The same red circle the renderer draws, for the moment between the click
    /// and the render that makes it real.
    private func drawMarker(_ marker: (centre: CGPoint, number: Int)) {
        let radius = ImageEdit.markerRadius
        let circle = CGRect(
            x: marker.centre.x - radius, y: marker.centre.y - radius,
            width: radius * 2, height: radius * 2)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        (NSColor(cgColor: ImageEdit.inkColor) ?? .systemRed).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let label = "\(marker.number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: radius * 1.15),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: marker.centre.x - size.width / 2,
                        y: marker.centre.y - size.height / 2),
            withAttributes: attributes)
    }
}

/// The strip across the top of the viewer: which tool, undo, and the two
/// decisions.
///
/// **Its geometry never changes.** Every control exists from the moment the
/// window opens and none of them is ever hidden, added or resized — a press only
/// changes what is tinted and what is inert. That is the whole reason the bar
/// could move to the top and stay there: a bar that re-measured itself per state
/// would jump under a pointer already on its way to a button, and at the top of
/// the window, where it sits over the picture rather than under it, the jump
/// would be the first thing anyone saw.
///
/// Icon-only tools with tooltips rather than words. Five titled pills plus Undo,
/// Cancel and Apply is a bar wider than the window a small capture opens in, and
/// the five are a set the eye should read as one control rather than as five
/// sentences.
private final class EditToolbar: NSView {
    var onTool: (ImageEditor.Tool) -> Void = { _ in }
    var onUndo: () -> Void = {}

    private let content: NSView
    private let tools: [(tool: ImageEditor.Tool, pill: HUDPill)]
    /// The only control here that is not a tool. There is no Apply and no
    /// Cancel: the file follows the list, so there is nothing to confirm and
    /// nothing to throw away that this cannot walk back.
    private let undo = HUDPill(
        title: "Undo", mark: .symbol("arrow.uturn.backward"),
        tint: NSColor(white: 1, alpha: 0.16))
    private let dividers = [HUDMetrics.divider(x: 0)]

    private static let toolMarks: [(tool: ImageEditor.Tool, symbol: String, help: String)] = [
        (.pointer, "cursorarrow", "Look — zoom and scroll, and change nothing (V)"),
        (.redact, "square.grid.3x3.fill", "Redact — destroy the pixels under a rectangle (R)"),
        (.marker, "1.circle", "Number — drop a numbered marker (N)"),
        (.text, "textformat", "Text — type a note onto the picture (T)"),
        (.crop, "crop", "Crop — keep only what you drag around (C)"),
    ]

    init() {
        let box = CGRect(x: 0, y: 0, width: 320, height: HUDMetrics.height)
        let chrome = HUDMetrics.chrome(in: box)
        content = chrome.content
        tools = Self.toolMarks.map { entry in
            let pill = HUDPill(title: "", mark: .symbol(entry.symbol), tint: .controlAccentColor)
            pill.toolTip = entry.help
            return (entry.tool, pill)
        }
        super.init(frame: box)
        addSubview(chrome.glass)

        undo.onClick = { [weak self] in self?.onUndo() }
        undo.toolTip = "Undo the last edit (⌘Z) — ⇧⌘Z puts it back"
        for (tool, pill) in tools {
            pill.onClick = { [weak self] in self?.onTool(tool) }
            pill.setSelected(false, animated: false)
            content.addSubview(pill)
        }
        for divider in dividers { content.addSubview(divider) }
        content.addSubview(undo)
        setState(tool: .pointer, canUndo: false, canRedo: false, isBusy: false)
        setFrameSize(fittingSize)
        layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(tool: ImageEditor.Tool, canUndo: Bool, canRedo: Bool, isBusy: Bool) {
        for (candidate, pill) in tools {
            pill.setLive(!isBusy, animated: false)
            pill.setSelected(candidate == tool, animated: false)
        }
        // Inert rather than hidden: a control that appears only once it becomes
        // usable moves whatever was beside it out from under the pointer already
        // heading for it — and here it would move the whole bar.
        undo.setLive((canUndo || canRedo) && !isBusy, animated: false)
    }

    /// Where a tool's button is, for the self-test that presses the real one.
    func pillFrame(for tool: ImageEditor.Tool) -> CGRect? {
        tools.first { $0.tool == tool }?.pill.frame
    }

    /// A constant, computed from the controls rather than typed out, and asked
    /// for once. Nothing about the state is in it.
    override var fittingSize: NSSize {
        let width = HUDMetrics.margin * 2
            + tools.reduce(0) { $0 + $1.pill.frame.width }
            + CGFloat(tools.count - 1) * HUDMetrics.gap
            + HUDMetrics.groupGap * 2 + 1
            + undo.frame.width
        return CGSize(width: width.rounded(), height: HUDMetrics.height)
    }

    override func layout() {
        super.layout()
        let midY = ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()
        var x = HUDMetrics.margin
        for (index, entry) in tools.enumerated() {
            entry.pill.setFrameOrigin(CGPoint(x: x, y: midY))
            x += entry.pill.frame.width
            if index < tools.count - 1 { x += HUDMetrics.gap }
        }
        x += HUDMetrics.groupGap
        dividers[0].setFrameOrigin(CGPoint(x: x, y: dividers[0].frame.minY))
        x += 1 + HUDMetrics.groupGap
        undo.setFrameOrigin(CGPoint(x: x, y: midY))
    }
}

/// The strip under the picture, and the only way anything leaves this window.
///
/// One button, deliberately. Copy is both halves of the same act — the clipboard
/// and a file beside the original — because an edit that lives only on the
/// clipboard is one ⌘C away from never having happened.
///
/// Its geometry is a constant, like the toolbar's: the pill's title does not
/// change with the state, only whether it is tinted.
private final class EditFooter: NSView {
    var onCopy: () -> Void = {}

    private let content: NSView
    private let copy = HUDPill(
        title: "Copy", mark: .symbol("doc.on.doc"), tint: .controlAccentColor)

    init() {
        let box = CGRect(x: 0, y: 0, width: 160, height: HUDMetrics.height)
        let chrome = HUDMetrics.chrome(in: box)
        content = chrome.content
        super.init(frame: box)
        addSubview(chrome.glass)
        copy.onClick = { [weak self] in self?.onCopy() }
        copy.toolTip = "Copy the edited picture, and save it beside the original"
        content.addSubview(copy)
        setFrameSize(fittingSize)
        layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tinted once there is an edit to take away, and inert — never hidden —
    /// before that: an unedited capture can still be copied, but the accent
    /// colour is reserved for the press that has something new in it.
    func setState(hasEdits: Bool, isBusy: Bool) {
        copy.setSelected(hasEdits, animated: false)
        copy.setLive(!isBusy, animated: false)
    }

    override var fittingSize: NSSize {
        CGSize(width: (HUDMetrics.margin * 2 + copy.frame.width).rounded(),
               height: HUDMetrics.height)
    }

    override func layout() {
        super.layout()
        copy.setFrameOrigin(CGPoint(
            x: HUDMetrics.margin,
            y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()))
    }
}
