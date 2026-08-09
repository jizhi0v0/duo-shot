import AppKit

/// Orchestrates a capture from trigger to result.
///
/// The whole area flow reads linearly here because `OverlayController.present()`
/// is an `await` rather than a delegate callback.
@MainActor
final class CaptureCoordinator {
    let engine = CaptureEngine()
    let overlay = OverlayController()
    let countdown = CaptureCountdown()

    /// `async` because the output pipeline is: the encode leg leaves the main
    /// thread and the caller has to be able to wait for it.
    var onResult: ((CaptureResult) async -> Void)?
    /// Extra windows to keep out of the shot — the floating previews, which are
    /// on screen from a previous capture and would otherwise be photographed.
    var additionalExcludedWindowIDs: () -> Set<CGWindowID> = { [] }
    /// Fired when ScreenCaptureKit reports the Screen Recording grant has lapsed.
    var onAuthorisationLost: (() -> Void)?

    init() {
        // Captures `engine` rather than `self`: the overlay holds this closure
        // for the life of the app, and routing it through the coordinator would
        // be a retain cycle for no gain.
        overlay.refreshWindows = { [engine] in
            try? await engine.refreshContent()
            return engine.shareableContent.windows
        }
        // Speculatively capture whatever the picker is suggesting, while it is
        // still fully opaque. A menu-bar popup is dismissed by the very click
        // that picks it, and the fade that starts there cannot be outrun from
        // the click — but it can be beaten from the hover. See
        // `CaptureEngine.preCapture` for the measurement.
        //
        // Gated, because a window capture is not free and hover fires often. A
        // popup is small or sits above the normal layer; an ordinary full-screen
        // window is neither, and is never dismissed by our click anyway, so its
        // live capture is always the authoritative one.
        overlay.onHoveredWindow = { [engine] window in
            let area = window.pickFrame.width * window.pickFrame.height
            let display = NSScreen.main?.frame ?? .zero
            let big = area > display.width * display.height / 4
            guard window.layer > 0 || !big else { return }
            engine.preCapture(window.id)
        }

        // Same reasoning: `engine`, not `self`. The cursor is deliberately left
        // out — a loupe magnifying a frozen arrow, while the live one moves over
        // it, is a picture of two pointers.
        overlay.captureBackdrop = { [engine] displayID, rect, excluded in
            var options = CaptureOptions.default
            options.excludedWindowIDs = excluded
            options.showsCursor = false
            let request: CaptureRequest = if let rect {
                .area(displayID: displayID, rectInAppKitGlobal: rect)
            } else {
                .display(displayID)
            }
            return try? await engine.capture(request, options: options)
        }
    }

