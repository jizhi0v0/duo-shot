import AppKit
import ScreenCaptureKit

/// The screen as it was *before* the user's pick, for the case where a window
/// capture comes back faded.
///
/// A menu-bar popup is dismissed by the same click that selects it, and the
/// window server fades it out over 150–350 ms while ScreenCaptureKit needs
/// 90–320 ms to answer — so the live shot lands inside the fade and the returned
/// image carries the compositor's alpha. Measured 2026-08-09: DuoShot's own
/// capture read mean body alpha 0/255 at 14:32:33.32 while an outside observer
/// read `kCGWindowAlpha` 0.502 for the same window at 14:32:33.31.
///
/// There is no way to win that race — the capture is slower than the fade — so
/// the only fix is to already hold pixels from before the click.
///
/// MainActor-bound on purpose. It carries a `CGImage`, and this module's rule is
/// that images do not cross isolation boundaries; nothing here ever leaves the
/// main actor.
struct WindowRecovery {
    /// One whole-screen photograph per display, taken before the overlay was on
    /// screen — which is also before the click that starts the fade.
    let frames: [CGDirectDisplayID: BackdropCache.Frame]
    /// The window list as it was at that same instant, front to back.
    ///
    /// Cutting a window out of a photograph of the whole screen is only honest
    /// when nothing was drawn over it, and "was" means *then*: by the time the
    /// fallback runs, the window is half gone and its own z-order says nothing
    /// useful.
    let windowsFrontToBack: [WindowInfo]
    /// Isolated captures, from that same instant, of the windows an app had
    /// raised over one of its own — a tooltip over its panel. See
    /// `CaptureEngine.adornments(of:in:excluding:)`.
    ///
    /// Taken before the overlay because the overlay is what dismisses them:
    /// measured 2026-09-11 on DuoUpdater, its tooltip was gone within 0.75 s of
    /// the overlay appearing, before the pick. At pick time there is nothing
    /// left to capture.
    var adornments: [CGWindowID: CaptureEngine.WindowShot] = [:]
}

/// Builds filters and configurations, and turns a `CaptureRequest` into a
/// `CaptureResult`.
///
/// A `@MainActor final class`, deliberately not an `actor`: it does essentially
/// no CPU work — ScreenCaptureKit does everything out of process — while it does
/// need `NSScreen`, `NSWindow.windowNumber` and live `SCDisplay`/`SCWindow`
/// objects, all of which are MainActor-bound. Making it an actor would force a
/// Sendable box around every screen read and buy nothing.
final class CaptureEngine {
    private let content = ShareableContentCache()
    private let wallpaper = DesktopWallpaper()

    /// An isolated capture of a window taken while the pointer was merely
    /// hovering it — before the click that dismisses a menu-bar popup, and so
    /// before the fade that click starts.
    ///
    /// **Why this beats the race the shipping capture cannot.** ScreenCaptureKit
    /// samples the frame close to when the request is *made*, not when it
    /// returns. Measured 2026-08-09 against a 250 ms fade, six runs each way:
    ///
    ///     request at the fade's start   capture took 272-277 ms  alpha 219-230/255
    ///     request 50 ms before it       capture took 326-328 ms  alpha 250/255
    ///     request 150 ms before it      capture took 429-436 ms  alpha 250/255
    ///
    /// A capture that *finishes* long after the window is gone still comes back
    /// at full opacity, provided it was asked for in time. Fifty milliseconds is
    /// enough, and a human takes far longer than that between settling on a
    /// window and clicking it.
    private var preCaptures: [CGWindowID: WindowShot] = [:]
    /// One speculative capture in flight at a time. Hover fires on every pointer
    /// move that changes the suggestion, and a window capture is not free.
    private var preCaptureInFlight = false
    /// For the self-tests: how many speculative captures have been started.
    private(set) var preCaptureCount = 0
    /// For the self-tests: the last reading `photographDisagreement` produced,
    /// so the threshold can be chosen from measurements instead of taste.
    private(set) var lastPhotographDisagreement: Int?

    /// Starts a speculative capture of a window the user is only hovering.
    ///
    /// Deliberately not `async` for the caller: the picker's hover callback must
    /// not wait on ScreenCaptureKit, and nothing goes wrong if the result lands
    /// after the click — it is consulted only when the live capture has already
    /// come back faded.
    func preCapture(_ windowID: CGWindowID) {
        guard !preCaptureInFlight, preCaptures[windowID] == nil else { return }
        guard let window = content.scWindow(for: windowID) else { return }
        preCaptureInFlight = true
        preCaptureCount += 1
        Task { [weak self] in
            defer { self?.preCaptureInFlight = false }
            guard let shot = try? await self?.captureIsolated(window, options: .default)
            else { return }
            // A speculative capture of a window that was *already* fading is
            // worth nothing, and keeping it would let the recovery hand back the
            // very thing it exists to avoid.
            guard PixelCompare.bodyOpacity(shot.image).meanAlpha >= 250 else { return }
            self?.preCaptures[windowID] = shot
        }
    }

    /// Drops the speculative captures. Called when the overlay comes down, so a
    /// later pick cannot be served pixels from a previous session.
    func forgetPreCaptures() {
        preCaptures.removeAll()
    }

    var shareableContent: ShareableContentCache { content }

    /// The padding backdrop for a display, for the self-tests. The shipping
    /// path reaches it through `pad`.
    func wallpaperBackdrop(for displayID: CGDirectDisplayID) async -> CGImage? {
        await wallpaper.image(for: displayID)
    }

    /// Drops the cached wallpaper, so a test can force a fresh grab.
    func invalidateWallpaper() {
        wallpaper.invalidate()
    }

    func refreshContent(onScreenOnly: Bool = true) async throws {
        try await content.refresh(onScreenOnly: onScreenOnly)
    }

    func capture(
        _ request: CaptureRequest,
        options: CaptureOptions = .default,
        recovery: WindowRecovery? = nil
    ) async throws -> CaptureResult {
        // Refresh when the cache cannot serve this request, not merely when it is
        // empty: a stale list that no longer contains the target display would
        // otherwise fail without ever re-enumerating.
        //
        // ScreenCaptureKit has been observed returning an empty display list
        // while `screencapture(1)`, the window enumeration and the TCC grant all
        // stayed healthy, recovering on its own later. A couple of retries turn
        // the short version of that into a hiccup instead of a failed capture.
        var attempt = 0
        while !canServe(request) {
            try await content.refresh()
            if canServe(request) { break }
            attempt += 1
            guard attempt < 3 else { break }
            Log.capture.notice("""
                shareable content cannot serve \(request.kind, privacy: .public); \
                retry \(attempt, privacy: .public)
                """)
            try? await Task.sleep(for: .milliseconds(250 * attempt))
        }

        let started = ContinuousClock.now
        let result: CaptureResult
        switch request {
        case .area(let displayID, let rect):
            result = try await captureArea(displayID: displayID, rectInAppKitGlobal: rect, options: options)
        case .display(let displayID):
            result = try await captureDisplay(displayID, options: options)
        case .window(let windowID):
            result = try await captureWindow(windowID, options: options, recovery: recovery)
        }

        Log.capture.notice("""
            captured \(request.kind, privacy: .public) \
            \(Int(result.pixelSize.width), privacy: .public)x\(Int(result.pixelSize.height), privacy: .public) px \
            scale=\(result.scale, privacy: .public) \
            in \(started.duration(to: .now).milliseconds, privacy: .public) ms
            """)
        return result
    }

