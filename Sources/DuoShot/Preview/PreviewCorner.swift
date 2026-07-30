import AppKit

/// Which corner the preview stack hugs.
///
/// The corner decides three things together, and they have to stay consistent:
/// where the panel sits, which end of the column the newest card occupies, and
/// which way a card is thrown to dismiss it. The newest card always sits *at*
/// the anchored corner so its position never depends on how many cards are
/// present — that is the whole reason the stack has an anchor.
nonisolated enum PreviewCorner: String, CaseIterable, Codable, Sendable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var title: String {
        switch self {
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        case .topRight: "Top right"
        case .topLeft: "Top left"
        }
    }

    var isTop: Bool {
        self == .topLeft || self == .topRight
    }

    var isTrailing: Bool {
        self == .bottomRight || self == .topRight
    }

    /// A card is thrown off the screen edge the stack lives against: left for a
    /// left corner, right for a right corner.
    var swipeDirection: CGFloat {
        isTrailing ? 1 : -1
    }

    func panelOrigin(in visibleFrame: CGRect, panelSize: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(
            x: isTrailing
                ? visibleFrame.maxX - inset - panelSize.width
                : visibleFrame.minX + inset,
            y: isTop
                ? visibleFrame.maxY - inset - panelSize.height
                : visibleFrame.minY + inset
        )
    }

    /// Y of the card `slot` places away from the anchor, in the document view's
    /// (non-flipped, y-up) coordinates.
    func cardY(slot: Int, cardHeight: CGFloat, pitch: CGFloat, contentHeight: CGFloat) -> CGFloat {
        isTop
            ? contentHeight - cardHeight - CGFloat(slot) * pitch
            : CGFloat(slot) * pitch
    }

    /// Scroll offset that keeps the newest card in view.
    func scrollOrigin(contentHeight: CGFloat, visibleHeight: CGFloat) -> CGPoint {
        CGPoint(x: 0, y: isTop ? max(contentHeight - visibleHeight, 0) : 0)
    }
}
