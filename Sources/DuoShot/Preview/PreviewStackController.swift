import AppKit

/// One floating panel holding a scrollable column of preview cards.
///
/// Previously one `NSPanel` per capture, capped at three. That could not scroll,
/// and every arrival or dismissal had to reposition live windows — which is what
/// made the stack jitter. A single panel with an `NSScrollView` removes the whole
/// class of problem: cards are views, the newest sits at the bottom, and anything
/// past the height of the screen simply scrolls.
@MainActor
final class PreviewStackController {
    private final class Item {
        let entry: PreviewEntry
        let card: PreviewCardView
        var dragSource: ImageDragSource?
        var dismissTask: Task<Void, Never>?

        init(entry: PreviewEntry, card: PreviewCardView) {
            self.entry = entry
            self.card = card
        }
    }

    /// Bottom-left of the source display, matching CleanShot X.
    private let screenInset: CGFloat = 20
    private let gap: CGFloat = 10
    /// How many captures are kept. More than fits on screen is fine — that is
    /// what the scroll view is for.
    private let maxRetained = 12
    private let moveDuration = 0.18

    /// Newest last.
    private var items: [Item] = []

    private var panel: PreviewPanel?
    private var scrollView: NSScrollView?
    private var documentView: NSView?
    private var panelTracking: NSTrackingArea?
    /// `NSTrackingArea.owner` is declared `weak` in the SDK, so an owner created
    /// inline is deallocated immediately and the area silently stops delivering
    /// events. That is why cards used to vanish from under the pointer: the
    /// panel-level enter/exit never fired at all.
    private var hoverProxy: PanelHoverProxy?
    private var isPointerInside = false
    /// The card the pointer is actually over. It is never auto-dismissed.
    private weak var hoveredItem: Item?

    var timeout: Duration = .seconds(6)

    /// Whether a recording is being written right now. Injected, because this
    /// controller owns no recorder.
    ///
    /// Decides one thing: a card raised *during* a take cannot be excluded from
    /// it — `SCContentFilter` is fixed when the stream starts and this panel
    /// does not exist yet at that moment — so it stays `.none` whatever the
    /// preference says. A card that was already up when the take began is a
    /// different case: it exists before the filter, so its window ID goes into
    /// the exclusion list and it can be visible.
    var isRecordingActive: (() -> Bool)?

    /// Read fresh rather than cached so changing it in Settings takes effect on
    /// the next capture without a relaunch.
    private var corner: PreviewCorner { Preferences.shared.previewCorner }

    // MARK: - Presenting

    /// Screenshots. The recording path goes through `present(_:poster:)`.
    ///
    /// `async` because building the entry downsamples the capture off-main.
    /// The card arriving a turn later is invisible next to the encode the
    /// caller has already awaited.
    func present(_ output: OutputPipeline.Output) async {
        present(await PreviewEntry(output))
    }

    /// Recordings. The poster frame is the caller's job because extracting one
    /// decodes off disk, and this method cannot be async without every card
    /// arriving a runloop turn late.
    func present(_ output: OutputPipeline.RecordingOutput, poster: NSImage) {
        present(PreviewEntry(output, poster: poster))
    }