    private func canServe(_ request: CaptureRequest) -> Bool {
        switch request {
        case .area(let displayID, _), .display(let displayID):
            content.scDisplay(for: displayID) != nil
        case .window(let windowID):
            content.scWindow(for: windowID) != nil
        }
    }

    // MARK: - Area

    private func captureArea(
        displayID: CGDirectDisplayID, rectInAppKitGlobal: CGRect, options: CaptureOptions
    ) async throws -> CaptureResult {
        guard let display = content.scDisplay(for: displayID) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = try await displayFilter(display, options: options)
        let scale = CGFloat(filter.pointPixelScale)
        let sourceRect = DisplayGeometry.sourceRect(
            fromAppKitGlobal: rectInAppKitGlobal, on: displayID)

        let configuration = configuration(for: sourceRect, scale: scale, options: options)
        configuration.sourceRect = sourceRect

        let output = try await SCKBridge.captureScreenshot(filter: filter, configuration: configuration)
        guard let image = output.image else { throw CaptureError.noImageProduced }
        return CaptureResult(
            image: image,
            pointSize: sourceRect.size,
            scale: scale,
            sourceDisplayID: displayID,
            sourceDescription: "Area",
            capturedAt: .now
        )
    }

    // MARK: - Whole display

    private func captureDisplay(
        _ displayID: CGDirectDisplayID, options: CaptureOptions
    ) async throws -> CaptureResult {
        guard let display = content.scDisplay(for: displayID) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = try await displayFilter(display, options: options)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = configuration(for: filter.contentRect, scale: scale, options: options)

        let output = try await SCKBridge.captureScreenshot(filter: filter, configuration: configuration)
        guard let image = output.image else { throw CaptureError.noImageProduced }

        let index = content.displayIDs.firstIndex(of: displayID).map { $0 + 1 } ?? 1
        return CaptureResult(
            image: image,
            pointSize: filter.contentRect.size,
            scale: scale,
            sourceDisplayID: displayID,
            sourceDescription: "Display \(index)",
            capturedAt: .now
        )
    }

    // MARK: - Window

    private func captureWindow(
        _ windowID: CGWindowID, options: CaptureOptions, recovery: WindowRecovery? = nil
    ) async throws -> CaptureResult {
        guard let window = content.scWindow(for: windowID) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let displayID = ScreenIndex
            .screen(containingAppKitGlobal: DisplayGeometry.flipped(window.frame).origin)
            .flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let info = content.windows.first { $0.id == windowID }

        var shot: WindowShot
        if let region = info?.visibleFrame {
            shot = try await captureStrip(
                region, of: windowID, on: displayID, options: options, recovery: recovery)
        } else {
            shot = try await captureIsolated(window, options: options)
        }

        // How opaque the window came back.
        //
        // Not instrumentation any more — it is the trigger. A window the
        // compositor is fading comes back carrying that fade, and the only thing
        // that can tell is the alpha of the pixels themselves.
        //
        // One 64×64 downscale per window capture, which is nothing next to the
        // capture it follows.
        let opacity = PixelCompare.bodyOpacity(shot.image)
        Log.capture.notice("""
            window \(windowID, privacy: .public) opacity: \
            body \(opacity.pixels, privacy: .public)/4096 cells, \
            mean alpha \(opacity.meanAlpha, privacy: .public)/255\
            \(opacity.meanAlpha >= 250 ? "" : "  DEGRADED", privacy: .public)
            """)
        if opacity.meanAlpha < 250 {
            // The hover picture first. It is an ordinary isolated capture, so it
            // frames exactly as a clean one does and contains one window's pixels
            // and nothing else — which is why this path needs no occlusion test
            // and leaves no border the trim would have removed. The photograph is
            // the fallback for when there was no hover to speculate on: a fast
            // click, a popup opened under a stationary pointer, a pick made by
            // keyboard.
            if let hovered = preCaptured(matching: shot, of: windowID) {
                shot = hovered
            } else if let rescued = recovered(
                shot, of: windowID, on: displayID, using: recovery) {
                shot = rescued
            }
        }

        // After the fade recovery, which judges the window by its own pixels and
        // would read a tooltip drawn over it as something occluding it. The Dock's
        // region capture already holds everything on screen.
        if info?.visibleFrame == nil {
            shot = await withAdornments(shot, of: windowID, options: options, recovery: recovery)
        }

        let (padded, pointSize) = await pad(
            shot.image, size: shot.pointSize, scale: shot.scale,
            on: displayID, options: options, bodyTop: shot.bodyTop)
        return CaptureResult(
            image: padded,
            pointSize: pointSize,
            scale: shot.scale,
            sourceDisplayID: displayID,
            sourceDescription: info?.displayName ?? "Window",
            capturedAt: .now,
            coversInCGGlobal: options.windowPadding > 0 ? nil : shot.coversInCGGlobal
        )
    }

    /// A window as it looks on screen, for the command line's default `shot`.
    struct SeenWindow {
        let result: CaptureResult
        /// The window, the group `captureGroup` framed with it and the
        /// adornments drawn over it — everything in the file that is *its own*.
        /// Any other window in front of it inside `result.coversInCGGlobal` is
        /// in the picture too, and the caller says so.
        let ownWindowIDs: Set<CGWindowID>
    }

    /// A window that was not the same on both sides of an as-seen capture.
    struct ChangedDuringCapture: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// For the self-test: runs between the shape and the region of an as-seen
    /// capture, which is the window in which a closing panel goes unnoticed.
    var betweenAsSeenCapturesForTest: (() async -> Void)?

