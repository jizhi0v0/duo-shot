import AppKit

/// The floating post-capture preview.
///
/// Never becomes key: it must not take the keyboard away from whatever the user
/// is working in. That is exactly why `acceptsFirstMouse` matters so much in
/// `PreviewContentView` — in a non-key window the first click is otherwise
/// swallowed as an activation click, and every button needs two clicks.
final class PreviewPanel: NSPanel {
    /// Test hook, mirroring OverlayPanel. With `.none` the panel is invisible to
    /// ScreenCaptureKit outright, which is the behaviour we ship — but it also
    /// makes an exclusion test unable to fail, so the self-test can turn it off.
    static var usesSharingTypeNone = true

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, view: NSView, hiddenFromCapture: Bool = true) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: isFloatingPanel resets `level`, so it goes first.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Above .floating, well below the overlay's shielding level so a new
        // selection always covers an existing preview.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // We own dragging: a drag on the body means drag-OUT, not move-window.
        isMovableByWindowBackground = false
        isMovable = false
        // Tracking areas in a panel that never becomes key are unreliable
        // without this; the action bar's hover reveal depends on it.
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Keep the preview out of a subsequent capture.
        sharingType = (Self.usesSharingTypeNone && hiddenFromCapture) ? .none : .readOnly

        contentView = view
    }

    /// Consumes a scroll event, returning true if the stack handled it.
    ///
    /// Set by `PreviewStackController`. Scroll events are hit-tested per event,
    /// so a gesture that starts on a card does not stay with that card — the
    /// measured symptom was `hit=PreviewCardView` for the first few events and
    /// `hit=nil` for the rest, including the `.ended` that decides the outcome.
    /// The window sees every event, so the latching is done here instead.
    var scrollHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, scrollHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// `acceptsFirstMouse` has to be overridden on the buttons too, not just the
/// content view — otherwise each one needs two clicks while another app is
/// frontmost.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
