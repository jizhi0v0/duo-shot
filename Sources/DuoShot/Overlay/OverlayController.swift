import AppKit
import ObjCException

nonisolated enum SelectionMode: Sendable {
    case area
    case window

    var toggled: SelectionMode { self == .area ? .window : .area }
}

/// Owns one overlay panel per screen and exposes the whole interaction as a
/// single `await`.
///
/// `present(mode:windows:)` returning an async value is the most important
/// structural decision in the UI layer: it collapses show / track / confirm /
/// tear-down into one linear statement in `CaptureCoordinator` instead of a
/// delegate web.
@MainActor
final class OverlayController {
    enum Outcome: Sendable {
        case area(displayID: CGDirectDisplayID, rectInAppKitGlobal: CGRect)
        case window(CGWindowID)
        case cancelled
    }

    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private let model = SelectionModel()
    private let picker = WindowPickerModel()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    private var rankTimer: Timer?
    private var ticksSinceEnumeration = 0
    private var isEnumerating = false
    private var mode: SelectionMode = .area
    private var allowsWindowMode = true
    private let toolbar = SelectionToolbar()
    /// Whether releasing the drag commits the selection or arms it.
    ///
    /// Screenshots commit on mouse-up: the whole value of the interaction is
    /// that it is over in one gesture. A recording is not the same transaction —
    /// it has settings that belong to the take, and no way to undo starting one
    /// — so it gets a step where the selection is final but nothing has begun.
    private var requiresConfirmation = false
    private var isArmed = false

    /// Re-enumerates the pickable windows while the overlay is up.
    ///
    /// Injected rather than reached for, because this type owns no capture
    /// engine — and because the self-tests need to drive the picker from a fixed
    /// list, which they do by leaving this nil.
    var refreshWindows: (() async -> [WindowInfo])?

    var isPresenting: Bool { !panels.isEmpty }

    /// Where the confirmation toolbar was when it went away, so whatever takes
    /// its place can start from there instead of appearing somewhere else.
    var lastToolbarFrame: CGRect? { toolbar.lastFrame }

    /// The CGWindowIDs of our panels, for `SCContentFilter(display:excludingWindows:)`.
    ///
    /// `NSWindow.windowNumber` *is* the `CGWindowID` — that is the join key.
    var panelWindowIDs: Set<CGWindowID> {
        // The toolbar is one of ours too. It is `.none` like the panels, so a
        // recording never sees it either way, but a *screenshot* taken through
        // this exclusion list would photograph it.
        Set(panels.map { CGWindowID($0.windowNumber) }).union(toolbar.windowIDs)
    }