    /// The window's region of the screen, cut to the window's own alpha.
    ///
    /// The Dock's technique (`captureStrip` + `shaped`) applied to any window.
    /// An isolated capture flattens a translucent surface to its base tint —
    /// there is no backdrop left in it to sample (see "Window capture" in
    /// CLAUDE.md: red behind a glass panel counted 0 in every isolated mode and
    /// 432906 as a region). So the isolated capture supplies only the *shape*
    /// and the rect — group framing, trim and adornments exactly as the
    /// ordinary path frames them — and the pixels come from the same rect taken
    /// off the display, kept where that shape has alpha.
    ///
    /// The two captures are taken one after the other, not at one instant, and
    /// a panel that closes between them leaves a shape with nothing of the
    /// panel's under it: measured in acceptance, closing one 110–130 ms after
    /// the request returned success, alpha 1, and a picture of what was behind
    /// it cut to the panel's outline, 6 times in 14. So after the region the
    /// window is checked again — on screen, where it was, opaque — and its
    /// shape retaken and compared. Anything different throws
    /// `ChangedDuringCapture`, which is worth retrying; a wrong picture is not.
    func captureAsSeen(_ windowID: CGWindowID, options: CaptureOptions) async throws -> SeenWindow {
        guard let window = content.scWindow(for: windowID) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let info = content.windows.first { $0.id == windowID }
        // The Dock is already captured this way, from its own pixels.
        if info?.visibleFrame != nil {
            let result = try await capture(.window(windowID), options: options)
            return SeenWindow(result: result, ownWindowIDs: [windowID])
        }
        let displayID = ScreenIndex
            .screen(containingAppKitGlobal: DisplayGeometry.flipped(window.frame).origin)
            .flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        guard let before = WindowZOrder.entries()[windowID]?.bounds else {
            throw ChangedDuringCapture(reason: "window \(windowID) is no longer on screen")
        }
        let base = try await captureIsolated(window, options: options)
        var shape = await withAdornments(base, of: windowID, options: options, recovery: nil)
        var own = shape.groupedWindowIDs.union([windowID])
        let live = WindowZOrder.sortedFrontToBack(content.windows)
        if let picked = live.first(where: { $0.id == windowID }) {
            own.formUnion(Self.adornments(
                of: picked, in: live,
                excluding: options.excludedWindowIDs.union(shape.groupedWindowIDs)).map(\.id))
        }

        await betweenAsSeenCapturesForTest?()
        let region = try await captureRegion(
            shape.coversInCGGlobal, on: displayID, options: options)
        try await confirmUnchanged(windowID, window: window, bounds: before, shape: base, options: options)
        guard let cut = await WindowComposite.masking(region.image, to: shape.image) else {
            throw CaptureError.noImageProduced
        }
        Log.capture.notice("""
            window \(windowID, privacy: .public) captured as seen: \
            \(cut.width, privacy: .public)x\(cut.height, privacy: .public) px of the display, \
            cut to its own outline
            """)
        return SeenWindow(
            result: CaptureResult(
                image: cut,
                pointSize: shape.coversInCGGlobal.size,
                scale: region.scale,
                sourceDisplayID: displayID,
                sourceDescription: info?.displayName ?? "Window",
                capturedAt: .now,
                coversInCGGlobal: shape.coversInCGGlobal),
            ownWindowIDs: own)
    }

    /// The second half of `captureAsSeen`'s guard: the window as it is now
    /// against the window the shape was taken from.
    private func confirmUnchanged(
        _ windowID: CGWindowID, window: SCWindow, bounds: CGRect, shape: WindowShot,
        options: CaptureOptions
    ) async throws {
        guard let now = WindowZOrder.entries()[windowID], let where_ = now.bounds else {
            throw ChangedDuringCapture(reason: "window \(windowID) closed while it was being captured")
        }
        guard now.alpha >= 0.99 else {
            throw ChangedDuringCapture(reason: String(
                format: "window %u started fading while it was being captured (alpha=%.3f)",
                windowID, now.alpha))
        }
        guard where_ == bounds else {
            throw ChangedDuringCapture(reason: "window \(windowID) moved or resized while it was being captured")
        }
        let again = try? await captureIsolated(window, options: options)
        guard let again, !PixelCompare.isBlank(again.image),
              again.coversInCGGlobal == shape.coversInCGGlobal
        else {
            throw ChangedDuringCapture(reason: "window \(windowID) changed shape while it was being captured")
        }
    }

    /// Whether a window paints anything inside a rect (CG global points), from
    /// its own pixels captured alone. Nil when it could not be captured.
    ///
    /// Every pixel of the overlap, not a thumbnail: an occluder can be a few
    /// points of a much larger window, and a downscale averages it away.
    func draws(_ windowID: CGWindowID, within rectInCGGlobal: CGRect) async -> Bool? {
        guard let window = content.scWindow(for: windowID) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        guard let image = try? await SCKBridge.captureScreenshot(
                  filter: filter,
                  configuration: configuration(for: filter.contentRect, scale: scale, options: .default)
              ).image
        else { return nil }
        let frame = window.frame
        let pixels = CGRect(
            x: (rectInCGGlobal.minX - frame.minX) * scale,
            y: (rectInCGGlobal.minY - frame.minY) * scale,
            width: rectInCGGlobal.width * scale, height: rectInCGGlobal.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, !pixels.isEmpty, let crop = image.cropping(to: pixels) else {
            return false
        }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 8 }
    }

    /// A window capture, plus where on the desktop its pixels came from.
    ///
    /// The rect is what makes the fade recovery possible at all: the same
    /// region has to be cut out of a photograph of the whole screen, and the
    /// trim (`trimmed`) moves the origin as well as the size.
    struct WindowShot {
        let image: CGImage
        let pointSize: CGSize
        let scale: CGFloat
        /// CG global points, origin top-left — the same space `SCWindow.frame`
        /// and `WindowInfo.frame` are in.
        let coversInCGGlobal: CGRect
        /// The window's whole frame, before `trimmed` dropped the border it never
        /// drew. Equal to `coversInCGGlobal` when nothing was trimmed.
        let frameInCGGlobal: CGRect
        /// The windows `captureGroup` brought in with this one, so that
        /// `withAdornments` does not draw any of them a second time.
        var groupedWindowIDs: Set<CGWindowID> = []
        /// Pixel rows at the top that the window shows above its body — the
        /// Dock's name label — which the padding lets stand in its top margin
        /// (`ImagePadding.topInset`). 0 for every ordinary window.
        var bodyTop = 0
    }

    /// The speculative capture taken while the window was merely hovered, if it
    /// is still the right picture of the right window.
    ///
    /// The frame check is the one guard that matters: a popup can resize between
    /// the hover and the click — DuoUpdater's grows when a check finishes — and a
    /// stale picture of a smaller window is a wrong screenshot, not a rescued
    /// one. Everything else the photograph path has to worry about is absent
    /// here, because an isolated capture cannot contain another window.
    private func preCaptured(matching shot: WindowShot, of windowID: CGWindowID) -> WindowShot? {
        guard let hovered = preCaptures[windowID] else { return nil }
        let before = hovered.frameInCGGlobal, now = shot.frameInCGGlobal
        guard abs(before.width - now.width) <= 1, abs(before.height - now.height) <= 1,
              abs(before.minX - now.minX) <= 1, abs(before.minY - now.minY) <= 1
        else {
            Log.capture.notice("""
                window \(windowID, privacy: .public) came back faded and the hover \
                capture is of a different frame; ignoring it
                """)
            return nil
        }
        Log.capture.notice("""
            window \(windowID, privacy: .public) recovered from the hover capture: \
            mean alpha \(PixelCompare.bodyOpacity(hovered.image).meanAlpha, privacy: .public)/255
            """)
        return hovered
    }

