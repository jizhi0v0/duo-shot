import AppKit
import ScreenCaptureKit

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

    var shareableContent: ShareableContentCache { content }

    func refreshContent(onScreenOnly: Bool = true) async throws {
        try await content.refresh(onScreenOnly: onScreenOnly)
    }

    func capture(
        _ request: CaptureRequest,
        options: CaptureOptions = .default
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
            result = try await captureWindow(windowID, options: options)
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
        _ windowID: CGWindowID, options: CaptureOptions
    ) async throws -> CaptureResult {
        guard let window = content.scWindow(for: windowID) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let displayID = ScreenIndex
            .screen(containingAppKitGlobal: DisplayGeometry.flipped(window.frame).origin)
            .flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let info = content.windows.first { $0.id == windowID }

        let image: CGImage
        let size: CGSize
        let scale: CGFloat
        if let region = info?.visibleFrame {
            (image, size, scale) = try await captureRegion(
                region, on: displayID, options: options)
        } else {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            scale = CGFloat(filter.pointPixelScale)
            let configuration = configuration(
                for: filter.contentRect, scale: scale, options: options)
            let output = try await SCKBridge.captureScreenshot(
                filter: filter, configuration: configuration)
            guard let captured = output.image else { throw CaptureError.noImageProduced }
            image = captured
            size = filter.contentRect.size
        }

        let (padded, pointSize) = await pad(
            image, size: size, scale: scale, on: displayID, options: options)
        return CaptureResult(
            image: padded,
            pointSize: pointSize,
            scale: scale,
            sourceDisplayID: displayID,
            sourceDescription: info?.displayName ?? "Window",
            capturedAt: .now
        )
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
    ) async throws -> (CGImage, CGSize, CGFloat) {
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
        return (image, sourceRect.size, scale)
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
        on displayID: CGDirectDisplayID, options: CaptureOptions
    ) async -> (CGImage, CGSize) {
        let padding = options.windowPadding
        guard padding > 0 else { return (image, size) }

        var backdrop: CGImage?
        if let wallpaperFilter = content.wallpaperFilter(for: displayID) {
            backdrop = await wallpaper.image(for: displayID, filter: wallpaperFilter)
        }
        guard let result = ImagePadding.pad(
            image, by: padding, scale: scale, backdrop: backdrop,
            fallbackFill: NSColor.windowBackgroundColor.cgColor)
        else {
            Log.capture.error("padding failed; falling back to the unpadded capture")
            return (image, size)
        }
        return (result, CGSize(width: size.width + padding * 2,
                               height: size.height + padding * 2))
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

    private func configuration(
        for region: CGRect, scale: CGFloat, options: CaptureOptions
    ) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        let (width, height) = DisplayGeometry.pixelSize(of: region, scale: scale)
        configuration.width = width
        configuration.height = height
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
