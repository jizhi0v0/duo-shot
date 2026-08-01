import AppKit

/// The still viewer's contents: the picture, and the one thing you are allowed
/// to do to it before it leaves.
///
/// Redaction lives in the viewer rather than on the preview card because it is
/// the only place the capture is shown large enough to point at. The card is a
/// 208-point tile — a rectangle drawn on it would be four points wide where it
/// mattered — and the overlay is long gone by the time anyone has read what they
/// just took a picture of.
///
/// The mode is deliberately explicit at both ends: nothing happens until Redact
/// is pressed, and nothing is written until Apply is. Escape leaves without
/// writing. That shape exists because the write cannot be taken back — see
/// `Redaction.apply(regions:toFileAt:)`, which overwrites the staged file so
/// that share, copy, drag and OCR cannot disagree about which version is real.
@MainActor
final class RedactionEditor: NSView {
    /// The staged file, which is both what is being shown and what will be
    /// overwritten. Every consumer of this capture reads this URL.
    private let url: URL
    /// The image's size in pixels, which is not its size in points: a 2× capture
    /// carries a DPI tag and `NSImage.size` honours it. This is the number the
    /// drawn rectangles are scaled into, because the redaction is applied to the
    /// bitmap and the bitmap has no idea what a point is.
    private let pixelSize: CGSize

    private let scrollView: ZoomingScrollView
    private let imageView: NSImageView
    private let canvas: RedactionCanvas
    private let bar: RedactionBar
    private let notice: RedactionNotice

    private var isRedacting = false
    /// True from Apply until the file has been rewritten. A second press in that
    /// window would redact the already-redacted file with the same rectangles,
    /// which is harmless, and would race the first write, which is not.
    private var isApplying = false

    /// Handed the fresh thumbnail after a successful write, so a preview card
    /// still on screen stops showing the pixels that no longer exist. Injected
    /// rather than reached for: this view has no business knowing the stack
    /// exists — see `ViewerWindowController.onImageRedacted`.
    var onRedacted: ((NSImage) -> Void)?

    init?(url: URL, image: NSImage, menu: NSMenu, frame: CGRect) {
        guard image.size.width >= 1, image.size.height >= 1 else { return nil }
        self.url = url
        // `representations` rather than a second decode: the image was just read
        // from this file and the rep carries the real pixel counts. Falling back
        // to the point size means a redaction on an image with no rep at all is
        // still applied in the right place, at 1×.
        let rep = image.representations.first
        self.pixelSize = CGSize(
            width: rep.map { CGFloat($0.pixelsWide) }.flatMap { $0 >= 1 ? $0 : nil }
                ?? image.size.width,
            height: rep.map { CGFloat($0.pixelsHigh) }.flatMap { $0 >= 1 ? $0 : nil }
                ?? image.size.height)

        let bounds = CGRect(origin: .zero, size: image.size)
        imageView = NSImageView(frame: bounds)
        canvas = RedactionCanvas(frame: bounds)
        scrollView = ZoomingScrollView(frame: CGRect(origin: .zero, size: frame.size))
        bar = RedactionBar()
        notice = RedactionNotice()
        super.init(frame: frame)

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        imageView.autoresizingMask = [.width, .height]
        canvas.addSubview(imageView)

        // On all four, and on purpose. The image view is the hit view over the
        // picture itself, the canvas over it while redacting, the scroll view
        // over the letterboxing around both, and this view is the window's
        // content view; a right-click that works on one but not the others reads
        // as the menu being broken rather than as a boundary anyone can see.
        imageView.menu = menu
        canvas.menu = menu
        scrollView.menu = menu
        self.menu = menu

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

        canvas.onRegionsChanged = { [weak self] in self?.refreshBar() }
        bar.onRedact = { [weak self] in self?.enterRedaction() }
        bar.onCancel = { [weak self] in self?.leaveRedaction() }
        bar.onApply = { [weak self] in self?.applyRedaction() }
        addSubview(bar)
        addSubview(notice)
        notice.isHidden = true
        refreshBar()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    private static let barInset: CGFloat = 14
    private static let noticeGap: CGFloat = 8

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let barSize = bar.fittingSize
        bar.frame = CGRect(
            x: ((bounds.width - barSize.width) / 2).rounded(),
            y: Self.barInset,
            width: barSize.width, height: barSize.height)
        guard !notice.isHidden else { return }
        // Capped to the window so a long sentence in a narrow viewer wraps
        // instead of hanging off both sides of it.
        let noticeSize = notice.fittingSize(inWidth: bounds.width - Self.barInset * 2)
        notice.frame = CGRect(
            x: ((bounds.width - noticeSize.width) / 2).rounded(),
            y: bar.frame.maxY + Self.noticeGap,
            width: noticeSize.width, height: noticeSize.height)
    }

