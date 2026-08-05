import AppKit

/// One borderless panel per `NSScreen`.
///
/// Not one giant window spanning every display, for three reasons that all bite
/// on a real multi-monitor setup:
///
/// 1. **Backing scale.** A spanning window has a single `backingScaleFactor`, so
///    hairlines and the crosshair render blurry on the other display.
/// 2. **Dead zones.** The union of a non-rectangular arrangement contains regions
///    that are on no display; the overlay would dim empty space and let you drag
///    a selection over nothing.
/// 3. **Identity.** A per-screen panel gives `panel.screen` directly, hence the
///    `CGDirectDisplayID`. A spanning window must hit-test every screen on every
///    mouse-moved event.
final class OverlayPanel: NSPanel {
    /// Test hook. `sharingType = .none` and `SCContentFilter(excludingWindows:)`
    /// are two independent ways to keep the overlay out of a capture; this lets
    /// the self-test disable them one at a time and find out which is actually
    /// doing the work — and, critically, that the test can fail at all.
    static var usesSharingTypeNone = true

    // **Never key.** This panel used to take key status to receive `keyDown`,
    // and that is what made a menu-bar app's popup unpickable: those panels
    // close when they resign key, so the thing the user was aiming at vanished
    // the instant the overlay appeared.
    //
    // Measured 2026-08-05 with `Scripts/popup-key-probe.swift`, which raises
    // this exact panel — same style mask, same shielding level, same collection
    // behaviour — differing only in this property:
    //
    //     canBecomeKey = false -> popup survived 1500 ms, 3 of 3 rounds
    //     canBecomeKey = true  -> popup died within 0-50 ms, 3 of 3 rounds
    //
    // `false` rather than merely not calling `makeKeyAndOrderFront`, because a
    // click on a key-capable panel makes it key by itself — which would have
    // killed the popup at the exact moment of picking it, one step before the
    // capture.
    //
    // The keyboard comes from `OverlayController.bindKeys` instead: the keys
    // this overlay needs are registered as transient Carbon hot keys, which
    // arrive without focus and without an Accessibility grant.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, view: NSView, hiddenFromCapture: Bool = true) {
        super.init(
            contentRect: screen.frame,
            // `.nonactivatingPanel` is the load-bearing flag. The naive approach
            // — NSApp.activate() + makeKeyAndOrderFront — works, but deactivates
            // the user's frontmost app *before the screenshot is taken*: title
            // bars grey out, carets stop blinking, some apps dim their chrome,
            // and all of that lands in the captured image. A non-activating panel
            // takes the keyboard without activating our application.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // ORDER MATTERS. `isFloatingPanel = true` resets the window level to
        // .floating (3), which is *below* the menu bar (24) and the Dock (20) —
        // so setting it after `level` silently undoes the shielding level and
        // the overlay stops covering them. Measured: level read back as 3.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false

        // The level the loginwindow shield uses (2147483628): unambiguously above
        // the menu bar and the Dock. `.screenSaver` (1000) also works today but is
        // a weaker guarantee.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // `.fullScreenAuxiliary` is what lets the overlay appear over another
        // app's fullscreen Space instead of forcing a Space switch.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // NSPanel resolves `.default` to the utility-window behaviour: macOS
        // scales the window up from ~90% and cross-fades it in on order-front.
        // For a full-screen overlay that means the crosshair, the dim edge and
        // the hint are all composited *offset from where they belong* for the
        // first ~0.15 s and then slide to their true positions — the pointer's
        // crosshair visibly drifts in from down-and-right of the real pointer.
        // A screenshot overlay must be exact on frame one, so: no animation.
        animationBehavior = .none

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        worksWhenModal = true
        ignoresMouseEvents = false
        // Belt alongside SCContentFilter(display:excludingWindows:). Historically
        // this excludes a window from screen captures; both mechanisms are used,
        // neither is relied on alone.
        // Two independent reasons to be capturable, and both must agree before
        // the panel hides: the self-tests force `.readOnly` to prove exclusion
        // works without it, and the user can ask for the overlay to be visible
        // to screen sharing.
        sharingType = (Self.usesSharingTypeNone && hiddenFromCapture) ? .none : .readOnly

        contentView = view
        setFrame(screen.frame, display: false)
    }
}