    /// Mean per-channel distance between the photograph and the window's own
    /// colour, over the part of the faded capture that is solid enough to speak.
    ///
    /// The faded capture stores colour premultiplied by the compositor's alpha,
    /// so `colour = stored * 255 / alpha` is what the photograph should hold at
    /// that pixel. Both are reduced to the same small grid first: this runs on
    /// the main thread behind a capture that may be 15 megapixels, and the
    /// separation between "clear" and "occluded" is more than twentyfold, so it
    /// does not need the resolution.
    ///
    /// Nil when the two cannot be compared at all — no crop, or too little solid
    /// body to judge from — which the caller treats as "do not swap".
    private func photographDisagreement(
        _ shot: WindowShot, _ frame: BackdropCache.Frame
    ) -> Int? {
        guard let cut = frame.crop(
            toAppKitGlobal: DisplayGeometry.flipped(shot.coversInCGGlobal))
        else { return nil }

        let side = 128
        func grid(_ image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            return drawn ? pixels : nil
        }
        guard let faded = grid(shot.image), let photo = grid(cut.image) else { return nil }

        var samples = 0, total = 0
        for index in stride(from: 0, to: faded.count, by: 4) {
            let alpha = Int(faded[index + 3])
            // The un-premultiply amplifies each channel by 255/alpha, and the
            // half-bit of quantisation in the capture with it. Where that stops
            // being usable was measured, not guessed —
            // `--selftest-occluded-recovery` prints this sweep and will print it
            // again on any machine that doubts it:
            //
            //     fade   clear   occluded
            //     0.60       2         72
            //     0.30       2         72
            //     0.15       3         72
            //     0.08       8         74
            //     0.04      12         71
            //
            // Four is the floor. The clear reading *is* the noise, and it roughly
            // doubles as the window halves; at alpha 4 the amplification is 64x
            // and the predicted worst case (±32) crosses the threshold below, so
            // a fainter pixel would be voting on nothing. Everything under it is
            // dropped, and a window with too little left is reported as
            // unjudgeable rather than as agreeing.
            guard alpha > 4 else { continue }
            samples += 1
            for channel in 0..<3 {
                let restored = min(255, Int(faded[index + channel]) * 255 / alpha)
                total += abs(restored - Int(photo[index + channel]))
            }
        }
        // A window with almost no solid body cannot testify about itself.
        guard samples >= side * side / 20 else { return nil }
        return total / (samples * 3)
    }

    /// The same window, cut out of a photograph taken before the fade started.
    ///
    /// Returns nil — leaving the faded capture alone — whenever the swap cannot
    /// be made honestly. Every one of those guards is load-bearing:
    ///
    /// - **No photograph for this display.** Nothing to fall back to.
    /// - **Something was drawn over the window.** Cutting it out of a picture of
    ///   the whole screen would hand back somebody else's pixels, which is the
    ///   one thing a selection UI must never do (see `trimmed`). Judged against
    ///   the window list from the photograph's own instant, because by now the
    ///   target is half gone and its live z-order says nothing useful.
    /// - **The photograph is no better.** If the window was already faded when
    ///   the picture was taken, swapping changes nothing and only risks the
    ///   geometry. This also covers the case where the fallback is simply wrong
    ///   about which pixels it cut.
    private func recovered(
        _ shot: WindowShot, of windowID: CGWindowID,
        on displayID: CGDirectDisplayID, using recovery: WindowRecovery?
    ) -> WindowShot? {
        guard let recovery, let frame = recovery.frames[displayID] else { return nil }

        // The window has to have existed when the photograph was taken; a popup
        // that opened afterwards is not in that picture at all.
        guard recovery.windowsFrontToBack.contains(where: { $0.id == windowID })
        else { return nil }

        // Was anything actually drawn over the window in that photograph?
        //
        // **Not z-order.** The first version of this asked the window server for
        // depth and frame intersection, and it is not an answer: measured
        // 2026-08-09 on the deployment-minimum machine, `UserNotificationCenter`
        // is listed at depth 3, `alpha=1.00`, frame (830,190 260x364) — in front
        // of everything in the middle of the screen and drawing nothing at all.
        // It vetoed every recovery on that machine and none on the developer's,
        // which is to say the rule's answer depended on luck. A window list
        // cannot report "this one draws nothing".
        //
        // Pixels can. The faded capture is the window's own colour premultiplied
        // by the compositor's alpha, so un-premultiplying it recovers the colour
        // the photograph must also show — unless something was drawn on top of
        // it there. Measured on the fixture across fade depths: 2–12 with nothing
        // over the window, 71–74 with an opaque panel over half of it. The gap
        // never closes above alpha 4/255, so twenty-four is read off a
        // measurement rather than being a number anyone has to tune.
        let disagreement = photographDisagreement(shot, frame)
        lastPhotographDisagreement = disagreement
        guard let disagreement else { return nil }
        guard disagreement <= 24 else {
            Log.capture.notice("""
                window \(windowID, privacy: .public) came back faded, and the \
                photograph disagrees with it by \(disagreement, privacy: .public)/255 — \
                something was over it; keeping the live capture
                """)
            return nil
        }

        // The window's whole frame, *not* the trimmed rect the live capture
        // produced. `trimmed` finds the drawn content by asking "alpha > 0" on a
        // downscale, and a fade pushes the faintest edges below the 8-bit floor
        // before it touches the body — so the deeper the fade, the further in the
        // trim walks, asymmetrically. Measured on DuoUpdater's popup, same window
        // every time: mean alpha 254/180/174 all trimmed to 312x343 pt, mean
        // alpha 0 trimmed to 297x335 and then 291x332. Cutting *that* rect out of
        // the photograph is what put the left third of the panel outside the
        // frame.
        //
        // The information is gone from the capture, not from the measurement, so
        // no cleverer threshold recovers it. What is left is to not depend on it:
        // the frame is a property of the window and does not fade. The cost is
        // that a recovered capture keeps the border the window never drew — for
        // this popup, 360x373 pt where a clean capture gives 312x343 — which is
        // looser framing, not wrong pixels.
        guard let cut = frame.crop(
            toAppKitGlobal: DisplayGeometry.flipped(shot.frameInCGGlobal))
        else { return nil }
        let after = PixelCompare.bodyOpacity(cut.image)
        guard after.meanAlpha > PixelCompare.bodyOpacity(shot.image).meanAlpha else {
            Log.capture.notice("""
                window \(windowID, privacy: .public) came back faded and the \
                photograph is no better; keeping the live capture
                """)
            return nil
        }

        Log.capture.notice("""
            window \(windowID, privacy: .public) recovered from the pre-pick \
            photograph: mean alpha \(after.meanAlpha, privacy: .public)/255
            """)
        return WindowShot(
            image: cut.image, pointSize: cut.pointSize, scale: frame.scale,
            coversInCGGlobal: shot.frameInCGGlobal,
            frameInCGGlobal: shot.frameInCGGlobal)
    }

