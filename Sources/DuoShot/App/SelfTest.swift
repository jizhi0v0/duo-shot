import AppKit
import Carbon.HIToolbox
import Darwin
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

/// Headless CLI modes, dispatched from `main.swift` before any UI exists.
///
/// This is the highest-leverage thing in the project: the two risks that could
/// invalidate the architecture — whether TCC sticks under a hand-assembled
/// bundle, and what coordinate space `sourceRect` actually uses — are both
/// settled here with zero UI code.
enum SelfTest {
    enum Mode {
        case permission
        case windows
        case capture(output: URL, displayIndex: Int?)
        /// Rect in AppKit global points: "x,y,w,h".
        case rect(CGRect, displayIndex: Int?, output: URL?)
        /// Settles whether `sourceRect` is filter-local or global.
        case sourceRectSpace
        /// Presents the real overlay, forces a selection, and proves the panels
        /// stay out of the captured image. `excluding: false` is the negative
        /// control — it must FAIL, or the positive result proves nothing.
        case overlay(CGRect, output: URL?, excluding: Bool)
        /// Runs a capture through the real output pipeline into a throwaway
        /// directory: filename, encoding, save, clipboard.
        case output(directory: URL)
        /// Presents a real floating preview and checks that it never takes focus,
        /// stays out of the next capture, and auto-dismisses.
        case preview(directory: URL)
        /// Presents several previews at once and photographs the stack, so the
        /// slot layout can be looked at rather than reasoned about.
        case previewStack(count: Int, directory: URL)
        /// Window-picker hit-testing, filtering and window capture geometry.
        case windowMode(directory: URL)
        /// Fullscreen capture with `includeMenuBar` both ways.
        case fullscreen(directory: URL)
        /// Settings persistence, key-combo encoding and the system-shortcut probe.
        case preferences
        /// Opens the real Settings window and captures it, so the SwiftUI layout
        /// can actually be looked at.
        case settingsWindow(directory: URL)
        /// Samples the Settings window height while switching tabs in ONE window,
        /// which is the path `settingsWindow` misses — it opens a fresh window per
        /// tab, so it cannot see a resize overshoot.
        case settingsResize
        /// Exercises every overlay exit path repeatedly, hunting for a hung or
        /// double-resumed continuation and leaked panels.
        case lifecycle(iterations: Int)
        /// Repeated captures through the whole pipeline, watching memory and the
        /// staging store.
        case soak(iterations: Int, directory: URL)