    func present(_ entry: PreviewEntry) {
        var callbacks = PreviewCardView.Callbacks()
        let card = PreviewCardView(
            image: entry.thumbnail, badge: entry.badge,
            isIncomplete: entry.isIncomplete, saveFailed: entry.saveFailed,
            callbacks: callbacks)
        let item = Item(entry: entry, card: card)

        // Every capture of `item` is weak. `item` owns the card, the card owns
        // these callbacks — a strong capture closes that loop and the Item never
        // deallocates, taking a multi-megabyte CGImage with it. Measured: a
        // 300-capture soak grew by 72 MB with strong captures, flat without.
        callbacks.copy = { [weak self, weak item] in
            entry.copyToClipboard()
            if let item { self?.dismiss(item) }
        }
        callbacks.reveal = { [weak self, weak item] in
            OutputPipeline.shared.reveal(entry.url)
            if let item { self?.dismiss(item) }
        }
        callbacks.close = { [weak self, weak item] in
            if let item { self?.dismiss(item) }
        }
        callbacks.open = { NSWorkspace.shared.open(entry.url) }
        callbacks.hoverChanged = { [weak self, weak item] isInside in
            guard let self, let item else { return }
            // Timers pause for the whole stack while the pointer is in the
            // panel, not per card: with a scrollable list, cards vanishing from
            // under the cursor while you read the column is hostile.
            if isInside {
                self.hoveredItem = item
            } else if self.hoveredItem === item {
                self.hoveredItem = nil
            }
            self.refreshDismissTimers()
        }
        callbacks.beginDrag = { [weak self, weak item] event, thumbnail in
            guard let self, let item, let panel = self.panel else { return }
            item.dismissTask?.cancel()
            let source = ImageDragSource(entry: entry) { [weak self, weak item] accepted in
                guard let self, let item else { return }
                if accepted { self.dismiss(item) } else { self.scheduleDismiss(item) }
            }
            item.dragSource = source
            // The session is begun from the panel's content view so the drag
            // survives the card being removed, but the dragging *frame* has to be
            // the card's own rect in that view's coordinates. Passing the content
            // view's bounds stretched the drag image over the whole column the
            // moment there was more than one card in it.
            let dragView = panel.contentView ?? item.card
            source.beginDrag(
                from: dragView, event: event, thumbnail: thumbnail,
                frame: item.card.convert(item.card.bounds, to: dragView))
        }
        card.apply(callbacks)

        ensurePanel(on: ScreenIndex.screen(for: entry.sourceDisplayID) ?? NSScreen.main)

        // Trim before adding, never in the middle of installing the new card.
        while items.count >= maxRetained, let oldest = items.first {
            remove(oldest, animated: false)
        }

        items.append(item)
        documentView?.addSubview(card)
        card.alphaValue = 0
        relayout(animated: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            card.animator().alphaValue = 1
        }
        scrollToNewest(animated: false)
        scheduleDismiss(item)
    }

    // MARK: - Panel