    /// What the still viewer opens at, and what the window's Escape handler and
    /// the self-tests reach for.
    func zoomToFit() { scrollView.zoomToFit() }

    var magnification: CGFloat { scrollView.magnification }

    // MARK: - The mode

    private func enterRedaction() {
        isRedacting = true
        canvas.isActive = true
        refreshBar()
    }

    /// Answers whether there was a mode to leave, because Escape means "close the
    /// window" when there is not — see `ViewerWindow.cancelOperation`.
    @discardableResult
    func leaveRedaction() -> Bool {
        guard isRedacting else { return false }
        isRedacting = false
        canvas.isActive = false
        canvas.clear()
        refreshBar()
        return true
    }

    private func refreshBar() {
        bar.setState(
            isRedacting
                ? .drawing(hasRegions: !canvas.regions.isEmpty, isBusy: isApplying)
                : .idle)
        needsLayout = true
    }

    // MARK: - Applying

    private func applyRedaction() {
        let regions = pixelRegions()
        guard !regions.isEmpty, !isApplying else { return }
        isApplying = true
        refreshBar()

        Task { [url, weak self] in
            defer { self?.isApplying = false }
            do {
                let result = try await Self.redact(
                    regions, in: url, thumbnailCap: PreviewThumbnail.maximumSize)
                self?.adopt(result.image, thumbnail: result.thumbnail)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The redaction could not be written."
                Log.app.error("redact: \(reason, privacy: .public)")
                NSSound.beep()
                // The rectangles stay on screen and the mode stays open: the file
                // is untouched, so the only useful next move is to press Apply
                // again, and clearing the drawing would take that away.
                self?.notice.show(message: reason, action: nil)
                self?.showNotice()
                self?.refreshBar()
            }
        }
    }

    /// The rectangles the user drew, in the bitmap's own pixels.
    ///
    /// The canvas is the scroll view's document, so its bounds are the image's
    /// *point* size whatever the magnification is — zooming scales the view, not
    /// its coordinate system. That is the whole reason the rectangles are kept
    /// in the canvas rather than in window coordinates: the conversion is one
    /// ratio, and it is the same ratio at 1× and at 16×.
    private func pixelRegions() -> [CGRect] {
        Redaction.regions(
            canvas.regions, atPointSize: canvas.bounds.size, inPixels: pixelSize)
    }

    /// One hop off the main actor for both halves. The thumbnail is a downsample
    /// of the same full-resolution bitmap the redaction just produced, so doing
    /// it here saves handing a 5K image back across the boundary only to send it
    /// straight out again.
    @concurrent
    private nonisolated static func redact(
        _ regions: [CGRect], in url: URL, thumbnailCap: CGSize
    ) async throws -> sending (image: CGImage, thumbnail: NSImage) {
        let redacted = try await Redaction.apply(regions: regions, toFileAt: url)
        return (redacted, PreviewThumbnail.image(redacted, cap: thumbnailCap))
    }

    private func adopt(_ image: CGImage, thumbnail: NSImage) {
        // The *point* size, not the pixel size: the file's DPI tag survived the
        // rewrite, so the picture is the same size it was and the window must not
        // resize under the user because its contents were edited.
        imageView.image = NSImage(cgImage: image, size: canvas.bounds.size)
        leaveRedaction()
        onRedacted?(thumbnail)

        guard let link = ShareService.shared.existingLink(for: url) else { return }
        // The one thing a redaction cannot do is reach a link that already
        // exists. Said here, in the window where it happened, rather than in a
        // modal: the user has just finished a deliberate action and an alert
        // would be dismissed as the acknowledgement of that rather than read.
        notice.show(
            message: "This capture was already shared — that link still serves the "
                + "original pixels.",
            action: ("Revoke Link", { [weak self] in self?.revoke(link.key) }))
        showNotice()
    }

    private func revoke(_ key: String) {
        notice.setBusy(true)
        Task { [weak self] in
            let gone = await ShareService.shared.revoke(key)
            self?.notice.show(
                message: gone
                    ? "The link has been revoked. The original pixels are no longer served."
                    : "The link could not be revoked. Try again from Recent Links.",
                action: nil)
            self?.needsLayout = true
        }
    }