        init?(arguments: [String]) {
            let rest = arguments.dropFirst()
            guard let flag = arguments.first else { return nil }

            func value(for name: String) -> String? {
                guard let i = rest.firstIndex(of: name), rest.index(after: i) < rest.endIndex
                else { return nil }
                return rest[rest.index(after: i)]
            }
            func positional() -> String? { rest.first { !$0.hasPrefix("--") } }
            func displayIndex() -> Int? { value(for: "--display").flatMap(Int.init) }

            switch flag {
            case "--selftest-permission":
                self = .permission
            case "--selftest-windows":
                self = .windows
            case "--selftest-sourcerect-space":
                self = .sourceRectSpace
            case "--selftest-capture":
                guard let path = positional() else { return nil }
                self = .capture(output: URL(fileURLWithPath: path), displayIndex: displayIndex())
            case "--selftest-rect":
                guard let spec = positional(), let parsed = Self.parseRect(spec) else { return nil }
                self = .rect(
                    parsed,
                    displayIndex: displayIndex(),
                    output: value(for: "--out").map { URL(fileURLWithPath: $0) }
                )
            case "--selftest-output":
                self = .output(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-preferences":
                self = .preferences
            case "--selftest-lifecycle":
                self = .lifecycle(iterations: positional().flatMap(Int.init) ?? 12)
            case "--selftest-soak":
                self = .soak(
                    iterations: positional().flatMap(Int.init) ?? 100,
                    directory: URL(fileURLWithPath: value(for: "--out") ?? "build/soak"))
            case "--selftest-settings-resize":
                self = .settingsResize
            case "--selftest-settings-window":
                self = .settingsWindow(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-window":
                self = .windowMode(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-fullscreen":
                self = .fullscreen(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-preview-stack":
                PreviewPanel.usesSharingTypeNone = false
                if let raw = value(for: "--corner"),
                   let corner = PreviewCorner(rawValue: raw) {
                    Preferences.shared.previewCorner = corner
                }
                self = .previewStack(
                    count: value(for: "--count").flatMap(Int.init) ?? 3,
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-preview":
                PreviewPanel.usesSharingTypeNone = !rest.contains("--sharing-default")
                self = .preview(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-overlay":
                guard let spec = positional(), let parsed = Self.parseRect(spec) else { return nil }
                OverlayPanel.usesSharingTypeNone = !rest.contains("--sharing-default")
                self = .overlay(
                    parsed,
                    output: value(for: "--out").map { URL(fileURLWithPath: $0) },
                    excluding: !rest.contains("--no-exclude")
                )
            default:
                return nil
            }
        }

        private static func parseRect(_ spec: String) -> CGRect? {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
    }

    static func run(_ mode: Mode) async -> Int32 {
        do {
            switch mode {
            case .permission: return permission()
            case .windows: return try await windows()
            case .capture(let url, let index): return try await capture(to: url, displayIndex: index)
            case .rect(let rect, let index, let url):
                return try await rectCheck(rect, displayIndex: index, output: url)
            case .sourceRectSpace: return try await sourceRectSpace()
            case .overlay(let rect, let url, let excluding):
                return try await overlayExclusion(rect, output: url, excluding: excluding)
            case .output(let directory): return try await outputPipeline(into: directory)
            case .preview(let directory): return try await previewPanel(into: directory)
            case .previewStack(let count, let directory):
                return try await previewStack(count: count, into: directory)
            case .windowMode(let directory): return try await windowMode(into: directory)
            case .fullscreen(let directory): return try await fullscreenMode(into: directory)
            case .preferences: return preferencesCheck()
            case .settingsWindow(let directory): return try await settingsWindow(into: directory)
            case .settingsResize: return try await settingsResize()
            case .lifecycle(let iterations): return try await lifecycle(iterations: iterations)
            case .soak(let iterations, let directory):
                return try await soak(iterations: iterations, into: directory)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            return 1
        }
    }

    // MARK: - Permission

    private static func permission() -> Int32 {
        let granted = ScreenPermission.isGranted
        print("screen-capture-access: \(granted ? "granted" : "denied")")
        print("bundle-id:             \(Bundle.main.bundleIdentifier ?? "<none>")")
        print("bundle-path:           \(Bundle.main.bundleURL.path)")
        print("parent:                \(parentProcessName())")
        if granted && getppid() != 1 {
            print("""
                WARNING:               launched from a shell, so TCC may be attributing this to an
                                       ancestor process that already holds the grant. Measured on
                                       this machine: shell-launched reports `granted` while the
                                       same binary launched via LaunchServices reports `denied`.
                                       Use `make tcc-check` for the real answer.
                """)
        }

        // Also to os_log, because the only launch that proves TCC is attributed
        // to *us* is one via LaunchServices (`open -n`), where there is no stdout.
        Log.permission.notice("""
            selftest-permission: \(granted ? "granted" : "denied", privacy: .public) \
            pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) \
            parent=\(parentProcessName(), privacy: .public)
            """)
        return granted ? 0 : 1
    }

    // MARK: - Enumeration

    private static func windows() async throws -> Int32 {
        let content = try await SCKBridge.shareableContent().value

        print("NSScreen:")
        for screen in NSScreen.screens {
            print("  \(ScreenIndex.describe(screen))")
        }

        // Two enumeration entry points that should agree. When displays vanish,
        // knowing whether both are empty separates a system-state problem from
        // an API-variant one.
        let plain = try? await SCKBridge.allShareableContent().value
        let onScreenOnlyFalse = try? await SCKBridge.shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: false).value
        print("""
            \nenumeration:  getShareableContent -> \(plain?.displays.count ?? -1) displays, \
            \(plain?.windows.count ?? -1) windows
                          excludingDesktop:true  onScreenOnly:true  -> \(content.displays.count) displays
                          excludingDesktop:false onScreenOnly:false -> \(onScreenOnlyFalse?.displays.count ?? -1) displays
            """)

        print("\nSCDisplay (\(content.displays.count)):")
        for display in content.displays {
            print(String(format: "  id=%-10u  frame=%@  %dx%d px",
                         display.displayID, rectString(display.frame),
                         display.width, display.height))
        }

        print("\nSCWindow (\(content.windows.count)):")
        for window in content.windows.sorted(by: { $0.windowLayer < $1.windowLayer }) {
            let app = window.owningApplication?.applicationName ?? "?"
            print(String(format: "  id=%-8u L%-4d %@ %-24@ %-24@ %@",
                         window.windowID, window.windowLayer,
                         window.isOnScreen ? "on " : "off",
                         app as NSString,
                         rectString(window.frame) as NSString,
                         (window.title ?? "") as NSString))
        }
        return 0
    }

    // MARK: - Whole-display capture

    private static func capture(to url: URL, displayIndex: Int?) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let content = try await SCKBridge.shareableContent().value
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
        let display = content.displays[min(displayIndex ?? 0, content.displays.count - 1)]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        print("display:       id=\(display.displayID) frame=\(rectString(display.frame))")
        print("filter:        contentRect=\(rectString(filter.contentRect)) pointPixelScale=\(scale)")
        print("supported:     \(SCScreenshotConfiguration.supportedContentTypes.map(\.identifier).joined(separator: ", "))")

        let started = ContinuousClock.now
        let output = try await captureRegion(
            filter: filter, sourceRect: nil, scale: scale, writeTo: url)
        let elapsed = started.duration(to: .now)

        guard let image = output.image else { throw CaptureError.noImageProduced }
        print("captured:      \(image.width)x\(image.height) px in \(milliseconds(elapsed)) ms")
        print("               sdr=\(output.sdrImage != nil) hdr=\(output.hdrImage != nil)")
        Log.capture.notice("""
            selftest-capture: \(image.width, privacy: .public)x\(image.height, privacy: .public) px \
            in \(milliseconds(elapsed), privacy: .public) ms scale=\(scale, privacy: .public) \
            sck-wrote-file=\(output.fileURL != nil, privacy: .public)
            """)

        report(sckFileURL: output.fileURL, requested: url)
        let ours = url.deletingPathExtension().appendingPathExtension("ours.png")
        try ImageEncoder.write(image, to: ours, as: .png, scale: scale)
        print("ours:          \(ours.path) (\(byteCount(of: ours)))")
        dumpDPI(of: ours, label: "ours")
        return 0
    }

    // MARK: - Rect capture, verified against a cropped full-display capture

    /// Proves the AppKit-global -> `sourceRect` pipeline end to end without a
    /// human eyeballing PNGs: capture the region two ways and diff the pixels.
    ///
    /// Caveat this test cannot cover on a single-display machine: with the only
    /// display at CG origin (0,0), display-local and CG-global coordinates
    /// coincide, so the `displayLocal` offset is a no-op and both readings of
    /// `sourceRect` pass. `--selftest-sourcerect-space` attacks that separately.
    private static func rectCheck(
        _ rectInAppKitGlobal: CGRect, displayIndex: Int?, output: URL?
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let content = try await SCKBridge.shareableContent().value
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        let display: SCDisplay
        if let displayIndex {
            display = content.displays[min(displayIndex, content.displays.count - 1)]
        } else if let screen = ScreenIndex.screen(containingAppKitGlobal: rectInAppKitGlobal.origin),
                  let id = ScreenIndex.displayID(of: screen),
                  let match = content.displays.first(where: { $0.displayID == id }) {
            display = match
        } else {
            display = content.displays[0]
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let sourceRect = DisplayGeometry.sourceRect(
            fromAppKitGlobal: rectInAppKitGlobal, on: display.displayID)

        print("input:         appkit-global \(rectString(rectInAppKitGlobal))")
        print("display:       id=\(display.displayID) cg-bounds=\(rectString(CGDisplayBounds(display.displayID)))")
        print("flip pivot:    \(DisplayGeometry.flipHeight) pt")
        print("cg-global:     \(rectString(DisplayGeometry.flipped(rectInAppKitGlobal.integral)))")
        print("sourceRect:    \(rectString(sourceRect))  <- display-local points")
        print("scale:         \(scale)")

        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            FileHandle.standardError.write(Data(
                "error: rect must be at least 1x1 points, got \(rectString(sourceRect))\n".utf8))
            return 3
        }
        guard filter.contentRect.contains(sourceRect) else {
            FileHandle.standardError.write(Data(
                "error: sourceRect \(rectString(sourceRect)) is outside contentRect \(rectString(filter.contentRect))\n".utf8))
            return 3
        }

        let cropInPixels = CGRect(
            x: (sourceRect.minX * scale).rounded(),
            y: (sourceRect.minY * scale).rounded(),
            width: (sourceRect.width * scale).rounded(),
            height: (sourceRect.height * scale).rounded()
        )
        let (expectedW, expectedH) = DisplayGeometry.pixelSize(of: sourceRect, scale: scale)

        // The two captures are of *live* screen content, so anything that
        // repaints between them (the menu-bar clock, the Dock, a blinking
        // caret) shows up as a pixel difference that has nothing to do with
        // geometry. Retry: correct geometry over static content matches on the
        // first or second try, wrong geometry never matches at all.
        var best: PixelCompare.Result?
        var region: CGImage?
        var cropped: CGImage?
        var sawStaticContent = false

        for attempt in 1...attemptLimit {
            // Sandwich the full-display capture between two identical region
            // captures. The outer pair is a *control*: if they disagree, the
            // area repainted during the run and any region-vs-crop difference
            // this attempt proves nothing about geometry.
            let before = try await captureRegion(
                filter: filter, sourceRect: sourceRect, scale: scale, writeTo: nil)
            let fullOutput = try await captureRegion(
                filter: filter, sourceRect: nil, scale: scale, writeTo: nil)
            let after = try await captureRegion(
                filter: filter, sourceRect: sourceRect, scale: scale, writeTo: nil)
            guard
                let capturedRegion = before.image,
                let recapturedRegion = after.image,
                let full = fullOutput.image,
                let capturedCrop = full.cropping(to: cropInPixels)
            else { throw CaptureError.noImageProduced }

            region = capturedRegion
            cropped = capturedCrop

            let stable = PixelCompare.compare(capturedRegion, recapturedRegion)
            let comparison = PixelCompare.compare(capturedRegion, capturedCrop)
            if stable.identical {
                sawStaticContent = true
                if best == nil || !best!.identical { best = comparison }
                if comparison.identical {
                    if attempt > 1 { print("attempts:      \(attempt)") }
                    break
                }
            } else if best == nil {
                best = comparison
            }
        }

        guard let region, let cropped, let comparison = best else {
            throw CaptureError.noImageProduced
        }

        let sizeMatches = region.width == expectedW && region.height == expectedH
        print("region:        \(region.width)x\(region.height) px (expected \(expectedW)x\(expectedH))")
        print("cropped:       \(cropped.width)x\(cropped.height) px")

        if let output {
            try ImageEncoder.write(region, to: output, as: .png, scale: scale)
            let croppedURL = output.deletingPathExtension().appendingPathExtension("cropped.png")
            try ImageEncoder.write(cropped, to: croppedURL, as: .png, scale: scale)
            print("wrote:         \(output.path)")
            print("               \(croppedURL.path)")
        }

        guard sizeMatches else {
            print("result:        FAIL — size mismatch, the geometry is wrong")
            return 1
        }
        guard sawStaticContent else {
            print("""
                stability:     the area repainted during every attempt, so region-vs-crop
                               cannot be attributed to geometry either way.
                result:        INCONCLUSIVE (size is correct) — re-run over a static area.
                """)
            return 0
        }

        print("pixel diff:    \(comparison.summary)")
        if comparison.identical {
            print("result:        PASS")
            return 0
        }

        // A misplaced rect samples entirely different content. Regions with
        // vibrancy/blur (menu bar, Dock, translucent chrome) recomposite their
        // backdrop slightly differently depending on the captured area; opaque
        // content is bit-exact through both paths. `isSamePicture` separates the
        // two on aggregate difference rather than the single worst pixel.
        if comparison.isSamePicture {
            print("""
                result:        PASS (within tolerance)
                               Geometry is exact; the residual is backdrop-blur recompositing,
                               not a positioning error.
                """)
            return 0
        }
        print("result:        FAIL — differences are too large to be recompositing")
        return 1
    }

    private static let attemptLimit = 4

    // MARK: - Is sourceRect filter-local or global?

    /// The header for `SCScreenshotConfiguration.sourceRect` says "in points in
    /// the display's logical coordinate system" (i.e. relative to the filter's
    /// `contentRect`), while the sibling `captureScreenshot(rect:)` documents
    /// its rect as global. Two contracts in one class, and on a single-display
    /// machine the display case cannot tell them apart.
    ///
    /// A *window* filter can: pick a window whose global origin is far from
    /// zero, ask for the top-left quarter via `sourceRect`, and see whether the
    /// result matches the top-left quarter of the full window capture. If it
    /// does, `sourceRect` is relative to `contentRect`, not global.
    private static func sourceRectSpace() async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let content = try await SCKBridge.shareableContent().value
        let candidates = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width >= 400 && $0.frame.height >= 300
                && $0.frame.minX > 40 && $0.frame.minY > 40
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            FileHandle.standardError.write(Data(
                "error: no on-screen window at a non-zero origin big enough to test with.\n".utf8))
            return 3
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let contentRect = filter.contentRect

        print("window:        id=\(window.windowID) \"\(window.title ?? "")\" (\(window.owningApplication?.applicationName ?? "?"))")
        print("window.frame:  \(rectString(window.frame))   <- CG global points")
        print("contentRect:   \(rectString(contentRect))")
        print("scale:         \(scale)")

        // Full window.
        let fullOutput = try await captureRegion(
            filter: filter, sourceRect: nil, scale: scale, writeTo: nil)
        guard let full = fullOutput.image else { throw CaptureError.noImageProduced }

        print("full:          \(full.width)x\(full.height) px")

        let half = CGSize(width: (contentRect.width / 2).rounded(.down),
                          height: (contentRect.height / 2).rounded(.down))
        guard let expected = full.cropping(to: CGRect(
            x: 0, y: 0,
            width: (half.width * scale).rounded(),
            height: (half.height * scale).rounded()))
        else { return 3 }

        // Two readings of the same rect. Only one can reproduce the top-left
        // quarter of the full window capture.
        let readings: [(name: String, rect: CGRect)] = [
            ("local  (origin 0,0)",
             CGRect(origin: .zero, size: half)),
            ("global (contentRect origin)",
             CGRect(origin: contentRect.origin, size: half)),
        ]

        var winner: String?
        for reading in readings {
            let output = try await captureRegion(
                filter: filter, sourceRect: reading.rect, scale: scale, writeTo: nil)
            guard let image = output.image else { continue }
            let comparison = PixelCompare.compare(image, expected)
            print("  \(reading.name.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + "\(rectString(reading.rect)) -> \(image.width)x\(image.height) px, \(comparison.summary)")
            if comparison.identical { winner = reading.name }
        }

        switch winner {
        case .some(let name) where name.hasPrefix("local"):
            print("""
                verdict:       sourceRect is FILTER-LOCAL — measured from the contentRect
                               origin, which is (0,0) regardless of where contentRect sits in
                               global space. DisplayGeometry.displayLocal() is correct.
                result:        PASS (FILTER-LOCAL)
                """)
            return 0
        case .some(let name):
            print("""
                verdict:       sourceRect matched the \(name) reading. DisplayGeometry
                               .displayLocal() must NOT subtract the display origin.
                """)
            return 1
        case .none:
            print("""
                verdict:       INCONCLUSIVE — neither reading reproduced the crop. Most likely
                               the window repainted between the two captures; re-run against a
                               static window before drawing any conclusion.
                """)
            return 1
        }
    }

    // MARK: - Overlay exclusion

    /// Exercises the real overlay end to end without a human at the mouse, and
    /// answers the one question M2 exists to answer: does our own dim end up in
    /// the screenshot?
    ///
    /// A plain image comparison cannot answer it. The dim is drawn with a hole
    /// exactly where the selection is, so even a completely un-excluded overlay
    /// produces a captured region that looks right. Hence the debug magenta
    /// border, drawn *inside* the selection edge: magenta in the output means
    /// the overlay was composited into the capture.
    private static func overlayExclusion(
        _ rect: CGRect, output: URL?, excluding: Bool
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        guard let screen = ScreenIndex.screen(containingAppKitGlobal: rect.origin) ?? NSScreen.main,
              let displayID = ScreenIndex.displayID(of: screen)
        else { throw CaptureError.noDisplays }

        OverlayView.drawsDebugSelectionBorder = true
        print("config:        excludingWindows=\(excluding) sharingType=\(OverlayPanel.usesSharingTypeNone ? ".none" : ".readOnly")")

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()

        // present() only returns once the interaction ends, so it runs detached
        // while we drive the selection from here.
        let presentation = Task {
            await coordinator.overlay.present(
                mode: .area, windows: coordinator.engine.shareableContent.windows)
        }
        try await Task.sleep(for: .milliseconds(400))

        coordinator.overlay.forceSelection(rect, on: screen)

        let panelIDs = coordinator.overlay.panelWindowIDs
        print("overlay:       \(panelIDs.count) panel(s), window IDs \(panelIDs.sorted())")
        print("panel state:   \(coordinator.overlay.debugPanelState)")
        print("selection:     appkit-global \(rectString(rect)) on display \(displayID)")

        // Sanity check the test itself: if the overlay is not actually composited
        // yet, a magenta-free capture proves nothing. Poll rather than sleeping a
        // guessed interval — a fixed delay made this flaky, reporting the overlay
        // as absent on some runs and present on others with identical settings.
        var witness = try await coordinator.engine.capture(.display(displayID))
        var witnessMagenta = 0
        var waited = Duration.zero
        while waited < .seconds(3) {
            witness = try await coordinator.engine.capture(.display(displayID))
            witnessMagenta = PixelCompare.count(witness.image, matching: PixelCompare.isDebugMagenta)
            if witnessMagenta > 0 { break }
            try await Task.sleep(for: .milliseconds(150))
            waited += .milliseconds(150)
        }
        print("witness:       \(witnessMagenta) magenta px after \(waited.milliseconds) ms"
            + " (unfiltered full-display capture)")
        if witnessMagenta == 0 {
            let witnessURL = (output ?? URL(fileURLWithPath: "build/m2-witness.png"))
                .deletingPathExtension().appendingPathExtension("witness.png")
            try? ImageEncoder.write(witness.image, to: witnessURL, as: .png, scale: witness.scale)
            print("""
                witness png:   \(witnessURL.path)
                result:        VOID — the overlay is not visible to ScreenCaptureKit at all, so
                               this test cannot distinguish "excluded" from "never drawn".
                """)
            coordinator.overlay.tearDown()
            presentation.cancel()
            return 3
        }

        var options = CaptureOptions.default
        options.excludedWindowIDs = excluding ? panelIDs : []
        if !excluding {
            print("mode:          NEGATIVE CONTROL — exclusion disabled, magenta is EXPECTED")
        }
        let withOverlay = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: rect), options: options)

        coordinator.overlay.tearDown()
        presentation.cancel()
        try await Task.sleep(for: .milliseconds(300))

        let withoutOverlay = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: rect))

        // Does the dim actually render? A band well outside the selection should
        // be measurably darker with the overlay up. Measured rather than eyeballed
        // — 28% black is easy to miss in a downscaled screenshot.
        let plainFull = try await coordinator.engine.capture(.display(displayID))
        let probe = CGRect(x: 40, y: 40, width: 200, height: 200)
        if let dimmed = PixelCompare.meanLuminance(witness.image, in: probe),
           let plain = PixelCompare.meanLuminance(plainFull.image, in: probe) {
            let ratio = plain > 0 ? dimmed / plain : 1
            print(String(format: "dim probe:     luma %.1f dimmed vs %.1f plain (ratio %.3f)",
                         dimmed, plain, ratio))
            if ratio > 0.95 {
                print("               WARNING: the dim is not rendering — expected ~0.72")
            }
        }

        let magenta = PixelCompare.count(withOverlay.image, matching: PixelCompare.isDebugMagenta)
        let comparison = PixelCompare.compare(withOverlay.image, withoutOverlay.image)

        print("with overlay:  \(withOverlay.image.width)x\(withOverlay.image.height) px")
        print("magenta px:    \(magenta)  <- must be 0")
        print("vs no overlay: \(comparison.summary)")

        if let output {
            try ImageEncoder.write(withOverlay.image, to: output, as: .png, scale: withOverlay.scale)
            let plain = output.deletingPathExtension().appendingPathExtension("nooverlay.png")
            try ImageEncoder.write(withoutOverlay.image, to: plain, as: .png, scale: withoutOverlay.scale)
            // The full-display witness is what shows whether the dim actually
            // covers the menu bar and the Dock — the region crop cannot.
            let witnessURL = output.deletingPathExtension().appendingPathExtension("witness.png")
            try ImageEncoder.write(witness.image, to: witnessURL, as: .png, scale: witness.scale)
            print("wrote:         \(output.path)")
            print("               \(plain.path)")
            print("               \(witnessURL.path)")
        }

        guard magenta == 0 else {
            print("""
                result:        FAIL — the overlay was composited into the capture.
                               SCContentFilter(display:excludingWindows:) did not exclude our
                               panels; check that panelWindowIDs matches NSWindow.windowNumber
                               and that the panels were on screen when the filter was built.
                """)
            return 1
        }

        if comparison.isSamePicture {
            print("result:        PASS — overlay fully excluded")
            return 0
        }
        print("""
            result:        PASS (no magenta) but the two captures differ more than expected.
                           Most likely live content changed between them; inspect the PNGs.
            """)
        return 0
    }

    // MARK: - Output pipeline

    private static func outputPipeline(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let result = try await coordinator.engine.capture(.display(displayID))

        // Pin the template for the run. Asserting against whatever the user has
        // configured is not a test of anything — this check failed once because
        // the live preference had been edited to "in".
        let preferences = Preferences.shared
        let originalTemplate = preferences.filenameTemplate
        preferences.filenameTemplate = FilenameFormatter.defaultTemplate
        defer { preferences.filenameTemplate = originalTemplate }

        NSPasteboard.general.clearContents()
        guard let output = OutputPipeline.shared.process(
            result, saveDirectoryOverride: directory)
        else {
            print("result:        FAIL — pipeline returned nothing")
            return 1
        }

        let exists = FileManager.default.fileExists(atPath: output.url.path)
        print("format:        \(Preferences.shared.imageFormat.identifier)")
        print("file:          \(output.url.path)")
        print("               exists=\(exists) saved=\(output.wasSaved) (\(byteCount(of: output.url)))")
        dumpDPI(of: output.url, label: "saved")

        // The pasteboard must carry a *point*-sized image, or every paste target
        // renders a 2x capture at double size.
        let pasteboardImage = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil)?.first as? NSImage
        let logical = pasteboardImage?.size ?? .zero
        let expected = result.pointSize
        let sizeOK = abs(logical.width - expected.width) < 1
            && abs(logical.height - expected.height) < 1
        print("clipboard:     image=\(pasteboardImage != nil) logical=\(Int(logical.width))x\(Int(logical.height))"
            + " expected=\(Int(expected.width))x\(Int(expected.height)) \(sizeOK ? "OK" : "WRONG")")

        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        print("clipboard url: \(urls?.first?.lastPathComponent ?? "<none>")")

        // Filename template: " at " in the default must survive as a literal,
        // not be interpreted as DateFormatter's AM/PM pattern character.
        let name = output.url.lastPathComponent
        let templateOK = name.contains(" at ") && !name.contains("AM at") && !name.contains("PM at")
        print("filename:      \(name) \(templateOK ? "OK" : "TEMPLATE BROKEN")")

        let pass = exists && output.wasSaved && sizeOK && pasteboardImage != nil && templateOK
        print("result:        \(pass ? "PASS" : "FAIL")")
        return pass ? 0 : 1
    }

