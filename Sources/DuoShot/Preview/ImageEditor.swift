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
        case line
        case arrow
        case rectangle
        case highlight
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
    /// A scan in flight. Vision takes the better part of a second on a 5K
    /// capture with no indicator saying so, which makes the second click likely
    /// rather than hypothetical -- and two scans would cover everything twice.
    private var isScanning = false
    private var renderTask: Task<Void, Never>?
    private var stack = EditList()
    private var tool: Tool = .pointer
    /// The index of the list entry a typing box is standing in for, if any. See
    /// `takeText` — this is what makes cancelling free.
    private var suspended: Int?
    /// The index of the mark the pointer has picked out, if any. Drawn with a
    /// frame around it, moved by dragging it, and removed by ⌫ or the bin.
    private var selection: Int?
    /// The colour and weight the next mark is made in — and the one applied to
    /// the selection the moment a swatch is pressed, which is what anybody who
    /// has used an editor expects a palette to do once something is picked.
    private var ink = Ink.default
    /// The highlighter keeps its own, because it is the one tool whose colour is
    /// part of what it is. Picking blue for the arrows must not turn the
    /// highlighter blue as a side effect.
    private var highlightInk = Ink.highlighter
    /// The size the next piece of text is written at. Kept here rather than in
    /// the canvas because the toolbar sets it and re-opening an annotation reads
    /// it back — the canvas is told, never asked.
    private var textSize: CGFloat = ImageEdit.textSize
    /// Bumped on every re-render so a slow one cannot land on top of a newer one:
    /// an undo races the render it is undoing, and losing that race would leave
    /// the picture showing an edit the list no longer has.
    private var renderGeneration = 0

    /// Called when the picture itself changes size — which only a crop does.
    ///
    /// The window is not this view's to resize, and the rule for how big it
    /// should be belongs with the rule that sized it when it opened. Injected,
    /// like every other thing this view needs from outside itself.
    var onPictureResized: ((CGSize) -> Void)?

    init(url: URL, image: NSImage, originalData: Data, menu: NSMenu, frame: CGRect) {
        self.url = url
        self.originalData = originalData
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
        canvas.takeTextForEditing = { [weak self] point in self?.takeText(at: point) }
        canvas.textUnder = { [weak self] point in self?.textBounds(at: point) }
        canvas.moveText = { [weak self] from, to in self?.moveText(from: from, to: to) }
        canvas.textSize = textSize
        canvas.textRasterScale = (pixelSize.width / originalPointSize.width
            + pixelSize.height / originalPointSize.height) / 2
        canvas.onTypingNeedsCleanPreview = { [weak self] in self?.renderNow() }
        canvas.onTypingFinished = { [weak self] committed in
            self?.finishTyping(committed: committed)
        }
        canvas.onTextSizeAdopted = { [weak self] size in
            self?.textSize = size
            self?.refreshBar()
        }
        canvas.onInkAdopted = { [weak self] ink in
            self?.ink = ink
            self?.refreshBar()
        }
        canvas.markerCount = { [weak self] in
            self?.stack.edits.count { if case .marker = $0 { true } else { false } } ?? 0
        }
        canvas.onFocusReturn = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        canvas.pick = { [weak self] point in self?.pick(at: point) }
        canvas.onSelect = { [weak self] point in self?.select(at: point) }
        canvas.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        canvas.ink = ink
        bar.onTool = { [weak self] tool in self?.choose(tool) }
        bar.onUndo = { [weak self] in self?.undo() }
        bar.onRedo = { [weak self] in self?.redo() }
        bar.onDelete = { [weak self] in self?.deleteSelection() }
        bar.onTextSize = { [weak self] size in self?.chooseTextSize(size) }
        bar.onColour = { [weak self] colour in self?.chooseColour(colour) }
        bar.onWeight = { [weak self] weight in self?.chooseWeight(weight) }
        footer.onCopy = { [weak self] in self?.copyOut() }
        footer.onSave = { [weak self] in self?.saveAs() }
        footer.onShare = { [weak self] in self?.shareOut() }
        footer.onDone = { [weak self] in self?.window?.performClose(nil) }

        addSubview(bar)
        addSubview(footer)
        addSubview(notice)
        notice.isHidden = true
        refreshBar()
        needsLayout = true
    }

    /// Kept for focused editor tests and callers that already own only an
    /// `NSImage`. The production viewer uses the data-taking initializer after
    /// loading and decoding off the main actor.
    convenience init?(url: URL, image: NSImage, menu: NSMenu, frame: CGRect) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(url: url, image: image, originalData: data, menu: menu, frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    private static let barInset: CGFloat = 12
    private static let noticeGap: CGFloat = 8

    /// The tools' band: two rows of bar, and the space around them.
    private static let topBand: CGFloat = barInset * 2 + EditMetrics.barHeight

    /// Copy's band, which is **the same height** even though its bar is one row
    /// rather than two.
    ///
    /// It was the footer's own height, and that put the picture off the middle of
    /// the window by half the difference — 21 points, low. Nobody would find that
    /// by looking at a full-window capture, where the picture fills the space; it
    /// is obvious the moment a crop leaves a small picture floating in a large
    /// one, which is exactly how it was reported.
    ///
    /// Equal bands rather than an offset applied somewhere further down: the
    /// picture is then centred by construction, and there is no second number
    /// that has to be kept in step with these two. The slack goes *above* the
    /// footer, so Copy stays where it has always been — a hand's width from the
    /// bottom edge — and what grows is the dark under the picture.
    private static let bottomBand: CGFloat = topBand

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
    static let chromeHeight: CGFloat = topBand + bottomBand

    /// How wide the window has to be for the toolbar to sit inside it with room
    /// either side.
    ///
    /// Measured from a real toolbar rather than typed out, because it was typed
    /// out and it went stale the moment the bar grew a second row: the window's
    /// floor stayed at 560, the bar came out 645, and a small capture opened with
    /// the Pick tool sliced off by the left edge of its own window.
    static let minimumContentWidth: CGFloat = EditToolbar().fittingSize.width
        + barInset * 2 + 24

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
        scrollView.frame = CGRect(
            x: 0, y: Self.bottomBand, width: bounds.width,
            height: max(0, bounds.height - Self.topBand - Self.bottomBand))

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

    /// Puts the pointer back. Answers whether there was a tool to put down.
    ///
    /// No longer on Escape's path — see `cancelOperation` — and kept because
    /// putting the tool down is still a thing the viewer does when it loses the
    /// picture out from under a gesture.
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
        canvas.ink = currentInk
        window?.makeFirstResponder(self)
        // A tool and a selection are two different answers to "what does the
        // next click mean", and holding both would make ⌫ ambiguous.
        if tool.draws { clearSelection() }
        refreshBar()
    }

    // MARK: - The selection

    /// The mark under a point, topmost first, or nil.
    ///
    /// The crop is skipped by `ImageEdit.contains`, and redactions are not: a
    /// mosaic covering the wrong thing is exactly the mark most worth being able
    /// to pick up and delete.
    private func pick(at point: CGPoint) -> Int? {
        let offset = stack.crop?.origin ?? .zero
        let hit = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        return stack.edits.indices.reversed().first {
            stack.edits[$0].contains(hit, within: originalPointSize)
        }
    }

    /// The selection's frame in the canvas's coordinates, which is the cropped
    /// picture's — the space `EditMarks` draws in.
    private var selectionFrame: CGRect? {
        guard let index = selection, stack.edits.indices.contains(index),
              let box = stack.edits[index].bounds(within: originalPointSize)
        else { return nil }
        let offset = stack.crop?.origin ?? .zero
        return box.offsetBy(dx: -offset.x, dy: -offset.y)
    }

    private func select(at point: CGPoint) {
        selection = pick(at: point)
        // The palette follows the selection, so the swatch shows the colour of
        // the thing that is about to be recoloured rather than the colour the
        // next mark would have been.
        if let index = selection, let picked = stack.edits[index].ink { ink = picked }
        showSelection()
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        showSelection()
    }

    private func showSelection() {
        canvas.selectionFrame = selectionFrame
        refreshBar()
    }

    private func moveSelection(by delta: CGPoint) {
        guard let index = selection, stack.edits.indices.contains(index) else { return }
        stack.replace(at: index, with: stack.edits[index].moved(by: delta))
        scheduleRender()
        showSelection()
    }

    /// ⌫, ⌦ and the bin. The one thing the editor could not do before: every
    /// mistake was a run of ⌘Z that also took back the four marks made after it.
    private func deleteSelection() {
        guard let index = selection, stack.edits.indices.contains(index) else { return }
        selection = nil
        stack.remove(at: index)
        scheduleRender()
        showSelection()
    }

    /// Recolours what is picked, or sets what the next mark will be made in.
    ///
    /// Both, rather than one or the other, and that is the whole reason the
    /// palette is worth having: a swatch that only ever applied to the *next*
    /// mark means an arrow drawn in the wrong colour has to be undone and drawn
    /// again.
    private func chooseColour(_ colour: InkColour) {
        if tool == .highlight, selection == nil {
            highlightInk.colour = colour
        } else {
            ink.colour = colour
        }
        applyInkToSelection()
        canvas.ink = currentInk
        refreshBar()
    }

    private func chooseWeight(_ weight: InkWeight) {
        ink.weight = weight
        applyInkToSelection()
        canvas.ink = currentInk
        refreshBar()
    }

    /// What the tool in force would draw with.
    private var currentInk: Ink { tool == .highlight ? highlightInk : ink }

    private func applyInkToSelection() {
        guard let index = selection, stack.edits.indices.contains(index) else { return }
        let recoloured = stack.edits[index].inked(
            { if case .highlight = stack.edits[index] { highlightInk } else { ink } }())
        guard recoloured != stack.edits[index] else { return }
        stack.replace(at: index, with: recoloured)
        scheduleRender()
        showSelection()
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
    /// The text under a point, removed from the list and handed back so the box
    /// can re-open on it.
    ///
    /// The list is in the original picture's coordinates and the canvas is in
    /// the cropped one, so both directions go through the crop's origin — the
    /// same conversion `add` makes, in reverse.
    /// The same lookup `takeText` does, without taking anything: what the hover
    /// highlight is drawn around.
    private func textBounds(at point: CGPoint) -> CGRect? {
        let offset = stack.crop?.origin ?? .zero
        let hit = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        for edit in stack.edits.reversed() {
            guard case .text(let anchor, let string, let size, _) = edit else { continue }
            let box = ImageEdit.bounds(ofText: string, at: anchor, size: size,
                                       within: originalPointSize)
            guard box.insetBy(dx: -4, dy: -4).contains(hit) else { continue }
            return box.offsetBy(dx: -offset.x, dy: -offset.y)
        }
        return nil
    }

    /// Moves the text under `from` by the drag's distance.
    ///
    /// Replaces the entry rather than removing and re-adding it, so the list
    /// keeps its order — a note dragged out of the way must not jump in front of
    /// the redaction it was drawn behind — and so one drag is one step to undo.
    private func moveText(from: CGPoint, to: CGPoint) {
        let offset = stack.crop?.origin ?? .zero
        let hit = CGPoint(x: from.x + offset.x, y: from.y + offset.y)
        let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
        for index in stack.edits.indices.reversed() {
            guard case .text(let anchor, let string, let size, _) = stack.edits[index],
                  ImageEdit.bounds(ofText: string, at: anchor, size: size,
                                   within: originalPointSize)
                    .insetBy(dx: -4, dy: -4).contains(hit)
            else { continue }
            stack.replace(at: index, with: .text(
                CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y), string, size))
            scheduleRender()
            refreshBar()
            return
        }
    }

    /// Hands the text under `point` to the typing box and *suspends* its list
    /// entry — which is not the same as removing it, and the difference is a bug
    /// that deleted people's annotations.
    ///
    /// It used to remove it. Committing put it back, so the happy path was fine;
    /// every other way out of the box was not. Escape and switching tool both go
    /// through `cancelTyping`, which only takes the box off the screen — so the
    /// note that had just been clicked was gone from the list, and stayed gone.
    /// The preview still showed it (a plain click deliberately does not
    /// re-render), so nothing said so until the next edit redrew the picture
    /// without it. Reported, exactly right, as Escape doing a ⌘Z.
    ///
    /// So the entry stays where it is, in its own place in the list, and only
    /// `visibleEdits` pretends it is not there for as long as the box is
    /// standing in for it. Cancelling is then genuinely nothing happening, and
    /// committing is a `replace` at the same index — one step to undo instead of
    /// two, and the note keeps its place in the z-order rather than jumping in
    /// front of whatever was drawn over it.
    private func takeText(
        at point: CGPoint
    ) -> (anchor: CGPoint, string: String, size: CGFloat, ink: Ink)? {
        let offset = stack.crop?.origin ?? .zero
        let hit = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        // Last first: the most recently made annotation is the one on top.
        for index in stack.edits.indices.reversed() {
            guard case .text(let anchor, let string, let size, let ink) = stack.edits[index],
                  ImageEdit.bounds(ofText: string, at: anchor, size: size,
                                   within: originalPointSize)
                    .insetBy(dx: -4, dy: -4).contains(hit)
            else { continue }
            suspended = index
            refreshBar()
            return (CGPoint(x: anchor.x - offset.x, y: anchor.y - offset.y), string, size, ink)
        }
        return nil
    }

    /// The list as the picture should show it: everything, less the one entry a
    /// typing box is currently standing in for.
    private var visibleEdits: [ImageEdit] {
        guard let index = suspended, stack.edits.indices.contains(index) else {
            return stack.edits
        }
        var list = stack.edits
        list.remove(at: index)
        return list
    }

    /// Called after the typing box has gone, whichever way it went.
    ///
    /// `add` clears `suspended` when a re-opened note is committed with words
    /// still in it, so anything left here is one of the two other endings:
    /// committed empty, which means delete it, or cancelled, which means put the
    /// picture back the way it was.
    private func finishTyping(committed: Bool) {
        guard let index = suspended else { return }
        suspended = nil
        if committed, stack.edits.indices.contains(index) { stack.remove(at: index) }
        scheduleRender()
        refreshBar()
    }

    private func add(_ edit: ImageEdit) {
        let offset = stack.crop?.origin ?? .zero
        if let index = suspended, case .text = edit, stack.edits.indices.contains(index) {
            suspended = nil
            stack.replace(at: index, with: edit.moved(by: offset))
        } else {
            stack.push(edit.moved(by: offset))
        }
        scheduleRender()
        refreshBar()
    }

    /// Covers everything in the capture that looks like it was not meant to
    /// leave the machine. Vision reads the file, `SensitiveText` decides, and
    /// what comes back becomes ordinary redactions.
    ///
    /// One stack entry per finding, not one for the lot. The list is the undo
    /// history, so a scan that covered four things and got one of them wrong is
    /// four ⌘Z away from being three things covered correctly -- which is the
    /// only sane answer to a detector that is right most of the time.
    ///
    /// `stack.push` directly rather than `add`, and the difference matters:
    /// `add` shifts an edit by the current crop's origin because the canvas
    /// hands it coordinates in the *cropped* picture's space. These come from
    /// the original file and are already in the list's own space, so shifting
    /// them would move every finding by the crop.
    func redactSensitive() {
        guard !isScanning else { return }
        isScanning = true
        let size = originalPointSize
        Task { [weak self, url] in
            let findings = await SensitiveText.findings(inFileAt: url, pointSize: size)
            guard let self else { return }
            self.isScanning = false
            guard !findings.isEmpty else {
                self.notice.show(
                    message: "Nothing here looked like an address, a key, a number or a card.",
                    action: nil, symbol: "checkmark.shield")
                self.showNotice()
                return
            }
            for finding in findings { self.stack.push(.redact(finding.rect)) }
            self.scheduleRender()
            self.refreshBar()
            let kinds = Set(findings.map(\.kind)).count
            self.notice.show(
                message: "Covered \(findings.count) thing\(findings.count == 1 ? "" : "s") "
                    + "in \(kinds) categor\(kinds == 1 ? "y" : "ies"). "
                    + "⌘Z takes them back one at a time — check them before you share.",
                action: nil, symbol: "eye.slash")
            self.showNotice()
        }
    }

    /// Both of these let go of the selection, and they have to: it is an *index*
    /// into the list, and stepping the list changes what that index points at.
    /// Held across an undo, the frame stays on screen around a different mark and
    /// ⌫ deletes that one instead.
    private func undo() {
        guard stack.undo() else { return }
        selection = nil
        scheduleRender()
        showSelection()
    }

    private func redo() {
        guard stack.redo() else { return }
        selection = nil
        scheduleRender()
        showSelection()
    }

    /// Sets the size the next piece of text is written at, and re-arms the text
    /// tool while doing it: picking a size is asking to write something.
    private func chooseTextSize(_ size: CGFloat) {
        textSize = size
        canvas.textSize = size
        // A size pressed while a piece of text is picked re-sets that text, the
        // same way a swatch recolours it.
        if let index = selection, case .text(let at, let string, _, let ink) = stack.edits[index] {
            stack.replace(at: index, with: .text(at, string, size, ink))
            scheduleRender()
            showSelection()
            return
        }
        if tool != .text { choose(.text) } else { refreshBar() }
    }

    private func refreshBar() {
        bar.setState(
            tool: tool, textSize: textSize, ink: currentInk,
            canUndo: stack.canUndo, canRedo: stack.canRedo,
            hasSelection: selection != nil, isBusy: isExporting)
        // `isConfigured`, not `ShareService.canShare(fileAt:)`. The latter asks
        // whether the *file* is a kind that could be uploaded, which for a PNG is
        // always yes — so the first version of this offered Share Link on an
        // install with no endpoint and no token, which is a button that can only
        // fail.
        footer.setState(hasEdits: !stack.isEmpty, canShare: ShareService.shared.isConfigured,
                        isBusy: isExporting)
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
        renderTask?.cancel()
        let edits = visibleEdits
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.renderDelay)
            guard !Task.isCancelled else { return }
            await self?.rerender(edits)
        }
    }

    /// Removes a re-opened annotation from the preview only after its contents
    /// actually change. A plain click keeps the exact old bitmap pixels; that is
    /// the only hand-off with zero per-glyph raster difference.
    private func renderNow() {
        renderTask?.cancel()
        let edits = visibleEdits
        renderTask = Task { [weak self] in await self?.rerender(edits) }
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
        if resized {
            // Frames first, picture second, and in that order for a reason: set
            // the image while the views are still the old size and there is one
            // layout pass where a smaller bitmap is stretched across a larger
            // frame. It lasts a frame and it looks like the whole picture
            // flinching — most visible on the text, which squashes and springs
            // back.
            //
            // A crop takes effect the moment the drag ends, so the canvas is a
            // different size now and everything drawn on it from here is in the
            // new picture's coordinates — see `add`, which puts them back into
            // the original's before they reach the list.
            let box = CGRect(origin: .zero, size: size)
            canvas.frame = box
            imageView.frame = box
            scrollView.naturalSize = size
        }
        // The *point* size, not the pixel size: the capture's DPI is what makes a
        // 2× picture the size it was on screen rather than twice that.
        imageView.image = NSImage(cgImage: image, size: size)
        pointSize = size
        pixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        canvas.clearPending(revealTyping: true)
        if resized {
            onPictureResized?(size)
            zoomToFit()
            // The crop frame is drawn from the canvas's bounds, and the canvas
            // has just changed size: without this it keeps the shape the picture
            // had before the crop, hanging off the edge of the one it has now.
            canvas.refreshCropFrame()
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
        // Anything still in the typing box is part of the picture, and pressing
        // Copy with a note half-typed used to export the list *without* it: the
        // box lives on the canvas and its words only reach the list on commit.
        // From the outside that is a note that vanishes at the moment of copying
        // — the one moment it must not.
        canvas.commitTyping()
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

    /// Puts the edited picture wherever the person wants it, rather than only
    /// beside the capture.
    ///
    /// Copy's file lands next to the original with "(edited)" on the end, which
    /// is the right default and the wrong answer to "I want this one in the
    /// ticket folder". A save panel is the answer every other app on this system
    /// gives to that, so this one gives it too.
    private func saveAs() {
        guard !isExporting else { return }
        canvas.commitTyping()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageEdit.exportURL(besides: url).lastPathComponent
        panel.canCreateDirectories = true
        panel.message = "Save the edited picture. The capture itself is not touched."
        // Modal to the viewer rather than to the app: DuoShot is `LSUIElement`
        // and has no windows of its own to be modal to, and a sheet on the
        // window being edited is what says *which* picture is being saved when
        // three viewers are open.
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.export(to: destination) { editor, file, size in
                Clipboard.write(fileAt: file, pointSize: size)
                editor.notice.show(
                    message: "Saved as \(file.lastPathComponent), and copied.",
                    action: ("Show in Finder", {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }),
                    symbol: "folder")
                editor.showNotice()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    /// Uploads the *edited* picture and copies the link.
    ///
    /// The preview card's share button uploads the capture, which is the file on
    /// disk and therefore the unedited one. Sharing from in here has to upload
    /// what is on screen, or the whole point of having redacted something before
    /// sharing it is lost — which is the worst possible way for this feature to
    /// be wrong.
    private func shareOut() {
        guard !isExporting else { return }
        canvas.commitTyping()
        guard ShareService.canShare(fileAt: url) else {
            notice.show(
                message: "Sharing is not set up yet. Settings ▸ Share has the endpoint "
                    + "and the token.",
                action: nil, symbol: "link.badge.plus")
            showNotice()
            return
        }
        export(to: ImageEdit.exportURL(besides: url)) { editor, file, _ in
            ShareService.shared.share(fileAt: file)
            editor.notice.show(
                message: "Uploading \(file.lastPathComponent) — the link lands on the "
                    + "clipboard when it is done.",
                action: nil, symbol: "link")
            editor.showNotice()
        }
    }

    /// The one write path behind Copy, Save As and Share: flatten the list onto
    /// the capture's own bytes, off the main actor, and hand back where it went.
    private func export(
        to destination: URL, then done: @escaping (ImageEditor, URL, CGSize) -> Void
    ) {
        isExporting = true
        refreshBar()
        let edits = stack.edits
        Task { [originalData, originalPointSize, weak self] in
            defer {
                self?.isExporting = false
                self?.refreshBar()
            }
            do {
                let size = try await Self.exportAndCopy(
                    edits, of: originalData, pointSize: originalPointSize, to: destination)
                guard let self else { return }
                done(self, destination, size)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The edited picture could not be written."
                Log.app.error("export: \(reason, privacy: .public)")
                NSSound.beep()
                self?.notice.show(message: reason, action: nil)
                self?.showNotice()
            }
        }
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
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        switch (key, flags) {
        case ("z", [.command]): undo()
        case ("z", [.command, .shift]): redo()
        // ⌘C copies the *edited* picture, which is the whole point of this
        // window. Without it the reflex reaches whatever the responder chain
        // offers — which here is nothing, so ⌘C in a viewer full of annotations
        // did nothing at all.
        case ("c", [.command]): copyOut()
        case ("s", [.command, .shift]): saveAs()
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
        // ⌫ and ⌦ take the selected mark away. Ahead of the letters because
        // neither is one, and behind `isTyping` because inside the box they are
        // what deletes a character.
        if event.keyCode == 51 || event.keyCode == 117 {
            guard selection != nil else {
                super.keyDown(with: event)
                return
            }
            deleteSelection()
            return
        }
        switch key {
        case "v": choose(.pointer)
        case "r": choose(.redact)
        case "n": choose(.marker)
        case "t": choose(.text)
        case "l": choose(.line)
        case "a": choose(.arrow)
        case "b": choose(.rectangle)
        case "h": choose(.highlight)
        case "c": choose(.crop)
        default: super.keyDown(with: event)
        }
    }

    /// Escape leaves: the box being typed in, then a selection, then the window.
    ///
    /// It used to put the *tool* down as its second step, and that step is gone.
    /// It was reported as "Escape will not close the window", and the report was
    /// right twice over: a bar with nine tools on it means Escape almost never
    /// reaches the window, and there was no way to tell from the screen which of
    /// the two things a press had just done. V puts the pointer back and says so
    /// on the button; Escape now only ever means "out of here".
    ///
    /// It still never throws edits away. Cancelling the box puts the annotation
    /// that was being edited back exactly as it was — see `takeText`, which is
    /// where that was broken.
    override func cancelOperation(_ sender: Any?) {
        if canvas.cancelTyping() { return }
        if selection != nil {
            clearSelection()
            return
        }
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
        await rerender(visibleEdits)
    }

    // MARK: Hooks for the selection and the palette

    /// Clicks the picture with the pointer, the way `select` is reached for real.
    func selectForTest(at point: CGPoint) {
        select(at: point)
    }

    var selectionForTest: Int? { selection }
    var selectionFrameForTest: CGRect? { selectionFrame }
    /// Whether the layer the selection frame is drawn on would be seen at all —
    /// the half of "is the frame there" that reading the model cannot answer.
    var marksAreVisibleForTest: Bool { canvas.marksAreVisibleForTest }
    var inkForTest: Ink { currentInk }

    func deleteSelectionForTest() { deleteSelection() }
    func chooseColourForTest(_ colour: InkColour) { chooseColour(colour) }
    func chooseWeightForTest(_ weight: InkWeight) { chooseWeight(weight) }

    /// Presses Escape exactly as the responder chain would.
    func escapeForTest() { cancelOperation(nil) }

    /// The index the typing box is standing in for, if any — what `takeText`
    /// suspends and `cancelTyping` must leave untouched.
    var suspendedForTest: Int? { suspended }

    /// Where the swatch for a colour is, and where the bin is, in this view's
    /// coordinates — so a test presses the real control rather than a point the
    /// bar happens to occupy today.
    func swatchFrameForTest(_ colour: InkColour) -> CGRect? {
        bar.swatchFrame(for: colour).map { convert($0, from: bar) }
    }

    func binFrameForTest() -> CGRect { convert(bar.binFrame(), from: bar) }

    var footerFrameForTest: CGRect { footer.frame }

    /// Whether Share Link is standing in the footer — which it must not be when
    /// there is no endpoint behind it.
    var shareButtonShownForTest: Bool { footer.shareIsShownForTest }
    var footerFittingWidthForTest: CGFloat { footer.fittingSize.width }

    /// Forces the footer to re-read whether sharing is configured, for the test
    /// that flips the setting under an open window.
    func refreshFooterForTest() { refreshBar() }

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

    /// Where the picture is scrolled to, which nothing about opening a text box
    /// may change.
    var scrollOriginForTest: CGPoint { scrollView.documentVisibleRect.origin }

    /// What part of the picture the window is showing, in the picture's own
    /// coordinates — the measurement "is it centred" is made on.
    var visibleRectForTest: CGRect { scrollView.documentVisibleRect }

    /// Where the picture actually is, which is the half of the layout the bar's
    /// own frame cannot answer.
    var pictureFrameForTest: CGRect { scrollView.frame }


    var isEditingForTest: Bool { isEditing }

    /// What the hover highlight is currently drawn around, if anything.
    var hoverForTest: CGRect? { canvas.hoverForTest }


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
private final class EditCanvas: NSView, NSTextViewDelegate, NSLayoutManagerDelegate {
    var isActive = false {
        didSet {
            marks.needsDisplay = true
            if !isActive { cancelTyping() }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The colour and weight the marks in progress are drawn with, so a blue
    /// arrow is blue while it is being dragged rather than only once it lands.
    var ink = Ink.default {
        didSet {
            guard ink != oldValue else { return }
            marks.ink = ink
            marks.needsDisplay = true
            box?.annotationColour = ink.colour
            box?.needsDisplay = true
        }
    }

    /// The frame around the mark the pointer has picked, in this view's
    /// coordinates. The editor owns which one that is; this only draws it.
    var selectionFrame: CGRect? {
        didSet {
            guard selectionFrame != oldValue else { return }
            marks.selection = selectionFrame
            marks.needsDisplay = true
        }
    }

    var tool: ImageEditor.Tool = .pointer {
        didSet {
            guard tool != oldValue else { return }
            cancelTyping()
            draft = nil
            marks.hover = nil
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

    /// Re-reads the frame from the canvas's current bounds, for when those have
    /// changed under it.
    func refreshCropFrame() { showCropFrame() }

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
    /// The size new text is written at, chosen in the toolbar.
    var textSize: CGFloat = ImageEdit.textSize
    /// The capture's pixels per point. The renderer creates fonts at this pixel
    /// size rather than scaling a point-sized font through a CGContext, and the
    /// live box must do the same for identical hinting.
    var textRasterScale: CGFloat = 1
    var onTypingNeedsCleanPreview: () -> Void = {}
    /// Called once the box has gone, either way. `true` means its words went
    /// into the list (or were emptied out, which is a commit of nothing);
    /// `false` means Escape, or a tool change, and nothing at all happened.
    var onTypingFinished: (Bool) -> Void = { _ in }
    /// Told back to the editor when re-opening an annotation adopts its size, so
    /// the toolbar shows the size that is actually being typed at.
    var onTextSizeAdopted: (CGFloat) -> Void = { _ in }
    /// The same, for its colour.
    var onInkAdopted: (Ink) -> Void = { _ in }
    /// Which entry in the list is under a point, for the pointer's hit-testing.
    var pick: (CGPoint) -> Int? = { _ in nil }
    /// A click with the pointer: pick whatever is under it, or nothing.
    var onSelect: (CGPoint) -> Void = { _ in }
    /// A drag with the pointer, once something is picked.
    var onMoveSelection: (CGPoint) -> Void = { _ in }
    /// How many markers are already down, so the one being placed can be drawn
    /// with the number it is about to be given.
    var markerCount: () -> Int = { 0 }
    /// Asks whether a click landed on text that has already been made, and takes
    /// it out of the list if it has: what comes back is where it was and what it
    /// said, so the box can open on top of it holding the same words.
    var takeTextForEditing: (CGPoint)
        -> (anchor: CGPoint, string: String, size: CGFloat, ink: Ink)? = { _ in nil }
    /// The same question without the taking, for the pointer passing over.
    var textUnder: (CGPoint) -> CGRect? = { _ in nil }
    /// Moves the piece of text under the first point by the drag's distance.
    var moveText: (CGPoint, CGPoint) -> Void = { _, _ in }
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
    private var box: TypingView?
    /// Where the pointer was when the field opened, which is where the baseline
    /// of the finished text goes. Kept rather than read back off the field: the
    /// field grows as it is typed into, and its frame is not the anchor.
    private var typingAnchor: CGPoint = .zero
    /// A box that has been committed and is standing in for its own words until
    /// the render lands.
    private var committed: NSTextView?

    /// What a crop drag is doing to the frame: pulling one corner, sliding the
    /// whole thing, or drawing a new one where there was nothing.
    private enum CropGrab {
        case corner(atMinX: Bool, atMinY: Bool)
        case move(from: CGPoint, origin: CGPoint)
        case fresh
    }

    private var cropGrab: CropGrab?
    /// A press that landed on a piece of text, before it is known whether it is
    /// a click that opens it or a drag that moves it.
    private var textGrab: (start: CGPoint, moved: Bool)?
    /// Where the pointer was on the last event of a drag that is moving the
    /// selected mark. Held as "last", not "start", because the editor is told
    /// the *delta* — it applies each one to the list, so a running total would
    /// move the mark by the square of the drag.
    private var selectionGrab: CGPoint?

    /// How close to a corner counts as grabbing it. In image points, so it grows
    /// and shrinks with the zoom the way the corner mark itself does.
    private static let cornerGrab: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        marks.frame = bounds
        marks.autoresizingMask = [.width, .height]
        // Never hidden any more. It used to be hidden whenever no tool was
        // armed, which was fine while everything it drew belonged to a gesture
        // in progress — but the selection frame belongs to the *pointer*, and
        // the viewer opens holding the pointer. Hidden, the frame around the
        // mark you had just clicked simply did not appear. Everything drawn here
        // is gated on its own value being non-nil, so an unhidden layer with
        // nothing to draw draws nothing.
        addSubview(marks)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard isActive else {
            // The pointer tool. It claims a click only where there is a mark to
            // pick up — everywhere else the answer is still nil, so double-click
            // to zoom, pinch to magnify and the scrollers go on reaching the
            // scroll view exactly as they did before anything was selectable.
            guard bounds.contains(local) else { return nil }
            if selectionFrame?.insetBy(dx: -6, dy: -6).contains(local) == true { return self }
            return pick(local) != nil ? self : nil
        }
        // The text field is a real control and has to keep receiving clicks:
        // selecting what has been typed is the one interaction inside this view
        // that is not a gesture on the picture.
        if let box, let inside = box.hitTest(local) {
            return inside
        }
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard isActive else { return }
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    /// Tracking for the hover highlight, rebuilt whenever the canvas changes
    /// size — a crop changes it, and a tracking area that outlived its bounds
    /// would report the pointer as being somewhere it is not.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// What the text tool can re-open, lit up as the pointer passes over it.
    ///
    /// Clicking a piece of text to correct it is not a thing anyone would guess
    /// at, and an affordance nobody can see is a feature nobody has.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let hit = isActive && tool == .text && !isTyping
            ? textUnder(convert(event.locationInWindow, from: nil))
            : nil
        guard hit != marks.hover else { return }
        marks.hover = hit
        marks.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard marks.hover != nil else { return }
        marks.hover = nil
        marks.needsDisplay = true
    }

    /// Cleared by the editor once the re-render has landed, so a committed mark
    /// does not blink out of existence for the length of a decode.
    func clearPending(revealTyping: Bool = false) {
        marks.pending = nil
        marks.pendingHighlight = nil
        marks.pendingStroke = nil
        marks.pendingMarker = nil
        draft = nil
        showCropFrame()
        marks.needsDisplay = true
        committed?.removeFromSuperview()
        committed = nil
        if revealTyping, let box, box.revealsAfterPreviewUpdate {
            box.revealsAfterPreviewUpdate = false
            box.showsAnnotation = true
            box.needsDisplay = true
        }
    }

    // MARK: - Gestures

    override func mouseDown(with event: NSEvent) {
        guard isActive else {
            // Reached only because `hitTest` found a mark here — see there.
            let point = convert(event.locationInWindow, from: nil)
            onSelect(point)
            selectionGrab = selectionFrame == nil ? nil : point
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
        case .redact, .highlight:
            anchor = point
            marks.pending = nil
            marks.pendingHighlight = nil
            marks.pendingStroke = nil
        case .line, .arrow, .rectangle:
            anchor = point
            marks.pending = nil
            marks.pendingStroke = nil
        case .crop:
            beginCrop(at: point)
        case .marker:
            marks.pendingMarker = (point, markerCount() + 1)
            onEdit(.marker(point, ink))
        case .text:
            // A drag on a piece of text moves it, and a click opens it. Which
            // one this is cannot be known yet, so the press only remembers where
            // it started; `mouseDragged` decides.
            if !isTyping, textUnder(point) != nil {
                textGrab = (start: point, moved: false)
                return
            }
            // A click while something is being typed finishes it, and does
            // nothing else. Opening the next box in the same gesture is what it
            // used to do, and it meant clicking away from a note left an empty
            // box sitting where you clicked — the click was a full stop, not the
            // start of a sentence.
            if isTyping {
                commitTyping()
                return
            }
            // Clicking a piece of text opens it again rather than starting a
            // second one on top of it. Anything else makes an annotation a thing
            // you can only make and never fix — and the undo stack is not an
            // editing tool.
            if let existing = takeTextForEditing(point) {
                // Re-opened at the size and in the colour it was written in, not
                // at whatever the toolbar happens to be set to now.
                textSize = existing.size
                ink = existing.ink
                onTextSizeAdopted(existing.size)
                onInkAdopted(existing.ink)
                beginTyping(at: existing.anchor, holding: existing.string)
            } else {
                beginTyping(at: point)
            }
        }
        marks.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let from = selectionGrab {
            selectionGrab = point
            onMoveSelection(CGPoint(x: point.x - from.x, y: point.y - from.y))
            return
        }
        if var grab = textGrab {
            // Four points of travel before a press becomes a drag: a click on a
            // word is never perfectly still, and text that jumped a point every
            // time it was opened would be worse than text that cannot be moved.
            if !grab.moved, hypot(point.x - grab.start.x, point.y - grab.start.y) < 4 {
                return
            }
            grab.moved = true
            textGrab = grab
            marks.hover = textUnder(grab.start)?.offsetBy(
                dx: point.x - grab.start.x, dy: point.y - grab.start.y)
            marks.needsDisplay = true
            return
        }
        if cropGrab != nil {
            dragCrop(to: point)
            return
        }
        guard let anchor else {
            super.mouseDragged(with: event)
            return
        }
        switch tool {
        case .redact:
            marks.pending = rect(from: anchor, to: point)
        case .highlight:
            marks.pendingHighlight = rect(from: anchor, to: point)
        case .line, .arrow, .rectangle:
            marks.pendingStroke = (tool, anchor, clamped(point))
        default:
            break
        }
        marks.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if selectionGrab != nil {
            selectionGrab = nil
            return
        }
        if let grab = textGrab {
            textGrab = nil
            let point = convert(event.locationInWindow, from: nil)
            if grab.moved {
                moveText(grab.start, point)
                marks.hover = nil
                marks.needsDisplay = true
            } else if let existing = takeTextForEditing(grab.start) {
                // Still a click: open it, the way it did before dragging was a
                // thing this view knew about.
                textSize = existing.size
                ink = existing.ink
                onTextSizeAdopted(existing.size)
                onInkAdopted(existing.ink)
                beginTyping(at: existing.anchor, holding: existing.string)
            }
            return
        }
        if cropGrab != nil {
            endCrop()
            return
        }
        guard let anchor else {
            super.mouseUp(with: event)
            return
        }
        self.anchor = nil
        let endpoint = clamped(convert(event.locationInWindow, from: nil))
        let drawn = rect(from: anchor, to: endpoint)
        let longEnough = hypot(endpoint.x - anchor.x, endpoint.y - anchor.y) >= Self.minimumSide
        let boxLargeEnough = drawn.width >= Self.minimumSide && drawn.height >= Self.minimumSide
        guard tool == .line || tool == .arrow ? longEnough : boxLargeEnough else {
            marks.pending = nil
            marks.pendingHighlight = nil
            marks.pendingStroke = nil
            marks.needsDisplay = true
            return
        }
        let edit: ImageEdit
        switch tool {
        case .redact:
            marks.pending = drawn
            edit = .redact(drawn)
        case .line:
            marks.pendingStroke = (tool, anchor, endpoint)
            edit = .line(anchor, endpoint, ink)
        case .arrow:
            marks.pendingStroke = (tool, anchor, endpoint)
            edit = .arrow(anchor, endpoint, ink)
        case .rectangle:
            marks.pendingStroke = (tool, anchor, endpoint)
            edit = .rectangle(drawn, ink)
        case .highlight:
            marks.pendingHighlight = drawn
            edit = .highlight(drawn, ink)
        default:
            marks.pending = nil
            marks.pendingHighlight = nil
            marks.pendingStroke = nil
            return
        }
        marks.needsDisplay = true
        onEdit(edit)
    }

    /// Clamped to the image, because a drag that leaves the window is the normal
    /// way to redact something touching an edge and a rectangle hanging off the
    /// side would be silently trimmed later anyway.
    private func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
            .intersection(bounds)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    // MARK: - The crop frame

    /// A crop that has been made is adjusted; one that has not is drawn.
    ///
    /// Dragging a fresh rectangle *every* time is how the first version worked,
    /// and it makes "a bit more off the left" into "draw the whole thing again,
    /// and hope the other three edges land where they were". So once there is a
    /// frame, every corner stays draggable and the whole thing can be slid —
    /// which is what makes trimming one side a gesture instead of a redo.
    ///
    /// Before there is one, a drag draws it. See the `chosen != nil` below for
    /// what happened when it did not.
    private func beginCrop(at point: CGPoint) {
        let chosen = draft ?? crop
        let frame = chosen ?? bounds
        let grab = Self.cornerGrab
        let nearMinX = abs(point.x - frame.minX) <= grab
        let nearMaxX = abs(point.x - frame.maxX) <= grab
        let nearMinY = abs(point.y - frame.minY) <= grab
        let nearMaxY = abs(point.y - frame.maxY) <= grab

        draft = frame
        if (nearMinX || nearMaxX) && (nearMinY || nearMaxY) {
            cropGrab = .corner(atMinX: nearMinX, atMinY: nearMinY)
        } else if chosen != nil, frame.contains(point) {
            // Only a frame somebody has actually drawn can be slid about.
            //
            // Before this it was any frame — and with nothing cropped yet the
            // frame *is* the whole picture, so every press inside it was a move.
            // A move that is already against all four edges is clamped to
            // exactly where it started, so the first thing anyone does with a
            // crop tool — drag a rectangle around the part they want — did
            // nothing whatsoever. Not a subtle failure: the tool looked broken,
            // and the only way through was to guess that the corners were
            // handles.
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
        // The draft stays up until the cropped picture arrives — the same
        // stand-in every other tool leaves behind. Clearing it here put the
        // whole uncropped picture back on screen, undimmed, for the length of a
        // render: one frame of "nothing happened" between letting go and the
        // crop appearing.
        onEdit(.crop(frame))
    }

    // MARK: - Typing

    var isTyping: Bool { box != nil }

    var typingAnchorForTest: CGPoint { typingAnchor }

    var hoverForTest: CGRect? { marks.hover }

    var marksAreVisibleForTest: Bool { !marks.isHidden && marks.alphaValue > 0 }


    /// The attributes every typed line is drawn with, here and in the renderer.
    ///
    /// The paragraph style is the load-bearing part: pinning the line height to
    /// `ImageEdit.textLineHeight(at: textSize)` is what makes TextKit put a second line where
    /// `ImageEdit.render` will put it. Kerning is nailed to zero for the reason
    /// `typeset` gives — the system font's tracking table is applied differently
    /// by the two typesetters, and on Han characters the difference is visible.
    /// What every line is drawn with, here and in the renderer — shadow
    /// included.
    ///
    /// The shadow is not decoration and it is not optional: `ImageEdit.render`
    /// draws one under every annotation, so text without it is text that will
    /// change the moment it is committed. It did, and it was reported three
    /// times as the words "shaking" or "getting smaller" — measured on the
    /// reporter's own screenshots, the box was carrying fourteen per cent more
    /// ink than the same words rendered, because a shadow eats into the contrast
    /// at every glyph edge.
    private func typingAttributes(shadowed: Bool = true) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ImageEdit.textLineHeight(at: textSize)
        paragraph.maximumLineHeight = ImageEdit.textLineHeight(at: textSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: textSize),
            .foregroundColor: NSColor(cgColor: ink.colour.stroke) ?? .systemRed,
            .kern: 0,
            .tracking: 0,
            .paragraphStyle: paragraph,
        ]
        guard shadowed else { return attributes }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        attributes[.shadow] = shadow
        return attributes
    }

    /// An `NSTextView` rather than an `NSTextField`, for two reasons that turned
    /// out to be one.
    ///
    /// A field is one line: long text ran off the end of it and could not be
    /// read back. And a field's text is inset and centred by amounts its cell
    /// does not publish, which meant the box had to be *probed* — draw a glyph,
    /// find its ink, work backwards — to sit where the render would. A text view
    /// with `textContainerInset` and `lineFragmentPadding` both zero puts the
    /// first baseline exactly one ascent below its top edge, and that is a
    /// number, not a measurement.
    /// `holding` re-opens an annotation that was already made: the anchor is its
    /// own, not the pointer's, so the words stay exactly where they were.
    private func beginTyping(at point: CGPoint, holding existing: String? = nil) {
        commitTyping()
        // The click lands in the middle of the first line, and the anchor is that
        // line's *top* — a constant, unlike its baseline, which moves with
        // whatever script is typed into it.
        typingAnchor = existing == nil
            ? CGPoint(x: point.x, y: point.y + ImageEdit.textLineHeight(at: textSize) / 2)
            : point

        let view = TypingView(frame: CGRect(
            x: 0, y: 0, width: textSize * 4, height: ImageEdit.textLineHeight(at: textSize)))
        view.annotationSize = textSize
        view.annotationScale = textRasterScale
        // Re-opening starts while the old annotation is still baked into the
        // preview bitmap. Showing this second copy immediately does not move its
        // bounds, but it composites every antialiased edge twice and adds about
        // 2.7% ink — perceived as a tiny zoom/stretch. `clearPending` reveals
        // the live copy only after the old one has left the new preview.
        view.showsAnnotation = existing == nil
        view.originalString = existing
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Wrapped at the right edge of the picture, and nowhere else.
        //
        // The renderer wraps at the same width with the same line breaker, so
        // the lines in the box are the lines in the file. Anything narrower is a
        // box inventing breaks the picture does not have; anything wider — an
        // infinite container, which this was — lets a long sentence run off the
        // side of the picture where it cannot be read back.
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = CGSize(
            width: max(textSize * 4, bounds.width - point.x), height: .greatestFiniteMagnitude)
        view.annotationWrappingWidth = view.textContainer?.size.width ?? bounds.width
        view.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Rich text on, which reads backwards for a box that only ever holds one
        // style: with it *off*, `NSTextView` forces its own font and colour onto
        // everything typed and quietly drops the rest of the attributes — the
        // paragraph style that pins the line height, the kerning, the tracking.
        // Those three are the whole of what makes the typing and the render
        // agree, so they have to survive. `textDidChange` re-stamps the lot, so
        // nothing pasted in can bring its own style along.
        view.isRichText = true
        view.usesFontPanel = false
        view.font = NSFont.boldSystemFont(ofSize: textSize)
        view.annotationColour = ink.colour
        view.textColor = NSColor(cgColor: ink.colour.stroke) ?? .systemRed
        view.drawsBackground = false
        // Clipped to itself, which an `NSView` is not by default.
        //
        // This is the one that was actually painting the picture grey. A text
        // view draws its selection across the whole *line fragment*, and the
        // fragments here are as wide as the container — ten million points, so
        // that nothing wraps. Nothing stops that drawing at the edge of the box
        // unless the box is told to clip, so a drag-selection filled the canvas
        // with highlight while the box itself stayed the size of its words.
        view.clipsToBounds = true

        // Neither: this view does not get to decide how big it is.
        //
        // A resizable text view sizes itself to its container, and the container
        // here is infinitely wide so that nothing wraps. That is fine until a
        // drag-selection, which makes AppKit lay the view out again — and the
        // box balloons to something the size of its container, with the
        // selection highlight painted across all of it. `place` is the only
        // thing that sets this frame, and it sets it to the width of the words.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.typingAttributes = typingAttributes()
        view.insertionPointColor = NSColor(cgColor: ink.colour.stroke) ?? .systemRed
        // Selected text keeps its own colour on a tint, instead of the system's
        // default — which is a grey plate with white letters on it, drawn across
        // the full width of every selected line, and looks for all the world
        // like the annotation has been replaced by a grey box. It is only
        // AppKit's unfocused-selection style, but nothing about it says so.
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.35),
        ]
        view.delegate = self
        view.layoutManager?.delegate = self
        view.onCommit = { [weak self] in self?.commitTyping() }
        view.onCancel = { [weak self] in _ = self?.cancelTyping() }
        view.onMarkedTextChange = { [weak self, weak view] in
            guard let view else { return }
            self?.typingContentsDidChange(view)
        }
        marks.hover = nil
        addSubview(view)
        box = view
        if let existing {
            view.textStorage?.setAttributedString(NSAttributedString(
                string: existing, attributes: typingAttributes()))
        }
        place(view)
        window?.makeFirstResponder(view)
        if existing != nil {
            view.setSelectedRange(NSRange(location: (existing! as NSString).length, length: 0))
        }
        marks.typing = view.frame
        marks.needsDisplay = true
    }

    /// Top-anchored: the first baseline stays on the anchor and new lines grow
    /// downwards, which is where a second line goes.
    private func place(_ view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        // Counted in lines, not measured in points. A line of Han characters is
        // three points shorter than a line of Latin ones, so a box sized to what
        // its text happens to need changes height as soon as the two are mixed —
        // which is a box that twitches while you type in it. Every line is one
        // pinned line height, and the box is however many of those there are.
        let height = CGFloat(max(1, lineCount(of: layout))) * ImageEdit.textLineHeight(at: textSize)
        // The glyphs' own width plus a caret, and no more.
        //
        // Measured with `boundingRect(forGlyphRange:in:)` rather than
        // `usedRect(for:)`, which answers with the *container's* width — and this
        // container is ten million points wide so that nothing ever wraps. A box
        // that wide is invisible until something is selected, at which point the
        // selection fills its line to the end of the box and paints a highlight
        // across the entire picture.
        let renderedWidth = ImageEdit.bounds(
            ofText: view.string, at: .zero, size: textSize,
            within: CGSize(width: container.size.width, height: .greatestFiniteMagnitude)).width
        let width = max(textSize, inkedWidth(of: layout), renderedWidth) + 2

        view.setFrameSize(CGSize(width: width, height: height))
        // The view is flipped and the canvas is not, so its top edge is
        // `frame.maxY` — and the anchor *is* that top edge. Nothing here reads
        // the text's metrics, which is the point: the frame used to be placed by
        // asking TextKit where it had put the first baseline, and that answer
        // changes by a point when the first line stops being pure Chinese. The
        // compensation arrived a frame after the layout it was compensating for,
        // so the line twitched every time the script changed.
        view.setFrameOrigin(CGPoint(x: typingAnchor.x, y: typingAnchor.y - height))
    }

    /// The widest line's *used* width, walked fragment by fragment.
    ///
    /// Neither `usedRect(for:)` nor `boundingRect(forGlyphRange:in:)` will do:
    /// both answer with the container's width, and this container is ten million
    /// points wide so that nothing wraps. `lineFragmentUsedRect` is the one that
    /// reports where the glyphs stop.
    private func inkedWidth(of layout: NSLayoutManager) -> CGFloat {
        var width: CGFloat = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var effective = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &effective)
            width = max(width, used.maxX)
            glyph = max(effective.upperBound, glyph + 1)
        }
        return width
    }

    private func lineCount(of layout: NSLayoutManager) -> Int {
        var lines = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var effective = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            lines += 1
            glyph = max(effective.upperBound, glyph + 1)
        }
        // A trailing newline gets no fragment of its own until something is
        // typed into it, and a box that does not grow when ⏎ is pressed reads as
        // ⏎ having done nothing.
        if box?.string.hasSuffix("\n") == true { lines += 1 }
        return lines
    }

    /// Pushes what has been typed into the list, if anything has been.
    ///
    /// The view stays on screen afterwards, inert, until the render that
    /// contains its words arrives — the same trick `marks.pending` plays for a
    /// redaction and `pendingMarker` for a number. Removing it at the moment of
    /// commit is the obvious thing and it makes the text blink out for the
    /// length of a decode and a render, which reads as having lost it.
    func commitTyping() {
        guard let view = box else { return }
        box = nil
        marks.typing = nil
        marks.needsDisplay = true
        let string = view.string
        onFocusReturn()
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            view.removeFromSuperview()
            // A commit all the same, and the difference matters upstream: an
            // annotation re-opened and emptied out is one that has been deleted,
            // not one that was left alone.
            onTypingFinished(true)
            return
        }
        view.isEditable = false
        view.isSelectable = false
        view.textStorage?.setAttributes(
            typingAttributes(),
            range: NSRange(location: 0, length: (string as NSString).length))
        committed?.removeFromSuperview()
        committed = view
        onEdit(.text(typingAnchor, string, textSize, ink))
        onTypingFinished(true)
    }

    /// Answers whether there was any typing to cancel, because Escape means
    /// something else entirely when there is not.
    @discardableResult
    func cancelTyping() -> Bool {
        guard let view = box else { return false }
        box = nil
        marks.typing = nil
        marks.needsDisplay = true
        view.removeFromSuperview()
        onFocusReturn()
        onTypingFinished(false)
        return true
    }

    /// Pins every line's baseline to the same place inside its box.
    ///
    /// This is the hook that makes typing hold still. Without it TextKit sets the
    /// baseline from the line's own metrics, and a line of Han characters has a
    /// shallower descent than one with Latin in it — so adding a single letter to
    /// a Chinese line lifted every glyph in it by a point and a half. The
    /// renderer uses the same constant, so what is typed and what is drawn agree
    /// line for line.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        baselineOffset.pointee = ImageEdit.textBaselineFromTop(at: textSize)
        return true
    }



    func textDidChange(_ notification: Notification) {
        guard let view = box else { return }
        // Re-stamped over everything, not just applied to what is typed next:
        // pasted text arrives with whatever attributes it was copied with, and
        // one pasted word in the system's default tracking is exactly the kind
        // of difference that shows up as a twitch on commit.
        view.textStorage?.setAttributes(
            typingAttributes(),
            range: NSRange(location: 0, length: (view.string as NSString).length))
        typingContentsDidChange(view)
    }

    /// Shared by ordinary committed input and an IME's in-progress marked text.
    /// AppKit does not promise `textDidChange` for every marked-text update, but
    /// the box must grow while 拼音 is still underlined, not only after a
    /// candidate is chosen.
    private func typingContentsDidChange(_ view: TypingView) {
        if let original = view.originalString, view.string != original {
            view.originalString = nil
            view.revealsAfterPreviewUpdate = true
            onTypingNeedsCleanPreview()
        }
        place(view)
        view.needsDisplay = true
        marks.typing = view.frame
        marks.needsDisplay = true
    }
}