    private func showNotice() {
        notice.isHidden = false
        needsLayout = true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// Escape means "stop drawing" while there is drawing to stop, and only then
    /// the window's own "close". Handled here rather than in `ViewerWindow` so
    /// the mode does not have to be visible from the window.
    override func cancelOperation(_ sender: Any?) {
        guard !leaveRedaction() else { return }
        window?.performClose(nil)
    }

    // MARK: - Test hooks

    /// Adds a rectangle in the canvas's own coordinates — image points, origin
    /// bottom left — the way a completed drag would.
    func addRegionForTest(_ rect: CGRect) {
        enterRedaction()
        canvas.add(rect)
    }

    /// What `--selftest-redact` measures: the point-to-pixel conversion, which is
    /// the one piece of this that a 2× capture can silently get wrong.
    var pixelRegionsForTest: [CGRect] { pixelRegions() }

    var pixelSizeForTest: CGSize { pixelSize }
}

/// The scroll view's document: the picture, plus the rectangles drawn over it.
///
/// Invisible to event routing unless a redaction is in progress. That is what
/// keeps the viewer's existing behaviour intact — `hitTest` answering nil sends
/// every click, drag and scroll straight through to the scroll view, which is
/// where double-click-to-zoom and pinch-to-magnify already live.
private final class RedactionCanvas: NSView {
    var isActive = false {
        didSet {
            marks.isHidden = !isActive
            marks.needsDisplay = true
        }
    }

    /// Committed rectangles in this view's coordinates: image points, origin at
    /// the bottom left, unaffected by magnification.
    private(set) var regions: [CGRect] = []
    var onRegionsChanged: () -> Void = {}

    /// Below the smallest rectangle worth having. A click with a pixel of travel
    /// is a click, and a one-point redaction would be an invisible mark on the
    /// file that nobody could see they had made.
    private static let minimumSide: CGFloat = 4

    private var anchor: CGPoint?
    private let marks = RedactionMarks()

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
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isActive else {
            super.mouseDown(with: event)
            return
        }
        anchor = convert(event.locationInWindow, from: nil)
        marks.pending = nil
        marks.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else {
            super.mouseDragged(with: event)
            return
        }
        marks.pending = rect(from: anchor, to: convert(event.locationInWindow, from: nil))
        marks.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else {
            super.mouseUp(with: event)
            return
        }
        self.anchor = nil
        let drawn = rect(from: anchor, to: convert(event.locationInWindow, from: nil))
        marks.pending = nil
        guard drawn.width >= Self.minimumSide, drawn.height >= Self.minimumSide else {
            marks.needsDisplay = true
            return
        }
        add(drawn)
    }

    func add(_ rect: CGRect) {
        regions.append(rect)
        marks.regions = regions
        marks.needsDisplay = true
        onRegionsChanged()
    }

    func clear() {
        regions.removeAll()
        marks.regions = []
        marks.pending = nil
        marks.needsDisplay = true
        onRegionsChanged()
    }

    /// Clamped to the image, because a drag that leaves the window is the normal
    /// way to redact something touching an edge and a rectangle hanging off the
    /// side would be silently trimmed later anyway.
    private func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
            .intersection(bounds)
    }
}

