import AppKit

/// Makes the menu bar item a place to drop files on.
///
/// A subview of the button rather than the button itself, because
/// `NSStatusBarButton` implements none of `NSDraggingDestination`: AppKit only
/// offers a drag to a view that answers `draggingEntered`, so registering the
/// button for file URLs would advertise a target that refuses every drop. This
/// view covers it exactly and hands the mouse back on, so clicking the item
/// still opens its menu.
///
/// The pointer is over the menu bar for the whole gesture, so the feedback has
/// to be up here too: the button's own highlight is what a menu bar item does
/// when something is happening to it, and it is enough.
final class StatusItemDropView: NSView {
    /// Every file the drop carried that `accepts` allowed, in the order the
    /// pasteboard listed them.
    var onDrop: ([URL]) -> Void = { _ in }

    /// Asked per file, before the drag is accepted. A file this refuses shows no
    /// drop cursor at all, which is a better answer than taking it and beeping.
    var accepts: (URL) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pinned to the button rather than autoresized into it, because the item is
    /// `variableLength` and grows a running timer mid-session: a frame copied
    /// once at install time would stop covering the button the moment a
    /// recording started.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            topAnchor.constraint(equalTo: superview.topAnchor),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor),
        ])
    }

    // MARK: - Mouse

    /// The button underneath is what pops the menu, and it can only do that from
    /// its own `mouseDown` — the tracking loop it runs there is the menu. This
    /// view has to be hit-testable to be a drag destination, so every click it
    /// swallows is handed straight back.
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    /// DuoShot is a menu bar app and is usually not the active one, so without
    /// this the first click after a drop would only bring it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Dragging

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !shareableURLs(in: sender).isEmpty else { return [] }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let urls = shareableURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func setHighlighted(_ highlighted: Bool) {
        (superview as? NSButton)?.highlight(highlighted)
    }

    /// `urlReadingFileURLsOnly`, or a dragged hyperlink arrives as a URL with a
    /// path extension and is offered to a gate that can only open files.
    private func shareableURLs(in sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL] ?? []).filter(accepts)
    }
}