    /// Captures a single window, alone — and notices when "alone" left nothing.
    ///
    /// `includeChildWindows` is off (see `CaptureOptions` for the WeChat alert
    /// that turned it off), and for most windows that is right. For some it is
    /// catastrophic: a window can be a bare frame whose entire visible content
    /// is a child window drawn inside it, and captured without its children it
    /// comes back not merely wrong but *empty*.
    ///
    /// Measured 2026-08-04 on DuoUpdater's menu-bar popup, one flag apart, same
    /// window and same instant:
    ///
    ///     includeChildWindows = false ->  0.0% non-black, mean luma  0.0
    ///     includeChildWindows = true  -> 35.1% non-black, mean luma 13.9
    ///
    /// Reported as "window screenshot of the popup is a black rectangle with no
    /// content", and true of every menu-bar popup tried — ClaudeUsageMenuBar's
    /// came out black too.
    ///
    /// So: keep the flag off, and treat a blank result as the evidence it is.
    /// Retrying is not a guess about which kind of window this was — it is a
    /// response to a capture that is already known to be worthless, and it
    /// cannot reach the case the flag exists for, because an alert composited
    /// over its parent is many things but never empty. The first image is kept
    /// if the retry is blank too, so a genuinely empty window is not made worse.
    private func captureIsolated(
        _ window: SCWindow, options: CaptureOptions
    ) async throws -> WindowShot {
        // Anything the window's own app has stacked on top of it is thrown away
        // by an isolated capture, so that case is answered before this one.
        if !options.includeChildWindows,
           let grouped = try await captureGroup(window, options: options) {
            return grouped
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        // `window.frame`, not `filter.contentRect`: the sizes agree, and only
        // the window's frame carries an origin on the desktop, which the fade
        // recovery needs to find the same region in a photograph of the screen.
        let frame = window.frame

        let output = try await SCKBridge.captureScreenshot(
            filter: filter,
            configuration: configuration(for: filter.contentRect, scale: scale, options: options))
        guard let captured = output.image else { throw CaptureError.noImageProduced }
        guard !options.includeChildWindows, PixelCompare.isBlank(captured) else {
            return trimmed(captured, frame: frame, scale: scale)
        }

        Log.capture.notice("""
            window \(window.windowID, privacy: .public) captured blank; \
            retrying with child windows
            """)
        var retried = options
        retried.includeChildWindows = true
        let second = try await SCKBridge.captureScreenshot(
            filter: filter,
            configuration: configuration(for: filter.contentRect, scale: scale, options: retried))
        guard let image = second.image, !PixelCompare.isBlank(image) else {
            return trimmed(captured, frame: frame, scale: scale)
        }
        return trimmed(image, frame: frame, scale: scale)
    }

    /// Captures a window together with whatever its own app has stacked on top
    /// of it — a popover, an attached panel, a sheet.
    ///
    /// Reported as "popover 无法通过窗口截图保留这种堆叠的关系", against
    /// DuoUpdater's runtime tag, which is a SwiftUI `.popover`. An isolated
    /// filter holds one window and nothing else, so the bubble is simply not in
    /// the picture. Measured on a replica of that app's shape — `MenuBarExtra`
    /// with `.menuBarExtraStyle(.window)`, a `.popover` opened inside it — one
    /// flag apart, same window and same instant:
    ///
    ///     includeChildWindows = false ->      0 px of the popover's colour
    ///     includeChildWindows = true  -> 71854 px
    ///
    /// **Membership is ScreenCaptureKit's, never ours.** The group it composites
    /// is the window server's own parent/child group, which is why an unrelated
    /// window of the same app cannot arrive in it: measured on one ordinary
    /// desktop, fourteen pairs of same-app windows overlapped each other — four
    /// Finder windows, four Mail windows — and a rule of our own that said
    /// "same app, in front, overlapping" would have dragged every one of them
    /// into a capture of the window behind. `stacked` only decides whether to
    /// *ask*.
    ///
    /// Returns nil when the group turns out to be the window alone, or when its
    /// rect cannot be established — both of which leave the caller on the
    /// ordinary isolated path.
    private func captureGroup(
        _ window: SCWindow, options: CaptureOptions
    ) async throws -> WindowShot? {
        let above = stacked(on: window.windowID, options: options)
        guard !above.isEmpty else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        var grouped = options
        grouped.includeChildWindows = true
        // **The output size is left unset, and that is the whole of this path
        // working.** ScreenCaptureKit grows the captured region to the group's
        // own rect and then fits it into whatever size it was given — so asking
        // for the picked window's size returns the group *squeezed* into it,
        // scaled down with transparent margins, under a point size that claims
        // to be the window's. Measured on the replica: a 420x300 pt panel with a
        // popover overhanging it by 84 pt came back as the 504x300 pt group
        // letterboxed into 840x600 px. Left alone, the header's documented
        // default — "the width of the content being captured" — is the group's
        // rect, and it came back 1008x600 px, exactly right.
        let configuration = configuration(for: nil, scale: scale, options: grouped)

        let output = try await SCKBridge.captureScreenshot(
            filter: filter, configuration: configuration)
        guard let image = output.image, !PixelCompare.isBlank(image) else { return nil }

        let frame = window.frame
        let size = CGSize(width: CGFloat(image.width) / scale,
                          height: CGFloat(image.height) / scale)
        // Something was in front of it, but nothing was *grouped* with it — an
        // overlapping window of the same app, which is the common case. The
        // image is the ordinary isolated capture and is framed as one.
        guard abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1 else {
            return trimmed(image, frame: frame, scale: scale)
        }

        // Where that rect sits on the desktop is the one thing SCK does not
        // report, and the fade recovery cannot work without it: it has to find
        // the same region in a photograph of the whole screen. So it is computed
        // from the candidates and then *checked* against the size SCK returned.
        // A mismatch means the group is not the set we guessed at, and a shot
        // placed at a rect we cannot vouch for is worse than no shot at all.
        //
        // A candidate that would push the rect past the size SCK reported cannot
        // be in the group, whatever the z-order says — which is what keeps an
        // unrelated window of the same app from stretching the frame. It is a
        // filter and not the verdict: the size check below is still the verdict.
        let members = above.filter {
            let candidate = frame.union($0.frame)
            return candidate.width <= size.width + 1 && candidate.height <= size.height + 1
        }
        let union = members.reduce(frame) { $0.union($1.frame) }
        guard abs(union.width - size.width) <= 1, abs(union.height - size.height) <= 1 else {
            Log.capture.notice("""
                window \(window.windowID, privacy: .public) has a group of \
                \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) pt \
                and the windows over it account for \
                \(Int(union.width), privacy: .public)x\(Int(union.height), privacy: .public); \
                cannot place it, capturing the window alone
                """)
            return nil
        }
        Log.capture.notice("""
            window \(window.windowID, privacy: .public) captured with \
            \(members.count, privacy: .public) window(s) stacked on it, \
            \(Int(union.width), privacy: .public)x\(Int(union.height), privacy: .public) pt
            """)
        var shot = trimmed(image, frame: union, scale: scale)
        shot.groupedWindowIDs = Set(members.map(\.id))
        return shot
    }

    /// Same-app windows drawn in front of this one and overlapping it, by frame.
    ///
    /// A trigger, not a selection. What ends up in the capture is decided by
    /// ScreenCaptureKit (see `captureGroup`); this only answers "is it worth
    /// asking for the group at all", and supplies the frames the group's rect is
    /// checked against afterwards.
    ///
    /// Being in front is what keeps the old regression fixed. Turning
    /// `includeChildWindows` on globally and then picking a *child* drags its
    /// parent in behind it — WeChat's "Tip" alert, 2026-07-30, an alert-sized
    /// file with the login window showing through around it, which is why the
    /// preference is off (`CaptureOptions.includeChildWindows`). A parent is
    /// *behind* its alert, so a pick on the alert finds nothing in front of it
    /// and never leaves the isolated path.
    ///
    /// The z-order is re-read rather than taken from the cached list: that order
    /// was established when the overlay opened, and `WindowZOrder.entries()`
    /// needs no TCC and costs a single window-server call.
    private func stacked(on windowID: CGWindowID, options: CaptureOptions) -> [WindowInfo] {
        let ordered = WindowZOrder.sortedFrontToBack(content.windows)
        guard let index = ordered.firstIndex(where: { $0.id == windowID }) else { return [] }
        let picked = ordered[index]
        guard let bundleID = picked.bundleID else { return [] }
        return ordered[..<index].compactMap { above in
            guard above.bundleID == bundleID,
                  // A window can be on screen at zero opacity; it contributes no
                  // pixels and must not stretch the rect. Same floor the picker
                  // uses to decide a window cannot be pointed at.
                  above.alpha >= 0.05,
                  !options.excludedWindowIDs.contains(above.id),
                  !above.frame.isEmpty,
                  above.frame.intersects(picked.frame)
            else { return nil }
            return above
        }
    }

    /// Draws the picked window's adornments (`adornments(of:in:excluding:)`)
    /// over it, overhang and all.
    ///
    /// Two sources, because there are two ways to get here. The instant window
    /// shortcut opens no overlay, and the tooltip is still on screen: it is
    /// captured now. A pick made through the overlay arrives after the overlay
    /// has dismissed it, and what is left is `WindowRecovery.adornments`, taken
    /// before it went up.
    ///
    /// "Still on screen" is the window server's answer, not the cached list's:
    /// that list was made when the shortcut fired and still names a tooltip that
    /// has since gone, and `sortedFrontToBack` sends a window it no longer lists
    /// behind everything — which is what takes a dismissed tooltip out of the
    /// live half.
    private func withAdornments(
        _ shot: WindowShot, of windowID: CGWindowID,
        options: CaptureOptions, recovery: WindowRecovery?
    ) async -> WindowShot {
        let excluded = options.excludedWindowIDs.union(shot.groupedWindowIDs)
        let onScreen = WindowZOrder.entries()
        let live = WindowZOrder.sortedFrontToBack(content.windows, using: onScreen)
        guard let picked = live.first(where: { $0.id == windowID }) else { return shot }

        // Back to front: the order they are drawn in.
        var layers: [WindowShot] = []

        // Dismissed since the shortcut fired: over this window in that instant's
        // list, and gone from the screen altogether. A tooltip that is still up
        // is the live half's to judge — if it has moved off, it is not over this
        // window any more, and putting it back would draw something that was not
        // there.
        if let recovery,
           let then = recovery.windowsFrontToBack.first(where: { $0.id == windowID }) {
            let dismissed = Self.adornments(
                of: then, in: recovery.windowsFrontToBack, excluding: excluded)
                .filter { onScreen[$0.id] == nil }
            layers += dismissed.reversed().compactMap { recovery.adornments[$0.id] }
        }

        for above in Self.adornments(of: picked, in: live, excluding: excluded).reversed()
        where onScreen[above.id] != nil {
            guard let window = content.scWindow(for: above.id),
                  let captured = try? await captureAlone(window, options: options)
            else { continue }
            layers.append(captured)
        }
        guard !layers.isEmpty else { return shot }

        let canvas = layers.reduce(shot.coversInCGGlobal) { $0.union($1.coversInCGGlobal) }
        guard let image = await WindowComposite.composited(
            [(shot.image, shot.coversInCGGlobal)] + layers.map { ($0.image, $0.coversInCGGlobal) },
            canvas: canvas, scale: shot.scale)
        else {
            Log.capture.error("""
                window \(windowID, privacy: .public): compositing what was over it \
                failed; keeping the window alone
                """)
            return shot
        }
        Log.capture.notice("""
            window \(windowID, privacy: .public) captured with \
            \(layers.count, privacy: .public) window(s) its app raised over it, \
            \(Int(canvas.width), privacy: .public)x\(Int(canvas.height), privacy: .public) pt
            """)
        return WindowShot(
            image: image, pointSize: canvas.size, scale: shot.scale,
            coversInCGGlobal: canvas, frameInCGGlobal: shot.frameInCGGlobal,
            groupedWindowIDs: shot.groupedWindowIDs)
    }

    /// Windows the picked window's own app has raised over it — DuoUpdater's
    /// hover tooltip over its menu-bar panel — front to back.
    ///
    /// Reported as "对于 tips 悬浮，窗口截图并不会把它包含进去". A tooltip is a
    /// window of its own and **not** in the window server's parent/child group,
    /// so `captureGroup` cannot reach it. Measured 2026-09-11 on DuoUpdater,
    /// panel at layer 101 and tooltip at 103: the panel captured with
    /// `includeChildWindows` came back 370x562 pt, the panel alone, and macOS's
    /// own `screencapture -l` returned the same panel-only picture with the
    /// tooltip on screen before and after it. So this is a rule of ours and goes
    /// past what the platform does, because a capture should be what was on
    /// screen.
    ///
    /// Two conditions keep it from taking what it should not. **A strictly
    /// higher layer**: `captureGroup` turned down "same app, in front,
    /// overlapping" because of Finder and Mail windows piled on one another, all
    /// at one layer. And **too small to be picked on its own**
    /// (`WindowPickerModel.isPickable(size:)`, the same test that keeps the
    /// picker from offering a tooltip): layer alone cannot tell a tooltip from a
    /// panel, and `--selftest-occluded-recovery` proved it — its occluder, a
    /// 420x150 panel at 103 over a window at 101, has a tooltip's layers
    /// exactly, and was composited into the very capture it exists to stay out
    /// of. The size also leaves out an inspector palette over a document window.
    /// What it costs is a tooltip long enough to be a window in its own right.
    ///
    /// Run against every window on one (quiet, 14-window) desktop the day it was
    /// written, the layer rule alone matched no pair.
    nonisolated static func adornments(
        of picked: WindowInfo, in frontToBack: [WindowInfo], excluding excluded: Set<CGWindowID>
    ) -> [WindowInfo] {
        guard let index = frontToBack.firstIndex(where: { $0.id == picked.id }),
              let bundleID = picked.bundleID
        else { return [] }
        return frontToBack[..<index].filter { above in
            above.bundleID == bundleID
                && above.layer > picked.layer
                // Same floor as `stacked` and the picker: on screen at zero
                // opacity contributes no pixels.
                && above.alpha >= 0.05
                && !excluded.contains(above.id)
                && !above.frame.isEmpty
                && above.frame.intersects(picked.frame)
                && !WindowPickerModel.isPickable(size: above.frame)
        }
    }

    /// Isolated captures of every window that is an adornment of some window
    /// behind it, for `WindowRecovery.adornments`.
    ///
    /// Every candidate rather than the picked window's, because it runs before
    /// the overlay and nobody knows yet what will be picked. On most desktops
    /// that is none, and this costs one pass over the list.
    func captureAdornments(
        among frontToBack: [WindowInfo], excluding excluded: Set<CGWindowID>
    ) async -> [CGWindowID: WindowShot] {
        let candidates = Set(frontToBack.flatMap {
            Self.adornments(of: $0, in: frontToBack, excluding: excluded).map(\.id)
        })
        var shots: [CGWindowID: WindowShot] = [:]
        for id in candidates {
            guard let window = content.scWindow(for: id),
                  let shot = try? await captureAlone(window, options: .default)
            else { continue }
            shots[id] = shot
        }
        return shots
    }

    /// One window by itself, for drawing over another. No group and no blank
    /// retry: those are for the window that was picked, and it has already been
    /// through `captureIsolated`.
    private func captureAlone(
        _ window: SCWindow, options: CaptureOptions
    ) async throws -> WindowShot? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        var alone = options
        alone.includeChildWindows = false
        let output = try await SCKBridge.captureScreenshot(
            filter: filter,
            configuration: configuration(for: filter.contentRect, scale: scale, options: alone))
        guard let image = output.image, !PixelCompare.isBlank(image) else { return nil }
        return trimmed(image, frame: window.frame, scale: scale)
    }

