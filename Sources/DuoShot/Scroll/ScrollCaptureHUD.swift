import AppKit

/// The bar a scrolling-capture session lives behind: how tall the stitch has
/// grown, Done, and Cancel.
///
/// The recording HUD's shape, one size smaller. Like it, this face usually
/// arrives by adoption — the selection toolbar's window swaps its controls and
/// stays where it stands, so the bar the user pressed Start on is the bar they
/// press Done on.
final class ScrollCaptureHUDView: NSView {
    struct Callbacks {
        var done: () -> Void = {}
        var cancel: () -> Void = {}
    }

    private static let doneTitle = "Done"
    /// Wide enough for both "99 999 pt" and the "Scroll slower" hint, so the
    /// bar never changes width while the user is mid-scroll.
    private static let labelWidth: CGFloat = 96

    static var barSize: CGSize {
        let width = HUDMetrics.margin + labelWidth + HUDMetrics.groupGap
            + 1 + HUDMetrics.groupGap
            + HUDPill.width(for: doneTitle) + HUDMetrics.gap
            + HUDMetrics.iconWidth + HUDMetrics.margin
        return CGSize(width: width, height: HUDMetrics.height)
    }

    private var callbacks: Callbacks
    private let heightLabel = NSTextField(labelWithString: "0 pt")
    private var lastHeightText = "0 pt"
    private var hintRestore: Task<Void, Never>?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(frame: CGRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildSubviews() {
        var x = HUDMetrics.margin

        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        heightLabel.textColor = .labelColor
        heightLabel.alignment = .left
        heightLabel.cell?.usesSingleLineMode = true
        heightLabel.lineBreakMode = .byClipping
        heightLabel.wantsLayer = true
        heightLabel.toolTip = "How tall the capture has grown"
        heightLabel.sizeToFit()
        heightLabel.frame = CGRect(
            x: x, y: ((HUDMetrics.height - heightLabel.frame.height) / 2).rounded(),
            width: Self.labelWidth, height: heightLabel.frame.height)
        addSubview(heightLabel)
        x += Self.labelWidth + HUDMetrics.groupGap

        addSubview(HUDMetrics.divider(x: x))
        x += 1 + HUDMetrics.groupGap

        let done = HUDPill(
            title: Self.doneTitle, mark: .symbol("checkmark"), tint: .systemGreen)
        done.setFrameOrigin(CGPoint(
            x: x, y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()))
        done.onClick = { [weak self] in self?.callbacks.done() }
        done.toolTip = "Finish and keep the capture"
        addSubview(done)
        x += done.frame.width + HUDMetrics.gap

        let cancel = FirstMouseButton(frame: CGRect(
            x: x, y: ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded(),
            width: HUDMetrics.iconWidth, height: HUDMetrics.controlHeight))
        cancel.bezelStyle = .accessoryBarAction
        cancel.isBordered = false
        cancel.image = HUDMetrics.symbol("trash", pointSize: 13)
        cancel.contentTintColor = .secondaryLabelColor
        cancel.imagePosition = .imageOnly
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.toolTip = "Cancel and discard  ⎋"
        cancel.wantsLayer = true
        addSubview(cancel)
    }

    func setHeight(points: Int) {
        let text = "\(Self.grouped(points)) pt"
        lastHeightText = text
        guard hintRestore == nil else { return }
        heightLabel.stringValue = text
    }

    /// Borrows the height label's slot for a moment — same trick as the
    /// recording bar's "Starting…": the bar must not change width, so the word
    /// has to fit in space that already exists.
    func flashHint(_ text: String) {
        hintRestore?.cancel()
        heightLabel.stringValue = text
        heightLabel.textColor = .systemOrange
        hintRestore = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            hintRestore = nil
            heightLabel.stringValue = lastHeightText
            heightLabel.textColor = .labelColor
        }
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    @objc private func cancelTapped() {
        callbacks.cancel()
    }
}

/// Owns the bar for the length of one scrolling-capture session. The
/// `RecordingHUD` pattern, without the clock and the phases: a session is live
/// from the moment the bar appears.
@MainActor
final class ScrollCaptureHUD {
    private var panel: FloatingBarPanel?
    private var view: ScrollCaptureHUDView?
    private var anchor: (rect: CGRect, screen: NSScreen)?

    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    /// `adopting` is the bar the armed selection was just using — given one,
    /// nothing appears and nothing is dismissed; the window re-levels off the
    /// shielding layer, swaps its face and narrows to this bar's width.
    func show(
        under region: CGRect, on screen: NSScreen,
        adopting handedOver: FloatingBarPanel? = nil, hiddenFromCapture: Bool = true
    ) {
        guard panel == nil else { return }
        let size = ScrollCaptureHUDView.barSize

        var callbacks = ScrollCaptureHUDView.Callbacks()
        callbacks.done = { [weak self] in self?.onDone() }
        callbacks.cancel = { [weak self] in self?.onCancel() }
        let view = ScrollCaptureHUDView(callbacks: callbacks)

        let panel: FloatingBarPanel
        if let handedOver {
            panel = handedOver
            // Off the shielding level before the face lands: the selection's
            // level sits above every window, which is right while the overlay
            // shields the screen and wrong for a session whose whole point is
            // that the user now scrolls those windows.
            panel.assume(.recording)
            panel.setHiddenFromCapture(hiddenFromCapture)
        } else {
            panel = FloatingBarPanel(
                role: .recording, size: size, hiddenFromCapture: hiddenFromCapture)
            panel.setFrame(CGRect(
                origin: HUDPlacement.origin(for: size, under: region, on: screen),
                size: size), display: false)
            panel.orderFrontRegardless()
        }
        panel.setFace(view, animated: handedOver != nil)
        anchor = (region, screen)
        panel.morph(to: CGRect(
            origin: HUDPlacement.origin(for: size, under: region, on: screen),
            size: size), animated: handedOver != nil)
        self.panel = panel
        self.view = view
    }

    func setHeight(points: Int) {
        view?.setHeight(points: points)
    }

    func flashHint(_ text: String) {
        view?.flashHint(text)
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        view = nil
        anchor = nil
        panel.dismiss()
    }

    var isVisible: Bool { panel != nil }

    /// For `CaptureOptions.excludedWindowIDs`: the session photographs its
    /// region several times a second, and the bar must be in none of them.
    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    var frameForTest: CGRect? { panel?.frame }
}