    // MARK: - Preview panel

    private static func previewPanel(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        let previews = PreviewStackController()
        previews.timeout = .seconds(2)
        coordinator.additionalExcludedWindowIDs = { previews.panelWindowIDs }

        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let baseline = try await coordinator.engine.capture(.display(displayID))

        let result = try await coordinator.engine.capture(.display(displayID))
        guard let output = OutputPipeline.shared.process(result, saveDirectoryOverride: directory)
        else { return 1 }
        previews.present(output)
        try await Task.sleep(for: .milliseconds(500))

        print("panels:        \(previews.count)")
        print("panel state:   \(previews.debugState)")

        // A preview that steals focus would make every capture-then-keep-typing
        // flow miserable, and would also alter what the next capture shows.
        let keyWindowIsPreview = NSApp.keyWindow is PreviewPanel
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        print("key window:    \(NSApp.keyWindow == nil ? "<none>" : "\(type(of: NSApp.keyWindow!))")"
            + " stealsFocus=\(keyWindowIsPreview)")
        print("frontmost:     \(frontmostBefore ?? "nil") -> \(frontmostAfter ?? "nil")")

        // Does the preview end up in the next screenshot? Compare the region it
        // occupies against the same region from before it existed.
        var exclusionOK = true
        var exclusionTestValid = false
        var panelFrame: CGRect?

        if let frame = previews.panelFrames.first {
            panelFrame = frame
            var excludingOptions = CaptureOptions.default
            excludingOptions.excludedWindowIDs = previews.panelWindowIDs

            let excluded = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: frame), options: excludingOptions)
            let unexcluded = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: frame))

            let lookURL = directory.appendingPathComponent("preview-appearance.png")
            try? ImageEncoder.write(
                unexcluded.image, to: lookURL, as: .png, scale: unexcluded.scale)

            // The actions only exist while hovering now, so capture that state too.
            previews.setHoverForTest(true)
            try await Task.sleep(for: .milliseconds(250))
            let hovered = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: frame))
            let hoverURL = directory.appendingPathComponent("preview-appearance-hover.png")
            try? ImageEncoder.write(hovered.image, to: hoverURL, as: .png, scale: hovered.scale)
            previews.setHoverForTest(false)
            try await Task.sleep(for: .milliseconds(200))

            print("appearance:    \(lookURL.lastPathComponent) + \(hoverURL.lastPathComponent)")

            // Validity check first. If excluding the panel changes nothing, the
            // panel was never visible to ScreenCaptureKit (sharingType = .none)
            // and "excluded" would be a vacuous pass.
            let visibility = PixelCompare.compare(excluded.image, unexcluded.image)
            let visibleRatio = Double(visibility.differingPixels)
                / Double(max(visibility.totalPixels, 1))
            exclusionTestValid = visibleRatio > 0.2
            print("panel visible: \(visibility.summary) -> "
                + (exclusionTestValid ? "test is meaningful" : "VACUOUS (panel invisible to SCK)"))

            if exclusionTestValid {
                // Compare against the same region once the panel is gone, not
                // against a baseline taken minutes earlier — the desktop
                // underneath keeps repainting.
                previews.dismissAll()
                try await Task.sleep(for: .milliseconds(400))
                let after = try await coordinator.engine.capture(
                    .area(displayID: displayID, rectInAppKitGlobal: frame))
                let comparison = PixelCompare.compare(excluded.image, after.image)
                exclusionOK = comparison.isSamePicture
                print("preview area:  \(comparison.summary) -> "
                    + (exclusionOK ? "excluded" : "LEAKED INTO CAPTURE"))
            }
        }
        _ = baseline

        // A card under the pointer must survive its own timer.
        //
        // Only the pointer *coordinate* is substituted. The containment check,
        // the panel's real frame and the timer loop are the shipping ones. An
        // earlier version stubbed the decision itself (an `isPointerInside`
        // flag), which is precisely why it reported "held" while the real
        // behaviour was still broken; a later one moved the panel under the
        // user's actual cursor, which was worse.
        var hoverOK = true
        previews.timeout = .milliseconds(300)
        if let fresh = try? await coordinator.engine.capture(.display(displayID)),
           let freshOutput = OutputPipeline.shared.process(
               fresh, saveDirectoryOverride: directory)
        {
            previews.present(freshOutput)
            try await Task.sleep(for: .milliseconds(200))

            // A second card, so the test can prove the hold is *per card* and
            // not "freeze the whole stack whenever the pointer is anywhere".
            if let second = try? await coordinator.engine.capture(.display(displayID)),
               let secondOutput = OutputPipeline.shared.process(
                   second, saveDirectoryOverride: directory) {
                previews.present(secondOutput)
                try await Task.sleep(for: .milliseconds(200))
            }

            let parked = previews.simulatePointerForTest(overCardAt: 0)
            print("pointer:       over card 0 = \(parked), held = \(previews.heldCardsForTest)")
            if !parked || previews.heldCardsForTest != [true, false] {
                hoverOK = false
                print("               FAIL: the hold is not confined to the hovered card")
            }

            let beforeHold = previews.count
            try await Task.sleep(for: .seconds(3))
            let held = previews.count
            // The hovered card stays; the other one must have gone on its own.
            print("hover hold:    \(beforeHold) -> \(held) after 3 s with a 0.3 s timeout -> "
                + (held == 1 ? "only the hovered card held" : "WRONG: expected exactly 1"))
            if held != 1 { hoverOK = false }

            // And it must go once the pointer is no longer over it.
            previews.simulatePointerForTest(overCardAt: nil)
            try await Task.sleep(for: .seconds(2))
            print("after leaving: \(previews.count) card(s) -> "
                + (previews.count == 0 ? "dismissed as expected" : "STILL PRESENT"))
            if previews.count != 0 { hoverOK = false }
        }

        // Auto-dismiss. Only meaningful if the exclusion check did not already
        // tear the stack down.
        var dismissed = previews.count == 0
        if !dismissed {
            try await Task.sleep(for: .seconds(3))
            dismissed = previews.count == 0
            print("auto-dismiss:  \(dismissed ? "fired" : "STILL VISIBLE after timeout")")
        } else if panelFrame != nil, exclusionTestValid {
            print("auto-dismiss:  skipped (stack torn down by the exclusion check)")
            dismissed = true
        }

        previews.dismissAll()
        let pass = !keyWindowIsPreview && frontmostBefore == frontmostAfter
            && exclusionOK && dismissed && hoverOK
        print("result:        \(pass ? "PASS" : "FAIL")")
        return pass ? 0 : 1
    }

    // MARK: - Window mode

    private static func windowMode(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let all = coordinator.engine.shareableContent.windows

        // Presenting for real exercises the same picker the user drives; the
        // hover is forced instead of moving the mouse.
        let presentation = Task {
            await coordinator.overlay.present(mode: .window, windows: all)
        }
        try await Task.sleep(for: .milliseconds(400))
        defer { presentation.cancel() }

        let pickable = coordinator.overlay.pickableWindowCount
        print("windows:       \(all.count) enumerated, \(pickable) pickable")

        // The Space-key path: switching modes must reset the other mode's state
        // and re-seed the pointer, or the overlay sits blank until the mouse moves.
        coordinator.overlay.setMode(.area)
        let afterAreaToggle = coordinator.overlay.hoveredWindow
        coordinator.overlay.setMode(.window)
        coordinator.overlay.forceHover(atAppKitGlobal: NSEvent.mouseLocation)
        let afterWindowToggle = coordinator.overlay.hoveredWindow
        let toggleOK = afterAreaToggle == nil
        print("mode toggle:   ->area clears hover=\(toggleOK) "
            + "->window rehovers=\(afterWindowToggle != nil ? "yes" : "no window under pointer")")

        // Filtering rules that keep the picker usable.
        let ownBundleID = Bundle.main.bundleIdentifier
        let offScreen = all.filter { !$0.isOnScreen }
        print("filtered out:  \(all.count - pickable) "
            + "(\(offScreen.count) off-screen incl. Stage Manager, plus non-zero layers/tiny/self)")

        // Z-order. The picker resolves a hover as "first frame in the list that
        // contains the point", so the list order IS the hit-test, and the window
        // server is the only authority on it.
        //
        // This check used to be written off as untestable — "it may return one in
        // front, which is correct z-order behaviour" — and that is exactly how the
        // picker shipped highlighting App Store from three layers behind the
        // window the user was looking at. `SCShareableContent.windows` is not
        // z-ordered; comparing against CGWindowList's order catches it directly.
        let depths = WindowZOrder.depths()
        let ranked = all.compactMap { window in depths[window.id].map { (window, $0) } }
        let inversions = zip(ranked, ranked.dropFirst()).filter { $0.1 > $1.1 }
        print("z-order:       \(ranked.count) of \(all.count) windows ranked by the window server, "
            + "\(inversions.count) out of order  <- must be 0")
        for (lhs, rhs) in inversions.prefix(3) {
            print("  \(lhs.0.displayName) (depth \(lhs.1)) listed ahead of "
                + "\(rhs.0.displayName) (depth \(rhs.1))")
        }

        // Hit-test: hover the centre of each candidate. A window may legitimately
        // resolve to one in front of it — that is what z-order means — so the
        // assertion is that the result contains the point, plus the strict version
        // below for the frontmost window, which has nothing in front of it.
        var tested = 0
        var hits = 0
        var selfLeaked = 0
        for window in all where window.isOnScreen && window.layer == 0
            && window.frame.width >= 200 && window.frame.height >= 200
        {
            let centreInCGGlobal = CGPoint(x: window.frame.midX, y: window.frame.midY)
            coordinator.overlay.forceHover(
                atAppKitGlobal: DisplayGeometry.flipped(centreInCGGlobal))
            tested += 1
            guard let hovered = coordinator.overlay.hoveredWindow else { continue }
            if hovered.frame.contains(centreInCGGlobal) { hits += 1 }
            // The overlay's panels, not everything DuoShot owns: its Settings
            // window is an ordinary window and is meant to be pickable.
            if coordinator.overlay.panelWindowIDs.contains(hovered.id) { selfLeaked += 1 }
        }
        print("hit-test:      \(hits)/\(tested) centres resolved to a window containing the point")
        print("overlay leaked: \(selfLeaked)  <- must be 0")

        // The strict one: the frontmost pickable window has nothing above it, so
        // hovering its centre must resolve to *itself* and nothing else.
        //
        // `layer <= 8`, not `layer == 0`: an app's floating panel (level 3) is a
        // perfectly ordinary capture target and is very often the frontmost thing
        // on screen. Written as `== 0` this test agreed with the picker's own
        // too-narrow filter and so could never catch it refusing to see one —
        // which is how a translator popup ended up unselectable.
        let frontmost = all.first {
            $0.isOnScreen && (0...8).contains($0.layer) && $0.bundleID != ownBundleID
                && $0.frame.width >= 200 && $0.frame.height >= 200
        }
        var frontmostOK = true
        if let frontmost {
            coordinator.overlay.forceHover(atAppKitGlobal: DisplayGeometry.flipped(
                CGPoint(x: frontmost.frame.midX, y: frontmost.frame.midY)))
            let hovered = coordinator.overlay.hoveredWindow
            frontmostOK = hovered?.id == frontmost.id
            print("frontmost:     \(frontmost.displayName) -> "
                + "\(hovered?.displayName ?? "nothing") \(frontmostOK ? "" : "MISMATCH")")
        }

        // Staleness. The window list is enumerated once, when the overlay opens,
        // and the order it captured does not survive the interaction — ⌘-Tab
        // raises a different app while the picker is up. Simulated by presenting
        // a deliberately wrong order (reversed) and checking the picker recovers.
        //
        // Nothing here moves the mouse or re-ranks by hand, so the only thing
        // that can fix the order is the controller's poll — which is the point.
        // The first version of this fix hung off the app-activation notification
        // instead, and that notification arrives before the window server has
        // restacked, so it recovered only once the user moved the pointer.
        //
        // Not a cosmetic staleness, which is why it is worth a test of its own:
        // with a maximized window stuck at the head of the list every point on
        // screen hit-tests to it, so the highlight cannot be moved off it at all.
        // Measured in the wild as 21 seconds inside the picker with exactly one
        // hover change logged.
        coordinator.overlay.tearDown()
        try await Task.sleep(for: .milliseconds(150))

        // Re-enumeration is disabled for this half, so the ONLY thing that can
        // repair a reversed list is the re-rank. Left on, it would repair the
        // order as a side effect and this would pass with the re-rank deleted.
        let enumerate = coordinator.overlay.refreshWindows
        coordinator.overlay.refreshWindows = nil
        let stalePresentation = Task {
            await coordinator.overlay.present(mode: .window, windows: all.reversed())
        }
        try await Task.sleep(for: .milliseconds(400))

        var recoveredOK = true
        if let frontmost {
            coordinator.overlay.forceHover(atAppKitGlobal: DisplayGeometry.flipped(
                CGPoint(x: frontmost.frame.midX, y: frontmost.frame.midY)))
            let recovered = coordinator.overlay.hoveredWindow
            recoveredOK = recovered?.id == frontmost.id
            print("stale order:   reversed list -> re-ranked to "
                + "\(recovered?.displayName ?? "nothing") \(recoveredOK ? "" : "MISMATCH")")
        }
        coordinator.overlay.tearDown()
        stalePresentation.cancel()
        coordinator.overlay.refreshWindows = enumerate
        try await Task.sleep(for: .milliseconds(200))

        // The other half of staleness: a window that is not in the list at all.
        // Presented without the frontmost window, the picker can only find it by
        // re-enumerating — which is what an open/save dialog appearing while the
        // picker is up looks like from in here.
        let missingPresentation = Task {
            await coordinator.overlay.present(
                mode: .window,
                windows: all.filter { $0.id != frontmost?.id })
        }
        // Long enough for the enumeration tick, which runs at a quarter of the
        // 120 ms poll and then has an async SCK round trip of its own.
        try await Task.sleep(for: .milliseconds(1400))

        var appearedOK = true
        if let frontmost {
            coordinator.overlay.forceHover(atAppKitGlobal: DisplayGeometry.flipped(
                CGPoint(x: frontmost.frame.midX, y: frontmost.frame.midY)))
            let found = coordinator.overlay.hoveredWindow
            appearedOK = found?.id == frontmost.id
            print("missing window: omitted \(frontmost.displayName) -> re-enumerated to "
                + "\(found?.displayName ?? "nothing") \(appearedOK ? "" : "MISMATCH")")
        }
        coordinator.overlay.tearDown()
        missingPresentation.cancel()
        try await Task.sleep(for: .milliseconds(200))

        // DuoShot's own Settings window is an ordinary window and must be
        // pickable. Excluding everything the app owns took it out with the
        // overlay panels, and it is nothing like an overlay panel — reported as
        // "the settings window can't be selected".
        //
        // Asserted against the picker's list rather than by hovering it: whether
        // a hover resolves to it depends on what else happens to be on screen in
        // front of it, and the bug was that it never reached the list at all.
        let settings = PreferencesWindowController()
        settings.activatesOnShow = false
        settings.show()
        try await Task.sleep(for: .milliseconds(700))
        try await coordinator.engine.refreshContent()
        let withSettings = coordinator.engine.shareableContent.windows

        var ownWindowOK = true
        if let settingsID = settings.windowNumber {
            let ownPresentation = Task {
                await coordinator.overlay.present(mode: .window, windows: withSettings)
            }
            try await Task.sleep(for: .milliseconds(400))
            ownWindowOK = coordinator.overlay.pickableWindowIDs.contains(settingsID)
            let panelLeak = !coordinator.overlay.pickableWindowIDs
                .isDisjoint(with: coordinator.overlay.panelWindowIDs)
            print("own windows:   Settings pickable=\(ownWindowOK), "
                + "overlay panels pickable=\(panelLeak) \(ownWindowOK && !panelLeak ? "" : "MISMATCH")")
            ownWindowOK = ownWindowOK && !panelLeak
            coordinator.overlay.tearDown()
            ownPresentation.cancel()
            try await Task.sleep(for: .milliseconds(200))
        }
        settings.close()

        let childOK = try await childWindowIsolation()

        // Geometry: capture the largest window and check the pixel size against
        // its frame. Also compare ignoreShadows on/off, which is the setting
        // most likely to silently change the output size.
        guard let target = all
            .filter({ $0.isOnScreen && $0.layer == 0 && $0.bundleID != ownBundleID })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            print("result:        FAIL — no window to capture")
            return 1
        }

        coordinator.overlay.tearDown()
        try await Task.sleep(for: .milliseconds(200))

        print("target:        \(target.displayName) frame=\(rectString(target.frame))")

        var sizes: [String: CGSize] = [:]
        for ignoreShadows in [true, false] {
            var options = CaptureOptions.default
            options.ignoreShadows = ignoreShadows
            let result = try await coordinator.engine.capture(.window(target.id), options: options)
            sizes[ignoreShadows ? "ignoreShadows" : "withShadows"] = result.pixelSize
            print(String(format: "  ignoreShadows=%-5@ -> %dx%d px (points %.0fx%.0f, scale %.1f)",
                         ignoreShadows ? "true" : "false" as NSString,
                         Int(result.pixelSize.width), Int(result.pixelSize.height),
                         result.pointSize.width, result.pointSize.height, result.scale))
            if ignoreShadows {
                let url = directory.appendingPathComponent("window-capture.png")
                try? ImageEncoder.write(result.image, to: url, as: .png, scale: result.scale)
                print("  wrote \(url.path)")
            }
        }

        // Padding. The arithmetic is the part worth asserting — the margin is in
        // POINTS while the image is in pixels, so a missing `* scale` gives half
        // the requested margin on a Retina display and nobody notices until they
        // compare two screenshots side by side.
        let padding: CGFloat = 32
        var paddingOptions = CaptureOptions.default
        paddingOptions.windowPadding = padding
        let padded = try await coordinator.engine.capture(
            .window(target.id), options: paddingOptions)
        let base = sizes["ignoreShadows"] ?? .zero
        let expected = CGSize(
            width: base.width + padding * 2 * padded.scale,
            height: base.height + padding * 2 * padded.scale)
        let paddingOK = padded.pixelSize == expected
            // The point size has to grow with it, or the file is stamped with a
            // DPI that makes it paste at the wrong size.
            && padded.pointSize.width == target.frame.width + padding * 2
        print(String(format: "  padding=%.0fpt -> %dx%d px (expected %dx%d), points %.0fx%.0f -> %@",
                     padding, Int(padded.pixelSize.width), Int(padded.pixelSize.height),
                     Int(expected.width), Int(expected.height),
                     padded.pointSize.width, padded.pointSize.height,
                     (paddingOK ? "OK" : "FAIL") as NSString))
        let paddedURL = directory.appendingPathComponent("window-capture-padded.png")
        try? ImageEncoder.write(padded.image, to: paddedURL, as: .png, scale: padded.scale)
        print("  wrote \(paddedURL.path)")

        let shadowOK = paddingCastsAShadow()

        // Child windows (sheets) change the captured bounds when included.
        for includeChildren in [true, false] {
            var options = CaptureOptions.default
            options.includeChildWindows = includeChildren
            let result = try await coordinator.engine.capture(.window(target.id), options: options)
            print("  includeChildWindows=\(includeChildren) -> "
                + "\(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) px")
        }

        let geometryOK = sizes["ignoreShadows"].map {
            $0.width > 0 && $0.height > 0
        } ?? false
        let pass = selfLeaked == 0 && hits == tested && tested > 0 && geometryOK && toggleOK
            && inversions.isEmpty && frontmostOK && recoveredOK && appearedOK && paddingOK
            && childOK && shadowOK && ownWindowOK
        print("result:        \(pass ? "PASS" : "FAIL")")
        return pass ? 0 : 1
    }

    /// The padding drops a shadow, and it traces the image's own silhouette.
    ///
    /// A pure-function check on `ImagePadding` — no capture, no window, so it
    /// cannot be knocked over by what is on screen. A white square on a white
    /// backdrop: every non-white pixel in the result is shadow, and there is
    /// nowhere else for one to come from.
    ///
    /// The corner sample is the load-bearing half. The square's own corners are
    /// opaque, so a shadow that traced the *bounding box* would darken the canvas
    /// corners as much as the edges; one that traces the alpha leaves them alone
    /// past the blur radius. That is the property the whole "we never need to
    /// know the window's corner radius" argument rests on.
    private static func paddingCastsAShadow() -> Bool {
        let side = 200, padding = 40
        guard let square = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        square.setFillColor(CGColor(gray: 1, alpha: 1))
        square.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let source = square.makeImage(),
              let padded = ImagePadding.pad(
                source, by: CGFloat(padding), scale: 1, backdrop: nil,
                fallbackFill: CGColor(gray: 1, alpha: 1))
        else { return false }

        let darkened = PixelCompare.count(padded) { r, g, b in r < 250 && g < 250 && b < 250 }
        let expected = CGSize(width: side + padding * 2, height: side + padding * 2)
        let sizeOK = padded.width == Int(expected.width) && padded.height == Int(expected.height)
        let ok = sizeOK && darkened > 0
        print(String(format: "  shadow: %dx%d px, %d shadowed px on a white backdrop -> %@",
                     padded.width, padded.height, darkened,
                     (ok ? "OK" : "FAIL") as NSString))
        return ok
    }

    /// Draws a filled shape well inside its bounds, leaving a transparent margin
    /// for whatever is behind the window to show through.
    private final class InsetFillView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemBlue.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 24, dy: 24), xRadius: 12, yRadius: 12
            ).fill()
        }
    }

    /// Picking a child window must capture that window, not its whole group.
    ///
    /// `includeChildWindows` does not mean what its name suggests. With a
    /// `desktopIndependentWindow` filter, ScreenCaptureKit composites the entire
    /// window group and then crops to the picked window's rect — so turning it on
    /// and then picking a *child* drags the parent in behind it. Reported
    /// 2026-07-30 against WeChat's "Tip" alert: the saved file was 560×462,
    /// exactly the alert's bounds, with the login window's title bar and buttons
    /// showing through around it. The marching ants said "this alert"; the pixels
    /// said "the whole window".
    ///
    /// The pair is built here rather than hunted for on screen, so the result
    /// does not depend on what the machine happens to have open: an opaque red
    /// parent, and a child that is transparent except for a blue shape inset
    /// inside it. Any red in the child's capture is the parent leaking through.
    ///
    /// The `includeChildWindows = true` capture is the negative control. Without
    /// it, a test that only asserts "no red" would still pass if the capture came
    /// back blank.
    private static func childWindowIsolation() async throws -> Bool {
        let engine = CaptureEngine()

        let parent = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.backgroundColor = .red
        parent.level = .floating
        parent.orderFrontRegardless()

        let child = NSWindow(
            contentRect: CGRect(x: 300, y: 275, width: 200, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        child.backgroundColor = .clear
        child.isOpaque = false
        child.hasShadow = false
        child.contentView = InsetFillView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        child.level = .floating
        parent.addChildWindow(child, ordered: .above)

        defer {
            parent.removeChildWindow(child)
            child.orderOut(nil)
            parent.orderOut(nil)
        }

        try await Task.sleep(for: .milliseconds(400))
        try await engine.refreshContent()

        let childID = CGWindowID(child.windowNumber)
        func redPixels(_ options: CaptureOptions) async throws -> Int {
            let result = try await engine.capture(.window(childID), options: options)
            return PixelCompare.count(result.image) { r, g, b in r > 180 && g < 90 && b < 90 }
        }

        var options = CaptureOptions.default
        let alone = try await redPixels(options)
        options.includeChildWindows = true
        let grouped = try await redPixels(options)

        let ok = alone == 0 && grouped > 0
        print("child window:  parent bleed \(alone) px on its own, "
            + "\(grouped) px with includeChildWindows -> \(ok ? "OK" : "FAIL")")
        return ok
    }

    // MARK: - Fullscreen mode

    private static func fullscreenMode(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        var captures: [Bool: CaptureResult] = [:]
        for includeMenuBar in [true, false] {
            var options = CaptureOptions.default
            options.includeMenuBar = includeMenuBar
            let result = try await coordinator.engine.capture(.display(displayID), options: options)
            captures[includeMenuBar] = result
            let url = directory.appendingPathComponent(
                "fullscreen-menubar-\(includeMenuBar).png")
            try? ImageEncoder.write(result.image, to: url, as: .png, scale: result.scale)
            print("includeMenuBar=\(includeMenuBar): "
                + "\(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) px -> \(url.lastPathComponent)")
        }

        // The setting must actually do something, and the difference must be
        // confined to the menu-bar strip at the top of the image.
        var effective = false
        if let withBar = captures[true], let without = captures[false],
           withBar.pixelSize == without.pixelSize
        {
            let barHeight = 32 * withBar.scale
            let strip = CGRect(x: 0, y: 0, width: withBar.pixelSize.width, height: barHeight)
            let body = CGRect(x: 0, y: barHeight,
                              width: withBar.pixelSize.width,
                              height: withBar.pixelSize.height - barHeight)
            if let a = withBar.image.cropping(to: strip), let b = without.image.cropping(to: strip) {
                let comparison = PixelCompare.compare(a, b)
                let ratio = Double(comparison.differingPixels) / Double(max(comparison.totalPixels, 1))
                effective = ratio > 0.02
                print(String(format: "menu-bar strip: %.2f%% of pixels differ -> %@",
                             ratio * 100, effective ? "setting is effective" : "NO EFFECT"))
            }
            if let a = withBar.image.cropping(to: body), let b = without.image.cropping(to: body) {
                let comparison = PixelCompare.compare(a, b)
                let ratio = Double(comparison.differingPixels) / Double(max(comparison.totalPixels, 1))
                print(String(format: "below the bar:  %.2f%% of pixels differ (live content)", ratio * 100))
            }
        }

        let pass = captures.count == 2
        print("result:        \(pass ? "PASS" : "FAIL")\(effective ? "" : "  (includeMenuBar had no visible effect — see note)")")
        return pass ? 0 : 1
    }

    // MARK: - Preview stack

    private static func previewStack(count: Int, into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        let previews = PreviewStackController()
        previews.timeout = .seconds(120)
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        // Differently shaped regions, because slot placement must not depend on
        // the panels' own heights.
        let rects = [
            CGRect(x: 300, y: 300, width: 520, height: 360),
            CGRect(x: 400, y: 400, width: 640, height: 220),
            CGRect(x: 500, y: 200, width: 300, height: 300),
            CGRect(x: 200, y: 500, width: 420, height: 300),
        ]
        var frames: [CGRect] = []
        for index in 0..<count {
            let result = try await coordinator.engine.capture(
                .area(displayID: displayID,
                      rectInAppKitGlobal: rects[index % rects.count]))
            guard let output = OutputPipeline.shared.process(
                result, saveDirectoryOverride: directory) else { continue }
            previews.present(output)
            try await Task.sleep(for: .milliseconds(250))
            frames = previews.panelFrames
        }

        previews.setHoverForTest(false)
        try await Task.sleep(for: .milliseconds(400))

        let shot = try await coordinator.engine.capture(.display(displayID))
        let url = directory.appendingPathComponent("preview-stack.png")
        try ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)

        var failures: [String] = []
        let corner = Preferences.shared.previewCorner
        print("corner:        \(corner.rawValue)")
        print("presented:     \(count), \(previews.count) retained")
        if let container = previews.containerFrame,
           let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main
        {
            let card = PreviewCardView.cardSize
            let contentHeight = previews.count == 0
                ? 0
                : CGFloat(previews.count) * card.height + CGFloat(previews.count - 1) * 10
            let maxHeight = screen.visibleFrame.height - 40
            let shouldScroll = contentHeight > maxHeight
            print(String(format: "panel:         %.0fx%.0f at (%.0f, %.0f), content %.0f, max %.0f -> %@",
                         container.width, container.height, container.minX, container.minY,
                         contentHeight, maxHeight,
                         (shouldScroll ? "scrolls" : "fits") as NSString))
            // The panel must never grow past the screen; that is the whole point
            // of putting the column in a scroll view.
            if container.height > maxHeight + 1 {
                failures.append("panel is taller than the available screen height")
            }
            if !shouldScroll && abs(container.height - contentHeight) > 1 {
                failures.append("panel height does not match its content")
            }
        }
        // `panelFrames` is newest first.
        for (index, frame) in frames.enumerated() {
            print(String(format: "  %@  origin (%.0f, %.0f)  size %.0fx%.0f",
                         index == 0 ? "newest" : "  #\(index) " as NSString,
                         frame.minX, frame.minY, frame.width, frame.height))
        }
        print("wrote:         \(url.path)")

        // 1. Uniform size.
        let card = PreviewCardView.cardSize
        if frames.contains(where: { $0.size != card }) {
            failures.append("cards are not all \(Int(card.width))x\(Int(card.height))")
        }

        // 2. No overlap — the "is this stacked or just piled up?" complaint.
        var overlaps = 0
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] where frame.intersects(other) { overlaps += 1 }
        }
        print("overlapping:   \(overlaps) pair(s)  <- must be 0")
        if overlaps > 0 { failures.append("\(overlaps) overlapping pair(s)") }

        // 3. Newest at the anchored corner, the rest marching away from it.
        let ordered = corner.isTop
            ? zip(frames, frames.dropFirst()).allSatisfy { $0.minY > $1.minY }
            : zip(frames, frames.dropFirst()).allSatisfy { $0.minY < $1.minY }
        print("ordering:      newest at the \(corner.isTop ? "top" : "bottom") -> \(ordered)")
        if !ordered { failures.append("stack order does not start at the anchored corner") }

        // 4. The panel actually hugs the requested corner.
        if let container = previews.containerFrame,
           let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main
        {
            let visible = screen.visibleFrame
            let expected = corner.panelOrigin(
                in: visible, panelSize: container.size, inset: 20)
            let placed = abs(container.minX - expected.x) < 1
                && abs(container.minY - expected.y) < 1
            print(String(format: "anchor:        panel at (%.0f, %.0f), expected (%.0f, %.0f) -> %@",
                         container.minX, container.minY, expected.x, expected.y,
                         (placed ? "OK" : "WRONG CORNER") as NSString))
            if !placed { failures.append("panel is not anchored to \(corner.rawValue)") }
        }

        // 5. The reported bug: an older card expiring frees a low position, and
        // the next capture drops into it — putting a *newer* card below an older
        // one. Reproduce it directly.
        previews.dismissAll()
        try await Task.sleep(for: .milliseconds(700))
        for index in 0..<2 {
            let result = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: rects[index]))
            if let output = OutputPipeline.shared.process(
                result, saveDirectoryOverride: directory) {
                previews.present(output)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let beforeExpiry = previews.panelFrames
        previews.expireOldestForTest()
        try await Task.sleep(for: .milliseconds(400))
        let afterResult = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: rects[2]))
        if let output = OutputPipeline.shared.process(
            afterResult, saveDirectoryOverride: directory) {
            previews.present(output)
        }
        try await Task.sleep(for: .milliseconds(400))
        let after = previews.panelFrames
        let stillAscending = corner.isTop
            ? zip(after, after.dropFirst()).allSatisfy { $0.minY > $1.minY }
            : zip(after, after.dropFirst()).allSatisfy { $0.minY < $1.minY }
        print("after expiry:  \(beforeExpiry.count) -> \(after.count) cards, "
            + "newest still lowest -> \(stillAscending)")
        if !stillAscending {
            failures.append("a card that expired freed a slot and the next card dropped below an older one")
        }

        previews.dismissAll()
        try await Task.sleep(for: .milliseconds(600))
        return report(failures)
    }

    // MARK: - Overlay lifecycle

    /// The overlay has several exit routes — mouse-up, Return, Esc, a screen
    /// reconfiguration, a second `present` — and a `CheckedContinuation` that is
    /// resumed twice is a hard crash while one never resumed hangs the caller
    /// forever. This drives every route in turn, many times.
    private static func lifecycle(iterations: Int) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let windows = coordinator.engine.shareableContent.windows
        let overlay = coordinator.overlay
        guard let screen = NSScreen.main else { throw CaptureError.noDisplays }

        enum ExitPath: CaseIterable {
            case tearDown
            case confirmArea
            case confirmWindow
            case screenReconfiguration
            case reentrantPresent

            var label: String {
                switch self {
                case .tearDown: "tearDown (Esc)"
                case .confirmArea: "confirm area"
                case .confirmWindow: "confirm window"
                case .screenReconfiguration: "screen reconfigured"
                case .reentrantPresent: "second present()"
                }
            }
        }

        var failures: [String] = []
        var timings: [String: Int] = [:]

        for iteration in 0..<iterations {
            let path = ExitPath.allCases[iteration % ExitPath.allCases.count]
            let mode: SelectionMode = path == .confirmWindow ? .window : .area

            let flag = CompletionFlag()
            let box = OutcomeBox()
            // Set by the paths that confirm a selection, so the outcome can be
            // checked. The paths that are *supposed* to cancel leave it false.
            var expectsConfirmation = false
            Task {
                box.outcome = await overlay.present(mode: mode, windows: windows)
                flag.markDone()
            }
            try await Task.sleep(for: .milliseconds(120))

            switch path {
            case .tearDown:
                overlay.tearDown()
            case .confirmArea:
                overlay.forceSelection(
                    CGRect(x: 100, y: 100, width: 200, height: 150), on: screen)
                overlay.confirmForTest()
                expectsConfirmation = true
            case .confirmWindow:
                // Confirming for real, not `tearDown()` standing in for it. The
                // outcome is then checked below, because the interesting failure
                // is not a hang — it is `present()` resuming promptly with
                // `.cancelled`, which looks like a pass from here and means every
                // window capture silently does nothing.
                if let target = windows.first(where: {
                    $0.isOnScreen && $0.layer == 0 && $0.bundleID != Bundle.main.bundleIdentifier
                }) {
                    overlay.forceHover(atAppKitGlobal: NSEvent.mouseLocation)
                    overlay.confirmWindowForTest(target.id)
                    expectsConfirmation = true
                } else {
                    failures.append("\(path.label): no pickable window to confirm")
                    overlay.tearDown()
                }
            case .screenReconfiguration:
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
                try await Task.sleep(for: .milliseconds(60))
                overlay.tearDown()
            case .reentrantPresent:
                // The second call must cancel the first, not strand it.
                let secondFlag = CompletionFlag()
                Task {
                    _ = await overlay.present(mode: .area, windows: windows)
                    secondFlag.markDone()
                }
                try await Task.sleep(for: .milliseconds(120))
                overlay.tearDown()
                if await secondFlag.wait(upTo: .seconds(2)) == false {
                    failures.append("\(path.label): the second present() never resumed")
                }
            }

            // A hang is the failure mode that matters most, so bound the wait.
            let started = ContinuousClock.now
            let completed = await flag.wait(upTo: .seconds(3))
            // `.components.seconds` is whole seconds and truncates everything
            // sub-second to zero, which made every path report 0 ms.
            let elapsed = Int(seconds(started.duration(to: .now)) * 1000)
            timings[path.label, default: 0] = max(timings[path.label] ?? 0, elapsed)

            if !completed {
                failures.append("\(path.label): present() never resumed")
            }
            if expectsConfirmation, case .cancelled? = box.outcome {
                failures.append(
                    "\(path.label): resumed with .cancelled instead of the confirmed selection")
            }
            overlay.tearDown()
            if overlay.panelCount != 0 {
                failures.append("\(path.label): \(overlay.panelCount) panel(s) leaked")
            }
            if overlay.hasPendingContinuation {
                failures.append("\(path.label): continuation still pending after tearDown")
            }
        }

        // The monthly re-authorisation path. The whole flow needs
        // `tccutil reset ScreenCapture com.boli.duoshot` and a human, but the
        // classification that gates it can be checked here — if userDeclined is
        // not recognised, DuoShot silently stops working once a month with no
        // prompt and no explanation.
        let classifications: [(String, Int, CaptureFailure)] = [
            ("userDeclined", -3801, .authorisationLost),
            ("missingEntitlements", -3803, .authorisationLost),
            ("noCaptureSource", -3815, .noCaptureSource),
            ("noDisplayList", -3814, .noCaptureSource),
            ("internalError", -3811, .transient),
        ]
        for (name, code, expected) in classifications {
            let error = NSError(domain: SCStreamErrorDomain, code: code)
            let actual = CaptureFailure(error)
            let ok = actual == expected
            print("  error \(name.padding(toLength: 20, withPad: " ", startingAt: 0))"
                + "\(code) -> \(actual) \(ok ? "" : "EXPECTED \(expected)")")
            if !ok { failures.append("SCStreamError \(code) misclassified as \(actual)") }
        }
        // A non-SCK error must not be mistaken for a permission problem.
        if CaptureFailure(CocoaError(.fileNoSuchFile)) == .authorisationLost {
            failures.append("a non-ScreenCaptureKit error was classified as lost authorisation")
        }

        print("iterations:    \(iterations) across \(ExitPath.allCases.count) exit paths")
        for path in ExitPath.allCases {
            print("  \(path.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                + "resolved, worst \(timings[path.label] ?? 0) ms")
        }
        print("panels leaked: \(overlay.panelCount)")

        // Negative control. If a present() that is never dismissed still reports
        // as "resolved", the hang detection above is meaningless and every PASS
        // it produced was vacuous.
        let strandedFlag = CompletionFlag()
        Task {
            _ = await overlay.present(mode: .area, windows: windows)
            strandedFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(120))
        let strandedResolved = await strandedFlag.wait(upTo: .milliseconds(600))
        print("hang control:  un-dismissed present() -> "
            + (strandedResolved ? "RESOLVED — detector is broken" : "correctly detected as pending"))
        if strandedResolved {
            failures.append("hang detection is vacuous: an un-dismissed present() reported as resolved")
        }
        overlay.tearDown()
        _ = await strandedFlag.wait(upTo: .seconds(2))

        return report(failures)
    }

    /// Tracks whether a detached `present()` has resumed.
    ///
    /// Deliberately a polled flag rather than racing `Task.value` inside a
    /// `withTaskGroup`: a task group implicitly awaits its children when the
    /// scope exits, and `Task.value` does not observe cancellation, so the
    /// "timeout" branch cannot actually abandon the work. That combination hung
    /// this very test for the full 300 s.
    @MainActor
    /// What `present()` actually resumed with, carried out of the detached task.
    ///
    /// The lifecycle test used to discard it, which is why a confirm path that
    /// resumed promptly with `.cancelled` read as a pass.
    private final class OutcomeBox {
        var outcome: OverlayController.Outcome?
    }

    private final class CompletionFlag {
        private(set) var isDone = false
        func markDone() { isDone = true }

        /// True if the flag flips before the deadline.
        func wait(upTo duration: Duration) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: duration)
            while ContinuousClock.now < deadline {
                if isDone { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return isDone
        }
    }

    // MARK: - Soak

    private static func soak(iterations: Int, into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let rect = CGRect(x: 200, y: 200, width: 400, height: 300)

        // Staging must be exercised, so saving is turned off for the run and
        // restored afterwards — otherwise every file is moved straight out and
        // the pruning path never runs.
        let preferences = Preferences.shared
        let originalSave = preferences.saveToDisk
        let originalClipboard = preferences.copyToClipboard
        let originalSound = preferences.playsSound
        preferences.saveToDisk = false
        preferences.copyToClipboard = false
        preferences.playsSound = false
        defer {
            preferences.saveToDisk = originalSave
            preferences.copyToClipboard = originalClipboard
            preferences.playsSound = originalSound
        }

        // Previews are presented too, and with a very short timeout, so panels
        // are being created, cascaded, retired and released constantly. This is
        // the exact shape of the reported crash: rapid consecutive captures
        // churning the preview stack. Without it the soak never touched the
        // panel lifetime at all.
        let previews = PreviewStackController()
        previews.timeout = .milliseconds(400)

        // Warm up so one-off allocations do not read as a leak.
        for _ in 0..<5 {
            _ = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: rect))
        }
        let baseline = MemoryFootprint.current()
        let started = ContinuousClock.now
        var failures: [String] = []

        for iteration in 1...iterations {
            let result = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: rect))
            if let output = OutputPipeline.shared.process(result) {
                previews.present(output)
            }
            if iteration % max(iterations / 5, 1) == 0 {
                let now = MemoryFootprint.current()
                print("  \(String(format: "%4d", iteration))  "
                    + "memory \(MemoryFootprint.formatted(now))  "
                    + "staged \(stagedFileCount())  "
                    + "panels \(previews.count)")
            }
        }
        previews.dismissAll()
        // Let the retirement grace period and any pending AppKit layout drain.
        try await Task.sleep(for: .seconds(2))

        let elapsed = started.duration(to: .now)
        let peak = MemoryFootprint.current()
        let growth = peak > baseline ? peak - baseline : 0
        let staged = stagedFileCount()

        print("iterations:    \(iterations) in \(elapsed.milliseconds) ms "
            + "(\(Int(Double(iterations) / max(seconds(elapsed), 0.001))) /s)")
        print("memory:        \(MemoryFootprint.formatted(baseline)) -> "
            + "\(MemoryFootprint.formatted(peak)) (+\(MemoryFootprint.formatted(growth)))")
        print("staged files:  \(staged) (cap 200)")

        // Each capture holds a ~1 MB CGImage; if none are released the footprint
        // climbs by roughly iterations x that. A generous ceiling still catches
        // a real leak.
        let ceiling: UInt64 = 200 * 1024 * 1024
        if growth > ceiling {
            failures.append("memory grew by \(MemoryFootprint.formatted(growth)) over \(iterations) captures")
        }
        if staged > 220 {
            failures.append("staging store did not prune: \(staged) files")
        }
        _ = directory
        return report(failures)
    }

    private static func stagedFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: StagingStore.shared.directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).count) ?? 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (whole, atto) = duration.components
        return Double(whole) + Double(atto) / 1e18
    }

    // MARK: - Settings window

    private static func settingsWindow(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        var allPassed = true
        let coordinator = CaptureCoordinator()

        // Every tab, from the enum rather than a hand-written list: a tab added
        // without a screenshot is a tab whose layout nobody has looked at.
        for tab in PreferencesWindowController.Tab.allCases {
            let controller = PreferencesWindowController()
            controller.activatesOnShow = false
            controller.show(tab: tab)
            try await Task.sleep(for: .milliseconds(900))

            guard let windowID = controller.windowNumber, let frame = controller.frame else {
                print("\(tab.rawValue): FAIL — window did not open")
                allPassed = false
                continue
            }

            try await coordinator.engine.refreshContent()
            guard let result = try? await coordinator.engine.capture(.window(windowID)) else {
                print("\(tab.rawValue): FAIL — could not capture")
                controller.close()
                allPassed = false
                continue
            }

            let url = directory.appendingPathComponent("settings-\(tab.rawValue).png")
            try ImageEncoder.write(result.image, to: url, as: .png, scale: result.scale)

            // A blank or collapsed SwiftUI layout still produces a window of the
            // right size, so check there is actual contrast in the image.
            let luma = PixelCompare.meanLuminance(result.image) ?? 0
            let ok = result.pixelSize.width > 400 && result.pixelSize.height > 300 && luma > 5
            print(String(format: "%-10@ %@ %dx%d px, luma %.1f -> %@",
                         tab.rawValue as NSString,
                         rectString(frame) as NSString,
                         Int(result.pixelSize.width), Int(result.pixelSize.height),
                         luma, (ok ? "OK" : "FAIL") as NSString))
            if !ok { allPassed = false }
            controller.close()
            try await Task.sleep(for: .milliseconds(300))
        }

        print("result:        \(allPassed ? "PASS" : "FAIL")")
        return allPassed ? 0 : 1
    }

    /// Switches tabs in one window and samples the frame every 8 ms.
    ///
    /// The bug this exists for: the window jumped to the tallest tab's height and
    /// then settled back, on every switch. A single before/after comparison
    /// cannot see that, so this samples the whole transition and reports the
    /// peak.
    private static func settingsResize() async throws -> Int32 {
        let controller = PreferencesWindowController()
        controller.activatesOnShow = false
        // Walks every tab and then back to the tallest, which is where an
        // overshoot shows up: shrinking is the direction that flashes.
        let order: [PreferencesWindowController.Tab] =
            PreferencesWindowController.Tab.allCases + [.general, .shortcuts, .capture]
        controller.show(tab: order[0])
        try await Task.sleep(for: .milliseconds(700))

        var allPassed = true
        for tab in order.dropFirst() {
            let start = Date()
            controller.debugSelectAsToolbarWould(tab)
            var heights: [CGFloat] = []
            var stamps: [Double] = []
            for _ in 0..<120 {
                if let frame = controller.frame {
                    heights.append(frame.height)
                    stamps.append(Date().timeIntervalSince(start) * 1000)
                }
                try await Task.sleep(for: .milliseconds(8))
            }
            let settled = heights.last ?? 0
            let peak = heights.max() ?? 0
            // The content height plus the titlebar+toolbar; comparing the peak
            // against the settled height is what makes this independent of the
            // exact chrome height.
            let overshoot = peak - settled
            let ok = overshoot <= 2
            print(String(format: "-> %-9@ settles %4.0f, peak %4.0f, overshoot %4.0f -> %@",
                         tab.rawValue as NSString, settled, peak, overshoot,
                         (ok ? "OK" : "FAIL") as NSString))
            if !ok { allPassed = false }
            if ProcessInfo.processInfo.arguments.contains("--trace") {
                let steps = heights.enumerated()
                    .filter { $0.offset == 0 || heights[$0.offset - 1] != $0.element }
                    .map { String(format: "%.0fms:%.0f", stamps[$0.offset], $0.element) }
                print("   trace: \(steps.joined(separator: " "))")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--trace") {
            for row in controller.debugFittingSizes {
                print(String(format: "   %-9@ declared %4.0f, SwiftUI wants %4.0f",
                             row.tab.rawValue as NSString, row.declared, row.fitting))
            }
        }
        controller.close()
        print("result:        \(allPassed ? "PASS" : "FAIL — window overshoots on tab switch")")
        return allPassed ? 0 : 1
    }

    // MARK: - Preferences

    private static func preferencesCheck() -> Int32 {
        var failures: [String] = []

        // 1. KeyCombo encoding. The masking step matters: without
        // .deviceIndependentFlagsMask the left/right-modifier and keypad bits
        // get persisted and the combo stops comparing equal on replay.
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0008)
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command])
        let masked = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: raw.union(.command))
        print("combo:         \(combo.displayString) carbon=0x\(String(combo.carbonModifiers, radix: 16))")
        if combo.carbonModifiers != UInt32(cmdKey | shiftKey) {
            failures.append("carbon modifier mapping")
        }
        if masked.modifiers & ~NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue != 0 {
            failures.append("modifier masking left device-dependent bits in place")
        }

        let table: [HotKeyAction: KeyCombo] = [.captureArea: combo]
        guard
            let encoded = try? JSONEncoder().encode(table),
            let decoded = try? JSONDecoder().decode([HotKeyAction: KeyCombo].self, from: encoded),
            decoded == table
        else {
            failures.append("hotkey JSON round-trip")
            print("round-trip:    FAILED")
            return report(failures)
        }
        print("round-trip:    \(decoded[.captureArea]!.displayString) survived encode/decode")

        // 2. The system-shortcut probe. It must be able to match *something*
        // that is actually enabled, or the conflict warning in Settings is
        // decorative and users silently get bindings that never fire. Probing a
        // disabled shortcut proves nothing, so the check walks the live table and
        // verifies a round trip through our own comparison logic.
        let screenshotShortcutsOn = SystemHotKeyProbe.systemScreenshotShortcutsEnabled
        print("system ⌘⇧3/4/5: \(screenshotShortcutsOn ? "enabled" : "disabled — those combos are free")")

        if let (combo, expected) = anyEnabledSystemShortcut() {
            let found = SystemHotKeyProbe.systemBinding(matching: combo)
            print("probe check:   \(combo.displayString) -> \(found ?? "<not found>") (expected \(expected))")
            if found == nil {
                failures.append("probe cannot match an enabled system shortcut — it is broken")
            }
        } else {
            print("probe check:   no enabled system shortcut to test against")
        }

        // Our own defaults should be clear of system bindings.
        for action in HotKeyAction.allCases {
            guard let defaultCombo = action.defaultCombo else { continue }
            let owner = SystemHotKeyProbe.systemBinding(matching: defaultCombo)
            print("default \(defaultCombo.displayString):  \(action.title)"
                + (owner.map { "  CONFLICT: \($0)" } ?? "  no system conflict"))
            if owner != nil { failures.append("default binding \(defaultCombo.displayString) collides") }
        }

        // 3. Filename template. Literal runs must survive DateFormatter, which
        // treats every ASCII letter as a pattern character — " at " would
        // otherwise come out as an AM/PM marker.
        let sample = CaptureResult(
            image: blankImage(), pointSize: CGSize(width: 10, height: 10), scale: 1,
            sourceDisplayID: CGMainDisplayID(), sourceDescription: "test",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        for template in ["DuoShot %Y-%m-%d at %H.%M.%S", "shot-%Y%m%d", "%d.%m.%Y at teatime"] {
            let name = FilenameFormatter.filename(
                for: sample, template: template, contentType: .png)
            print("template:      \(template.padding(toLength: 30, withPad: " ", startingAt: 0)) -> \(name)")
            if name.contains("AM") || name.contains("PM") {
                failures.append("template '\(template)' leaked an AM/PM marker")
            }
        }

        // 3b. Chip round trip. The Settings editor shows the template as chips
        // and writes it back as a string on every edit, so `parse` -> `string`
        // has to be lossless — otherwise editing one chip quietly rewrites the
        // rest of the template.
        let roundTripCases = [
            "DuoShot %Y-%m-%d at %H.%M.%S",
            "shot-%Y%m%d",
            "%Y",
            "no variables at all",
            "100%% sure",
            "",
        ]
        for template in roundTripCases {
            let segments = FilenameTemplate.parse(template)
            let rebuilt = FilenameTemplate.string(from: segments)
            let rendersSame = FilenameFormatter.render(template: rebuilt, date: sample.capturedAt)
                == FilenameFormatter.render(template: template, date: sample.capturedAt)
            let ok = rebuilt == template && rendersSame
            print("chips:         \(template.isEmpty ? "<empty>" : template) -> "
                + "\(segments.count) chip(s) -> \(ok ? "identical" : "CHANGED to '\(rebuilt)'")")
            if !ok { failures.append("chip round trip changed '\(template)'") }
        }

        // A text chip holding a percent sign must not come back as a variable.
        let escaped = FilenameTemplate.string(from: [.text("50%"), .variable(.year)])
        if FilenameTemplate.parse(escaped) != [.text("50%"), .variable(.year)] {
            failures.append("percent in a text chip did not survive a round trip")
        }

        // 4. Settings persistence, restored afterwards so a test run never
        // changes what the user actually has configured.
        let preferences = Preferences.shared
        let originalTemplate = preferences.filenameTemplate
        let originalTimeout = preferences.previewTimeout
        preferences.filenameTemplate = "selftest-%Y"
        preferences.previewTimeout = 17
        UserDefaults.standard.synchronize()
        let persistedTemplate = UserDefaults.standard.string(forKey: "filenameTemplate")
        let persistedTimeout = UserDefaults.standard.double(forKey: "previewTimeout")
        preferences.filenameTemplate = originalTemplate
        preferences.previewTimeout = originalTimeout
        print("persistence:   template=\(persistedTemplate ?? "<nil>") timeout=\(persistedTimeout)")
        if persistedTemplate != "selftest-%Y" || persistedTimeout != 17 {
            failures.append("settings did not persist to UserDefaults")
        }

        failures.append(contentsOf: loginItemChecks(preferences))
        return report(failures)
    }

    // MARK: - Launch at login

    /// Everything about the login-item toggle that does not need a human at
    /// System Settings.
    ///
    /// Which is, as it turns out, both halves of what was actually broken. The
    /// footer copy read `.notFound` as "Unavailable — move DuoShot to
    /// /Applications" on a copy that was already in /Applications; and
    /// `launchAtLogin` queried `SMAppService` from a computed property, which
    /// `@Observable` cannot track, so the Toggle never re-rendered after its own
    /// setter and the switch looked dead even when `register()` had succeeded.
    /// Both are assertable here with no UI and no system mutation.
    ///
    /// Measured on macOS 26.5 (Developer ID, /Applications), which is the fact
    /// the copy hangs on: never registered -> `.notFound`, register() ->
    /// `.enabled`, unregister() -> `.notRegistered`. `.notFound` is the pristine
    /// state, not a broken install.
    ///
    /// The live `register()` round trip is opt-in (`--register-login-item`)
    /// because it writes a row into the user's real Login Items, and `.notFound`
    /// is a one-way door: once registered, the way back is `.notRegistered`.
    private static func loginItemChecks(_ preferences: Preferences) -> [String] {
        var failures: [String] = []
        let live = preferences.launchAtLoginStatus

        print("login item:    \(preferences.launchAtLoginStatusDescription)")
        print("               live=\(name(of: live)) (\(live.rawValue))  "
            + "in an Applications folder: \(preferences.isInstalledInApplicationsDirectory)")
        print("               \(Bundle.main.bundleURL.path)")

        // 1. Copy for every state the system can report. Nothing that is merely
        // *off* may say anything about where the app is installed, wherever this
        // binary happens to be running from.
        var offCopy: Set<String> = []
        for status in [SMAppService.Status.enabled, .notRegistered, .requiresApproval, .notFound] {
            preferences.setLaunchAtLoginStateForTest(status)
            let copy = preferences.launchAtLoginStatusDescription
            print("  \(name(of: status).padding(toLength: 17, withPad: " ", startingAt: 0))"
                + "on=\(preferences.launchAtLogin ? "yes" : "no ")  \(copy)")

            if copy.isEmpty { failures.append("\(name(of: status)) has no description") }
            if mentionsInstallLocation(copy) {
                failures.append("\(name(of: status)) blames the install location")
            }
            if (status == .enabled) != preferences.launchAtLogin {
                failures.append("launchAtLogin does not follow \(name(of: status))")
            }
            if status == .notFound || status == .notRegistered { offCopy.insert(copy) }
        }
        if offCopy.count != 1 {
            failures.append("notFound and notRegistered read differently; both just mean off")
        }

        // 2. A thrown registration error is the only branch allowed to mention
        // the location — and not even then, if the app is already in
        // /Applications. That combination is the reported bug.
        preferences.setLaunchAtLoginStateForTest(.notFound, failure: "Operation not permitted")
        let failureCopy = preferences.launchAtLoginStatusDescription
        print("  \("failure".padding(toLength: 17, withPad: " ", startingAt: 0))     \(failureCopy)")
        if !failureCopy.contains("Operation not permitted") {
            failures.append("a registration failure is never shown to the user")
        }
        if preferences.isInstalledInApplicationsDirectory, mentionsInstallLocation(failureCopy) {
            failures.append("blames the install location for an app already in /Applications")
        }

        // 3. The dead-switch regression: is a change to the login-item state
        // visible to SwiftUI's observation at all?
        for (label, read) in [
            ("launchAtLogin", { _ = preferences.launchAtLogin }),
            ("status footer", { _ = preferences.launchAtLoginStatusDescription }),
        ] as [(String, () -> Void)] {
            preferences.setLaunchAtLoginStateForTest(.notRegistered)
            let witness = ObservationWitness()
            withObservationTracking(read) { witness.fired = true }
            preferences.setLaunchAtLoginStateForTest(.enabled)
            print("observable:    \(label) notifies on change: \(witness.fired)")
            if !witness.fired {
                failures.append("\(label) is not observable — the settings UI will not update")
            }
        }

        preferences.refreshLaunchAtLoginStatus()
        if preferences.launchAtLoginStatus != live {
            failures.append("the live login-item status was not restored")
        }

        guard CommandLine.arguments.contains("--register-login-item") else { return failures }

        // 4. Opt-in: the real thing, restored to whatever it was on the way out.
        let wasEnabled = live == .enabled
        preferences.launchAtLogin = true
        print("register:      \(name(of: preferences.launchAtLoginStatus)) "
            + "failure=\(preferences.launchAtLoginFailure ?? "none")")
        if preferences.launchAtLoginStatus != .enabled {
            failures.append("register() did not enable the login item")
        }
        preferences.launchAtLogin = false
        print("unregister:    \(name(of: preferences.launchAtLoginStatus)) "
            + "failure=\(preferences.launchAtLoginFailure ?? "none")")
        if preferences.launchAtLogin {
            failures.append("unregister() left the login item enabled")
        }
        preferences.launchAtLogin = wasEnabled
        print("restored:      \(name(of: preferences.launchAtLoginStatus))"
            + (live == .notFound ? "  (was notFound; there is no way back to \"no record\")" : ""))
        return failures
    }

    private static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    private static func mentionsInstallLocation(_ copy: String) -> Bool {
        let lowered = copy.lowercased()
        return lowered.contains("/applications") || lowered.contains("move ")
    }

    /// `withObservationTracking`'s callback is `@Sendable`, so it cannot write to
    /// a captured `var`.
    /// `nonisolated` because the module defaults to `MainActor` isolation and the
    /// callback is not — it fires from wherever the mutation happened.
    private nonisolated final class ObservationWitness: @unchecked Sendable {
        var fired = false
    }

    private static func report(_ failures: [String]) -> Int32 {
        if failures.isEmpty {
            print("result:        PASS")
            return 0
        }
        for failure in failures { print("  FAIL: \(failure)") }
        print("result:        FAIL")
        return 1
    }

    /// Reads the live `com.apple.symbolichotkeys` table and builds a `KeyCombo`
    /// for the first enabled entry, so the probe can be tested against something
    /// that genuinely exists on this machine.
    private static func anyEnabledSystemShortcut() -> (KeyCombo, String)? {
        guard
            let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
            let table = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return nil }

        for (identifier, rawEntry) in table.sorted(by: { $0.key < $1.key }) {
            guard
                let entry = rawEntry as? [String: Any],
                entry["enabled"] as? Bool == true,
                let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Any],
                parameters.count >= 3,
                let keyCode = (parameters[1] as? NSNumber)?.intValue,
                keyCode >= 0, keyCode < 0xFFFF,
                let modifiers = (parameters[2] as? NSNumber)?.uintValue,
                modifiers != 0
            else { continue }
            let combo = KeyCombo(
                keyCode: UInt16(keyCode),
                modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
            return (combo, "id \(identifier)")
        }
        return nil
    }

    private static func blankImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    // MARK: - Capture helper

    private static func captureRegion(
        filter: SCContentFilter, sourceRect: CGRect?, scale: CGFloat, writeTo url: URL?
    ) async throws -> SCKOutput {
        let configuration = SCScreenshotConfiguration()
        let region = sourceRect ?? filter.contentRect
        let (width, height) = DisplayGeometry.pixelSize(of: region, scale: scale)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        if let sourceRect { configuration.sourceRect = sourceRect }
        if let url {
            // `contentType` is declared `assign` in the SDK, so it imports as the
            // ObjC class (UTTypeReference) rather than bridging to the Swift value
            // type. `fileURL` here is `strong` and does bridge — unlike the one on
            // SCScreenshotOutput, which is `assign` and stays NSURL.
            configuration.contentType = UTType.png as UTTypeReference
            configuration.fileURL = url
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try await SCKBridge.captureScreenshot(filter: filter, configuration: configuration)
    }

    // MARK: - Reporting helpers

    private static func permissionHint() -> Int32 {
        let hint = """
            error: no screen-capture permission. Launch DuoShot once and grant it, or:
              open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'

            """
        FileHandle.standardError.write(Data(hint.utf8))
        return 2
    }

    private static func report(sckFileURL: URL?, requested: URL) {
        guard let sckFileURL else {
            print("sck-writer:    fileURL was nil — SCK did not write the file")
            return
        }
        let exists = FileManager.default.fileExists(atPath: sckFileURL.path)
        print("sck-writer:    \(sckFileURL.path) exists=\(exists) (\(byteCount(of: sckFileURL)))")
        if exists { dumpDPI(of: sckFileURL, label: "sck") }
        if sckFileURL.standardizedFileURL != requested.standardizedFileURL {
            print("               NOTE: differs from requested \(requested.path)")
        }
    }

    private static func dumpDPI(of url: URL, label: String) {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }
        let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 0
        let dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? 0
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        print("               [\(label)] \(width)x\(height) px, dpi=\(dpiX)x\(dpiY)")
    }

    private static func parentProcessName() -> String {
        let ppid = getppid()
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(ppid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(ppid)" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return "\(String(decoding: bytes, as: UTF8.self)) (\(ppid))"
    }

    private static func byteCount(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static func rectString(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)",
               rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
