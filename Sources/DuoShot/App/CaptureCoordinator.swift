import AppKit

/// Orchestrates a capture from trigger to result.
///
/// The whole area flow reads linearly here because `OverlayController.present()`
/// is an `await` rather than a delegate callback.
@MainActor
final class CaptureCoordinator {
    let engine = CaptureEngine()
    let overlay = OverlayController()

    var onResult: ((CaptureResult) -> Void)?
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
        overlay.captureBackdrop = { [engine] displayID, excluded in
            var options = CaptureOptions.default
            options.excludedWindowIDs = excluded
            options.showsCursor = false
            return try? await engine.capture(.display(displayID), options: options)
        }
    }

    private var isCapturing = false
    /// Remembered for "Capture Previous Area", which repeats the last region
    /// without showing the overlay at all.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    /// Interactive capture. Returns nil if the user cancelled.
    ///
    /// One entry point for both modes because Space toggles between them mid-
    /// interaction: which one the user ends up in is only known at confirm time.
    @discardableResult
    func captureInteractive(startingIn mode: SelectionMode) async -> CaptureResult? {
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

        let outcome = await overlay.present(
            mode: mode, windows: engine.shareableContent.windows)

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
            defer { overlay.tearDown() }
            return await perform(
                .area(displayID: displayID, rectInAppKitGlobal: rect), options: options)

        case .window(let windowID):
            // The panels are still on screen, as in the area case above. A window
            // filter contains only its window and cannot pick them up — but the
            // Dock is captured as a region of the desktop, so that its glass has
            // a backdrop to sample, and a region capture would photograph the dim.
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = overlay.panelWindowIDs
                .union(additionalExcludedWindowIDs())
            defer { overlay.tearDown() }
            return await perform(.window(windowID), options: options)
        }
    }

    /// Repeats the last region with no overlay at all.
    @discardableResult
    func captureLastArea() async -> CaptureResult? {
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
        await captureInteractive(startingIn: .area)
    }

    @discardableResult
    func captureWindow() async -> CaptureResult? {
        await captureInteractive(startingIn: .window)
    }

    private func perform(
        _ request: CaptureRequest, options: CaptureOptions, isRetry: Bool = false
    ) async -> CaptureResult? {
        do {
            let result = try await engine.capture(request, options: options)
            onResult?(result)
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
                return await perform(request, options: options, isRetry: true)
            default:
                NSSound.beep()
            }
            return nil
        }
    }

    @discardableResult
    func captureDisplay(_ displayID: CGDirectDisplayID? = nil) async -> CaptureResult? {
        do {
            try await engine.refreshContent()
            let target = displayID
                ?? ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
                ?? CGMainDisplayID()
            var options = Preferences.shared.captureOptions
            options.excludedWindowIDs = additionalExcludedWindowIDs()
            let result = try await engine.capture(.display(target), options: options)
            onResult?(result)
            return result
        } catch {
            Log.capture.error("display capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
