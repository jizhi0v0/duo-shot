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
        case selectionToolbar
        case hudAppearance(directory: URL)
        /// Repeated captures through the whole pipeline, watching memory and the
        /// staging store.
        case soak(iterations: Int, directory: URL)
        /// Reports the microphone grant and, if undecided, asks for it.
        ///
        /// Separate from `record` and meant to be run through LaunchServices,
        /// for the same reason `--selftest-permission` is: TCC addresses its
        /// prompt to the *responsible* process, so a shell-launched request is
        /// attributed to the terminal's ancestor and the dialog never reaches
        /// the user. See `make mic-check`.
        case microphone
        /// The recording pipeline end to end, headless: SCStream + SCRecordingOutput
        /// write a real file, a stream's `sourceRect` crops where we think, and
        /// the audio tracks asked for are the ones that show up.
        case record(
            directory: URL, seconds: Double, rect: CGRect?,
            audio: Bool, microphone: Bool, fps: Int)
        /// The whole recording flow through the coordinator: toggle semantics,
        /// the state machine, the HUD's lifetime, and the discard path.
        case recordFlow(directory: URL, seconds: Double)
        /// Whether the recording HUD — a window that appears *after* the stream
        /// is already running — ends up inside the recording.
        case recordHUD(
            directory: URL, seconds: Double, sharingNone: Bool, hudFirst: Bool,
            plainWindow: Bool, statusItem: Bool)

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
            case "--selftest-hud-appearance":
                RecordingHUDPanel.usesSharingTypeNone = false
                SelectionToolbarPanel.usesSharingTypeNone = false
                self = .hudAppearance(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-selection-toolbar":
                self = .selectionToolbar
            case "--selftest-lifecycle":
                self = .lifecycle(iterations: positional().flatMap(Int.init) ?? 12)
            case "--selftest-soak":
                self = .soak(
                    iterations: positional().flatMap(Int.init) ?? 100,
                    directory: URL(fileURLWithPath: value(for: "--out") ?? "build/soak"))
            case "--selftest-record-flow":
                self = .recordFlow(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"),
                    seconds: value(for: "--seconds").flatMap(Double.init) ?? 2)
            case "--selftest-record-hud":
                // NOTE the default: `.readOnly`, not the shipping `.none`.
                //
                // The two are a matched pair and the suite runs both — see the
                // verdict block in `recordHUD`. `.readOnly` asserts the surface
                // IS recorded, which is what proves the measurement can see a
                // leak; `--sharing-none` runs the shipping configuration and
                // asserts it is not. Neither half means much alone.
                self = .recordHUD(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"),
                    seconds: value(for: "--seconds").flatMap(Double.init) ?? 3,
                    sharingNone: rest.contains("--sharing-none"),
                    // Shows the HUD *before* the stream is built, which is the
                    // A/B for "does a display filter see windows that did not
                    // exist when it was created".
                    hudFirst: rest.contains("--hud-first"),
                    // Swaps the HUD for the most ordinary window AppKit can
                    // make: titled, .normal level, default everything. Tells
                    // "our panel is configured oddly" apart from "a stream does
                    // not render the capturing process's own windows".
                    plainWindow: rest.contains("--plain-window"),
                    // The menu-bar item is our window too. If a stream drops
                    // every window this process owns, our own status item
                    // vanishes from a fullscreen recording — which decides
                    // whether a running timer can live up there.
                    statusItem: rest.contains("--status-item"))
            case "--selftest-microphone":
                self = .microphone
            case "--selftest-record":
                self = .record(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"),
                    seconds: value(for: "--seconds").flatMap(Double.init) ?? 3,
                    // No --rect means the whole display, which is the other mode
                    // rather than a degenerate case of this one.
                    rect: value(for: "--rect").flatMap(Self.parseRect),
                    audio: !rest.contains("--no-audio"),
                    microphone: rest.contains("--mic"),
                    fps: value(for: "--fps").flatMap(Int.init) ?? 60)
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
            case .selectionToolbar: return try await selectionToolbar()
            case .hudAppearance(let d): return try await hudAppearance(into: d)
            case .soak(let iterations, let directory):
                return try await soak(iterations: iterations, into: directory)
            case .microphone: return await microphoneCheck()
            case .recordFlow(let directory, let seconds):
                return try await recordFlow(into: directory, seconds: seconds)
            case .recordHUD(let d, let seconds, let sharingNone, let hudFirst, let plain, let status):
                return try await recordHUD(
                    into: d, seconds: seconds, sharingNone: sharingNone,
                    hudFirst: hudFirst, plainWindow: plain, statusItem: status)
            case .record(let directory, let seconds, let rect, let audio, let microphone, let fps):
                return try await recordCheck(
                    into: directory, seconds: seconds, rect: rect,
                    audio: audio, microphone: microphone, fps: fps)
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

        // The picker's verdict on every window, from the picker's own rules
        // rather than a second copy of them. This is the tool for "why can I not
        // select that window": the rule that dropped it is named outright,
        // instead of being worked out by measuring one property at a time.
        //
        // Front-to-back, because the order is half of what the picker does — a
        // window is only reachable if nothing accepted sits in front of it.
        let cache = ShareableContentCache()
        try await cache.refresh()
        let picker = WindowPickerModel()
        let entries = WindowZOrder.entries()

        print("\nwindow picker (\(cache.windows.count) enumerated, front to back):")
        for window in cache.windows {
            let verdict = picker.rejectionReason(for: window).map { "dropped: \($0)" } ?? "PICKABLE"
            print(String(format: "  depth=%-5@ L%-4d a=%.2f %-22@ %-32@ %@",
                         entries[window.id].map { "\($0.depth)" } as NSString? ?? "—",
                         window.layer, window.alpha,
                         rectString(window.pickFrame) as NSString,
                         window.displayName as NSString,
                         verdict as NSString))
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
        // The claim is that showing a preview does not steal focus — not that
        // nothing else on the machine may take it. Requiring the frontmost app
        // to be unchanged asserted the second, and failed whenever something
        // unrelated came forward: measured 2026-07-31, System Settings
        // activating itself mid-test turned `com.openai.codex` into
        // `com.apple.systempreferences` and the preview panel was blamed for it.
        //
        // What must hold is that *we* did not come forward. A third-party app
        // taking focus is somebody else's business and cannot be prevented by
        // this panel anyway.
        let ownBundle = Bundle.main.bundleIdentifier
        let weStoleFocus = frontmostAfter == ownBundle && frontmostBefore != ownBundle
        if frontmostBefore != frontmostAfter, !weStoleFocus {
            print("               (another app took focus during the test; not ours to prevent)")
        }
        let pass = !keyWindowIsPreview && !weStoleFocus
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
        let entries = WindowZOrder.entries()
        let ranked = all.compactMap { window in entries[window.id].map { (window, $0.depth) } }
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
        // `alpha > 0` is not padding on the filter, it is the difference between
        // testing the picker and testing the machine it happens to run on.
        // Measured 2026-07-31: a DuoPaste panel — the same alpha-0.000 window
        // `WindowInfo.alpha` was introduced for — ranked first here, so this
        // picked an invisible window, demanded the picker resolve to it, and
        // failed all three z-order assertions for doing exactly what the
        // opacity check two screens down asserts it must do. The expectation has
        // to be built with the picker's rules, or it contradicts them.
        let frontmost = all.first {
            $0.isOnScreen && (0...8).contains($0.layer) && $0.bundleID != ownBundleID
                && $0.frame.width >= 200 && $0.frame.height >= 200 && $0.alpha > 0
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

        let furnitureOK = try await systemFurnitureIsPickable(coordinator, all)
        let opacityOK = try await invisibleWindowsAreNotPickable(coordinator)

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

        // The padding backdrop must not carry the menu bar. Excluding every
        // application does not exclude it — it belongs to none of them — and
        // `SCContentFilter.includeMenuBar` defaults to true, so this has to be
        // turned off by hand. Asserted on the filter rather than on pixels
        // because whether the leak is *visible* depends on the aspect ratio of
        // the capture: the backdrop is aspect-filled, so a tall one keeps the
        // wallpaper's top edge and a wide one crops it away. That is what made
        // it look intermittent, and it is exactly what a pixel test would miss.
        let backdropFilter = coordinator.engine.shareableContent
            .wallpaperFilter(for: padded.sourceDisplayID)
        let menuBarOK = backdropFilter?.includeMenuBar == false
        print("backdrop:      menu bar excluded=\(menuBarOK) "
            + "\(backdropFilter == nil ? "(no filter — cannot tell)" : "")")

        let shadowOK = paddingCastsAShadow()
        let cardOK = paddingFollowsTheWindowCurve()

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
            && childOK && shadowOK && ownWindowOK && cardOK && menuBarOK && furnitureOK && opacityOK
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

    /// A window at zero opacity is never offered, however well it ranks.
    ///
    /// `isOnScreen` does not mean visible. Several menu-bar utilities keep a
    /// panel parked over the display at alpha 0 — measured on DuoPaste: 701×596,
    /// on screen, ranked directly in front of Claude, and duly highlighted by the
    /// picker as though the user could see it.
    ///
    /// Two windows are put up, identical but for opacity, so the assertion is a
    /// comparison rather than a claim about one window: the visible one must be
    /// offered and the invisible one must not. Without the visible control, a
    /// picker that had simply stopped enumerating would pass.
    private static func invisibleWindowsAreNotPickable(
        _ coordinator: CaptureCoordinator
    ) async throws -> Bool {
        func panel(alpha: CGFloat, x: CGFloat) -> NSWindow {
            let window = NSWindow(
                contentRect: CGRect(x: x, y: 400, width: 300, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .green
            window.alphaValue = alpha
            window.level = .floating
            window.orderFrontRegardless()
            return window
        }
        let visible = panel(alpha: 1, x: 100)
        let invisible = panel(alpha: 0, x: 500)
        defer {
            visible.orderOut(nil)
            invisible.orderOut(nil)
        }

        try await Task.sleep(for: .milliseconds(500))
        try await coordinator.engine.refreshContent()
        let windows = coordinator.engine.shareableContent.windows

        let presentation = Task {
            await coordinator.overlay.present(mode: .window, windows: windows)
        }
        try await Task.sleep(for: .milliseconds(400))
        let pickable = coordinator.overlay.pickableWindowIDs
        coordinator.overlay.tearDown()
        presentation.cancel()
        try await Task.sleep(for: .milliseconds(200))

        let visibleOffered = pickable.contains(CGWindowID(visible.windowNumber))
        let invisibleOffered = pickable.contains(CGWindowID(invisible.windowNumber))
        let ok = visibleOffered && !invisibleOffered
        print("opacity:       alpha 1 pickable=\(visibleOffered), "
            + "alpha 0 pickable=\(invisibleOffered) -> \(ok ? "OK" : "FAIL")")
        return ok
    }

    /// The menu bar and the Dock are pickable, and the Dock is cut down to size.
    ///
    /// Both are ordinary screenshot targets that the picker used to refuse. The
    /// menu bar only needed the filters widened — its frame is honest. The Dock
    /// did not: its window is the entire display, so offering it as-is would put
    /// a full-screen window in front of everything and every hover anywhere would
    /// land on it, which is the frozen-picker failure all over again. It is
    /// offered against the strip it reserves instead, and the capture is cut to
    /// the same rect so the outline and the file cannot disagree.
    private static func systemFurnitureIsPickable(
        _ coordinator: CaptureCoordinator, _ all: [WindowInfo]
    ) async throws -> Bool {
        let menuBar = all.first { $0.layer == WindowInfo.menuBarLayer && $0.isOnScreen }
        let dock = all.first { $0.layer == WindowInfo.dockLayer && $0.isOnScreen }

        let presentation = Task {
            await coordinator.overlay.present(mode: .window, windows: all)
        }
        try await Task.sleep(for: .milliseconds(400))
        let pickable = coordinator.overlay.pickableWindowIDs
        coordinator.overlay.tearDown()
        presentation.cancel()
        try await Task.sleep(for: .milliseconds(200))

        var ok = true
        if let menuBar {
            let offered = pickable.contains(menuBar.id)
            print("menu bar:      \(rectString(menuBar.frame)) pickable=\(offered) "
                + "\(offered ? "" : "MISMATCH")")
            ok = ok && offered
        } else {
            print("menu bar:      not enumerated — cannot tell")
        }

        guard let dock else {
            print("dock:          not enumerated — cannot tell")
            return ok
        }
        let offered = pickable.contains(dock.id)
        // The whole point: what it is offered as must be a strip, not a display.
        let narrowed = dock.pickFrame != dock.frame
            && dock.pickFrame.height < dock.frame.height / 2
        print("dock:          window \(rectString(dock.frame)) "
            + "offered as \(rectString(dock.pickFrame)) pickable=\(offered)")
        ok = ok && offered && narrowed

        // And the capture follows the outline rather than the window.
        let result = try await coordinator.engine.capture(.window(dock.id))
        let expected = CGSize(width: (dock.pickFrame.width * result.scale).rounded(),
                              height: (dock.pickFrame.height * result.scale).rounded())
        let sizeOK = result.pixelSize == expected

        // And it must have been taken against the desktop, not in isolation. The
        // Dock is a glass surface: with nothing behind it to sample it falls back
        // to a flat tint, which is what "why did the dock background disappear"
        // was. The tell is the corners — the strip runs the full width while the
        // dock itself is centred, so in an isolated capture the ends are empty
        // and transparent, and in a region capture they are wallpaper.
        let corners = [
            (1, 1), (Int(result.pixelSize.width) - 2, 1),
            (1, Int(result.pixelSize.height) - 2),
            (Int(result.pixelSize.width) - 2, Int(result.pixelSize.height) - 2),
        ]
        let opaqueCorners = corners.filter {
            (PixelCompare.alpha(result.image, atX: $0.0, y: $0.1) ?? 0) > 250
        }.count
        let glassOK = opaqueCorners == corners.count
        print("dock capture:  \(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) px "
            + "(expected \(Int(expected.width))x\(Int(expected.height))), "
            + "\(opaqueCorners)/4 corners opaque -> \(sizeOK && glassOK ? "OK" : "FAIL")")
        return ok && sizeOK && glassOK
    }

    /// The padded card's corner radius tracks the window's own.
    ///
    /// Synthetic, so the radius is known rather than measured off whatever is on
    /// screen: a rounded rect of a chosen radius on a transparent canvas, which
    /// is exactly the shape a window capture has.
    ///
    /// Three things are checked, and the third is the one that matters. That the
    /// radius is read back correctly. That the card's corner is transparent, so
    /// the outer edge is rounded at all. And that the *midpoint* of the top edge
    /// is opaque — without it, a clip that swallowed the whole canvas would pass
    /// the first two.
    private static func paddingFollowsTheWindowCurve() -> Bool {
        let side = 240, radius = 40, padding = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
            cornerWidth: CGFloat(radius), cornerHeight: CGFloat(radius), transform: nil))
        context.fillPath()

        guard let source = context.makeImage() else { return false }
        let measured = ImagePadding.cornerRadius(of: source)
        // Antialiasing puts the first fully opaque pixel a hair inside the ideal
        // corner, so this is a tolerance, not an equality.
        let radiusOK = measured.map { abs($0 - CGFloat(radius)) <= 3 } ?? false

        guard let padded = ImagePadding.pad(
            source, by: CGFloat(padding), scale: 1, backdrop: nil,
            fallbackFill: CGColor(gray: 0.5, alpha: 1))
        else { return false }

        let cornerAlpha = PixelCompare.alpha(padded, atX: 1, y: 1) ?? 255
        let edgeAlpha = PixelCompare.alpha(padded, atX: padded.width / 2, y: 1) ?? 0
        let ok = radiusOK && cornerAlpha == 0 && edgeAlpha > 250
        print(String(format: "  card corner: window radius %@ px (drawn %d), "
                     + "card corner alpha %d, top edge alpha %d -> %@",
                     measured.map { String(format: "%.0f", $0) } as NSString? ?? "none",
                     radius, cornerAlpha, edgeAlpha, (ok ? "OK" : "FAIL") as NSString))
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
    /// Photographs both floating bars, in every state, so their layout can be
    /// looked at instead of reasoned about.
    ///
    /// Reasoning about it is what went wrong: a rewrite that shared metrics
    /// between the two bars compiled, passed the whole suite, and rendered
    /// wrongly — because nothing in the suite has ever looked at the HUD.
    ///
    /// Both panels ship `sharingType = .none`, so the arguments turn that off;
    /// with it on they are invisible to ScreenCaptureKit and every frame would
    /// come back empty.
    private static func hudAppearance(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let screen = NSScreen.main,
              let displayID = ScreenIndex.displayID(of: screen)
        else { throw CaptureError.noDisplays }

        let engine = CaptureEngine()
        try await engine.refreshContent()

        func shoot(_ name: String, frame: CGRect) async throws {
            try await Task.sleep(for: .milliseconds(400))
            let shot = try await engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: frame))
            let url = directory.appendingPathComponent("\(name).png")
            try? ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)
            print("  \(name).png  \(rectString(frame))")
        }

        // The anchor both bars are placed against. They appear here one after
        // the other during one continuous action, so where they land is part of
        // whether they read as one bar changing state.
        let anchor = CGRect(
            x: screen.frame.midX - 200, y: screen.frame.midY, width: 400, height: 300)

        let hud = RecordingHUD()
        hud.showStarting(on: screen, under: anchor)
        guard let starting = hud.frameForTest else { return 1 }
        try await shoot("hud-starting", frame: starting)

        hud.beginRecording(elapsed: { 754 })
        guard let running = hud.frameForTest else { return 1 }
        try await shoot("hud-recording", frame: running)
        for line in hud.debugSubviewFrames { print("    hud: \(line)") }
        hud.hide()

        let toolbar = SelectionToolbar()
        toolbar.show(under: anchor, on: screen)
        guard let bar = toolbar.frameForTest else { return 1 }
        try await shoot("toolbar", frame: bar)
        toolbar.hide()

        // The two are meant to read as one bar changing state, so what is worth
        // asserting is that they agree on height and on where they sit against
        // the same anchor. Width legitimately differs; a HUD as wide as the
        // toolbar would be padding.
        var failures: [String] = []
        if abs(starting.height - bar.height) >= 0.5 {
            failures.append("different heights: hud \(Int(starting.height)) vs toolbar \(Int(bar.height))")
        }
        // Same top edge against the same anchor. Centres cannot be compared —
        // the widths differ on purpose — and the top edge is the one the eye
        // tracks as the contents change.
        if abs(starting.maxY - bar.maxY) >= 0.5 {
            failures.append("different top edges: hud \(Int(starting.maxY)) vs toolbar \(Int(bar.maxY))")
        }
        if abs(running.maxY - bar.maxY) >= 0.5 {
            failures.append("the bar moved when the take started: "
                + "\(Int(bar.maxY)) -> \(Int(running.maxY))")
        }
        print("placement:     anchor \(rectString(anchor))")
        print("               toolbar \(rectString(bar))")
        print("               hud starting \(rectString(starting)) running \(rectString(running))")
        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.joined(separator: "; "))")")
        return failures.isEmpty ? 0 : 1
    }

    /// The confirmation step: mouse-up arms the selection instead of committing
    /// it, and only the second confirm resumes the caller.
    ///
    /// The failure this is really guarding against is not the toolbar failing to
    /// appear — that is visible the first time anyone records. It is
    /// `present()` resuming on the *first* confirm anyway, which looks identical
    /// from the outside (a recording starts) and silently deletes the entire
    /// feature. So every assertion below is about the continuation, not about
    /// pixels.
    private static func selectionToolbar() async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        guard let screen = NSScreen.main else { throw CaptureError.noDisplays }

        let coordinator = CaptureCoordinator()
        let overlay = coordinator.overlay
        var failures: [String] = []

        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        // --- armed, then confirmed -------------------------------------------
        let selection = CGRect(x: 240, y: 260, width: 420, height: 300)
        let box = OutcomeBox()
        let flag = CompletionFlag()
        Task {
            box.outcome = await overlay.present(
                mode: .area, windows: [], allowsWindowMode: false, requiresConfirmation: true)
            flag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))

        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(120))

        check(overlay.isArmedForTest, "first confirm arms rather than commits")
        check(overlay.hasPendingContinuation, "present() has NOT resumed yet")
        check(overlay.toolbarIsVisibleForTest, "toolbar is on screen")
        check(!flag.isDone, "the caller is still waiting")

        // Under the selection, and inside the screen. Both matter: a bar placed
        // off-screen is as useless as one that never appeared, and it is the
        // clamping that is easy to get wrong.
        if let bar = overlay.toolbarFrameForTest {
            print("  bar: \(rectString(bar))  selection: \(rectString(selection))")
            check(bar.midY < selection.midY, "toolbar sits below the selection's centre")
            check(screen.visibleFrame.contains(bar), "toolbar is fully on screen")
        } else {
            check(false, "toolbar has a frame")
        }

        // The toolbar is one of ours, so a screenshot taken through this list
        // must not photograph it.
        check(overlay.panelWindowIDs.count >= 2, "toolbar window is in panelWindowIDs")

        overlay.confirmForTest()
        let resumed = await flag.wait(upTo: .seconds(2))
        check(resumed, "second confirm resumes present()")
        if case .area(_, let rect)? = box.outcome {
            check(rect == selection, "outcome carries the armed rect, unchanged")
        } else {
            check(false, "outcome is .area (got \(String(describing: box.outcome)))")
        }
        check(!overlay.toolbarIsVisibleForTest, "toolbar is gone after the commit")
        overlay.tearDown()
        try await Task.sleep(for: .milliseconds(120))

        // --- a new drag disarms ----------------------------------------------
        let secondFlag = CompletionFlag()
        Task {
            _ = await overlay.present(
                mode: .area, windows: [], allowsWindowMode: false, requiresConfirmation: true)
            secondFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))
        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(100))
        check(overlay.toolbarIsVisibleForTest, "armed again")

        overlay.restartSelectionForTest(
            at: CGPoint(x: selection.maxX + 40, y: selection.maxY + 40), on: screen)
        try await Task.sleep(for: .milliseconds(100))
        check(!overlay.isArmedForTest, "starting a new drag disarms")
        check(!overlay.toolbarIsVisibleForTest, "toolbar goes away with it")
        check(overlay.hasPendingContinuation, "still not resumed by the restart")

        // --- tearDown always takes the bar with it ---------------------------
        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(100))
        check(overlay.toolbarIsVisibleForTest, "armed a third time")
        overlay.tearDown()
        try await Task.sleep(for: .milliseconds(120))
        check(!overlay.toolbarIsVisibleForTest, "tearDown hides the toolbar")
        check(await secondFlag.wait(upTo: .seconds(2)), "tearDown resumes present()")

        // The screenshot path must be untouched by any of this.
        let stillFlag = CompletionFlag()
        let stillBox = OutcomeBox()
        Task {
            stillBox.outcome = await overlay.present(mode: .area, windows: [])
            stillFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))
        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        let stillResumed = await stillFlag.wait(upTo: .seconds(2))
        check(stillResumed, "without requiresConfirmation, one confirm still commits")
        check(!overlay.toolbarIsVisibleForTest, "and no toolbar appears for screenshots")
        overlay.tearDown()

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

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

    // MARK: - Microphone

    /// Peak and RMS of a file's audio track, decoded to float PCM.
    ///
    /// Exists because "the file has an audio track" and "the file has audio in
    /// it" are different claims, and only the second one is the feature. A track
    /// of digital silence is exactly what a dropped microphone looks like from
    /// the container's point of view — and a real microphone in a quiet room
    /// still sits well above zero, so the noise floor is the signal here.
    private static func audioLevels(
        of url: URL
    ) async throws -> (peak: Double, rms: Double, samples: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peak = 0.0
        var sumOfSquares = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard
                CMBlockBufferGetDataPointer(
                    block, atOffset: 0, lengthAtOffsetOut: nil,
                    totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                let pointer
            else { continue }
            let floats = UnsafeRawPointer(pointer)
                .bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
            for index in 0..<(length / MemoryLayout<Float>.size) {
                let value = Double(abs(floats[index]))
                peak = max(peak, value)
                sumOfSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (peak, (sumOfSquares / Double(count)).squareRoot(), count)
    }

    /// Accumulates audio levels from a realtime tap.
    ///
    /// `nonisolated` and lock-guarded because `installTap` calls back on an
    /// audio render thread, which is nobody's actor.
    private nonisolated final class LevelMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0.0
        private var sumOfSquares = 0.0
        private var count = 0

        func add(_ buffer: AVAudioPCMBuffer) {
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var localPeak = 0.0
            var localSum = 0.0
            var localCount = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames {
                    let value = Double(abs(samples[frame]))
                    localPeak = max(localPeak, value)
                    localSum += value * value
                    localCount += 1
                }
            }
            lock.withLock {
                peak = max(peak, localPeak)
                sumOfSquares += localSum
                count += localCount
            }
        }

        var snapshot: (peak: Double, rms: Double, samples: Int) {
            lock.withLock {
                guard count > 0 else { return (0, 0, 0) }
                return (peak, (sumOfSquares / Double(count)).squareRoot(), count)
            }
        }
    }

    /// Measures the default input device through AVAudioEngine — a path that
    /// does not involve ScreenCaptureKit at all.
    ///
    /// This is the control for the microphone question. A silent track inside a
    /// recording has two possible causes, and only one of them is a bug in our
    /// code: ScreenCaptureKit dropped the microphone, or the microphone itself
    /// is producing silence (a wireless receiver with its transmitter switched
    /// off presents as a perfectly healthy input device and sends zeros). One
    /// number from outside SCK tells the two apart.
    private static func inputDeviceLevels(seconds: Double) async -> (peak: Double, rms: Double, samples: Int) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return (0, 0, 0) }

        let meter = LevelMeter()
        // The tap block MUST be spelled `@Sendable`, and this is not a formality.
        // `AVAudioNodeTapBlock` carries no Sendable annotation in the SDK, so
        // under the module's MainActor default isolation an inline closure is
        // inferred MainActor-isolated and the compiler plants an executor check
        // in it — which then fires on the audio render thread:
        //
        //   BUG IN CLIENT OF LIBDISPATCH: Assertion failed:
        //   Block was expected to execute on queue [com.apple.main-thread]
        //
        // Third time this project has met the same shape: an AppKit/AVF callback
        // that is documented to arrive on some other thread, silently adopting
        // MainActor because nothing in the header says otherwise.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            meter.add(buffer)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
        do {
            try engine.start()
        } catch {
            print("input-device:  could not start the audio engine: \(error.localizedDescription)")
            return (0, 0, 0)
        }
        try? await Task.sleep(for: .seconds(seconds))
        engine.stop()
        input.removeTap(onBus: 0)
        return meter.snapshot
    }

    private static func microphoneCheck() async -> Int32 {
        let before = MicrophonePermission.statusDescription
        print("microphone:    \(before)")
        print("usage-string:  "
            + (Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
                ? "present" : "MISSING — the process is killed, not denied, on first use"))
        print("parent:        \(parentProcessName())")

        let granted = await MicrophonePermission.request()
        let after = MicrophonePermission.statusDescription
        print("after request: \(after)")

        if granted {
            let device = AVCaptureDevice.default(for: .audio)
            print("input-device:  \(device?.localizedName ?? "<none>")")
            let levels = await inputDeviceLevels(seconds: 3)
            print(String(
                format: "input-levels:  peak %.5f  rms %.5f  (%d samples) -> %@",
                levels.peak, levels.rms, levels.samples,
                levels.rms < 0.00003
                    ? "SILENT — this device is sending zeros, so a silent recording is not SCK's doing"
                    : "has signal"))
        }
        if getppid() != 1 {
            print("""
                WARNING:       launched from a shell, so TCC attributes the prompt to an ancestor
                               process — measured 2026-07-31, a request made this way was addressed
                               to the terminal's parent app and never reached the user, leaving
                               SCStream.startCapture hanging forever. Use `make mic-check`.
                """)
        }

        // To os_log as well: a LaunchServices launch is the only one that proves
        // the attribution, and it has no stdout to read.
        Log.record.notice("""
            selftest-microphone: before=\(before, privacy: .public) \
            after=\(after, privacy: .public) parent=\(parentProcessName(), privacy: .public)
            """)
        return granted ? 0 : 1
    }

    // MARK: - Recording flow

    /// Drives `RecordingCoordinator` the way the hotkey does, and checks the
    /// things a human would otherwise have to notice: that the same binding
    /// stops what it started, that the HUD lives exactly as long as the take,
    /// and that discarding leaves nothing behind.
    private static func recordFlow(into directory: URL, seconds: Double) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The test must not reach into the user's session. Their clipboard is
        // theirs, and a shutter sound from a background self-test is the kind of
        // thing that makes a test suite unrunnable.
        let preferences = Preferences.shared
        let savedClipboard = preferences.copyToClipboard
        let savedSound = preferences.playsSound
        preferences.copyToClipboard = false
        preferences.playsSound = false
        defer {
            preferences.copyToClipboard = savedClipboard
            preferences.playsSound = savedSound
        }

        let recorder = RecordingCoordinator(overlay: OverlayController())
        recorder.saveDirectoryOverride = directory
        var outputs: [OutputPipeline.RecordingOutput] = []
        recorder.onResult = { outputs.append($0) }

        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        // --- the toggle ---------------------------------------------------
        await recorder.perform(.recordFullscreen)
        check(recorder.isRecording, "the binding started a recording")
        check(recorder.hudIsVisibleForTest, "the HUD is on screen while recording")
        let staged = recorder.stagedURLForTest
        check(staged?.deletingLastPathComponent() == StagingStore.shared.directory,
              "the take is being written into staging, not straight to the save folder")

        try await Task.sleep(for: .seconds(seconds))

        // The same action again: this is what makes it a toggle rather than a
        // way to end up with two streams.
        await recorder.perform(.recordFullscreen)
        check(!recorder.isRecording, "the same binding stopped it")
        check(!recorder.hudIsVisibleForTest, "the HUD came down with it")
        check(outputs.count == 1, "exactly one output was produced (got \(outputs.count))")

        if let output = outputs.first {
            let exists = FileManager.default.fileExists(atPath: output.url.path)
            check(exists, "the file exists at \(output.url.lastPathComponent)")
            check(output.url.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL,
                  "it was moved to the save directory")
            check(!FileManager.default.fileExists(atPath: staged?.path ?? ""),
                  "staging no longer holds a copy")
            let asset = AVURLAsset(url: output.url)
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            check(duration >= seconds * 0.5,
                  String(format: "it is %.2fs long (asked for %.1fs)", duration, seconds))
            check(!tracks.isEmpty, "it has a video track")
        }

        // --- discard ------------------------------------------------------
        await recorder.perform(.recordFullscreen)
        check(recorder.isRecording, "a second recording started")
        let discarded = recorder.stagedURLForTest
        try await Task.sleep(for: .seconds(1))
        await recorder.discard()
        check(!recorder.isRecording, "discard ended it")
        check(!recorder.hudIsVisibleForTest, "discard took the HUD down")
        check(outputs.count == 1, "discard produced no output (still \(outputs.count))")
        check(!FileManager.default.fileExists(atPath: discarded?.path ?? "/nonexistent"),
              "discard deleted the file")

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — " + failures.joined(separator: "; "))")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - HUD exclusion

    /// Whether our own on-screen controls end up inside the recording.
    ///
    /// **This is not the same question the screenshot tests answered.** There,
    /// exclusion rests on `SCContentFilter(display:excludingWindows:)`, and the
    /// filter is fixed when the capture is made — the panels are already on
    /// screen and already in the list. A recording's filter is fixed when the
    /// *stream starts*, and the HUD appears afterwards, so it can never be in
    /// that list. Whether `sharingType = .none` covers a window created after a
    /// stream is running is a genuinely different claim, and M2 did not test it.
    ///
    /// Method as in M2: the HUD paints itself flat magenta, the recording is
    /// sampled, and the frame is counted for magenta. `--sharing-default` is the
    /// negative control — with it the HUD *must* show up, or a clean run proves
    /// nothing at all.
    /// A plain magenta window, as ordinary as AppKit allows.
    private static func makePlainMagentaWindow(on screen: NSScreen?) -> NSWindow {
        let size = RecordingHUDView.barSize
        let target = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(
            contentRect: CGRect(
                x: target.frame.midX - size.width / 2,
                y: target.visibleFrame.minY + 24,
                width: size.width, height: size.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.magenta.cgColor
        window.contentView = view
        window.backgroundColor = .magenta
        // `.floating`, despite this being the "most ordinary window AppKit can
        // make" surface. The property under test is `sharingType` — left at the
        // default `.readOnly` — and the level is not part of the claim: M9's own
        // matrix showed level, panel-ness and creation order make no difference.
        //
        // What the level *did* affect was whether the test could run at all. A
        // `.normal` window belongs to a background, non-frontmost process, so any
        // app coming forward covers it; measured 2026-07-31 this produced runs
        // where the screenshot saw 0 px and others where it saw 27079 of 36058,
        // i.e. an intermittent failure reporting "our window was not recorded"
        // when the truth was "something was sitting on top of it".
        window.level = .floating
        window.orderFrontRegardless()
        return window
    }

    private static func recordHUD(
        into directory: URL, seconds: Double, sharingNone: Bool, hudFirst: Bool,
        plainWindow: Bool, statusItem useStatusItem: Bool
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        RecordingHUDPanel.usesSharingTypeNone = sharingNone
        RecordingHUDView.debugFillsMagenta = true

        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let screen = ScreenIndex.screen(for: displayID)

        var options = RecordingOptions.default
        options.capturesSystemAudio = false
        options.capturesMicrophone = false

        let url = directory.appendingPathComponent("record-hud.mp4")
        try? FileManager.default.removeItem(at: url)

        let engine = RecordingEngine()
        let hud = RecordingHUD()

        // Default order is HUD *after* the stream is running, because that is
        // what the app will actually do and it is the case `excludingWindows`
        // cannot cover. `--hud-first` flips it, which is how the two are told
        // apart when the control refuses to respond.
        var recording: ActiveRecording?
        var plain: NSWindow?
        var status: NSStatusItem?
        func showSurface() {
            if useStatusItem {
                let item = NSStatusBar.system.statusItem(withLength: 44)
                let swatch = NSImage(size: NSSize(width: 40, height: 18), flipped: false) { rect in
                    NSColor.magenta.setFill()
                    rect.fill()
                    return true
                }
                // Templates are recoloured by AppKit; this one has to keep the
                // exact magenta the counter is looking for.
                swatch.isTemplate = false
                item.button?.image = swatch
                status = item
            } else if plainWindow {
                plain = makePlainMagentaWindow(on: screen)
            } else {
                // The bar is in magenta debug mode, where `update` is a no-op,
                // so there is nothing for the ticker to read.
                hud.show(on: screen, elapsed: { 0 })
            }
        }
        if hudFirst {
            showSurface()
            // Polled, not slept. A fixed 400 ms was the flaky part of this test
            // in exactly the way the M2 overlay test taught: it holds on an idle
            // machine and misses under load, and the failure it produces is
            // silent and backwards. Measured 2026-07-31, running this straight
            // after two overlay tests left the plain window still painting when
            // the stream started, and because the screen was otherwise static
            // ScreenCaptureKit then delivered no further frame — so the video
            // held a frame from before the window existed and the test reported
            // "the surface was NOT recorded", i.e. a pass turning into a failure
            // that blames the product for the harness being early.
            //
            // Skipped under `.none`, where the surface is invisible to the
            // screenshot by definition and this could only ever time out.
            if !sharingNone {
                let painted = await waitUntilPainted(on: displayID, upTo: .seconds(3))
                print("paint:         \(painted) px magenta before the stream was built")
            } else {
                try await Task.sleep(for: .milliseconds(400))
            }
            recording = try await engine.start(.display(displayID), options: options, to: url)
        } else {
            recording = try await engine.start(.display(displayID), options: options, to: url)
            showSurface()
        }
        guard recording != nil else { return 1 }
        let hudFrame = status?.button?.window?.frame ?? plain?.frame ?? hud.frameForTest ?? .zero
        let surfaceWindowNumber = status?.button?.window?.windowNumber
            ?? plain?.windowNumber
            ?? hud.windowIDs.first.map(Int.init)
        let surfaceName =
            if useStatusItem { "NSStatusItem (menu bar, our process's window)" }
            else if plainWindow { "plain NSWindow (.normal level, titled)" }
            else { "RecordingHUDPanel (.statusBar, nonactivating)" }
        print("surface:       \(surfaceName)")
        print("order:         HUD shown \(hudFirst ? "BEFORE" : "AFTER") the stream started")
        print("hud:           \(rectString(hudFrame)) sharingType=\(sharingNone ? "none" : "readOnly")")

        // Cross-check through the screenshot path before judging the video.
        // "No magenta in the frame" has two causes and only one is about
        // exclusion: the HUD may simply not be painting. A still capture, taken
        // with the already-proven pipeline and nothing excluded, separates them
        // — and without it a negative control that fails to respond is
        // indistinguishable from one that responds correctly.
        try await Task.sleep(for: .milliseconds(600))
        let capture = CaptureEngine()
        try await capture.refreshContent()
        var stillOptions = CaptureOptions.default
        stillOptions.excludedWindowIDs = []
        let still = try await capture.capture(.display(displayID), options: stillOptions)
        let stillMagenta = PixelCompare.count(still.image, matching: PixelCompare.isDebugMagenta)
        try? ImageEncoder.write(
            still.image,
            to: directory.appendingPathComponent(
                "record-hud-still-\(sharingNone ? "sharing-none" : "readonly").png"),
            as: .png, scale: still.scale)
        print("still capture: \(stillMagenta) px magenta "
            + "(is the HUD painting at all, and does a *screenshot* see it)")

        // Asked NOW, while the surface is still up.
        //
        // It used to be asked in the verdict block, which runs after `hide()`
        // and `orderOut` — so the answer was a race with the window server
        // dropping the window from its on-screen list, and the `.none` case,
        // whose only evidence this is, intermittently came back INCONCLUSIVE
        // for a surface that had been on screen the whole take.
        let windowServerOnScreen = surfaceWindowNumber.map(windowServerSaysOnScreen) ?? false

        // Let the window server actually composite it. A fixed sleep here was
        // the flaky part of the M2 overlay test; the recording is long enough
        // that a generous settle is cheaper than a poll.
        try await Task.sleep(for: .seconds(seconds))
        let result = try await engine.stop()
        hud.hide()
        plain?.orderOut(nil)
        plain = nil
        if let status { NSStatusBar.system.removeStatusItem(status) }
        status = nil

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else {
            print("result:        FAIL — the recording has no duration")
            return 1
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, actual) = try await generator.image(
            at: CMTime(seconds: duration.seconds * 0.6, preferredTimescale: 600))
        let framePath = directory.appendingPathComponent(
            "record-hud-\(sharingNone ? "sharing-none" : "readonly").png")
        try? ImageEncoder.write(frame, to: framePath, as: .png, scale: result.scale)

        // What is in the video where the surface is? "No magenta" alone cannot
        // distinguish "the window was excluded and we see the desktop behind
        // it" from "the frame is broken". The luminance of that exact rect
        // answers it: desktop content is mid-grey, a broken frame is black, and
        // flat magenta is ~73 (Rec. 709 luma of 255,0,255).
        let surfaceInPixels = DisplayGeometry.flipped(hudFrame)
            .applying(CGAffineTransform(scaleX: result.scale, y: result.scale))
        let videoLuma = PixelCompare.meanLuminance(frame, in: surfaceInPixels)
        let stillLuma = PixelCompare.meanLuminance(still.image, in: surfaceInPixels)
        print(String(
            format: "surface rect:  luminance in video %.1f vs in screenshot %.1f (flat magenta measures 72.6)",
            videoLuma ?? -1, stillLuma ?? -1))

        let magenta = PixelCompare.count(frame, matching: PixelCompare.isDebugMagenta)
        // How much magenta a fully visible HUD is worth, so "0" can be read
        // against something rather than admired on its own.
        let expected = Int(hudFrame.width * hudFrame.height * result.scale * result.scale)
        print("frame:         t=\(String(format: "%.2f", actual.seconds))s "
            + "\(frame.width)x\(frame.height) px -> \(framePath.lastPathComponent)")
        print("magenta:       \(magenta) px in the video, \(stillMagenta) px in the screenshot "
            + "(window rect would hold ~\(expected) px)")

        // What this test asserts changed on 2026-07-31, because what it was
        // asserting turned out not to be true.
        //
        // It was written around M9: "a stream does not render the capturing
        // process's own windows at all", with the screenshot as the control —
        // if the still sees the surface and the video does not, the difference
        // is the stream. Measured against a plain titled `.normal` window shown
        // *before* the stream was built, the video came back holding 35525 of
        // its 36060 px. The stream renders our windows. M9 is withdrawn.
        //
        // So the two configurations now assert opposite things, and the pair is
        // the test:
        //
        //   .readOnly — the surface IS expected in the video. This is the
        //     documented behaviour now, and it doubles as the positive control:
        //     it is what proves the magenta counter, the frame extraction and
        //     the rect mapping can see a leak at all.
        //   .none     — the surface must be ABSENT. This is the mechanism the
        //     app actually relies on for the HUD, the overlay and the preview
        //     panel, and it is the only one of the two that can regress into a
        //     user-visible defect.
        //
        // `.none` blinds the screenshot control as well, so on-screen-ness is
        // established without ScreenCaptureKit in the loop: the window server's
        // own on-screen list. That is metadata, not pixels — no capture path,
        // nothing for `sharingType` to hide from — so it stays honest in exactly
        // the configuration where the old control could not.
        // Two independent ways to establish it, because neither covers both
        // configurations. The window server's list is the only one that works
        // under `.none`, but it does not work for a status item: measured
        // 2026-07-31, `NSStatusItem.button?.window?.windowNumber` reported 2^32
        // — AppKit's not-ordered-in value — while the swatch was plainly on
        // screen at 2844 of its 2880 px. The screenshot covers that case and is
        // blind under `.none`. Either one is enough.
        let onScreen = windowServerOnScreen || stillMagenta > 500
        print("on screen:     window server says \(windowServerOnScreen) "
            + "(window \(surfaceWindowNumber.map(String.init) ?? "<none>")), "
            + "screenshot says \(stillMagenta > 500) (\(stillMagenta) px) -> \(onScreen)")

        let leaked = magenta > max(stillMagenta / 20, 100)
        guard onScreen else {
            // Exit 0, loudly labelled. This says nothing about the product: a
            // surface that never reached the window server cannot demonstrate
            // either outcome, and failing on it would make the suite red for a
            // crowded menu bar. Measured 2026-07-31 with `--status-item`, whose
            // window reported number 2^32 — the value AppKit uses before a
            // window is ordered in — because the menu bar had no room left to
            // show a new item.
            print("result:        INCONCLUSIVE — the surface never reached the window server "
                + "(window \(surfaceWindowNumber.map(String.init) ?? "<none>"), "
                + "\(stillMagenta) px in the screenshot). For --status-item this usually means "
                + "the menu bar is full; nothing is being asserted either way")
            return 0
        }
        if sharingNone {
            print("result:        \(leaked ? "FAIL" : "PASS") — "
                + (leaked
                    ? "sharingType = .none did NOT keep the surface out of the recording"
                    : "on screen and absent from the recording, which is what .none must do"))
            return leaked ? 1 : 0
        }
        print("result:        \(leaked ? "PASS" : "FAIL") — "
            + (leaked
                ? "recorded, as a .readOnly window of our own process is expected to be"
                : "a .readOnly window of ours did NOT reach the video (\(magenta) px). "
                    + "Either M9 has become true again or this test can no longer detect a leak — "
                    + "check the .none case, which now has no working positive control"))
        return leaked ? 0 : 1
    }

    /// Blocks until the magenta surface has finished compositing, and returns
    /// the count it settled on.
    ///
    /// "Settled" rather than "non-zero": a window caught mid-composite reports a
    /// real but partial count — measured 20569 px of an eventual 36060 — so a
    /// first sighting is not the same as a painted window. Two equal readings in
    /// a row is the cheapest test for that.
    private static func waitUntilPainted(
        on displayID: CGDirectDisplayID, upTo timeout: Duration
    ) async -> Int {
        let engine = CaptureEngine()
        var options = CaptureOptions.default
        options.excludedWindowIDs = []
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var previous = -1

        while ContinuousClock.now < deadline {
            guard
                let still = try? await engine.capture(.display(displayID), options: options)
            else { break }
            let count = PixelCompare.count(still.image, matching: PixelCompare.isDebugMagenta)
            if count > 500, count == previous { return count }
            previous = count
            try? await Task.sleep(for: .milliseconds(120))
        }
        return previous
    }

    /// Whether the window server lists this window as on screen.
    ///
    /// Metadata only — `CGWindowListCopyWindowInfo` reports no pixels, so it is
    /// not a capture path and `sharingType` has nothing to hide from it. That is
    /// the whole reason it is used as the control for the `.none` case.
    private static func windowServerSaysOnScreen(_ windowNumber: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == windowNumber }
    }

    // MARK: - Recording

    /// The recording equivalent of `--selftest-rect`, and the first thing worth
    /// writing for phase 2: it settles, with no UI at all, whether
    /// `SCStream` + `SCRecordingOutput` produces a real file, what a stream's
    /// `sourceRect` actually crops, and how long start and finalisation take.
    ///
    /// The geometry claim is made **relatively**, against a deliberately offset
    /// control, rather than against an absolute threshold. H.264 is lossy, so a
    /// correctly aligned frame will never match a PNG screenshot the way two
    /// screenshots match each other — an absolute bound would be a number picked
    /// to make the test pass. A wrong `sourceRect` has to look like the offset
    /// control, and that comparison stays honest whatever the bitrate.
    private static func recordCheck(
        into directory: URL, seconds: Double, rect: CGRect?,
        audio: Bool, microphone: Bool, fps: Int
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let capture = CaptureEngine()
        try await capture.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        // The engine silently drops the microphone when the grant is undecided,
        // because letting SCK meet that state hangs `startCapture` outright. The
        // test has to know which of the two it is measuring, or a downgraded run
        // reads as "audio is broken".
        let microphoneEffective = microphone && MicrophonePermission.isGranted
        if microphone {
            print("microphone:    grant is \(MicrophonePermission.statusDescription)"
                + (microphoneEffective ? "" : " — recording without it"))
        }

        var options = RecordingOptions.default
        options.capturesSystemAudio = audio
        options.capturesMicrophone = microphone
        options.frameRate = fps

        let request: RecordingRequest = rect.map {
            .area(displayID: displayID, rectInAppKitGlobal: $0)
        } ?? .display(displayID)
        let url = directory.appendingPathComponent("record-\(request.kind).\(options.fileExtension)")
        try? FileManager.default.removeItem(at: url)

        print("display:       \(ScreenIndex.describe(ScreenIndex.screen(for: displayID) ?? .main!))")
        print("request:       \(request.kind)\(rect.map { " " + rectString($0) } ?? "")")

        let engine = RecordingEngine()
        let startClock = ContinuousClock.now
        let recording = try await engine.start(request, options: options, to: url)
        let startLatency = startClock.duration(to: .now)
        print("start:         \(milliseconds(startLatency)) ms to first written frame")
        print("expected:      \(Int(recording.pixelSize.width))x\(Int(recording.pixelSize.height)) px "
            + "from \(Int(recording.pointSize.width))x\(Int(recording.pointSize.height)) pt "
            + "@\(recording.scale)x")

        // Halfway through, photograph the same region through the already-proven
        // screenshot path, twice, ~120 ms apart. Two shots because comparing a
        // video frame against live screen content is only meaningful if the
        // content was not moving — the same sandwich `--selftest-rect` uses.
        let recordingStart = ContinuousClock.now
        try await Task.sleep(for: .seconds(seconds / 2))

        let probeRect = rect ?? DisplayGeometry.flipped(CGDisplayBounds(displayID))
        let offsetRect = probeRect.offsetBy(dx: 0, dy: min(200, probeRect.height))
        let probeOffset = recordingStart.duration(to: .now).seconds

        let aligned = try await capture.capture(
            .area(displayID: displayID, rectInAppKitGlobal: probeRect))
        try await Task.sleep(for: .milliseconds(120))
        let alignedAgain = try await capture.capture(
            .area(displayID: displayID, rectInAppKitGlobal: probeRect))
        let control = try await capture.capture(
            .area(displayID: displayID, rectInAppKitGlobal: offsetRect))

        try await Task.sleep(for: .seconds(max(0.2, seconds / 2)))

        let stopClock = ContinuousClock.now
        let result = try await engine.stop()
        print("stop:          \(milliseconds(stopClock.duration(to: .now))) ms to finalise")
        print("file:          \(result.url.lastPathComponent) "
            + "\(byteCount(of: result.url)) duration=\(String(format: "%.2f", result.duration))s")

        // MARK: what the container actually says

        let asset = AVURLAsset(url: result.url)
        let assetDuration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        print("asset:         duration=\(String(format: "%.2f", assetDuration.seconds))s "
            + "video-tracks=\(videoTracks.count) audio-tracks=\(audioTracks.count)")

        var encodedSize = CGSize.zero
        var nominalRate: Float = 0
        if let track = videoTracks.first {
            encodedSize = try await track.load(.naturalSize)
            nominalRate = try await track.load(.nominalFrameRate)
            print("video-track:   \(Int(encodedSize.width))x\(Int(encodedSize.height)) px "
                + "@\(String(format: "%.1f", nominalRate)) fps nominal")
        }
        var audioIsSilent = false
        if audio || microphoneEffective {
            print("audio-request: system=\(audio) microphone=\(microphoneEffective) -> "
                + "\(audioTracks.count) track(s) in the file")
            if let levels = try await audioLevels(of: result.url) {
                // -90 dBFS is below any real microphone's noise floor and above
                // literal zero, so it separates "captured a quiet room" from
                // "captured nothing".
                audioIsSilent = levels.rms < 0.00003
                print(String(
                    format: "  levels:      peak %.5f  rms %.5f  (%d samples) -> %@",
                    levels.peak, levels.rms, levels.samples,
                    audioIsSilent ? "SILENT" : "has signal"))
            }
        }

        // MARK: does the frame show the region we asked for

        var geometry = "SKIPPED"
        var geometryPassed = true
        if let track = videoTracks.first, assetDuration.seconds > 0 {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Zero tolerance, or the generator is free to hand back a keyframe
            // from somewhere else entirely and the comparison means nothing.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            _ = track
            let time = CMTime(
                seconds: min(probeOffset, max(0, assetDuration.seconds - 0.1)),
                preferredTimescale: 600)
            let (frame, actual) = try await generator.image(at: time)
            let framePath = directory.appendingPathComponent("record-frame.png")
            try? ImageEncoder.write(frame, to: framePath, as: .png, scale: recording.scale)
            print("frame:         t=\(String(format: "%.2f", actual.seconds))s "
                + "\(frame.width)x\(frame.height) px -> \(framePath.lastPathComponent)")

            let crop = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let liveDrift = PixelCompare.compare(
                aligned.image.cropping(to: crop) ?? aligned.image,
                alignedAgain.image.cropping(to: crop) ?? alignedAgain.image)
            let match = PixelCompare.compare(frame, aligned.image.cropping(to: crop) ?? aligned.image)
            let offset = PixelCompare.compare(frame, control.image.cropping(to: crop) ?? control.image)

            print(String(format: "  live drift:  mean abs diff %.3f (two screenshots 120 ms apart)",
                         liveDrift.meanAbsoluteDifference))
            print(String(format: "  aligned:     mean abs diff %.3f  (%.1f%% of pixels)",
                         match.meanAbsoluteDifference, match.differingFraction * 100))
            print(String(format: "  offset ctrl: mean abs diff %.3f  (%.1f%% of pixels)",
                         offset.meanAbsoluteDifference, offset.differingFraction * 100))

            if liveDrift.meanAbsoluteDifference > 4.0 {
                geometry = "INCONCLUSIVE — the region was repainting during the take"
            } else if offset.meanAbsoluteDifference < 2.0 {
                geometry = "INCONCLUSIVE — the offset control matches too, so the region is featureless"
            } else if match.meanAbsoluteDifference < offset.meanAbsoluteDifference / 3 {
                geometry = "PASS — the frame is the requested region, not the offset one"
            } else {
                geometry = "FAIL — the frame does not favour the requested region"
                geometryPassed = false
            }
            print("  verdict:     \(geometry)")
        }

        // MARK: verdict

        var failures: [String] = []
        if videoTracks.isEmpty { failures.append("no video track") }
        if result.fileSize <= 0 { failures.append("empty file") }
        if assetDuration.seconds < seconds * 0.5 {
            failures.append(String(format: "duration %.2fs is far short of the requested %.2fs",
                                   assetDuration.seconds, seconds))
        }
        if !videoTracks.isEmpty, encodedSize != recording.pixelSize {
            failures.append("encoded \(Int(encodedSize.width))x\(Int(encodedSize.height)) px "
                + "≠ requested \(Int(recording.pixelSize.width))x\(Int(recording.pixelSize.height)) px")
        }
        if (audio || microphoneEffective) && audioTracks.isEmpty {
            failures.append("audio was requested but the file has no audio track")
        }
        // Both sources present means exactly ONE track, not two.
        //
        // `SCRecordingOutputConfiguration.mixesAudioWithMicrophone` decides
        // this, and the engine pins it to true rather than trusting the default.
        // Two tracks would look fine here and be wrong in the world: many
        // players choose one audio track instead of summing them, so a viewer
        // would get the system audio and no narration, or the reverse.
        //
        // Only checkable when the microphone is genuinely on, which needs the
        // grant, which needs a LaunchServices launch — so a shell run reports
        // rather than asserts instead of pretending to have tested it.
        if audio && microphoneEffective {
            if audioTracks.count != 1 {
                failures.append("system audio + microphone produced \(audioTracks.count) "
                    + "audio tracks; mixesAudioWithMicrophone should give exactly 1")
            }
        } else if audio || microphoneEffective {
            print("mixing:        not asserted — only one source was active "
                + "(system=\(audio) microphone=\(microphoneEffective))")
        }
        // Only asserted for the microphone. System audio is legitimately silent
        // when nothing is playing, so a silent track proves nothing there.
        //
        // And even for the microphone the assertion has to be qualified against
        // the device itself: measured 2026-07-31, the default input was a
        // wireless receiver with no transmitter powered on, which presents as a
        // healthy 48 kHz stereo device and sends nothing but zeros. Blaming SCK
        // for that would be blaming the wrong layer, so the control decides
        // between FAIL and INCONCLUSIVE.
        if microphoneEffective && audioIsSilent {
            let device = await inputDeviceLevels(seconds: 1)
            if device.rms < 0.00003 {
                print("  microphone:  INCONCLUSIVE — \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "the input device")"
                    + " is itself sending digital silence (rms \(String(format: "%.5f", device.rms)))")
            } else {
                failures.append(
                    "the input device has signal but the recorded microphone track is silence")
            }
        }
        if !geometryPassed { failures.append("geometry") }

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — " + failures.joined(separator: "; "))")
        return failures.isEmpty ? 0 : 1
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