/// The box being typed into.
///
/// ⏎ is a newline, because text on a screenshot is often two lines and a key
/// that ends the sentence cannot also break it. ⌘⏎ finishes — as does clicking
/// anywhere else, which is what most people do — and Escape throws it away.
private final class TypingView: NSTextView {
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMarkedTextChange: () -> Void = {}
    var annotationSize: CGFloat = ImageEdit.textSize
    var annotationScale: CGFloat = 1
    var annotationWrappingWidth: CGFloat = .greatestFiniteMagnitude
    var annotationColour: InkColour = .red
    var showsAnnotation = true
    var originalString: String?
    var revealsAfterPreviewUpdate = false

    /// TextKit owns editing, selection and the insertion point, but not the
    /// visible glyphs.  The flattened annotation is rasterised by CoreText and
    /// NSTextView's screen drawing can snap the very same fractional advances
    /// four pixels wider at 40 pt.  Drawing the visible line through the output
    /// renderer removes that last state-dependent change while leaving native
    /// text interaction intact.
    override func draw(_ dirtyRect: NSRect) {
        let range = NSRange(location: 0, length: (string as NSString).length)
        if range.length > 0 {
            layoutManager?.addTemporaryAttribute(
                .foregroundColor, value: NSColor.clear, forCharacterRange: range)
        }
        super.draw(dirtyRect)
        if range.length > 0 {
            layoutManager?.removeTemporaryAttribute(
                .foregroundColor, forCharacterRange: range)
        }

        guard showsAnnotation, !string.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }
        ImageEdit.drawEditorText(
            string, size: annotationSize, unit: annotationScale,
            wrappingAt: annotationWrappingWidth, colour: annotationColour, in: context)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers == "\r" {
            onCommit()
            return
        }
        super.keyDown(with: event)
    }

    override func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        super.setMarkedText(
            string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// Never scrolls the picture to show itself.
    ///
    /// `NSTextView` asks to be scrolled into view when it takes the keyboard and
    /// again as the caret moves, and it is inside the scroll view that holds the
    /// picture — so opening a box near an edge slid the whole capture under the
    /// pointer. From the outside that is the text jumping the moment you click
    /// it, which is exactly what it was reported as. The box is always placed
    /// inside the picture, so there is nothing it needs scrolled into view.
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func scroll(_ point: NSPoint) {}

    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
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
    var pendingHighlight: CGRect?
    var pendingStroke: (tool: ImageEditor.Tool, start: CGPoint, end: CGPoint)?
    var pendingMarker: (centre: CGPoint, number: Int)?
    /// The crop frame, when the crop tool is holding one.
    var crop: CGRect?
    /// Whether anything is actually being thrown away yet.
    var dimsOutsideCrop = false
    /// The box being typed into. Drawn as a dashed outline rather than filled,
    /// because what goes into the file is the words and not a plate behind them.
    var typing: CGRect?
    /// A piece of text the pointer is over and the text tool could re-open.
    var hover: CGRect?
    /// The mark the pointer has picked out, framed so it is obvious which one ⌫
    /// is about to take away.
    var selection: CGRect?
    /// What the marks in progress are drawn in, so what is being dragged is the
    /// colour it will land in.
    var ink = Ink.default

    /// How far outside the words every outline sits — the hover highlight and
    /// the box being typed in alike.
    ///
    /// One number, because the two are the same annotation half a second apart:
    /// hovering draws a plate around the words, clicking replaces it with the
    /// typing frame, and if those are different sizes the words look like they
    /// moved when they did not. They were 4 and 2 points, and the report was
    /// "there is still an offset at the moment of clicking — is it the padding?"
    static let outlineInset = CGSize(width: 3, height: 2)

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
        if let pendingHighlight {
            // The same multiply the renderer uses. An alpha wash here would be a
            // different colour from the one that lands in the file, and the
            // swap at the end of the render would read as the highlight
            // shifting shade the moment it was committed.
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .multiply
            (NSColor(cgColor: ink.colour.wash) ?? .systemYellow).setFill()
            NSBezierPath(rect: pendingHighlight).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        if let pendingStroke { drawStroke(pendingStroke) }
        if let pendingMarker { drawMarker(pendingMarker) }
        if let hover, typing == nil {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            let plate = NSBezierPath(
                roundedRect: hover.insetBy(
                    dx: -Self.outlineInset.width, dy: -Self.outlineInset.height),
                xRadius: 4, yRadius: 4)
            plate.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            plate.lineWidth = 1
            plate.stroke()
        }
        if let typing { drawTyping(typing) }
        if let selection { drawSelection(selection) }
    }

    /// A dashed frame with four solid corners, in the accent colour — the same
    /// vocabulary as the crop's handles, because it means the same thing: this
    /// is the thing the next gesture acts on.
    private func drawSelection(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -5, dy: -5)
        NSColor(white: 0, alpha: 0.45).setStroke()
        let backing = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        backing.lineWidth = 3
        backing.stroke()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1.5
        outline.setLineDash([5, 3], count: 2, phase: 0)
        outline.stroke()
    }

    /// The box being typed into, and the one thing it has to say for itself.
    ///
    /// A text view has no placeholder, and the sentence that used to be in one
    /// is wrong now anyway: ⏎ breaks the line, so the key that finishes has to
    /// be named somewhere. Under the box rather than inside it, so an empty box
    /// is an empty box and not a box with grey words sitting in it.
    private func drawTyping(_ frame: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: frame.insetBy(
            dx: -Self.outlineInset.width, dy: -Self.outlineInset.height))
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.7)
        shadow.shadowBlurRadius = 3
        ("⌘⏎ to finish" as NSString).draw(
            at: CGPoint(x: frame.minX - 2, y: frame.minY - 17),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.75),
                .shadow: shadow,
            ])
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

    private func drawStroke(
        _ stroke: (tool: ImageEditor.Tool, start: CGPoint, end: CGPoint)
    ) {
        let color = NSColor(cgColor: ink.colour.stroke) ?? .systemRed
        let width = ImageEdit.strokeWidth * ink.weight.strokeScale
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        color.setStroke()

        let path: NSBezierPath
        if stroke.tool == .rectangle {
            let rect = CGRect(
                x: min(stroke.start.x, stroke.end.x),
                y: min(stroke.start.y, stroke.end.y),
                width: abs(stroke.end.x - stroke.start.x),
                height: abs(stroke.end.y - stroke.start.y))
            path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        } else {
            path = NSBezierPath()
            path.move(to: stroke.start)
            path.line(to: stroke.end)
            if stroke.tool == .arrow {
                let angle = atan2(
                    stroke.end.y - stroke.start.y, stroke.end.x - stroke.start.x)
                let head = ImageEdit.arrowHeadLength * ink.weight.strokeScale
                for turn in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                    path.move(to: stroke.end)
                    path.line(to: CGPoint(
                        x: stroke.end.x + cos(angle + turn) * head,
                        y: stroke.end.y + sin(angle + turn) * head))
                }
            }
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The same red circle the renderer draws, for the moment between the click
    /// and the render that makes it real.
    private func drawMarker(_ marker: (centre: CGPoint, number: Int)) {
        let radius = ImageEdit.markerRadius * ink.weight.markerScale
        let circle = CGRect(
            x: marker.centre.x - radius, y: marker.centre.y - radius,
            width: radius * 2, height: radius * 2)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        (NSColor(cgColor: ink.colour.stroke) ?? .systemRed).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let label = "\(marker.number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: radius * 1.15),
            .foregroundColor: NSColor(cgColor: ink.colour.onStroke) ?? .white,
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
/// Icon-only tools with tooltips rather than words. Titled pills for nine tools
/// is a bar wider than the window a small capture opens in, and the tools are a
/// set the eye should read as one control rather than as a row of sentences.
///
/// **Two rows, and that is the redesign.** One row of nine 37-point squares was
/// the whole editor: no colour, no weight, no redo button, and nothing to press
/// to delete the mark you had just drawn in the wrong place. Everything a person
/// could reach for was either a keystroke nobody had been told about or a run of
/// ⌘Z. The tools and the actions keep the top row; what a mark is *made of* —
/// colour, weight, size — gets its own, laid out as swatches you can see rather
/// than menus you have to open.
private final class EditToolbar: NSView {
    var onTool: (ImageEditor.Tool) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onDelete: () -> Void = {}
    var onTextSize: (CGFloat) -> Void = { _ in }
    var onColour: (InkColour) -> Void = { _ in }
    var onWeight: (InkWeight) -> Void = { _ in }

    private let content: NSView
    private let tools: [(tool: ImageEditor.Tool, pill: HUDPill)]
    private let swatches: [(colour: InkColour, view: InkSwatch)]
    private let weights: [(weight: InkWeight, view: WeightSwatch)]

    /// How big the next piece of text is: the number, and a menu of the sizes
    /// worth having behind it.
    ///
    /// A menu rather than a control that steps through them, which is what this
    /// was first: three sizes was too coarse to be called a size, and stepping
    /// through eight is worse than picking one. The pill shows the number and
    /// never changes width — every label is two digits — so the bar's geometry
    /// is still a constant.
    private let size = HUDPill(
        title: "20", mark: .symbol("textformat.size"),
        tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    private var currentSize = ImageEdit.textSize

    private let undo = HUDPill(
        title: "", mark: .symbol("arrow.uturn.backward"),
        tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    private let redo = HUDPill(
        title: "", mark: .symbol("arrow.uturn.forward"),
        tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    /// Deletes the picked mark. Red rather than accent-tinted: it is the only
    /// control in this window that takes something away without a step back
    /// being obvious, and it should not look like one more tool.
    private let bin = HUDPill(
        title: "", mark: .symbol("trash"), tint: .systemRed,
        height: EditMetrics.controlHeight, sizing: .editor)
    private let dividers = [
        EditMetrics.divider(x: 0), EditMetrics.divider(x: 0), EditMetrics.divider(x: 0),
    ]

    private static let toolMarks: [(tool: ImageEditor.Tool, symbol: String, help: String)] = [
        (.pointer, "cursorarrow",
         "Pick — select a mark to move, recolour or delete; zoom and scroll (V)"),
        (.redact, "square.grid.3x3.fill", "Redact — destroy the pixels under a rectangle (R)"),
        (.marker, "1.circle", "Number — drop a numbered marker (N)"),
        (.text, "textformat", "Text — type a note onto the picture (T)"),
        (.line, "line.diagonal", "Line — draw a straight line (L)"),
        (.arrow, "arrow.up.right", "Arrow — point at something (A)"),
        (.rectangle, "rectangle", "Box — outline a rectangle (B)"),
        (.highlight, "highlighter", "Highlight — tint without hiding what is under it (H)"),
        (.crop, "crop", "Crop — keep only what you drag around (C)"),
    ]

    init() {
        let box = CGRect(x: 0, y: 0, width: 640, height: EditMetrics.barHeight)
        let chrome = EditMetrics.chrome(in: box)
        content = chrome.content
        tools = Self.toolMarks.map { entry in
            let pill = HUDPill(
                title: "", mark: .symbol(entry.symbol), tint: .controlAccentColor,
                height: EditMetrics.controlHeight, sizing: .editor)
            pill.toolTip = entry.help
            return (entry.tool, pill)
        }
        swatches = InkColour.allCases.map { ($0, InkSwatch(colour: $0)) }
        weights = InkWeight.allCases.map { ($0, WeightSwatch(weight: $0)) }
        super.init(frame: box)
        addSubview(chrome.glass)

        size.onClick = { [weak self] in self?.showSizeMenu() }
        size.toolTip = "How big the next piece of text is — or the piece that is picked"
        undo.onClick = { [weak self] in self?.onUndo() }
        undo.toolTip = "Undo the last edit (⌘Z)"
        redo.onClick = { [weak self] in self?.onRedo() }
        redo.toolTip = "Put back what was undone (⇧⌘Z)"
        bin.onClick = { [weak self] in self?.onDelete() }
        bin.toolTip = "Delete the picked mark (⌫)"
        for (tool, pill) in tools {
            pill.onClick = { [weak self] in self?.onTool(tool) }
            pill.setSelected(false, animated: false)
            content.addSubview(pill)
        }
        for (colour, swatch) in swatches {
            swatch.onClick = { [weak self] in self?.onColour(colour) }
            swatch.toolTip = colour.label
            content.addSubview(swatch)
        }
        for (weight, swatch) in weights {
            swatch.onClick = { [weak self] in self?.onWeight(weight) }
            swatch.toolTip = "\(weight.label) — how heavy a line, a box or an arrow is"
            content.addSubview(swatch)
        }
        for divider in dividers { content.addSubview(divider) }
        for pill in [undo, redo, bin, size] { content.addSubview(pill) }
        setState(tool: .pointer, textSize: ImageEdit.textSize, ink: .default,
                 canUndo: false, canRedo: false, hasSelection: false, isBusy: false)
        setFrameSize(fittingSize)
        layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(
        tool: ImageEditor.Tool, textSize: CGFloat, ink: Ink,
        canUndo: Bool, canRedo: Bool, hasSelection: Bool, isBusy: Bool
    ) {
        for (candidate, pill) in tools {
            pill.setLive(!isBusy, animated: false)
            pill.setSelected(candidate == tool, animated: false)
        }
        for (colour, swatch) in swatches { swatch.isChosen = colour == ink.colour }
        for (weight, swatch) in weights { swatch.isChosen = weight == ink.weight }
        // The number itself, and tinted while the text tool is the one in force
        // so the size reads as belonging to it rather than to the picture.
        currentSize = textSize
        size.setTitle("\(Int(textSize))")
        size.setLive(!isBusy, animated: false)
        size.setSelected(tool == .text && !isBusy, animated: false)
        // Inert rather than hidden: a control that appears only once it becomes
        // usable moves whatever was beside it out from under the pointer already
        // heading for it — and here it would move the whole bar.
        undo.setLive(canUndo && !isBusy, animated: false)
        redo.setLive(canRedo && !isBusy, animated: false)
        bin.setLive(hasSelection && !isBusy, animated: false)
        bin.setSelected(hasSelection && !isBusy, animated: false)
    }

    /// Popped under the pill, with the size in force ticked.
    private func showSizeMenu() {
        let menu = NSMenu()
        for option in ImageEdit.textSizes {
            let item = NSMenuItem(
                title: "\(Int(option)) pt", action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(option)
            item.state = option == currentSize ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: CGPoint(x: size.frame.minX, y: size.frame.minY - 6),
                   in: content)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        onTextSize(CGFloat(sender.tag))
    }

    /// Where a tool's button is, for the self-test that presses the real one.
    func pillFrame(for tool: ImageEditor.Tool) -> CGRect? {
        tools.first { $0.tool == tool }?.pill.frame
    }

    /// Where a colour's swatch is, likewise.
    func swatchFrame(for colour: InkColour) -> CGRect? {
        swatches.first { $0.colour == colour }?.view.frame
    }

    func binFrame() -> CGRect { bin.frame }

    /// A constant, computed from the controls rather than typed out. Nothing
    /// about the state is in it — see the class comment.
    override var fittingSize: NSSize {
        CGSize(width: max(topRowWidth, styleRowWidth).rounded(), height: EditMetrics.barHeight)
    }

    private var topRowWidth: CGFloat {
        EditMetrics.margin * 2
            + tools.reduce(0) { $0 + $1.pill.frame.width }
            + CGFloat(tools.count - 1) * EditMetrics.gap
            + EditMetrics.groupGap * 2 + 1
            + undo.frame.width + EditMetrics.gap + redo.frame.width
            + EditMetrics.gap + bin.frame.width
    }

    private var styleRowWidth: CGFloat {
        EditMetrics.margin * 2
            + swatches.reduce(0) { $0 + $1.view.frame.width }
            + CGFloat(swatches.count - 1) * EditMetrics.gap
            + EditMetrics.groupGap * 2 + 1
            + weights.reduce(0) { $0 + $1.view.frame.width }
            + CGFloat(weights.count - 1) * EditMetrics.gap
            + EditMetrics.groupGap * 2 + 1
            + size.frame.width
    }

    /// Both rows centred inside the bar rather than left-aligned in it: they are
    /// different widths, and a short row hanging off the left of a long one reads
    /// as a layout that gave up.
    override func layout() {
        super.layout()
        let topY = EditMetrics.margin + EditMetrics.controlHeight + EditMetrics.rowGap
        var x = ((bounds.width - topRowWidth) / 2).rounded() + EditMetrics.margin
        for (index, entry) in tools.enumerated() {
            entry.pill.setFrameOrigin(CGPoint(x: x, y: topY))
            x += entry.pill.frame.width
            if index < tools.count - 1 { x += EditMetrics.gap }
        }
        x += EditMetrics.groupGap
        dividers[0].setFrameOrigin(CGPoint(x: x, y: topY + EditMetrics.dividerInset))
        x += 1 + EditMetrics.groupGap
        for pill in [undo, redo, bin] {
            pill.setFrameOrigin(CGPoint(x: x, y: topY))
            x += pill.frame.width + EditMetrics.gap
        }

        let styleY = EditMetrics.margin
        x = ((bounds.width - styleRowWidth) / 2).rounded() + EditMetrics.margin
        for (index, entry) in swatches.enumerated() {
            entry.view.setFrameOrigin(CGPoint(x: x, y: styleY))
            x += entry.view.frame.width
            if index < swatches.count - 1 { x += EditMetrics.gap }
        }
        x += EditMetrics.groupGap
        dividers[1].setFrameOrigin(CGPoint(x: x, y: styleY + EditMetrics.dividerInset))
        x += 1 + EditMetrics.groupGap
        for (index, entry) in weights.enumerated() {
            entry.view.setFrameOrigin(CGPoint(x: x, y: styleY))
            x += entry.view.frame.width
            if index < weights.count - 1 { x += EditMetrics.gap }
        }
        x += EditMetrics.groupGap
        dividers[2].setFrameOrigin(CGPoint(x: x, y: styleY + EditMetrics.dividerInset))
        x += 1 + EditMetrics.groupGap
        size.setFrameOrigin(CGPoint(x: x, y: styleY))
    }
}

/// The editor's own metrics.
///
/// Separate from `HUDMetrics` on purpose. Those numbers size a bar that appears
/// over someone's screen for a few seconds and is trying not to be in the way;
/// these size furniture in a window that is worked in. Sharing them is what made
/// the editor feel like a HUD that had been asked to do a job it was not built
/// for — nine 37-point squares in a 40-point strip.
enum EditMetrics {
    static let controlHeight: CGFloat = 36
    static let margin: CGFloat = 10
    static let gap: CGFloat = 5
    static let groupGap: CGFloat = 11
    /// Between the two rows of the toolbar.
    static let rowGap: CGFloat = 7
    static let cornerRadius: CGFloat = 20
    static let dividerInset: CGFloat = 5

    /// One row and its margins — the footer's height.
    static let rowHeight: CGFloat = margin * 2 + controlHeight
    /// Two rows and their margins — the toolbar's.
    static let barHeight: CGFloat = margin * 2 + controlHeight * 2 + rowGap

    static func chrome(in bounds: CGRect) -> (glass: NSGlassEffectView, content: NSView) {
        let chrome = HUDMetrics.chrome(in: bounds)
        chrome.glass.cornerRadius = cornerRadius
        return chrome
    }

    static func divider(x: CGFloat) -> NSView {
        let view = NSView(frame: CGRect(
            x: x, y: 0, width: 1, height: controlHeight - dividerInset * 2))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        return view
    }
}

/// One colour, shown as itself.
///
/// A row of eight of these rather than a menu behind a single well. A menu hides
/// the palette until it is opened, which means the answer to "can I make this
/// blue" is "open it and see"; eight squares in the bar answer it from across the
/// room, and picking one is one click rather than two.
private final class InkSwatch: NSView {
    var onClick: () -> Void = {}
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            needsDisplay = true
        }
    }

    static let width: CGFloat = 30

    private let colour: InkColour

    init(colour: InkColour) {
        self.colour = colour
        super.init(frame: CGRect(
            x: 0, y: 0, width: Self.width, height: EditMetrics.controlHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height) - 10
        let box = CGRect(
            x: ((bounds.width - side) / 2).rounded(),
            y: ((bounds.height - side) / 2).rounded(),
            width: side, height: side)
        // A hairline in white at a low alpha under every swatch, because two of
        // the eight are white and near-black: without it the white one is
        // invisible against the glass and the black one is a hole in the bar.
        let chip = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        (NSColor(cgColor: colour.stroke) ?? .systemRed).setFill()
        chip.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        chip.lineWidth = 1
        chip.stroke()

        guard isChosen else { return }
        // A ring around it rather than a tick on it: a tick has to be drawn in a
        // colour, and there is no one colour that reads on all eight.
        let ring = NSBezierPath(
            roundedRect: box.insetBy(dx: -3.5, dy: -3.5), xRadius: 10, yRadius: 10)
        ring.lineWidth = 2
        NSColor.white.setStroke()
        ring.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

/// One weight, drawn as a line of that weight.
///
/// The control says what it does by being what it does. "Thin / Medium / Thick"
/// as words needs reading; three lines of visibly different thickness does not,
/// and it is the same information.
private final class WeightSwatch: NSView {
    var onClick: () -> Void = {}
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            needsDisplay = true
        }
    }

    static let width: CGFloat = 40

    private let weight: InkWeight

    init(weight: InkWeight) {
        self.weight = weight
        super.init(frame: CGRect(
            x: 0, y: 0, width: Self.width, height: EditMetrics.controlHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            NSColor(white: 1, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        let thickness = ImageEdit.strokeWidth * weight.strokeScale
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 10, y: bounds.midY))
        line.line(to: CGPoint(x: bounds.width - 10, y: bounds.midY))
        line.lineWidth = thickness
        line.lineCapStyle = .round
        NSColor(white: 1, alpha: isChosen ? 1 : 0.7).setStroke()
        line.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

/// The strip under the picture: every way anything leaves this window.
///
/// It was one button. Copy does both halves of the same act — the clipboard and
/// a file beside the original — and that is still the one to press, so it is
/// still the only tinted one. But "beside the original, called (edited)" is one
/// answer to "where do you want this", and it was the only answer there was: a
/// picture wanted in a particular folder had to be copied and then pasted, and a
/// picture wanted as a link had to be shared from the preview card, which
/// uploads the *unedited* capture — the redaction quietly not coming with it.
///
/// Its geometry is a constant, like the toolbar's: no title changes with the
/// state, only what is tinted and what is inert.
private final class EditFooter: NSView {
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var onShare: () -> Void = {}
    var onDone: () -> Void = {}

    private let content: NSView
    private let copy = HUDPill(
        title: "Copy", mark: .symbol("doc.on.doc"), tint: .controlAccentColor,
        height: EditMetrics.controlHeight, sizing: .editor)
    private let save = HUDPill(
        title: "Save As…", mark: .symbol("square.and.arrow.down"),
        tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    private let share = HUDPill(
        title: "Share Link", mark: .symbol("link"), tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    private let done = HUDPill(
        title: "Done", mark: .symbol("xmark"), tint: NSColor(white: 1, alpha: 0.16),
        height: EditMetrics.controlHeight, sizing: .editor)
    private let dividers = [EditMetrics.divider(x: 0)]

    init() {
        let box = CGRect(x: 0, y: 0, width: 480, height: EditMetrics.rowHeight)
        let chrome = EditMetrics.chrome(in: box)
        content = chrome.content
        super.init(frame: box)
        addSubview(chrome.glass)
        copy.onClick = { [weak self] in self?.onCopy() }
        copy.toolTip = "Copy the edited picture, and save it beside the original (⌘C)"
        save.onClick = { [weak self] in self?.onSave() }
        save.toolTip = "Write the edited picture wherever you like (⇧⌘S)"
        share.onClick = { [weak self] in self?.onShare() }
        share.toolTip = "Upload the edited picture and copy the link"
        done.onClick = { [weak self] in self?.onDone() }
        done.toolTip = "Close the viewer (Esc). Anything not copied or saved is not kept."
        for pill in [copy, save, share, done] { content.addSubview(pill) }
        for divider in dividers { content.addSubview(divider) }
        setState(hasEdits: false, canShare: false, isBusy: false)
        setFrameSize(fittingSize)
        layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tinted once there is an edit to take away, and inert — never hidden —
    /// before that: an unedited capture can still be copied, but the accent
    /// colour is reserved for the press that has something new in it.
    ///
    /// Share Link is the exception to "nothing here is ever hidden", and it is
    /// the same exception `PreviewCardView.layoutActionBar` already makes for the
    /// same button: with no endpoint and no token there is nothing behind it, and
    /// a button that can only fail is worse than no button. This changes with a
    /// *setting*, not with the editing state, so the bar still never moves while
    /// anyone is working in it.
    func setState(hasEdits: Bool, canShare: Bool, isBusy: Bool) {
        copy.setSelected(hasEdits, animated: false)
        copy.setLive(!isBusy, animated: false)
        save.setLive(!isBusy, animated: false)
        share.setLive(!isBusy, animated: false)
        done.setLive(!isBusy, animated: false)
        guard share.isHidden == canShare else { return }
        share.isHidden = !canShare
        setFrameSize(fittingSize)
        needsLayout = true
        // The bar is centred by whoever owns it, so a change of width has to
        // reach them too.
        superview?.needsLayout = true
    }

    private var pills: [HUDPill] { [copy, save, share].filter { !$0.isHidden } }

    var shareIsShownForTest: Bool { !share.isHidden }

    override var fittingSize: NSSize {
        let width = EditMetrics.margin * 2
            + pills.reduce(0) { $0 + $1.frame.width }
            + CGFloat(max(0, pills.count - 1)) * EditMetrics.gap
            + EditMetrics.groupGap * 2 + 1
            + done.frame.width
        return CGSize(width: width.rounded(), height: EditMetrics.rowHeight)
    }

    override func layout() {
        super.layout()
        let midY = ((EditMetrics.rowHeight - EditMetrics.controlHeight) / 2).rounded()
        var x = EditMetrics.margin
        for pill in pills {
            pill.setFrameOrigin(CGPoint(x: x, y: midY))
            x += pill.frame.width + EditMetrics.gap
        }
        x += EditMetrics.groupGap - EditMetrics.gap
        dividers[0].setFrameOrigin(CGPoint(x: x, y: dividers[0].frame.minY))
        x += 1 + EditMetrics.groupGap
        done.setFrameOrigin(CGPoint(x: x, y: midY))
    }
}