    /// Drops a border of pixels the window never drew.
    ///
    /// The outline the picker drew is the window's frame, and this can return
    /// less than that — which is normally the one thing a selection UI must not
    /// do (see `CaptureOptions.includeChildWindows` for the version of that
    /// mistake which cost a round). It is allowed here because the asymmetry
    /// runs the safe way: nothing appears in the file that was not inside the
    /// outline, only empty space is missing. The failure that rule exists to
    /// prevent is the opposite one — another window's pixels arriving unasked.
    private func trimmed(
        _ image: CGImage, frame: CGRect, scale: CGFloat
    ) -> WindowShot {
        let whole = WindowShot(
            image: image, pointSize: frame.size, scale: scale,
            coversInCGGlobal: frame, frameInCGGlobal: frame)
        guard let bounds = PixelCompare.opaqueBounds(image),
              let cropped = image.cropping(to: bounds)
        else { return whole }
        Log.capture.notice("""
            trimmed \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public) pt \
            to \(Int(bounds.width / scale), privacy: .public)x\
            \(Int(bounds.height / scale), privacy: .public) pt of drawn content
            """)
        // `opaqueBounds` is in image pixels with the origin at the **top** left
        // (the same way round as the bitmap it scans), and so is a CG global
        // frame — so the offset carries across with no flip, only a divide.
        return WindowShot(
            image: cropped,
            pointSize: CGSize(width: bounds.width / scale, height: bounds.height / scale),
            scale: scale,
            coversInCGGlobal: CGRect(
                x: frame.minX + bounds.minX / scale,
                y: frame.minY + bounds.minY / scale,
                width: bounds.width / scale,
                height: bounds.height / scale),
            frameInCGGlobal: frame)
    }