    private var isCapturing = false
    /// The exclusion list the last capture actually went out with, for
    /// `--selftest-delay`. Reading the options back is the only way to assert
    /// that the countdown bar was named in them without depending on whether the
    /// window server had finished retiring the window.
    private(set) var lastExcludedWindowIDsForTest: Set<CGWindowID> = []
    /// Remembered for "Capture Previous Area", which repeats the last region
    /// without showing the overlay at all.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    /// Interactive capture. Returns nil if the user cancelled.
    ///
    /// One entry point, and one overlay: dragging gives a region, clicking takes
    /// the window the overlay is suggesting. Which of the two the user ends up
    /// with is only known at confirm time, so both outcomes are handled here.
    @discardableResult
    func captureInteractive() async -> CaptureResult? {
        guard !isCapturing else {
            Log.capture.notice("capture already in progress; ignoring trigger")
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }
        // Each interactive session speculates afresh. A picture of a popup from
        // the previous invocation is exactly the kind of thing that would be
        // served silently and be wrong.
        engine.forgetPreCaptures()

        do {
            try await engine.refreshContent()
        } catch {
            Log.capture.error("could not refresh shareable content: \(error, privacy: .public)")
            return nil
        }

        // Before the overlay, or there is no point. Everything freeze mode is for
        // — a hover state, an open popover, a screen that is still moving — is
        // gone the instant a window that accepts mouse events covers the pointer.
        //
        // Taken whether or not freeze mode is on, and only *shown* when it is.
        // The picture has a second job now: a menu-bar popup is dismissed by the
        // same click that picks it, and no live capture can outrun the fade that
        // starts (`WindowRecovery`). This is the only moment pixels from before
        // that click can be had, and by then nobody knows yet whether the user
        // is going to pick a window at all.
        //
        // ~80 ms per trigger for a user who has freeze off, measured with
        // `--selftest-freeze`. Paid on every interactive capture, spent on maybe
        // one in ten. The alternative — deciding later, once a popup is hovered —
        // is a photograph taken after the overlay is up, and freeze mode exists
        // precisely because that is too late.
        let photographs = await freezeEveryDisplay()
        let frozen = Preferences.shared.freezesScreen ? photographs : [:]

        let windowsAtPhotographTime = engine.shareableContent.windows
        let recovery = WindowRecovery(
            frames: photographs, windowsFrontToBack: windowsAtPhotographTime)

        let outcome = await overlay.present(windows: windowsAtPhotographTime, frozen: frozen)
        let delay = Preferences.shared.captureDelaySeconds

        switch outcome {
        case .cancelled:
            overlay.tearDown()
            return nil

        // The delay and the freeze pull in opposite directions and that is the
        // point of having both: freezing decides which *pixels* by taking them
        // early, delaying decides which *moment* by taking them late. When both
        // are on the selection is still made against the frozen picture — that is
        // what the user aimed with — and the shot itself is live, because the
        // whole reason to wait is that the interesting frame has not happened yet.
        case .area(let displayID, let rect) where delay > 0:
            lastArea = (displayID, rect)
            overlay.tearDown()
            guard await countdown.wait(seconds: delay, on: Self.screen(for: displayID))
            else { return nil }
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = countdown.lastWindowIDs
                .union(additionalExcludedWindowIDs())
            return await perform(
                .area(displayID: displayID, rectInAppKitGlobal: rect), options: options)

        case .window(let windowID) where delay > 0:
            overlay.tearDown()
            guard await countdown.wait(seconds: delay, on: NSScreen.main) else { return nil }
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = countdown.lastWindowIDs
                .union(additionalExcludedWindowIDs())
            // No recovery on the delayed path: the whole point of a delay is that
            // the interesting frame has not happened yet, so a photograph from
            // before the countdown is the wrong picture by definition.
            return await perform(.window(windowID), options: options)

        case .area(let displayID, let rect) where frozen[displayID] != nil:
            lastArea = (displayID, rect)
            defer { overlay.tearDown() }
            guard let frame = frozen[displayID],
                  let result = Self.crop(frame, to: rect, on: displayID)
            else {
                // The photograph is there and the crop still failed — a rect off
                // the edge of its own display, which the model should not be able
                // to produce. Fall through to a live capture rather than handing
                // back nothing: a screenshot without the hover beats no
                // screenshot at all.
                Log.capture.error("frozen crop failed; falling back to a live capture")
                var options = Preferences.shared.captureOptions
                options.excludedWindowIDs = overlay.panelWindowIDs
                    .union(additionalExcludedWindowIDs())
                return await perform(
                    .area(displayID: displayID, rectInAppKitGlobal: rect), options: options,
                    afterCapture: { [overlay] in overlay.tearDown() })
            }
            // The overlay comes down before the output pipeline encodes, exactly
            // as `perform` does it — the panels are not holding an exclusion list
            // open here, so there is nothing to wait for.
            overlay.tearDown()
            await onResult?(result)
            return result

        case .area(let displayID, let rect):
            // The panels are still on screen at this point, on purpose: their
            // window IDs are what keeps them out of the shot, and ordering them
            // out first would race the window server's next composite.
            lastArea = (displayID, rect)
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = overlay.panelWindowIDs
                .union(additionalExcludedWindowIDs())
            // The defer is the safety net for the failure paths; the success path
            // takes the overlay down through `afterCapture`, before the encode.
            defer { overlay.tearDown() }
            return await perform(
                .area(displayID: displayID, rectInAppKitGlobal: rect), options: options,
                afterCapture: { [overlay] in overlay.tearDown() })

        case .window(let windowID):
            // The panels are still on screen, as in the area case above. A window
            // filter contains only its window and cannot pick them up — but the
            // Dock is captured as a region of the desktop, so that its glass has
            // a backdrop to sample, and a region capture would photograph the dim.
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = overlay.panelWindowIDs
                .union(additionalExcludedWindowIDs())
            defer { overlay.tearDown() }
            return await perform(
                .window(windowID), options: options, recovery: recovery,
                afterCapture: { [overlay] in overlay.tearDown() })
        }
    }