/// Draws the rectangles over the picture.
///
/// A separate view above the image rather than the canvas's own `draw` because
/// subviews are composited on top of their superview's drawing: marks drawn by
/// the canvas would be underneath the image and therefore invisible.
private final class RedactionMarks: NSView {
    var regions: [CGRect] = []
    /// The one being dragged right now, drawn the same way so what is being
    /// promised is what will be delivered.
    var pending: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Nearly opaque, not a light wash. The rectangle is a promise that
        // whatever is under it will be destroyed, and a tint you can still read
        // through invites the reading that it is a highlight.
        NSColor(white: 0.06, alpha: 0.88).setFill()
        NSColor(red: 1, green: 0.45, blue: 0.3, alpha: 0.9).setStroke()
        for rect in regions + (pending.map { [$0] } ?? []) {
            let path = NSBezierPath(rect: rect)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// The strip along the bottom of the viewer.
private final class RedactionBar: NSView {
    enum State {
        case idle
        case drawing(hasRegions: Bool, isBusy: Bool)
    }

    var onRedact: () -> Void = {}
    var onCancel: () -> Void = {}
    var onApply: () -> Void = {}

    private let content: NSView
    private let hint = NSTextField(labelWithString: "")
    private let redact = HUDPill(
        title: "Redact", mark: .symbol("rectangle.dashed"),
        tint: NSColor(white: 1, alpha: 0.16))
    private let cancel = HUDPill(
        title: "Cancel", mark: .symbol("xmark"), tint: NSColor(white: 1, alpha: 0.16))
    /// Red rather than the accent colour: Apply overwrites the file and cannot be
    /// undone, and the button is the last place to say so.
    private let apply = HUDPill(
        title: "Apply", mark: .symbol("checkmark"), tint: .systemRed)

    private static let hintText = "Drag over anything that should not leave this Mac."
    private var state: State = .idle

    init() {
        let box = CGRect(x: 0, y: 0, width: 320, height: HUDMetrics.height)
        let chrome = HUDMetrics.chrome(in: box)
        content = chrome.content
        super.init(frame: box)
        addSubview(chrome.glass)

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = Self.hintText
        content.addSubview(hint)

        redact.onClick = { [weak self] in self?.onRedact() }
        cancel.onClick = { [weak self] in self?.onCancel() }
        apply.onClick = { [weak self] in self?.onApply() }
        for pill in [redact, cancel, apply] { content.addSubview(pill) }
        setState(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(_ state: State) {
        self.state = state
        switch state {
        case .idle:
            redact.isHidden = false
            cancel.isHidden = true
            apply.isHidden = true
            hint.isHidden = true
        case .drawing(let hasRegions, let isBusy):
            redact.isHidden = true
            cancel.isHidden = false
            apply.isHidden = false
            hint.isHidden = false
            hint.stringValue = isBusy ? "Rewriting the file…" : Self.hintText
            // Inert rather than hidden until something has been drawn: Apply
            // appearing halfway through the gesture would move Cancel out from
            // under the pointer heading for it.
            apply.setLive(hasRegions && !isBusy, animated: false)
            cancel.setLive(!isBusy, animated: false)
        }
        hint.sizeToFit()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override var fittingSize: NSSize {
        var width = HUDMetrics.margin * 2
        switch state {
        case .idle:
            width += redact.frame.width
        case .drawing:
            width += hint.frame.width + HUDMetrics.groupGap
                + cancel.frame.width + HUDMetrics.gap + apply.frame.width
        }
        return CGSize(width: width.rounded(), height: HUDMetrics.height)
    }

    override func layout() {
        super.layout()
        let midY = ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()
        var x = HUDMetrics.margin
        switch state {
        case .idle:
            redact.setFrameOrigin(CGPoint(x: x, y: midY))
        case .drawing:
            hint.setFrameOrigin(CGPoint(
                x: x, y: ((HUDMetrics.height - hint.frame.height) / 2).rounded()))
            x += hint.frame.width + HUDMetrics.groupGap
            cancel.setFrameOrigin(CGPoint(x: x, y: midY))
            x += cancel.frame.width + HUDMetrics.gap
            apply.setFrameOrigin(CGPoint(x: x, y: midY))
        }
    }
}

/// A sentence in the window, and at most one thing to do about it.
///
/// Not an `NSAlert`. The viewer's whole idiom is a floating strip over the
/// picture, and the sentence this exists to say — that a link made before the
/// redaction still serves what was redacted — is one the user needs to be able
/// to read twice and act on, which is exactly what a modal takes away.
private final class RedactionNotice: NSView {
    private let content: NSView
    private let label = NSTextField(wrappingLabelWithString: "")
    private var pill: HUDPill?
    private var action: (() -> Void)?

    private static let verticalPadding: CGFloat = 10

    init() {
        let box = CGRect(x: 0, y: 0, width: 360, height: HUDMetrics.height)
        let chrome = HUDMetrics.chrome(in: box)
        content = chrome.content
        super.init(frame: box)
        addSubview(chrome.glass)

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        content.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(message: String, action: (title: String, run: () -> Void)?) {
        label.stringValue = message
        pill?.removeFromSuperview()
        pill = nil
        self.action = action?.run
        guard let action else { return }
        let button = HUDPill(
            title: action.title, mark: .symbol("link.badge.plus"),
            tint: NSColor(white: 1, alpha: 0.16))
        button.onClick = { [weak self] in self?.action?() }
        content.addSubview(button)
        pill = button
    }

    func setBusy(_ busy: Bool) { pill?.setLive(!busy, animated: false) }

    /// Sized against the width it will be given, because the message wraps and
    /// its height is therefore a function of that width rather than a constant.
    func fittingSize(inWidth available: CGFloat) -> CGSize {
        let pillWidth = pill.map { $0.frame.width + HUDMetrics.groupGap } ?? 0
        let textLimit = max(120, min(420, available - HUDMetrics.margin * 2 - pillWidth))
        let height = label.sizeThatFits(
            CGSize(width: textLimit, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: HUDMetrics.margin, y: Self.verticalPadding,
                             width: textLimit, height: height)
        let boxHeight = max(HUDMetrics.height, height + Self.verticalPadding * 2)
        label.setFrameOrigin(CGPoint(
            x: HUDMetrics.margin, y: ((boxHeight - height) / 2).rounded()))
        if let pill {
            pill.setFrameOrigin(CGPoint(
                x: HUDMetrics.margin + textLimit + HUDMetrics.groupGap,
                y: ((boxHeight - pill.frame.height) / 2).rounded()))
        }
        return CGSize(
            width: (HUDMetrics.margin * 2 + textLimit + pillWidth).rounded(),
            height: boxHeight.rounded())
    }
}
