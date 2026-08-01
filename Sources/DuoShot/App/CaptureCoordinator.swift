import AppKit

/// Orchestrates a capture from trigger to result.
///
/// The whole area flow reads linearly here because `OverlayController.present()`
/// is an `await` rather than a delegate callback.
@MainActor
final class CaptureCoordinator {
    let engine = CaptureEngine()
    let overlay = OverlayController()

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

        do {
            try await engine.refreshContent()
        } catch {
            Log.capture.error("could not refresh shareable content: \(error, privacy: .public)")
            return nil
        }

        let outcome = await overlay.present(windows: engine.shareableContent.windows)

        switch outcome {
        case .cancelled:
            overlay.tearDown()
            return nil

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
                .window(windowID), options: options,
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
        var options = Preferences.shared.captureOptions
        options.excludedWindowIDs = additionalExcludedWindowIDs()
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

        var options = Preferences.shared.captureOptions
        options.excludedWindowIDs = additionalExcludedWindowIDs()
        return await perform(.window(target.id), options: options)
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
        _ request: CaptureRequest, options: CaptureOptions, isRetry: Bool = false,
        afterCapture: () -> Void = {}
    ) async -> CaptureResult? {
        do {
            let result = try await engine.capture(request, options: options)
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
                    request, options: options, isRetry: true, afterCapture: afterCapture)
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
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = additionalExcludedWindowIDs()
            let result = try await engine.capture(.display(target), options: options)
            await onResult?(result)
            return result
        } catch {
            Log.capture.error("display capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