    /// Repeats the last region with no overlay at all.
    @discardableResult
    func captureLastArea() async -> CaptureResult? {
        // Same gate as `captureInteractive`: this is on a hotkey, and a
        // double-tap would stack two full encodes on the same main-thread turn.
        guard !isCapturing else {
            Log.capture.notice("capture already in progress; ignoring trigger")
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }
        guard let lastArea else {
            Log.capture.notice("no previous area to repeat")
            NSSound.beep()
            return nil
        }
        do {
            try await engine.refreshContent()
        } catch {
            Log.capture.error("could not refresh shareable content: \(error, privacy: .public)")
            return nil
        }
        guard await countdown.wait(
            seconds: Preferences.shared.captureDelaySeconds,
            on: Self.screen(for: lastArea.displayID))
        else { return nil }
        var options = Preferences.shared.captureOptions
        options.excludedWindowIDs = countdown.lastWindowIDs
            .union(additionalExcludedWindowIDs())
        return await perform(
            .area(displayID: lastArea.displayID, rectInAppKitGlobal: lastArea.rect),
            options: options)
    }

    var hasPreviousArea: Bool { lastArea != nil }

    @discardableResult
    func captureArea() async -> CaptureResult? {
        await captureInteractive()
    }

    /// Captures the window under the pointer with no overlay at all.
    ///
    /// This used to open the overlay in window mode. Once hovering inside the
    /// ordinary overlay suggests windows on its own, that was the same gesture
    /// reached two ways — so this shortcut took the other half of the job
    /// instead, and became the zero-interaction version the way
    /// `captureLastArea` is the zero-interaction version of `captureArea`.
    ///
    /// The pointer has to already be over what you want, which is the whole
    /// point: there is no selection step to get wrong, and the preview card that
    /// lands a moment later is where you check the result.
    @discardableResult
    func captureWindow() async -> CaptureResult? {
        guard !isCapturing else {
            Log.capture.notice("capture already in progress; ignoring trigger")
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }

        do {
            try await engine.refreshContent()
        } catch {
            Log.capture.error("could not refresh shareable content: \(error, privacy: .public)")
            return nil
        }

        // The same picker the overlay drives, with the same rejection rules — a
        // window this cannot pick is one the overlay would not have offered
        // either, and having the two disagree about what "the window under the
        // pointer" means would be worse than either answer.
        let picker = WindowPickerModel()
        // The overlay keeps its own panels out; there are none here, but the
        // floating previews from an earlier shot are on screen and are the one
        // thing on this display that is certainly not what the user meant. Same
        // second line of defence as the overlay's: they are `.none` and so
        // normally invisible to the enumeration in the first place.
        picker.excludedWindowIDs = additionalExcludedWindowIDs()
        picker.load(engine.shareableContent.windows)
        picker.reRank()
        picker.updateHover(atAppKitGlobal: NSEvent.mouseLocation)

        // Deliberately not falling through to whatever is behind. With an
        // overlay up, a pointer over nothing pickable shows no highlight and the
        // user simply does not click; with no overlay there is nothing to see,
        // so capturing the window *underneath* the one being pointed at would be
        // a wrong answer delivered silently.
        guard let target = picker.hovered else {
            Log.capture.notice("no pickable window under the pointer")
            NSSound.beep()
            return nil
        }
        Log.capture.notice("""
            instant window capture: \(target.displayName, privacy: .public)
            """)

        guard await countdown.wait(
            seconds: Preferences.shared.captureDelaySeconds, on: NSScreen.main)
        else { return nil }
        var options = Preferences.shared.captureOptions
        options.excludedWindowIDs = countdown.lastWindowIDs
            .union(additionalExcludedWindowIDs())
        return await perform(.window(target.id), options: options)
    }