    private func ensurePanel(on screen: NSScreen?) {
        guard let screen else { return }
        if panel != nil { return }

        let width = PreviewCardView.cardSize.width
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 10))

        let scroll = NSScrollView(frame: container.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed

        let document = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        scroll.documentView = document
        container.addSubview(scroll)

        let hidden = !Preferences.shared.overlayVisibleToScreenSharing
            || (isRecordingActive?() ?? false)
        let created = PreviewPanel(
            contentRect: container.bounds, view: container, hiddenFromCapture: hidden)
        created.setFrameOrigin(corner.panelOrigin(
            in: screen.visibleFrame, panelSize: container.bounds.size, inset: screenInset))
        created.orderFrontRegardless()

        created.scrollHandler = { [weak self] event in
            self?.handleScroll(event) ?? false
        }

        panel = created
        scrollView = scroll
        documentView = document
        installPanelTracking(on: container)
    }

    private func installPanelTracking(on view: NSView) {
        if let panelTracking { view.removeTrackingArea(panelTracking) }
        let proxy = PanelHoverProxy(controller: self)
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: proxy
        )
        view.addTrackingArea(area)
        panelTracking = area
        hoverProxy = proxy
    }

    /// Held strongly by the controller — see `hoverProxy`.
    private final class PanelHoverProxy: NSResponder {
        private weak var controller: PreviewStackController?
        init(controller: PreviewStackController) {
            self.controller = controller
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func mouseEntered(with event: NSEvent) {
            MainActor.assumeIsolated { controller?.setPointerInside(true) }
        }
        override func mouseExited(with event: NSEvent) {
            MainActor.assumeIsolated { controller?.setPointerInside(false) }
        }
    }

    fileprivate func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        refreshDismissTimers()
    }

    private func tearDownPanelIfEmpty() {
        guard items.isEmpty, let panel else { return }
        // Stragglers: a card is only removed from the view tree in an animation
        // completion handler, and a competing NSAnimationContext group can
        // cancel that group so the handler never runs. The leftover view then
        // sits in the document view as an empty dark tile after everything is
        // supposedly gone.
        documentView?.subviews.forEach { $0.removeFromSuperview() }
        let closing = panel
        self.panel = nil
        scrollView = nil
        documentView = nil
        panelTracking = nil
        isPointerInside = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            closing.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                closing.orderOut(nil)
                // Held one more turn: AppKit can still have the content view in
                // a constraint-update pass, and freeing it there segfaulted.
                self?.retired.append(closing)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.retired.removeAll { $0 === closing }
                }
            }
        }
    }

    private var retired: [PreviewPanel] = []

    // MARK: - Layout

    /// Newest at the bottom (y = 0), older stacked above.
    private func relayout(animated: Bool) {
        guard let panel, let document = documentView, let screen = panel.screen ?? NSScreen.main
        else { return }

        let card = PreviewCardView.cardSize
        let contentHeight = items.isEmpty
            ? 0
            : CGFloat(items.count) * card.height + CGFloat(items.count - 1) * gap
        let maxHeight = screen.visibleFrame.height - screenInset * 2
        // An empty stack keeps its current height until `tearDownPanelIfEmpty`
        // fades the whole panel out. Shrinking to zero here would clip the last
        // card's leaving animation before it could be seen.
        let panelHeight = items.isEmpty
            ? panel.frame.height
            : min(contentHeight, maxHeight)

        document.setFrameSize(CGSize(width: card.width, height: contentHeight))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? moveDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, item) in items.enumerated() {
                let slot = items.count - 1 - index
                let frame = CGRect(
                    x: 0,
                    y: corner.cardY(slot: slot, cardHeight: card.height,
                                    pitch: card.height + gap, contentHeight: contentHeight),
                    width: card.width, height: card.height)
                guard item.card.frame != frame else { continue }
                if animated {
                    item.card.animator().frame = frame
                } else {
                    item.card.frame = frame
                }
            }
        }

        // The panel grows away from whichever corner it is anchored to.
        let size = CGSize(width: card.width, height: panelHeight)
        let origin = corner.panelOrigin(
            in: screen.visibleFrame, panelSize: size, inset: screenInset)
        let frame = CGRect(origin: origin, size: size)
        if panel.frame != frame {
            if animated {
                panel.animator().setFrame(frame, display: true)
            } else {
                panel.setFrame(frame, display: false)
            }
        }
    }

    private func scrollToNewest(animated: Bool) {
        guard let scroll = scrollView, let document = documentView else { return }
        // The document view is not flipped: y = 0 is the bottom of the content.
        let target = corner.scrollOrigin(
            contentHeight: document.frame.height,
            visibleHeight: scroll.contentView.bounds.height)
        if animated {
            scroll.contentView.animator().setBoundsOrigin(target)
        } else {
            scroll.contentView.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Swipe

    private enum ScrollGesture {
        case undecided
        case swiping
        case scrolling
    }

    private var scrollTarget: Item?
    private var scrollGesture: ScrollGesture = .undecided
    private var swipeAccumulator: CGFloat = 0
    private var scrollAccumulator: CGFloat = 0

    /// The whole trackpad gesture, driven from the window.
    ///
    /// Scroll events are hit-tested per event, so a gesture that begins on a
    /// card does not stay with it: measured, `hit` was the card for the first
    /// few events and `nil` for every one after — including the `.ended` that
    /// decides whether to throw the card away. The card therefore never learned
    /// the gesture had finished, and nothing happened. Latching the target at
    /// `.began` and feeding it every subsequent event fixes that at the root.
    ///
    /// Returns true when the stack consumed the event.
    private func handleScroll(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) {
            scrollGesture = .undecided
            swipeAccumulator = 0
            scrollAccumulator = 0
            scrollTarget = items.first { isPointerOver($0) }
        }
        guard let target = scrollTarget else { return false }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let gesture = scrollGesture
            let offset = swipeAccumulator
            scrollTarget = nil
            scrollGesture = .undecided
            swipeAccumulator = 0
            guard gesture == .swiping else { return false }
            finishSwipe(target, offset: offset)
            return true
        }

        swipeAccumulator += event.scrollingDeltaX
        scrollAccumulator += event.scrollingDeltaY

        if scrollGesture == .undecided {
            guard max(abs(swipeAccumulator), abs(scrollAccumulator))
                > PreviewCardView.gestureSlop else {
                // Consumed, not forwarded: handing even one event to the
                // enclosing NSScrollView makes it latch the whole gesture.
                return true
            }
            scrollGesture = abs(swipeAccumulator) > abs(scrollAccumulator) * 1.3
                ? .swiping : .scrolling
            if scrollGesture == .swiping { target.dismissTask?.cancel() }
        }

        guard scrollGesture == .swiping, let layer = target.card.layer else { return false }

        // A layer transform, not the frame: moving the frame slid the card out
        // from under the pointer, which is what broke the routing in the first
        // place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(swipeAccumulator, 0, 0)
        let progress = min(abs(swipeAccumulator) / PreviewCardView.swipeThreshold, 1)
        layer.opacity = Float(1 - progress * 0.55)
        CATransaction.commit()
        return true
    }

    private func finishSwipe(_ item: Item, offset: CGFloat) {
        guard let layer = item.card.layer else { return }

        guard abs(offset) >= PreviewCardView.swipeThreshold else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut))
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
            scheduleDismiss(item)
            return
        }

        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at: index)
        item.dismissTask?.cancel()
        item.dismissTask = nil
        item.dragSource = nil

        let card = item.card
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                card.removeFromSuperview()
                self.tearDownPanelIfEmpty()
            }
        }
        layer.transform = CATransform3DMakeTranslation(
            (offset < 0 ? -1 : 1) * PreviewCardView.cardSize.width * 1.6, 0, 0)
        layer.opacity = 0
        CATransaction.commit()

        relayout(animated: true)
    }

    // MARK: - Dismissal

    /// Ground truth, asked at the moment it matters.
    ///
    /// The previous version gated dismissal on `isPointerInside`, a flag fed by
    /// an `NSTrackingArea`. That is an event mechanism that can silently stop
    /// delivering — it already did once, because `NSTrackingArea.owner` is
    /// `weak` and the owner was being deallocated — and when it fails the
    /// symptom is a card vanishing from under the cursor. Reading the pointer
    /// position directly cannot fail that way.
    private var isPointerOverPanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(pointerLocation())
    }

    /// Whether the pointer is over *this card specifically*.
    ///
    /// Only the card under the cursor is held; the rest keep running their own
    /// timers. Holding the whole stack whenever the pointer was anywhere in the
    /// panel was too blunt — it froze cards the user was not looking at.
    ///
    /// The panel-level check is still required: a card scrolled out of view can
    /// still contain the converted point, because the document view extends past
    /// the clip view.
    private func isPointerOver(_ item: Item) -> Bool {
        guard let panel, panel.isVisible else { return false }
        let location = pointerLocation()
        guard panel.frame.contains(location) else { return false }
        let inWindow = panel.convertPoint(fromScreen: location)
        return item.card.bounds.contains(item.card.convert(inWindow, from: nil))
    }

    /// Where the pointer is. Substituted by `--selftest-preview` so the test can
    /// exercise the hold-under-pointer path without hijacking the real cursor —
    /// only this one input is replaced; the containment check, the panel's real
    /// frame and the whole timer loop stay exactly as they ship.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    private func scheduleDismiss(_ item: Item) {
        item.dismissTask?.cancel()
        item.dismissTask = Task { [weak self, weak item] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(6))

            // The timer has elapsed, but the card under the pointer is never
            // taken away. Hold until the pointer leaves *this card*, then give a
            // short grace so it does not vanish the instant the mouse moves off.
            while !Task.isCancelled, let self, let item, self.isPointerOver(item) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(600))

            guard !Task.isCancelled, let self, let item else { return }
            guard !self.isPointerOver(item) else {
                // Pointer came back during the grace period.
                self.scheduleDismiss(item)
                return
            }
            self.dismiss(item)
        }
    }

    /// Every card always has a running timer; whether it is allowed to fire is
    /// decided by the live pointer position inside the task. Cancelling timers
    /// from a hover flag meant a flag that got stuck could strand a card on
    /// screen forever, or — when the flag never became true — let one vanish
    /// from under the cursor.
    private func refreshDismissTimers() {
        for item in items where item.dismissTask == nil {
            scheduleDismiss(item)
        }
    }

    private func dismiss(_ item: Item, animated: Bool = true) {
        remove(item, animated: animated)
    }

    private func remove(_ item: Item, animated: Bool) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        if scrollTarget === item {
            scrollTarget = nil
            scrollGesture = .undecided
            swipeAccumulator = 0
        }
        items.remove(at: index)
        item.dismissTask?.cancel()
        item.dismissTask = nil
        item.dragSource = nil

        guard animated else {
            item.card.removeFromSuperview()
            relayout(animated: false)
            tearDownPanelIfEmpty()
            return
        }
        // The panel goes only after the card has finished leaving. Collapsing it
        // in parallel clipped the last card's animation away entirely — the
        // panel's height animates to zero the moment the stack empties.
        vanish(item.card) { [weak self] in self?.tearDownPanelIfEmpty() }
        relayout(animated: true)
    }

    /// The leaving animation.
    ///
    /// Driven on the layer, like the swipe, rather than through
    /// `NSAnimationContext` on the view's frame. `relayout` animates frames too,
    /// and two animation groups fighting over the same property made each
    /// dismissal look more hurried than the last. A layer transform is not
    /// something `relayout` touches.
    private func vanish(_ card: PreviewCardView, completion: @escaping () -> Void) {
        guard let layer = card.layer else {
            card.removeFromSuperview()
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                card.removeFromSuperview()
                completion()
            }
        }
        // Drifts toward the edge the stack hugs and shrinks slightly: a plain
        // alpha fade reads as the card blinking out of existence.
        layer.transform = CATransform3DConcat(
            CATransform3DMakeScale(0.92, 0.92, 1),
            CATransform3DMakeTranslation(corner.swipeDirection * 26, 0, 0))
        layer.opacity = 0
        CATransaction.commit()
    }

    func dismissAll() {
        for item in items { remove(item, animated: false) }
    }

    // MARK: - Test hooks

    var panelWindowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    var count: Int { items.count }

    /// Card frames converted to AppKit global points, newest first.
    var panelFrames: [CGRect] {
        guard let panel else { return [] }
        return items.reversed().map { item in
            let inWindow = item.card.convert(item.card.bounds, to: nil)
            return panel.convertToScreen(inWindow)
        }
    }

    var containerFrame: CGRect? { panel?.frame }

    /// Simulates the oldest card's auto-dismiss timer firing.
    func expireOldestForTest() {
        guard let oldest = items.first else { return }
        dismiss(oldest)
    }

    func setHoverForTest(_ hovering: Bool) {
        for item in items { item.card.setHoverForTest(hovering) }
    }

    /// Points the substituted pointer at the panel, or far away from it.
    /// Never moves a window and never touches the real cursor.
    /// Points the substituted pointer at card `index` (newest first), or far
    /// away from everything. Never moves a window or the real cursor.
    @discardableResult
    func simulatePointerForTest(overCardAt index: Int?) -> Bool {
        guard let panel else { return false }
        guard let index else {
            let away = CGPoint(x: panel.frame.maxX + 500, y: panel.frame.maxY + 500)
            pointerLocation = { away }
            return true
        }
        let ordered = Array(items.reversed())
        guard index < ordered.count else { return false }
        let card = ordered[index].card
        let inWindow = card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let target = panel.convertPoint(toScreen: inWindow)
        pointerLocation = { target }
        return isPointerOver(ordered[index])
    }

    /// Which cards (newest first) the substituted pointer currently holds.
    var heldCardsForTest: [Bool] {
        Array(items.reversed()).map { isPointerOver($0) }
    }

    var debugState: String {
        guard let panel else { return "<no panel>" }
        return "cards=\(items.count) visible=\(panel.isVisible) key=\(panel.isKeyWindow) "
            + "canBecomeKey=\(panel.canBecomeKey) level=\(panel.level.rawValue) "
            + "sharingType=\(panel.sharingType.rawValue) frame=\(panel.frame)"
    }
}
