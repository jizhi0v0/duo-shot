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
    private var mode: SelectionMode = .area

    var isPresenting: Bool { !panels.isEmpty }

    /// The CGWindowIDs of our panels, for `SCContentFilter(display:excludingWindows:)`.
    ///
    /// `NSWindow.windowNumber` *is* the `CGWindowID` — that is the join key.
    var panelWindowIDs: Set<CGWindowID> {
        Set(panels.map { CGWindowID($0.windowNumber) })
    }

    func present(mode initialMode: SelectionMode, windows: [WindowInfo]) async -> Outcome {
        if isPresenting { dismiss(resumingWith: .cancelled) }

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        mode = initialMode
        model.reset()
        picker.load(windows)

        let refresh: () -> Void = { [weak self] in self?.views.forEach { $0.refresh() } }
        model.onChange = refresh
        picker.onChange = refresh

        let callbacks = OverlayView.Callbacks(
            confirmArea: { [weak self] in self?.confirmArea() },
            confirmWindow: { [weak self] id in self?.confirmWindow(id) },
            cancel: { [weak self] in self?.dismiss(resumingWith: .cancelled) },
            toggleMode: { [weak self] in self?.toggleMode() }
        )

        for screen in NSScreen.screens {
            let view = OverlayView(
                screen: screen, model: model, picker: picker, callbacks: callbacks)
            view.mode = mode
            let panel = OverlayPanel(screen: screen, view: view)
            // Registered BEFORE it goes on screen. Ordering a window can throw
            // (see `ordering`), and an exception here must not leave a panel that
            // AppKit knows about and this controller does not — that panel would
            // never be torn down and its view would be freed under AppKit's feet.
            panels.append(panel)
            views.append(view)
            guard ordering({ panel.orderFrontRegardless() }) else {
                dismiss(resumingWith: .cancelled)
                return .cancelled
            }
        }

        // Only the panel under the pointer needs the keyboard; AppKit routes
        // mouse events by position on its own.
        let pointerDisplayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
        let keyPanel = panels.first {
            $0.screen.flatMap(ScreenIndex.displayID(of:)) == pointerDisplayID
        } ?? panels.first
        guard ordering({ keyPanel?.makeKeyAndOrderFront(nil) }) else {
            dismiss(resumingWith: .cancelled)
            return .cancelled
        }
        if let index = panels.firstIndex(where: { $0 === keyPanel }) {
            keyPanel?.makeFirstResponder(views[index])
        }
        seedPointer()

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
        mode = mode.toggled
        model.reset()
        picker.reset()
        views.forEach { $0.mode = self.mode }
        seedPointer()
        Log.overlay.notice("selection mode -> \(String(describing: self.mode), privacy: .public)")
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
        // Deliberately *not* tearing down here. The panels must still be on
        // screen when the caller builds its SCContentFilter, because that is
        // where `panelWindowIDs` comes from and because ordering windows out and
        // immediately capturing races the window server's next composite — the
        // classic way to end up with the dim in the screenshot. The caller
        // captures with the panels excluded, then calls `tearDown()`.
        resume(with: .area(displayID: displayID, rectInAppKitGlobal: rect))
    }

    private func confirmWindow(_ id: CGWindowID) {
        // Window capture uses SCContentFilter(desktopIndependentWindow:), which
        // only ever contains that one window — our panels cannot get in. So
        // unlike the area path there is nothing to exclude, and tearing down
        // first avoids photographing the dim if the window is translucent.
        tearDown()
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
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
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

    var panelCount: Int { panels.count }
    var hasPendingContinuation: Bool { continuation != nil }
}
