import AppKit

/// A sentence in the viewer, and at most one thing to do about it.
///
/// Not an `NSAlert`. The viewer's whole idiom is a floating strip over the
/// content, and the sentence this exists to say — that a link made before the
/// edit still serves what was edited — is one the user needs to be able to read
/// twice and act on, which is exactly what a modal takes away.
///
/// Shared by both editors rather than owned by either: the still's redaction and
/// the recording's trim both overwrite the staged file, so both have the same
/// thing to say afterwards and it must not be said two slightly different ways.
final class ViewerNotice: NSView {
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
