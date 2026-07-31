import AppKit

/// The grab zones around a settled selection: eight handles in a ring, and the
/// middle.
///
/// One type rather than three sets of arithmetic, because the same geometry is
/// asked for in three places and they must agree exactly: hit-testing a press,
/// laying out cursor rects, and drawing the handles. A press that resizes where
/// the cursor said "move" is worse than no handles at all.
///
/// Everything here is pure geometry on a rect, so it works equally in AppKit
/// global points (hit-testing) and in a view's own coordinates (cursors,
/// drawing). AppKit's y is up, so `top` is the higher edge.
struct SelectionZones {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// The pointer shape for this handle.
        ///
        /// `NSCursor.frameResize(position:directions:)` — macOS 15 and later,
        /// well under this app's floor of 26. It is also the only public way to
        /// get the diagonal ones: `resizeLeftRight` and friends are deprecated
        /// in the SDK header with a note pointing here, and the corner cursors
        /// were never exposed at all before it.
        var cursor: NSCursor {
            NSCursor.frameResize(position: position, directions: .all)
        }

        private var position: NSCursor.FrameResizePosition {
            switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
        }
    }

    /// How far either side of an edge counts as grabbing it.
    ///
    /// Straddling the edge rather than sitting inside it: a selection's edge is
    /// routinely placed hard against something, and a zone that only reached
    /// inwards would make the outermost row of the rect unreachable for a move
    /// while still not being generous enough to hit.
    private static let reach: CGFloat = 8

    let rect: CGRect
    /// Shrunk for small selections, so a 20 pt rect is not entirely handles with
    /// nothing left to grab for a move.
    let grab: CGFloat

    init(rect: CGRect) {
        self.rect = rect
        self.grab = min(Self.reach, rect.width / 3, rect.height / 3)
    }

    /// The middle: everything inside the ring, where a press means "move".
    var interior: CGRect { rect.insetBy(dx: grab, dy: grab) }

    /// Where each handle's grab zone is. Corners are squares straddling the
    /// corner; edges are the strips between them. Adjacent, never overlapping —
    /// which is what lets the cursor rects be laid out without relying on
    /// AppKit's undefined behaviour for overlapping ones.
    func zone(_ handle: Handle) -> CGRect {
        let side = grab * 2
        let innerWidth = max(rect.width - side, 0)
        let innerHeight = max(rect.height - side, 0)
        switch handle {
        case .topLeft:
            return CGRect(x: rect.minX - grab, y: rect.maxY - grab, width: side, height: side)
        case .topRight:
            return CGRect(x: rect.maxX - grab, y: rect.maxY - grab, width: side, height: side)
        case .bottomLeft:
            return CGRect(x: rect.minX - grab, y: rect.minY - grab, width: side, height: side)
        case .bottomRight:
            return CGRect(x: rect.maxX - grab, y: rect.minY - grab, width: side, height: side)
        case .top:
            return CGRect(x: rect.minX + grab, y: rect.maxY - grab,
                          width: innerWidth, height: side)
        case .bottom:
            return CGRect(x: rect.minX + grab, y: rect.minY - grab,
                          width: innerWidth, height: side)
        case .left:
            return CGRect(x: rect.minX - grab, y: rect.minY + grab,
                          width: side, height: innerHeight)
        case .right:
            return CGRect(x: rect.maxX - grab, y: rect.minY + grab,
                          width: side, height: innerHeight)
        }
    }

    /// The handle under a point, if any. Corners first: they overlap no edge
    /// zone by construction, but asking in this order documents which wins if
    /// the arithmetic ever changes.
    func handle(at point: CGPoint) -> Handle? {
        let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        if let corner = corners.first(where: { zone($0).contains(point) }) { return corner }
        return [Handle.top, .bottom, .left, .right].first { zone($0).contains(point) }
    }

    /// The corners, for drawing. The edge handles are deliberately left
    /// undrawn: four dots read as "this is adjustable" and eight read as a
    /// diagram, and the edges announce themselves through the cursor anyway.
    var cornerPoints: [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
    }

    /// `rect` with the dragged edge or corner moved to `point`, and every other
    /// side exactly where it was.
    ///
    /// A side dragged past its opposite **stops** `minimumSide` short of it
    /// rather than crossing over. The first version normalised the result
    /// instead, which let the rect flip: pulling the left edge 200 pt past the
    /// right edge produced a 200 pt rect sitting entirely to the *right* of where
    /// the selection had been. That is what a drawing tool does, and it is wrong
    /// here — this rect is about to be recorded, the handle the cursor named
    /// would silently become the opposite one, and nobody drags an edge across
    /// the whole selection meaning "put it over there".
    static func resized(
        _ rect: CGRect, by handle: Handle, to point: CGPoint,
        minimumSide: CGFloat = SelectionModel.minimumSide
    ) -> CGRect {
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: left = min(point.x, right - minimumSide)
        case .right, .topRight, .bottomRight: right = max(point.x, left + minimumSide)
        case .top, .bottom: break
        }
        switch handle {
        case .top, .topLeft, .topRight: top = max(point.y, bottom + minimumSide)
        case .bottom, .bottomLeft, .bottomRight: bottom = min(point.y, top - minimumSide)
        case .left, .right: break
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