    /// A window that is really a region of the screen — the Dock — as that
    /// region: cut from the photograph taken when the shortcut fired, whenever
    /// that photograph shows it, and live otherwise.
    ///
    /// Reported 2026-09-11 as "dock上面有一个进程名字的tip，然后截图不是dock本身了".
    /// An auto-hidden Dock retracts once the pointer leaves it, and by the time
    /// of the pick the pointer is over the overlay, often on the name label or
    /// the slack around the strip rather than on the Dock. Measured the same
    /// day: DuoShot's own hover captures of the Dock window came back blank from
    /// 0.7 s after the overlay went up, and three of four picks photographed
    /// whatever was behind the Dock. A window capture would at least come back
    /// empty; a region capture cannot tell — the pixels are there, they are just
    /// somebody else's.
    ///
    /// The photograph is from the instant the shortcut fired, which is also the
    /// picture the user aimed at, and the Dock is taken from it whenever it was
    /// on screen then. The instant window shortcut opens no overlay, has no
    /// photograph and needs the pointer on the Dock to pick it, so it stays live
    /// — and the Dock stays up for it.
    func captureStrip(
        _ region: CGRect, of windowID: CGWindowID, on displayID: CGDirectDisplayID,
        options: CaptureOptions, recovery: WindowRecovery?
    ) async throws -> WindowShot {
        let shot: WindowShot
        if let recovery, let frame = recovery.frames[displayID],
           recovery.windowsFrontToBack.contains(where: { $0.id == windowID }),
           let cut = frame.crop(toAppKitGlobal: DisplayGeometry.flipped(region)) {
            Log.capture.notice("""
                window \(windowID, privacy: .public) is a region of the screen; cut \
                from the photograph taken when the shortcut fired
                """)
            shot = WindowShot(
                image: cut.image, pointSize: cut.pointSize, scale: frame.scale,
                coversInCGGlobal: region, frameInCGGlobal: region)
        } else {
            shot = try await captureRegion(region, on: displayID, options: options)
        }
        return await shaped(shot, of: windowID)
    }

