import AppKit

/// A border drawn around the region an area recording is capturing.
///
/// Without it a take gives no indication of what it is recording: the overlay
/// tears down the moment the stream starts, and the HUD is a fixed bar at the
/// bottom of the screen that says nothing about which rectangle is live. For a
/// fullscreen take that is fine — the answer is "everything". For an area take
/// it left the user watching a timer with no idea what was inside the frame.
///
/// It is `sharingType = .none`, so it cannot appear in the recording it marks.
/// It also ignores mouse events entirely: it sits over whatever is being
/// demonstrated, and a border that ate clicks would break the demonstration.
final class RecordingRegionOutlinePanel: NSPanel {
    static var usesSharingTypeNone = true

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, view: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: `isFloatingPanel` resets `level`, so it goes first.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = Self.usesSharingTypeNone ? .none : .readOnly

        contentView = view
    }
}

final class RecordingRegionOutlineView: NSView {
    /// Three hairlines: dark, light, dark. The panel is grown by this much on
    /// every side, so the border brackets the region instead of covering the
    /// outermost points of what is being demonstrated.
    static let strokeWidth: CGFloat = 3

    /// Why this is not a single colour chosen from the background.
    ///
    /// Sampling what is behind the border and picking a contrasting colour is
    /// the obvious answer, and it does not survive the situation it is for: the
    /// content behind the border is a *recording in progress*, so it changes
    /// continuously. A colour sampled once at the start is wrong as soon as the
    /// user scrolls, and re-sampling means a screen capture on a timer for the
    /// length of every take — cost paid the whole time to solve a problem at the
    /// edges only.
    ///
    /// A dark/light/dark sandwich needs no sampling and cannot lose: whatever is
    /// behind it, one of the two tones contrasts with it, including the red that
    /// made the previous solid-red border disappear. It is also quieter than a
    /// saturated line, which is the other half of the complaint — the border
    /// marks the region, it is not the point of what is on screen.
    override func draw(_ dirtyRect: NSRect) {
        let tones: [NSColor] = [
            NSColor(white: 0, alpha: 0.55),
            NSColor(white: 1, alpha: 0.9),
            NSColor(white: 0, alpha: 0.55),
        ]
        for (index, colour) in tones.enumerated() {
            let inset = CGFloat(index) + 0.5
            colour.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Owns the outline for the length of one area recording.
@MainActor
final class RecordingRegionOutline {
    private var panel: RecordingRegionOutlinePanel?

    var isVisible: Bool { panel != nil }

    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    /// `rect` is the recorded region in AppKit global points. The panel is grown
    /// outwards from it so the border brackets the region rather than sitting
    /// inside it and shaving two points off every edge of what you see.
    func show(around rect: CGRect) {
        let width = RecordingRegionOutlineView.strokeWidth
        let frame = rect.insetBy(dx: -width, dy: -width)
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let view = RecordingRegionOutlineView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        let created = RecordingRegionOutlinePanel(contentRect: frame, view: view)
        created.orderFrontRegardless()
        panel = created
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var frameForTest: CGRect? { panel?.frame }
}