    /// Which `NSScreen` a display ID belongs to, for placing the countdown bar
    /// where the user is already looking.
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ScreenIndex.displayID(of: $0) == displayID } ?? NSScreen.main
    }

    /// One whole-screen photograph per display, taken with nothing of ours on
    /// screen.
    ///
    /// Sequential rather than concurrent: these are tens of megabytes each, and a
    /// three-display machine kicking off three full-resolution SCK captures at
    /// once is a spike in exactly the moment the user is waiting on.
    ///
    /// Cursorless, always, whatever the preference says. The live pointer keeps
    /// moving over a frozen screen, so a photographed one would put two arrows on
    /// screen at once — and the selection is drawn against this picture, so the
    /// second arrow would be baked into the saved image wherever the pointer
    /// happened to be at hotkey time.
    private func freezeEveryDisplay() async -> [CGDirectDisplayID: BackdropCache.Frame] {
        // `.default`, not `Preferences.captureOptions`, and the difference that
        // matters is `includeMenuBar`. That preference is about what a *fullscreen*
        // capture contains; these frames are only ever cropped for area
        // selections, where the menu bar is simply part of the screen and comes
        // out whenever the rect covers it. Inheriting the preference here would
        // punch a hole in the frozen picture where the menu bar was.
        var options = CaptureOptions.default
        options.showsCursor = false
        // The floating preview cards are ours and are on screen right now. The
        // live path keeps them out of the shot the same way; a frozen frame that
        // baked one in would carry it into every crop taken from it.
        options.excludedWindowIDs = additionalExcludedWindowIDs()

        var frames: [CGDirectDisplayID: BackdropCache.Frame] = [:]
        for screen in NSScreen.screens {
            guard let displayID = ScreenIndex.displayID(of: screen) else { continue }
            do {
                let shot = try await engine.capture(.display(displayID), options: options)
                frames[displayID] = BackdropCache.Frame(
                    image: shot.image, scale: shot.scale, covers: screen.frame)
            } catch {
                // One display failing is not a reason to lose the others: a
                // display with no frozen frame simply takes the live path.
                Log.capture.error("""
                    could not freeze display \(displayID, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return frames
    }

    /// Cuts a selection out of a frozen frame.
    ///
    /// `nonisolated` and static so it is a pure function of its arguments — this
    /// is the step where a y-flip or a scale can go wrong silently, producing a
    /// picture of the wrong part of the screen that looks entirely plausible, so
    /// it is worth being testable on its own.
    nonisolated static func crop(
        _ frame: BackdropCache.Frame, to rectInAppKitGlobal: CGRect,
        on displayID: CGDirectDisplayID
    ) -> CaptureResult? {
        guard let cut = frame.crop(toAppKitGlobal: rectInAppKitGlobal) else { return nil }
        return CaptureResult(
            image: cut.image,
            pointSize: cut.pointSize,
            scale: frame.scale,
            sourceDisplayID: displayID,
            sourceDescription: "Area",
            capturedAt: .now
        )
    }

    /// `afterCapture` runs the moment the image is in hand and before anything is
    /// done with it.
    ///
    /// It exists so the overlay can come down *before* the output pipeline
    /// encodes. The panels have to stay up across the capture itself — their
    /// window IDs are the exclusion list — but the encode is tens of milliseconds
    /// of full-resolution compression, and leaving the dim on screen for it made
    /// every capture look like a freeze. Not called on the failure path, where
    /// the retry still needs the panels.
    private func perform(
        _ request: CaptureRequest, options: CaptureOptions,
        recovery: WindowRecovery? = nil, isRetry: Bool = false,
        afterCapture: () -> Void = {}
    ) async -> CaptureResult? {
        lastExcludedWindowIDsForTest = options.excludedWindowIDs
        do {
            let result = try await engine.capture(request, options: options, recovery: recovery)
            afterCapture()
            await onResult?(result)
            return result
        } catch {
            let failure = CaptureFailure(error)
            Log.capture.error("""
                \(request.kind, privacy: .public) capture failed: \
                \(failure.summary, privacy: .public) — \
                \(error.localizedDescription, privacy: .public)
                """)

            switch failure {
            case .authorisationLost:
                // SCK does not re-prompt on our behalf; without this the app
                // just silently stops working once macOS expires the grant.
                onAuthorisationLost?()
            case .noCaptureSource where !isRetry:
                // A display or window disappeared between enumeration and
                // capture. One refresh-and-retry covers the common race.
                try? await engine.refreshContent()
                return await perform(
                    request, options: options, recovery: recovery, isRetry: true,
                    afterCapture: afterCapture)
            default:
                NSSound.beep()
            }
            return nil
        }
    }

    @discardableResult
    func captureDisplay(_ displayID: CGDirectDisplayID? = nil) async -> CaptureResult? {
        // Same gate as `captureInteractive`, for the same hotkey reason.
        guard !isCapturing else {
            Log.capture.notice("capture already in progress; ignoring trigger")
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }
        do {
            try await engine.refreshContent()
            let target = displayID
                ?? ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
                ?? CGMainDisplayID()
            guard await countdown.wait(
                seconds: Preferences.shared.captureDelaySeconds, on: Self.screen(for: target))
            else { return nil }
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = countdown.lastWindowIDs
                .union(additionalExcludedWindowIDs())
            let result = try await engine.capture(.display(target), options: options)
            await onResult?(result)
            return result
        } catch {
            Log.capture.error("display capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