    /// The strip cut to the outline of the window it holds, so a Dock capture
    /// comes out as a Dock — rounded, with nothing around it — rather than as a
    /// rectangle of whatever the Dock was standing in front of.
    ///
    /// Reported 2026-09-11 as "这个窗口截图，把背景截图进去了". The strip has to be
    /// taken as a region or the glass goes flat (see `captureRegion`), and what
    /// that cost was everything around the rounded platter and beside the name
    /// label. The Dock's own window captured alone is flat but has exactly the
    /// right shape — measured on one instant, 27% of its drawn box was alpha 0,
    /// all of it outside the platter. So the region's pixels are kept where that
    /// shape has alpha and nowhere else: the real glass, in the Dock's outline.
    /// The shape is `ShareableContentCache.dockShape`, from the same refresh as
    /// the photograph, so a label that has since come or gone leaves no outline
    /// behind.
    private func shaped(_ shot: WindowShot, of windowID: CGWindowID) async -> WindowShot {
        guard let shape = content.dockShape, shape.id == windowID else { return shot }
        let covers = shot.coversInCGGlobal
        let pixels = CGRect(
            x: (covers.minX - shape.frame.minX) * shape.scale,
            y: (covers.minY - shape.frame.minY) * shape.scale,
            width: covers.width * shape.scale, height: covers.height * shape.scale).integral
        guard let cut = shape.image.cropping(to: pixels),
              let image = await WindowComposite.masking(shot.image, to: cut)
        else {
            Log.capture.error("""
                window \(windowID, privacy: .public): could not cut the strip to its \
                outline; keeping the rectangle
                """)
            return shot
        }
        Log.capture.notice("window \(windowID, privacy: .public) cut to its own outline")
        var outlined = trimmed(image, frame: covers, scale: shot.scale)
        outlined.bodyTop = PixelCompare.bodyTop(outlined.image)
        return outlined
    }

    /// Captures a window that is really a region of the screen, as that region.
    ///
    /// The Dock is the case, and it needs both halves of this. Its window is the
    /// whole display, so the rect has to come from `visibleFrame` — the same one
    /// the picker outlined, which is what keeps the highlight and the file
    /// agreeing.
    ///
    /// And it has to be captured against the desktop rather than in isolation.
    /// A `desktopIndependentWindow` filter contains one window and nothing else,
    /// so a translucent surface has no backdrop left to sample and falls back to
    /// its base tint: measured 2026-07-30, the Dock's liquid glass came out flat
    /// black, while the same strip taken as a screen region shows the wallpaper
    /// through it. Isolation is the right default for an ordinary window and
    /// exactly wrong for a piece of the desktop.
    private func captureRegion(
        _ regionInCGGlobal: CGRect, on displayID: CGDirectDisplayID, options: CaptureOptions
    ) async throws -> WindowShot {
        guard let display = content.scDisplay(for: displayID) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = try await displayFilter(display, options: options)
        let scale = CGFloat(filter.pointPixelScale)
        let sourceRect = DisplayGeometry.displayLocal(regionInCGGlobal, on: displayID)

        let configuration = configuration(for: sourceRect, scale: scale, options: options)
        configuration.sourceRect = sourceRect

        let output = try await SCKBridge.captureScreenshot(
            filter: filter, configuration: configuration)
        guard let image = output.image else { throw CaptureError.noImageProduced }
        return WindowShot(
            image: image, pointSize: sourceRect.size, scale: scale,
            coversInCGGlobal: regionInCGGlobal, frameInCGGlobal: regionInCGGlobal)
    }

    /// Applies `options.windowPadding`, returning the image and its new point size.
    ///
    /// Baked into the `CaptureResult` rather than applied per output action, so
    /// the file, the clipboard, the floating preview and a drag-out can never
    /// disagree about what the capture is. Every failure path returns the
    /// original: padding is decoration, and losing the screenshot over it would
    /// be a poor trade.
    private func pad(
        _ image: CGImage, size: CGSize, scale: CGFloat,
        on displayID: CGDirectDisplayID, options: CaptureOptions, bodyTop: Int = 0
    ) async -> (CGImage, CGSize) {
        let padding = options.windowPadding
        guard padding > 0 else { return (image, size) }

        let backdrop = await wallpaper.image(for: displayID)
        guard let result = await ImagePadding.padded(
            image, by: padding, scale: scale, backdrop: backdrop,
            fallbackFill: NSColor.windowBackgroundColor.cgColor, bodyTop: bodyTop,
            roundsCorners: options.roundsPaddingCorners)
        else {
            Log.capture.error("padding failed; falling back to the unpadded capture")
            return (image, size)
        }
        // The top margin is its own number when a label stands in it — see
        // `ImagePadding.topInset`. Equal to `padding` for every other window.
        let inset = Int((padding * scale).rounded())
        let top = CGFloat(ImagePadding.topInset(for: inset, bodyTop: bodyTop)) / scale
        return (result, CGSize(width: size.width + padding * 2,
                               height: size.height + padding + top))
    }

    // MARK: - Filter / configuration

    private func displayFilter(
        _ display: SCDisplay, options: CaptureOptions
    ) async throws -> SCContentFilter {
        let excluded = try await content.ownWindows(matching: options.excludedWindowIDs)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        // Defaults to YES for the excludingWindows initialiser, so it must be
        // set explicitly rather than assumed.
        filter.includeMenuBar = options.includeMenuBar
        return filter
    }

    /// A nil `region` leaves `width`/`height` unset, which is not the same as
    /// leaving them at the picked window's size — see `captureGroup`, which is
    /// the only caller that wants it and says why.
    private func configuration(
        for region: CGRect?, scale: CGFloat, options: CaptureOptions
    ) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        if let region {
            let (width, height) = DisplayGeometry.pixelSize(of: region, scale: scale)
            configuration.width = width
            configuration.height = height
        }
        configuration.showsCursor = options.showsCursor
        configuration.ignoreShadows = options.ignoreShadows
        configuration.includeChildWindows = options.includeChildWindows
        // `destinationRect` is left unset: it is measured in *pixels* (unlike
        // sourceRect, which is points) and only exists for letterboxing into a
        // fixed-size surface, which we never want.
        //
        // `fileURL` is also left unset: measured on macOS 27, SCK's own writer
        // produced no file and returned a nil fileURL. ImageEncoder owns writing.
        return configuration
    }
}

extension Duration {
    nonisolated var milliseconds: String {
        let (seconds, attoseconds) = components
        return String(format: "%.1f", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