    func present(
        mode initialMode: SelectionMode, windows: [WindowInfo], allowsWindowMode: Bool = true,
        requiresConfirmation: Bool = false
    ) async -> Outcome {
        if isPresenting { dismiss(resumingWith: .cancelled) }

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        mode = initialMode
        self.allowsWindowMode = allowsWindowMode
        self.requiresConfirmation = requiresConfirmation
        isArmed = false
        model.reset()

        // The toolbar follows the selection, so it has to move on the same
        // signal the views redraw on — arrow keys nudge and resize the rect
        // while the bar is up.
        let refresh: () -> Void = { [weak self] in
            guard let self else { return }
            views.forEach { $0.refresh() }
            if isArmed { repositionToolbar() }
        }
        model.onChange = refresh
        picker.onChange = refresh

        toolbar.onStart = { [weak self] in self?.confirmArea() }

        let callbacks = OverlayView.Callbacks(
            confirmArea: { [weak self] in self?.confirmArea() },
            confirmWindow: { [weak self] id in self?.confirmWindow(id) },
            cancel: { [weak self] in self?.dismiss(resumingWith: .cancelled) },
            toggleMode: { [weak self] in self?.toggleMode() },
            selectionRestarted: { [weak self] in self?.disarm() }
        )

        for screen in NSScreen.screens {
            let view = OverlayView(
                screen: screen, model: model, picker: picker, callbacks: callbacks)
            view.mode = mode
            view.allowsWindowMode = allowsWindowMode
            let panel = OverlayPanel(screen: screen, view: view)
            // Registered BEFORE it goes on screen. Ordering a window can throw
            // (see `ordering`), and an exception here must not leave a panel that
            // AppKit knows about and this controller does not — that panel would
            // never be torn down and its view would be freed under AppKit's feet.
            panels.append(panel)
            views.append(view)
        }

        // Loaded after the panels exist, so their window IDs can be kept out of
        // the picker. The enumeration predates them, so nothing is lost by
        // waiting — and the poll's re-enumeration definitely runs while they are
        // on screen.
        picker.excludedWindowIDs = panelWindowIDs
        picker.load(windows)

        // Seeded before anything is composited, not after. Ordering the panels on
        // screen first and only then filling in the pointer state means the first
        // frame the window server shows has no crosshair (or, in window mode, no
        // highlight) and the correct one arrives a frame or two later — which
        // reads as the selection UI popping into place rather than being there.
        seedPointer()

        for panel in panels {
            guard ordering({ panel.orderFrontRegardless() }) else {
                dismiss(resumingWith: .cancelled)
                return .cancelled
            }
        }

        guard takeKeyboard() else {
            dismiss(resumingWith: .cancelled)
            return .cancelled
        }

        startRankPolling()

        // A display topology change mid-selection is not worth the bug surface
        // of remapping an in-flight rect: tear down and cancel.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.overlay.notice("screen parameters changed during selection; cancelling")
                self?.dismiss(resumingWith: .cancelled)
            }
        }

        // Proves the non-activating-panel claim: showing the overlay must not
        // deactivate whatever the user was working in, or the captured image
        // shows greyed-out chrome and a frozen caret.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmostBefore != frontmostAfter {
            Log.overlay.error("""
                overlay changed the frontmost app: \(frontmostBefore ?? "nil", privacy: .public) \
                -> \(frontmostAfter ?? "nil", privacy: .public)
                """)
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Runs a window-ordering call with an ObjC exception guard. Returns false if
    /// AppKit threw.
    ///
    /// Not paranoia: measured on 2026-07-30. Typing in the Preferences window
    /// spins up a TextInputUI remote view; when that view service dies, the stale
    /// `NSRemoteView` stays subscribed to the window-will-order-on-screen
    /// notification, and the next `orderFrontRegardless()` on an overlay panel
    /// raises NSInternalInconsistencyException from inside ViewBridge. AppKit's
    /// top-level handler swallows it and the app keeps running — but the
    /// exception has already unwound through this `async` frame, skipping every
    /// Swift cleanup, so the continuation is never resumed and a half-ordered
    /// panel's view is left dangling in AppKit's tracking-area manager. It
    /// segfaulted in `resetCursorRects` three seconds later.
    ///
    /// Catching it turns that into an ordinary cancelled selection.
    private func ordering(_ body: () -> Void) -> Bool {
        guard let exception = DSExceptionFrom(body) else { return true }
        Log.overlay.error("""
            AppKit raised while ordering an overlay panel: \
            \(exception.name.rawValue, privacy: .public) \
            \(exception.reason ?? "no reason", privacy: .public)
            """)
        return false
    }

    // MARK: - Mode

    private func toggleMode() {
        guard allowsWindowMode else { return }
        mode = mode.toggled
        model.reset()
        picker.reset()
        views.forEach { $0.mode = self.mode }
        // Ahead of the poll rather than waiting up to 120 ms for it: Space is a
        // deliberate switch into window mode, and the first highlight should be
        // right the moment it lands.
        if mode == .window { picker.reRank() }
        seedPointer()
        Log.overlay.notice("selection mode -> \(String(describing: self.mode), privacy: .public)")
    }

    // MARK: - Keeping the picker's z-order live

    /// Polls the window server's z-order while the overlay is up.
    ///
    /// A timer, not `NSWorkspace.didActivateApplicationNotification`, which is
    /// what this was first written as. That notification is posted *before* the
    /// window server finishes restacking, so re-ranking on it read the old order
    /// straight back and changed nothing — the highlight only caught up when the
    /// user happened to move the mouse, which after a ⌘-Tab they have no reason
    /// to do. Polling has no such race.
    ///
    /// A tick is one `CGWindowListCopyWindowInfo` read and an ID comparison: no
    /// ScreenCaptureKit call, no TCC, nothing async, and no redraw at all unless
    /// the order actually moved. 120 ms is below where a highlight starts to feel
    /// like it lags the switch.
    ///
    /// `.common` run-loop modes so it keeps firing inside any AppKit tracking
    /// loop, where a `.default`-mode timer silently stops.
    private func startRankPolling() {
        ticksSinceEnumeration = 0
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresenting else { return }
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rankTimer = timer
    }

    /// Makes the panel under the pointer key and its view first responder.
    ///
    /// Only the panel under the pointer needs the keyboard; AppKit routes mouse
    /// events by position on its own. Returns false if AppKit threw while
    /// ordering — see `ordering`.
    @discardableResult
    private func takeKeyboard() -> Bool {
        let pointerDisplayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
        let keyPanel = panels.first {
            $0.screen.flatMap(ScreenIndex.displayID(of:)) == pointerDisplayID
        } ?? panels.first
        guard ordering({ keyPanel?.makeKeyAndOrderFront(nil) }) else { return false }
        if let index = panels.firstIndex(where: { $0 === keyPanel }) {
            keyPanel?.makeFirstResponder(views[index])
        }
        return true
    }

    /// Takes the keyboard back after some other application has been activated.
    ///
    /// Measured 2026-07-30: a `.nonactivatingPanel` holding key status loses it
    /// the instant any other application activates — which is precisely what
    /// ⌘-Tab does, and ⌘-Tab is a gesture this overlay now actively supports,
    /// since the picker follows the switch. Mouse tracking survives it (the
    /// tracking area is `.activeAlways`), so the highlight keeps following the
    /// pointer and nothing *looks* wrong — but `keyDown` stops arriving, and Esc,
    /// Space, Return and the arrow keys all silently stop working. Reported as
    /// "can't Esc out once a window is selected".
    ///
    /// Re-taking key does not undo the switch: measured, the frontmost
    /// application stays the one the user just moved to.
    private func restoreKeyboardIfLost() {
        guard !panels.contains(where: \.isKeyWindow) else { return }
        Log.overlay.debug("overlay lost key status; taking the keyboard back")
        takeKeyboard()
    }

    private func poll() {
        // Both modes: every key the overlay handles dies with key status, not
        // just the picker's.
        restoreKeyboardIfLost()
        guard mode == .window else { return }

        if picker.reRank() { seedPointer() }

        // Membership, not just order. The window list is enumerated once, before
        // the overlay opens, so anything that appears afterwards — an open/save
        // dialog, a new document, an alert — was unpickable for as long as the
        // picker stayed up, no matter where the pointer went.
        //
        // At a quarter of the polling rate because this one is not free: a
        // ScreenCaptureKit enumeration is an async round trip, against the
        // CGWindowList read that `reRank` does inline. Windows appear far more
        // rarely than they restack, so ~half a second is the right trade.
        ticksSinceEnumeration += 1
        guard ticksSinceEnumeration >= 4, !isEnumerating, let refreshWindows else { return }
        ticksSinceEnumeration = 0
        isEnumerating = true

        Task { [weak self] in
            let windows = await refreshWindows()
            guard let self else { return }
            isEnumerating = false
            // The overlay can have been torn down or switched to area mode while
            // the enumeration was in flight.
            guard isPresenting, mode == .window else { return }
            if picker.load(windows) { seedPointer() }
        }
    }

    /// Populates the hover/crosshair state immediately, so the overlay is not
    /// blank until the pointer happens to move.
    private func seedPointer() {
        let location = NSEvent.mouseLocation
        switch mode {
        case .area: model.pointerMoved(to: location)
        case .window: picker.updateHover(atAppKitGlobal: location)
        }
        views.forEach { $0.refresh() }
    }

    // MARK: - Exit paths

    private func confirmArea() {
        guard
            let rect = model.rectInAppKitGlobal,
            let displayID = model.originDisplayID,
            model.isUsable
        else {
            dismiss(resumingWith: .cancelled)
            return
        }

        // First commit only arms it. The second — Record, or Return — is what
        // resumes the caller.
        if requiresConfirmation, !isArmed {
            arm(rect: rect, displayID: displayID)
            return
        }
        toolbar.hide()
        // Deliberately *not* tearing down here. The panels must still be on
        // screen when the caller builds its SCContentFilter, because that is
        // where `panelWindowIDs` comes from and because ordering windows out and
        // immediately capturing races the window server's next composite — the
        // classic way to end up with the dim in the screenshot. The caller
        // captures with the panels excluded, then calls `tearDown()`.
        resume(with: .area(displayID: displayID, rectInAppKitGlobal: rect))
    }

    /// Freezes the selection and puts the toolbar under it.
    ///
    /// The overlay panels stay exactly as they are: the dim, the marching ants
    /// and the keyboard handling all still apply, so the rect can still be
    /// nudged with the arrow keys and abandoned with Escape. Only the meaning of
    /// "confirm" has changed.
    private func arm(rect: CGRect, displayID: CGDirectDisplayID) {
        isArmed = true
        views.forEach { $0.isArmed = true }
        guard let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main else { return }
        toolbar.show(under: rect, on: screen)
        Log.overlay.notice("selection armed \(self.rectString(rect), privacy: .public)")
    }

    /// Back to dragging. Called when a new drag begins under the armed bar.
    private func disarm() {
        guard isArmed else { return }
        isArmed = false
        views.forEach { $0.isArmed = false }
        toolbar.hide()
    }

    private func repositionToolbar() {
        guard
            let rect = model.rectInAppKitGlobal,
            let displayID = model.originDisplayID,
            let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main
        else { return }
        toolbar.reposition(under: rect, on: screen)
    }

    private func rectString(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))"
    }

    private func confirmWindow(_ id: CGWindowID) {
        // Left standing, exactly like the area path, and for the same reason.
        //
        // This used to tear down first, on the grounds that a window filter
        // contains one window and our panels therefore cannot get into the shot.
        // That is still true of an ordinary window — but not of the Dock, which
        // is captured as a region of the desktop so that its glass has something
        // to sample, and a region capture will happily photograph the dim.
        // Ordering the panels out and capturing immediately races the window
        // server's next composite; keeping them up and excluding them by ID does
        // not. The caller tears down after it has the image.
        resume(with: .window(id))
    }

    private func dismiss(resumingWith outcome: Outcome) {
        tearDown()
        resume(with: outcome)
    }

    /// Removes the panels. Safe to call more than once.
    ///
    /// Also resumes any still-pending continuation with `.cancelled`, so no exit
    /// path can leave `present()` awaiting forever. Harmless after a confirm,
    /// which has already taken the continuation.
    func tearDown() {
        // Unconditional, not `if isArmed`. This is the one exit every path goes
        // through, and a toolbar left on screen at shielding level with no
        // overlay under it is unreachable furniture the user cannot dismiss.
        isArmed = false
        views.forEach { $0.isArmed = false }
        toolbar.hide()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        // The run loop holds the timer, and a repeating timer's block holds
        // whatever it captured, so leaving it running keeps this controller's
        // work alive for the rest of the process.
        rankTimer?.invalidate()
        rankTimer = nil
        for view in views { view.detachFromDisplayCycle() }
        for panel in panels { panel.orderOut(nil) }
        // Held one turn past the tear-down, the same way PreviewStackController
        // retires its panels: AppKit's display cycle can still have these views in
        // a tracking-area / cursor-rect pass, and freeing them there segfaults.
        // `detachFromDisplayCycle` above should already have unhooked them; this
        // is the second lock on the same door, and it is cheap.
        let closing = panels
        retired.append(contentsOf: closing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.retired.removeAll { retiredPanel in
                closing.contains { $0 === retiredPanel }
            }
        }
        panels.removeAll()
        views.removeAll()
        model.onChange = nil
        picker.onChange = nil
        resume(with: .cancelled)
    }

    private var retired: [OverlayPanel] = []

    /// Resuming a continuation twice is a hard crash, and the overlay has
    /// several exit routes (mouse-up, Return, Esc, screen reconfiguration, a
    /// second `present`). Taking the continuation out of the property before
    /// resuming makes double-resume structurally impossible.
    private func resume(with outcome: Outcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }

    // MARK: - Test hooks

    var debugPanelState: String {
        panels.map { panel in
            "visible=\(panel.isVisible) onScreen=\(panel.occlusionState.contains(.visible)) "
                + "level=\(panel.level.rawValue) alpha=\(panel.alphaValue) "
                + "sharingType=\(panel.sharingType.rawValue) frame=\(panel.frame)"
        }.joined(separator: " | ")
    }

    var hoveredWindow: WindowInfo? { picker.hovered }
    var pickableWindowCount: Int { picker.windows.count }
    var pickableWindowIDs: Set<CGWindowID> { Set(picker.windows.map(\.id)) }

    /// Drives the selection without mouse input, for `--selftest-overlay`.
    func forceSelection(_ rectInAppKitGlobal: CGRect, on screen: NSScreen) {
        model.setSelection(rectInAppKitGlobal, on: screen)
        views.forEach { $0.refresh() }
        views.forEach { $0.displayIfNeeded() }
    }

    /// Drives window-picker hover without mouse input.
    func forceHover(atAppKitGlobal point: CGPoint) {
        picker.updateHover(atAppKitGlobal: point)
        views.forEach { $0.refresh() }
        views.forEach { $0.displayIfNeeded() }
    }

    func setMode(_ newMode: SelectionMode) {
        guard newMode != mode else { return }
        toggleMode()
    }

    /// Drives the confirm path without a mouse-up, for `--selftest-lifecycle`.
    func confirmForTest() {
        confirmArea()
    }

    /// The window-mode equivalent. Worth its own hook: the lifecycle test used to
    /// stand in for this path by calling `tearDown()`, which exercises the cancel
    /// route instead — and that is precisely how `confirmWindow` shipped resuming
    /// every window capture with `.cancelled`.
    func confirmWindowForTest(_ id: CGWindowID) {
        confirmWindow(id)
    }

    var panelCount: Int { panels.count }
    var hasPendingContinuation: Bool { continuation != nil }

    // MARK: - Confirmation-step test hooks

    var isArmedForTest: Bool { isArmed }
    var toolbarIsVisibleForTest: Bool { toolbar.isVisible }
    var toolbarFrameForTest: CGRect? { toolbar.frameForTest }

    /// Begins a fresh drag the way `mouseDown` does, without a mouse. The point
    /// of the hook is the disarm side effect, which is otherwise only reachable
    /// through a real gesture.
    func restartSelectionForTest(at pointInAppKitGlobal: CGPoint, on screen: NSScreen) {
        disarm()
        model.beginDrag(at: pointInAppKitGlobal, on: screen)
    }
}
