import AVKit
import AppKit
import Carbon.HIToolbox
import Darwin
import Linkdrop
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
        /// The in-app viewer: window geometry for a still, a full-screen still
        /// and a recording, plus the one-window-per-file rule.
        case viewer(directory: URL)
        /// The image editor, image in and image out: the point-to-pixel mapping
        /// at 2×, whether the bytes under a rectangle are really gone, and whether
        /// the list that ⌘Z walks backwards renders what it says it does.
        case edit(directory: URL)
        /// Trimming a recording: whether the export, the swap and the reload
        /// leave one shorter file where the long one was.
        case trim(directory: URL)
        /// Window-picker hit-testing, filtering and window capture geometry.
        case windowMode(directory: URL)
        /// Fullscreen capture with `includeMenuBar` both ways.
        case fullscreen(directory: URL)
        /// Settings persistence, key-combo encoding and the system-shortcut probe.
        case preferences
        /// Pure geometry of the armed selection's grab zones. Headless: no screen,
        /// no capture, so it runs where the interactive tests cannot.
        case selectionZones
        /// Where the size readout lands, and that the loupe never covers it.
        /// Geometry headless, then the same question asked of a live drag.
        case badgePlacement
        /// Pointer position -> pixel in a backdrop frame, including the offsets a
        /// second display introduces. Headless, and the only way to test them on
        /// a one-screen machine.
        case pixelMapping
        /// A cancelled task polling `SCKLatch.wait` must give up promptly, not
        /// spin at full speed until the deadline. Headless.
        case latchCancel
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
        case overlaySharing
        case previewInRecording(directory: URL, seconds: Double, excludes: Bool)
        case hudAppearance(directory: URL)
        /// The lit border, photographed and measured over black and over white.
        case regionOutline(directory: URL)
        /// Whether the loupe magnifies the pixels it says it does.
        case loupe(directory: URL)
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
        /// The app-level share paths, against the real bucket.
        case shareFlow
        /// Keychain round trip, both synchronizable and not.
        case shareCredentials
        /// Photographs a preview card in each of the three share states.
        case shareCard(directory: URL)
        /// ⌘V in a text field, which an LSUIElement app does not get for free.
        case editMenu
        /// On-device OCR: whether Vision reads a drawn page back as its words,
        /// in order, onto the clipboard.
        case copyText(directory: URL)
        case sensitiveText(directory: URL)
        case gif(directory: URL)
        case history(directory: URL)
        /// The share pipeline against a local `wrangler dev`. Endpoint and token
        /// are arguments, never Settings: a test that read the live
        /// configuration would upload to the real bucket.
        case share(endpoint: String?, token: String?, file: URL?, bigMegabytes: Int?)
        /// What is really inside a recording, which its settings cannot tell you.
        case shareCompat(URL)
        case recordHUD(
            directory: URL, seconds: Double, sharingNone: Bool, hudFirst: Bool,
            plainWindow: Bool, statusItem: Bool, excludeIDs: Bool)
        /// The scrolling-capture stitcher, headless: synthetic frames cut from a
        /// source whose every row is unique, so a mis-measured shift cannot
        /// produce the right pixels. `broken` is the negative control — it
        /// sabotages the shift search and the run must FAIL.
        case scrollStitch(directory: URL, broken: Bool)
        /// The whole session against the live screen: a real window whose
        /// content is scrolled programmatically while the real coordinator
        /// loop captures and stitches it, ended through the ⌘⇧L toggle.
        case scrollFlow(directory: URL)

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
            case "--selftest-share-flow":
                self = .shareFlow
            case "--selftest-share-credentials":
                self = .shareCredentials
            case "--selftest-share-card":
                self = .shareCard(directory: URL(fileURLWithPath: positional() ?? "build/share-ui"))
            case "--selftest-edit-menu":
                self = .editMenu
            case "--selftest-copy-text":
                self = .copyText(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-sensitive":
                self = .sensitiveText(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-gif":
                self = .gif(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-history":
                self = .history(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-share":
                let configured = rest.contains("--configured")
                let endpoint = value(for: "--endpoint")
                let token = value(for: "--token")
                guard configured || (endpoint != nil && token != nil) else { return nil }
                self = .share(
                    endpoint: endpoint, token: token,
                    file: value(for: "--file").map { URL(fileURLWithPath: $0) },
                    bigMegabytes: value(for: "--big").flatMap(Int.init))
            case "--selftest-share-compat":
                guard let path = positional() else { return nil }
                self = .shareCompat(URL(fileURLWithPath: path))
            case "--selftest-preferences":
                self = .preferences
            case "--selftest-selection-zones":
                self = .selectionZones
            case "--selftest-badge-placement":
                self = .badgePlacement
            case "--selftest-pixel-mapping":
                self = .pixelMapping
            case "--selftest-latch-cancel":
                self = .latchCancel
            case "--selftest-hud-appearance":
                FloatingBarPanel.usesSharingTypeNone = false
                self = .hudAppearance(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-loupe":
                // The loupe lives in an overlay panel, which ships invisible to
                // ScreenCaptureKit; a capture of it would come back empty.
                OverlayPanel.usesSharingTypeNone = false
                self = .loupe(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-region-outline":
                // The border ships invisible to ScreenCaptureKit, so a capture of
                // it would come back showing the backdrop and nothing else.
                RecordingRegionOutlinePanel.usesSharingTypeNone = false
                self = .regionOutline(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-preview-in-recording":
                // `.readOnly`, or the card is invisible to ScreenCaptureKit
                // outright and the assertion below could never fail.
                PreviewPanel.usesSharingTypeNone = false
                self = .previewInRecording(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"),
                    seconds: value(for: "--seconds").flatMap(Double.init) ?? 3,
                    // The negative control. Without it a pass here could mean
                    // the exclusion works or that the card was never capturable.
                    excludes: !rest.contains("--no-exclude"))
            case "--selftest-overlay-sharing":
                self = .overlaySharing
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
                    statusItem: rest.contains("--status-item"),
                    // Puts the surface's window ID into the stream's exclusion
                    // list. Only meaningful with `--hud-first`: a window that
                    // does not exist when `SCContentFilter` is built cannot be
                    // named in it.
                    excludeIDs: rest.contains("--exclude-ids"))
            case "--selftest-scroll-stitch":
                self = .scrollStitch(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"),
                    broken: rest.contains("--broken"))
            case "--selftest-scroll-flow":
                self = .scrollFlow(
                    directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
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
            case "--selftest-edit":
                self = .edit(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-trim":
                self = .trim(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
            case "--selftest-viewer":
                self = .viewer(directory: URL(fileURLWithPath: positional() ?? "build/selftest-output"))
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
            case .viewer(let directory): return try await viewerWindow(into: directory)
            case .edit(let directory): return try await editCheck(into: directory)
            case .trim(let directory): return try await trimCheck(into: directory)
            case .windowMode(let directory): return try await windowMode(into: directory)
            case .fullscreen(let directory): return try await fullscreenMode(into: directory)
            case .preferences: return preferencesCheck()
            case .share(let endpoint, let token, let file, let big):
                return await ShareSelfTest.run(
                    endpoint: endpoint, token: token, file: file, bigMegabytes: big)
            case .shareCompat(let url): return await ShareSelfTest.compatibility(of: url)
            case .editMenu: return await editMenuCheck()
            case .copyText(let d): return try await copyTextCheck(into: d)
            case .sensitiveText(let d): return try await sensitiveTextCheck(into: d)
            case .gif(let d): return try await gifCheck(into: d)
            case .history(let d): return try await historyCheck(into: d)
            case .shareCard(let d): return try await shareCardStates(into: d)
            case .shareCredentials: return await ShareSelfTest.credentials()
            case .shareFlow: return await ShareFlowSelfTest.run()
            case .selectionZones: return selectionZonesCheck()
            case .badgePlacement: return try await badgePlacementCheck()
            case .pixelMapping: return pixelMappingCheck()
            case .latchCancel: return await latchCancelCheck()
            case .settingsWindow(let directory): return try await settingsWindow(into: directory)
            case .settingsResize: return try await settingsResize()
            case .lifecycle(let iterations): return try await lifecycle(iterations: iterations)
            case .selectionToolbar: return try await selectionToolbar()
            case .overlaySharing: return try await overlaySharing()
            case .previewInRecording(let d, let seconds, let excludes):
                return try await previewInRecording(into: d, seconds: seconds, excludes: excludes)
            case .hudAppearance(let d): return try await hudAppearance(into: d)
            case .regionOutline(let d): return try await regionOutline(into: d)
            case .loupe(let d): return try await loupe(into: d)
            case .soak(let iterations, let directory):
                return try await soak(iterations: iterations, into: directory)
            case .microphone: return await microphoneCheck()
            case .scrollStitch(let directory, let broken):
                return try await scrollStitchCheck(into: directory, broken: broken)
            case .scrollFlow(let directory):
                return try await scrollFlowCheck(into: directory)
            case .recordFlow(let directory, let seconds):
                return try await recordFlow(into: directory, seconds: seconds)
            case .recordHUD(let d, let seconds, let sharingNone, let hudFirst, let plain,
                            let status, let excludeIDs):
                return try await recordHUD(
                    into: d, seconds: seconds, sharingNone: sharingNone,
                    hudFirst: hudFirst, plainWindow: plain, statusItem: status,
                    excludeIDs: excludeIDs)
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

        // `isSamePicture`, not `identical`, for the reason `rectCheck` gives and
        // this one used to ignore: a window worth testing with is a large one,
        // and a large one has translucent chrome that recomposites its backdrop
        // from a different area in the two capture paths. Measured here against
        // Mail on 2026-08-02, the correct reading came back 0.08% different with
        // a worst channel of 3 — invisible, and rejected by a bit-exact rule, so
        // the check reported INCONCLUSIVE every run and blamed a moving screen
        // for it. The wrong reading in the same run differed on 65% of pixels
        // with a worst channel of 255. Aggregate mean separates them by three
        // orders of magnitude; the single worst pixel separates nothing.
        var matched: [(name: String, exact: Bool)] = []
        for reading in readings {
            let output = try await captureRegion(
                filter: filter, sourceRect: reading.rect, scale: scale, writeTo: nil)
            guard let image = output.image else { continue }
            let comparison = PixelCompare.compare(image, expected)
            print("  \(reading.name.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + "\(rectString(reading.rect)) -> \(image.width)x\(image.height) px, \(comparison.summary)")
            if comparison.isSamePicture {
                matched.append((reading.name, comparison.identical))
            }
        }

        switch matched.count {
        case 1 where matched[0].name.hasPrefix("local"):
            print("""
                verdict:       sourceRect is FILTER-LOCAL — measured from the contentRect
                               origin, which is (0,0) regardless of where contentRect sits in
                               global space. DisplayGeometry.displayLocal() is correct.
                result:        PASS (FILTER-LOCAL\(matched[0].exact ? "" : ", within tolerance"))
                """)
            return 0
        case 1:
            print("""
                verdict:       sourceRect matched the \(matched[0].name) reading. DisplayGeometry
                               .displayLocal() must NOT subtract the display origin.
                """)
            return 1
        case 2:
            // Both readings qualifying means the window was too uniform to tell
            // them apart — a blank page, a solid backdrop — not that both are
            // right. Nothing was discriminated, so nothing may be concluded.
            print("""
                verdict:       INCONCLUSIVE — both readings reproduced the crop, so this window
                               cannot discriminate between them. Re-run over a window with
                               detail in its top-left quarter.
                """)
            return 0
        default:
            // Exit 0, like every other INCONCLUSIVE in this file.
            //
            // The rule: a non-zero exit means "the thing under test is broken".
            // "The screen moved so nothing could be measured" is not that, and
            // reporting it as failure trains people to ignore a red suite —
            // which is how a real failure gets waved past. This one used to
            // return 1 while `--selftest-rect` and `--selftest-record-hud`
            // returned 0 for the same situation, so `make test` was red whenever
            // a live window happened to be the largest one on screen.
            //
            // Silence is the other danger, so `make test` counts these and says
            // how many there were: green with three inconclusive results is a
            // different report from green.
            print("""
                verdict:       INCONCLUSIVE — neither reading reproduced the crop. Most likely
                               the window repainted between the two captures; re-run against a
                               static window before drawing any conclusion.
                """)
            return 0
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
                windows: coordinator.engine.shareableContent.windows)
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

        // The mid-drag frame, photographed after every assertion above has taken
        // its captures. It is the only frame that draws the crosshair — the guide
        // lines moved from idle to button-down, and are clipped to outside the
        // selection so they cannot run across the region being selected. "Clipped
        // to nothing" and "clipped correctly" are the same answer from the model,
        // so this is a picture or it is not checked at all.
        OverlayView.drawsDebugSelectionBorder = false
        coordinator.overlay.forceDragForTest(
            from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), on: screen)
        try await Task.sleep(for: .milliseconds(200))
        let midDrag = try? await coordinator.engine.capture(.display(displayID))
        // The panel state goes next to the path on purpose: a mid-drag photo with
        // nothing in it means either the drawing is wrong or the overlay had
        // already gone (an Escape from whoever is at the keyboard does it), and
        // the picture alone cannot tell those apart.
        print("mid-drag:      \(coordinator.overlay.debugPanelState)")
        if let midDrag, let output {
            let url = output.deletingPathExtension().appendingPathExtension("middrag.png")
            try? ImageEncoder.write(midDrag.image, to: url, as: .png, scale: midDrag.scale)
            print("mid-drag png:  \(url.path)")
        }

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

    /// Proves ⌘V reaches a text field.
    ///
    /// Not a test of `NSTextField` — a test of the *routing*. With no main menu
    /// installed, `NSApplication` has nothing to turn ⌘V into `paste:`, so the
    /// field never hears about it. That is invisible in every screenshot of the
    /// Settings window and shows up only when somebody tries to paste a token.
    ///
    /// Runs the real key-equivalent path (`NSMenu.performKeyEquivalent`) rather
    /// than calling `paste:` directly, because calling `paste:` works fine with
    /// no menu at all and would pass against the broken build.
    ///
    /// INCONCLUSIVE when the app could not become (or stay) active: activation
    /// is cooperative and the system refuses it while the user is working in
    /// another app, and without it there is no key window for the paste to land
    /// in — nothing under test was exercised, broken or not.
    private static func editMenuCheck() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        EditMenu.install()
        check("main menu installed", NSApp.mainMenu != nil)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 300, height: 24))
        window.contentView?.addSubview(field)

        // The app has to be *active*, not merely have a window ordered in. A
        // text field's editing session runs in the window's shared field editor,
        // and that editor is only installed for a key window -- so in an
        // unactivated accessory app `makeFirstResponder` returns true and yet
        // there is nothing to paste into. This cost a wrong diagnosis: the first
        // run of this check blamed the menu for a paste that never had anywhere
        // to land.
        //
        // And activation is only a request. `activate()` is cooperative, and
        // while the user is working in another app the system is free to say
        // no -- which is the same wrong diagnosis one layer up: the check would
        // blame the menu for a paste that had nowhere to land. So insist on
        // being active *and* key before asserting anything, and give up as
        // INCONCLUSIVE rather than FAIL if the machine is in use.
        //
        // Observed on 26.6: the request is granted when the frontmost app is an
        // ancestor of this process (the terminal `make test` was typed into),
        // and refused -- indefinitely, not just while input is arriving -- when
        // an unrelated app holds frontmost. So the usual run from a terminal
        // still asserts everything, and only running it from *behind* some
        // other app downgrades.
        for _ in 0..<30 where !(NSApp.isActive && window.isKeyWindow) {
            NSApp.activate()
            // Inside the loop: a makeKey issued while the app was still
            // inactive does not take effect retroactively when activation is
            // finally granted.
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard NSApp.isActive, window.isKeyWindow else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName
            print("""
                result:        INCONCLUSIVE — activation was refused (\(front ?? "another app") \
                stayed frontmost;
                               active=\(NSApp.isActive) key=\(window.isKeyWindow)), so there is no \
                key window for the
                               paste to land in and the routing was never exercised. Re-run
                               without touching the machine.
                """)
            window.orderOut(nil)
            return 0
        }
        try? await Task.sleep(for: .milliseconds(200))
        check("field became first responder", window.makeFirstResponder(field))
        check("field editor exists", field.currentEditor() != nil)

        let secret = "pasted-\(UUID().uuidString.prefix(8))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)

        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
        else {
            print("result:        FAIL — could not synthesise the event")
            return 1
        }

        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        check("menu claimed the key equivalent", handled)

        // Read the field *editor*, not the field. While a text field is being
        // edited its `stringValue` still holds the value from before the session
        // started -- the live text lives in the shared field editor and is only
        // written back when editing ends. The first version of this check read
        // `stringValue`, saw "", and blamed the menu for a paste that had in fact
        // worked.
        let live = field.currentEditor()?.string ?? field.stringValue
        check("text arrived in the field", live == secret, "field=\"\(live)\"")

        // And once editing ends it must be in the field itself, which is what
        // every binding and every read in the Settings window actually uses.
        window.endEditing(for: field)
        check("text survived end of editing", field.stringValue == secret,
              "field=\"\(field.stringValue)\"")

        // Activation can also be *lost* mid-run: the reproduced failure had the
        // field editor installed and the menu claiming ⌘V, and the paste still
        // landed nowhere because the user's app had taken key back in between.
        // A failure while we are no longer active+key says nothing about the
        // menu, so it is downgraded, not reported. Read the key status before
        // orderOut, which would clear it.
        let disturbed = !(NSApp.isActive && window.isKeyWindow)
        window.orderOut(nil)
        if failures > 0 && disturbed {
            print("""
                result:        INCONCLUSIVE — activation was lost while the check ran, so the
                               failures above only say the machine was in use. Re-run without
                               touching it.
                """)
            return 0
        }
        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Copy Text

    /// Whether Vision reads a picture of words back as those words, and whether
    /// the two menus that ask it to are there to be clicked.
    ///
    /// Headless and offline by construction: the picture is drawn here rather
    /// than captured, so this asserts the same thing on a locked screen as on a
    /// busy one, and the recognition never leaves the machine.
    ///
    /// The ordering assertion is the one worth having. Vision returns
    /// observations in an order it does not promise to be geometric, and a
    /// transcript with its paragraphs shuffled looks perfectly plausible — there
    /// is nothing in the pasted text to say it came out wrong.
    /// `--selftest-sensitive`
    ///
    /// Two layers, because they fail for entirely different reasons and lumping
    /// them together would mean never knowing which one did.
    ///
    /// The patterns are pure — a string in, ranges out — so they get an exact
    /// table, and half of that table is things that must **not** match. That
    /// half is the important one. A detector that flags everything scores
    /// perfectly on positives and is worse than useless: it silently destroys
    /// pixels the user wanted, in the one feature whose promise is that the
    /// destruction cannot be undone once the window closes.
    ///
    /// The end-to-end layer can only be as good as OCR was that day, so it
    /// reports INCONCLUSIVE when Vision cannot read its own fixture rather than
    /// blaming the detector for it.
    private static func sensitiveTextCheck(into directory: URL) async throws -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // MARK: the patterns, exactly

        let table: [(line: String, expected: [SensitiveText.Kind])] = [
            ("write to bobby.li+dev@example.co.uk about it", [.email]),
            ("the box answers on 192.168.1.14 today", [.ipAddress]),
            ("OPENAI_API_KEY=sk-abcdefghijklmnop0123456789", [.secret]),
            ("token ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5", [.secret]),
            ("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", [.secret]),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345", [.secret]),
            ("cookie eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP", [.secret]),
            ("call me on 13800138000 tonight", [.phone]),
            ("ring +44 20 7946 0958 instead", [.phone]),
            ("card 4111 1111 1111 1111 expires soon", [.card]),
            // Two different things on one line, neither swallowing the other.
            ("4012888888881881 receipts to ops@acme.io", [.card, .email]),

            // The half that matters. Every one of these is a shape that a
            // careless pattern takes and a careful one leaves alone.
            ("order 48213 shipped on tuesday", []),
            // One digit off a real card: same length, same prefix, fails Luhn.
            ("card 4111 1111 1111 1112 declined", []),
            ("upgraded to version 1.2.3 this morning", []),
            ("999.1.1.1 is not an address", []),
            ("commit a3f9c2b1d4e5f6a7b8c9d0e1f2a3b4c5 landed", []),
            ("the meeting is at 2024 10 21 09 30", []),
            ("sk-short", []),
        ]
        for row in table {
            let kinds = SensitiveText.matches(in: row.line).map(\.kind)
            let wanted = row.expected
            check(row.expected.isEmpty
                    ? "leaves alone: \(row.line)"
                    : "finds \(wanted.map(\.rawValue).joined(separator: "+")): \(row.line)",
                  Set(kinds) == Set(wanted) && kinds.count == wanted.count,
                  kinds.isEmpty ? "nothing" : kinds.map(\.rawValue).joined(separator: ","))
        }

        // Luhn on its own, since it is the whole reason the card pattern is not
        // "any sixteen digits".
        check("Luhn accepts a real number", SensitiveText.isCard("4111111111111111"))
        check("and rejects one digit off", !SensitiveText.isCard("4111111111111112"))
        check("and rejects a short run", !SensitiveText.isCard("41111111"))

        // MARK: through Vision, onto the pixels

        let secrets = ["Email bobby@example.com", "Host 192.168.1.14", "Card 4111 1111 1111 1111"]
        let sample = directory.appendingPathComponent("sensitive-sample.png")
        try ImageEncoder.write(wordsImage(secrets), to: sample)

        // Read back from the file, and take the point size from what is
        // actually there rather than from what `wordsImage` was asked for.
        // `lockFocus` renders at the display's backing scale, so the 900×500 it
        // is handed arrives on disk as 1800×1000 — and a point size of 900×500
        // against an 1800×1000 bitmap puts the findings and the pixels being
        // checked in two different coordinate spaces. The first draft of this
        // check did exactly that and reported every changed pixel as being
        // outside a finding.
        guard let source = CGImageSourceCreateWithURL(sample as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("result:        INCONCLUSIVE — the fixture could not be read back")
            return 0
        }
        // The fixture is written at 72 dpi, so a point here is a pixel and the
        // rectangles below need no scaling to be compared against the bitmap.
        let points = CGSize(width: original.width, height: original.height)
        let findings = await SensitiveText.findings(inFileAt: sample, pointSize: points)
        print("found:         "
            + (findings.isEmpty
                ? "nothing"
                : findings.map { "\($0.kind.rawValue)\(rectString($0.rect))" }
                    .joined(separator: " ")))
        guard !findings.isEmpty else {
            print("""
                result:        INCONCLUSIVE — Vision read nothing out of the fixture, so the \
                image half asserted nothing. The pattern checks above still stand.
                """)
            return failures == 0 ? 0 : 1
        }

        check("every kind planted in the picture came back",
              Set(findings.map(\.kind)) == Set([.email, .ipAddress, .card]),
              Set(findings.map(\.kind)).map(\.rawValue).sorted().joined(separator: ","))

        // The rectangles have to land on the ink, not merely exist. Redacting
        // them must change the pixels *inside* them and leave the rest of the
        // picture alone — a finding whose rect is off by a line would pass a
        // "something changed" check while covering the wrong words.
        let edits = findings.map { ImageEdit.redact($0.rect) }
        guard let redacted = ImageEdit.render(
            original, edits: edits, pointSize: points, cropping: false) else {
            check("the findings redact", false, "render returned nothing")
            return failures == 0 ? 0 : 1
        }
        let before = rgba(of: original)
        let after = rgba(of: redacted)
        var changedInside = 0
        var changedOutside = 0
        // One mosaic block of slack around each finding. `Redaction` averages on
        // a grid anchored to the image, so a block straddling a region's edge is
        // pixelated in full — pixels just outside the rectangle are meant to
        // change. The slack is one block and no more, so a finding sitting on
        // the wrong line of text is still caught by the check below.
        let slack = Redaction.blockSize(width: original.width, height: original.height)
        var inside = Set<Int>()
        for finding in findings {
            // Bitmap rows run from the top; findings are in bottom-left space.
            let top = max(0, original.height - Int(finding.rect.maxY) - slack)
            let bottom = min(original.height, original.height - Int(finding.rect.minY) + slack)
            let left = max(0, Int(finding.rect.minX) - slack)
            let right = min(original.width, Int(finding.rect.maxX) + slack)
            guard top < bottom, left < right else { continue }
            for row in top..<bottom {
                for column in left..<right {
                    inside.insert(row * original.width + column)
                }
            }
        }
        for pixel in 0..<(original.width * original.height)
        where before[pixel * 4] != after[pixel * 4]
            || before[pixel * 4 + 1] != after[pixel * 4 + 1]
            || before[pixel * 4 + 2] != after[pixel * 4 + 2] {
            if inside.contains(pixel) { changedInside += 1 } else { changedOutside += 1 }
        }
        check("the words under a finding are destroyed", changedInside > 500,
              "\(changedInside) pixels changed inside \(findings.count) findings")
        check("and nothing outside one is touched", changedOutside == 0,
              "\(changedOutside) pixels changed outside")

        // The two checks above are self-consistent and cannot catch the failure
        // that matters: they redact at rect R and then look for change inside
        // rect R, so a finding covering the wrong words passes both. The only
        // question worth asking is whether the secret is still readable, so ask
        // the same machine that read it in the first place.
        let scrubbed = directory.appendingPathComponent("sensitive-redacted.png")
        try ImageEncoder.write(redacted, to: scrubbed, scale: 1)
        let reread = await TextRecognition.text(inFileAt: scrubbed) ?? ""
        print("re-read:       \(reread.replacingOccurrences(of: "\n", with: " / "))")
        for secret in ["bobby@example.com", "192.168.1.14", "4111"] {
            check("\"\(secret)\" cannot be read back out", !reread.contains(secret))
        }
        // ...and the control that gives those their meaning. If OCR simply
        // failed on the redacted image, every check above would pass while
        // proving nothing. The labels sit on the same lines as the values that
        // were destroyed, so their survival says the reader still works.
        let labels = ["Email", "Host", "Card"].filter { reread.contains($0) }
        check("while the words beside them still are", labels.count >= 2,
              "\(labels.count) of 3 labels survived: \(labels.joined(separator: ","))")

        // MARK: through the menu item, which is the only way a user reaches it
        //
        // Fired through its own target and action rather than by calling
        // `redactSensitive()`. `NSMenuItem.action(_:handler:)` hangs the closure
        // off a separate `MenuAction` object because the item's target is weak,
        // and an item whose target has been released is silently *disabled* by
        // AppKit rather than broken-looking — so "the row exists" and "the row
        // does something" are genuinely different claims.
        //
        // `perform` is safe here for the reason CLAUDE.md's warning implies:
        // `MenuAction.fire` is @objc on an NSObject. It is the non-@objc case
        // that crashes.
        let viewer = ViewerWindowController.shared
        viewer.activatesOnShow = false
        defer { viewer.closeAll() }
        viewer.show(PreviewEntry(
            kind: .image(pointSize: points),
            thumbnail: NSImage(size: PreviewCardView.cardSize),
            url: sample, sourceDisplayID: CGMainDisplayID()))
        for _ in 0..<40 where viewer.windowForTest(sample) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let editor = viewer.windowForTest(sample)?.contentView as? ImageEditor,
              let item = viewer.windowForTest(sample)?.contentView?.menu?.items
                .first(where: { $0.title == "Redact Sensitive Text" }),
              let target = item.target, let selector = item.action else {
            check("the menu item is wired to a live target", false, "no item, target or editor")
            print("result:        FAIL (\(failures))")
            return 1
        }
        check("the menu item is wired to a live target", true)
        check("nothing is redacted before it is pressed", editor.editsForTest.isEmpty,
              "\(editor.editsForTest.count) edits")
        target.perform(selector)
        // Vision again, on the main path this time, so poll rather than sleep.
        for _ in 0..<150 where editor.editsForTest.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let placed = editor.editsForTest
        check("pressing it puts redactions on the picture", placed.count == findings.count,
              "\(placed.count) edits for \(findings.count) findings")
        check("and every one of them is a redaction",
              !placed.isEmpty && placed.allSatisfy { if case .redact = $0 { true } else { false } },
              placed.map { "\($0)".prefix(8) }.joined(separator: ","))
        // One entry each, so a scan that got one wrong is one ⌘Z from being
        // right rather than all-or-nothing. This is the property that makes a
        // detector which is usually right safe to ship.
        editor.undoForTest()
        check("and ⌘Z takes them back one at a time",
              editor.editsForTest.count == placed.count - 1,
              "\(placed.count) -> \(editor.editsForTest.count)")

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// A clip whose colour says what second it is: solid red for the first,
    /// green for the second, blue for the third.
    ///
    /// Synthesised rather than recorded, unlike `--selftest-trim`'s fixture. A
    /// GIF's whole job is to play the right frames in the right order at the
    /// right speed, and a recording of whatever happened to be on screen cannot
    /// answer any of those three. This can: frame 5 must be red, frame 15 green,
    /// frame 25 blue, and no amount of arithmetic error survives that.
    private static func colourClip(
        to url: URL, seconds: Int, size: CGSize
    ) async throws -> [(second: Int, colour: (r: UInt8, g: UInt8, b: UInt8))] {
        try? FileManager.default.removeItem(at: url)
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (230, 30, 30), (30, 200, 60), (40, 70, 235),
            (240, 200, 20), (200, 40, 200), (30, 210, 210),
        ]
        let width = Int(size.width)
        let height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        for frame in 0..<(seconds * fps) {
            let colour = palette[(frame / fps) % palette.count]
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<height {
                    for column in 0..<width {
                        let i = row * rowBytes + column * 4
                        bytes[i] = colour.b
                        bytes[i + 1] = colour.g
                        bytes[i + 2] = colour.r
                        bytes[i + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return (0..<seconds).map { ($0, palette[$0 % palette.count]) }
    }

    /// `--selftest-history`
    ///
    /// Same split as `--selftest-sensitive`, for the same reason. Search is
    /// exactly answerable when it is handed text; it is only as answerable as
    /// OCR when it is handed a picture. The index gets its own file under the
    /// test's directory rather than the real one in Application Support -- a
    /// self-test that wrote into the user's actual history would be a strange
    /// thing to run twice.
    private static func historyCheck(into directory: URL) async throws -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let store = directory.appendingPathComponent("history-index.json")
        try? FileManager.default.removeItem(at: store)
        let index = CaptureIndex(location: store)

        // Real files, because `forgetMissingFiles` is part of what is under
        // test and it asks the filesystem.
        func plant(_ name: String, _ text: String, _ ago: TimeInterval) async -> URL {
            let url = directory.appendingPathComponent(name)
            try? Data("x".utf8).write(to: url)
            await index.record(url, text: text, capturedAt: Date(timeIntervalSinceNow: -ago))
            return url
        }

        _ = await plant(
            "old.png", "Fatal error\nNullPointerException in AuthService\nline 42", 300)
        let invoice = await plant(
            "mid.png", "INVOICE\nAcme Corporation\nService charge\nTotal due £480.00", 200)
        _ = await plant(
            "new.png", "会议纪要\n下周三发布新版本\n负责人：李波", 100)

        // MARK: finding things

        func names(_ query: String) async -> [String] {
            await index.search(query).map(\.name)
        }
        check("finds a word from the middle of a capture",
              await names("NullPointer") == ["old.png"])
        check("is case-insensitive", await names("nullpointerexception") == ["old.png"])
        check("matches inside a word, so Chinese works at all",
              await names("发布新版本") == ["new.png"])
        check("finds by filename too", await names("invoice") == ["mid.png"])
        // AND rather than OR. The second word someone types is there to narrow
        // the answer; if it widened it, adding detail would make things worse.
        check("two words must both appear",
              await names("acme total") == ["mid.png"])
        check("and a word that appears in neither finds nothing",
              await names("acme kubernetes").isEmpty)
        check("no query lists everything, newest first",
              await names("") == ["new.png", "mid.png", "old.png"])
        // "service" is in both old.png (AuthService) and mid.png (Service
        // charge); mid.png is the newer of the two and has to come first.
        check("two matches come back newest first",
              await names("service") == ["mid.png", "old.png"],
              "\(await names("service"))")

        // The snippet is what makes a row answerable at a glance, so it has to
        // be the line that matched rather than the first line of the capture.
        let hit = await index.search("NullPointer").first
        check("the row shows the line that matched",
              hit?.snippet == "NullPointerException in AuthService",
              hit?.snippet ?? "none")

        // MARK: surviving a relaunch

        let reopened = CaptureIndex(location: store)
        check("the index is still there after a restart",
              await reopened.search("NullPointer").map(\.name) == ["old.png"])
        check("and knows how much it holds", await reopened.count == 3,
              "\(await reopened.count)")

        // MARK: forgetting

        try? FileManager.default.removeItem(at: invoice)
        let dropped = await reopened.forgetMissingFiles()
        check("a deleted capture drops out of the index", dropped == 1,
              "\(dropped) dropped")
        // Asked of `reopened`, not of `index`. Two instances over one file each
        // hold their own copy of it and will disagree the moment either writes;
        // the app has exactly one, and the second here exists only to prove the
        // file survives a relaunch. Asking the stale one was this check's first
        // draft, and it failed for that reason rather than a real one.
        check("and stops being findable",
              await reopened.search("acme").isEmpty,
              "\(await reopened.search("acme").map(\.name))")

        // MARK: through Vision

        let shot = directory.appendingPathComponent("history-ocr.png")
        try ImageEncoder.write(wordsImage(["Kubernetes", "pod evicted"]), to: shot)

        // Whether this half can run is decided by OCR alone, asked directly.
        // Deciding it from the search result instead conflates "Vision read
        // nothing" with "search is broken" -- and the negative control for the
        // checks above breaks search, so it printed INCONCLUSIVE while failing.
        // A test that changes its own verdict when the code under test breaks is
        // worth nothing.
        guard let readable = await TextRecognition.text(inFileAt: shot),
              readable.localizedCaseInsensitiveContains("kubernetes") else {
            print("""
                result:        INCONCLUSIVE — Vision could not read the fixture, so only the \
                search half was exercised. Those checks still stand.
                """)
            return failures == 0 ? 0 : 1
        }
        await index.index(shot, capturedAt: .now)
        let read = await index.search("kubernetes").map(\.name)
        check("a real capture is indexed by what Vision read in it",
              read == ["history-ocr.png"], "\(read)")
        // Indexing is skipped for a file already known, so re-running over a
        // folder costs nothing. Without this, every launch would re-OCR
        // everything.
        let countBefore = await index.count
        await index.index(shot, capturedAt: .now)
        check("indexing the same file twice does not add a second row",
              await index.count == countBefore, "\(countBefore) -> \(await index.count)")

        // MARK: the way in
        //
        // Everything above is reachable only if something opens it.
        //
        // The menu bar row is asserted in `--selftest-share-flow` rather than
        // here. Building the status menu reads the share settings, which reads
        // the Keychain, which in a run with no credentials set up blocks on a
        // prompt nobody is there to answer -- measured: this check hung for the
        // full ten minutes and printed nothing.
        let search = CaptureSearchWindowController.shared
        search.activatesOnShow = false
        defer { search.close() }
        check("the window is not open to begin with", !search.isOpen)
        search.show()
        check("and opening it puts one on screen", search.isOpen)

        // The field's binding, driven through the model rather than by typing
        // into it. Setting `query` is exactly what SwiftUI's `TextField` does to
        // this object, and the `didSet` that turns it into a search is this
        // project's code; the `TextField`-to-binding half is Apple's and not
        // mine to prove. Synthesizing keystrokes into it would also mean
        // delivering events to an NSTextView, which CLAUDE.md records as hanging
        // the run for ten minutes.
        let model = CaptureSearchModel(index: index)
        model.query = "NullPointer"
        for _ in 0..<40 where model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        check("typing in the field narrows the list",
              model.hits.count == 1 && model.hits.first?.name == "old.png",
              "\(model.hits.map(\.name))")
        model.query = "kubernetes NullPointer"
        for _ in 0..<40 where !model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        check("and a second word that narrows it to nothing empties it",
              model.hits.isEmpty, "\(model.hits.map(\.name))")

        search.close()
        // Closing has to be observed, or the next open would find a stale window
        // and hand back one that is no longer on screen.
        for _ in 0..<20 where search.isOpen {
            try await Task.sleep(for: .milliseconds(50))
        }
        check("closing it lets go of the window", !search.isOpen)

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// `--selftest-gif`
    private static func gifCheck(into directory: URL) async throws -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // Deliberately larger than `maximumEdge` in both directions, so the cap
        // is exercised rather than assumed.
        let clip = directory.appendingPathComponent("gif-source.mp4")
        let seconds = 3
        let expected = try await colourClip(
            to: clip, seconds: seconds, size: CGSize(width: 1600, height: 900))
        guard FileManager.default.fileExists(atPath: clip.path) else {
            print("result:        INCONCLUSIVE — the fixture clip could not be written")
            return 0
        }

        let destination = GIFExport.url(besides: clip)
        try? FileManager.default.removeItem(at: destination)
        let outcome = try await GIFExport.write(clip, to: destination)
        print("wrote:         \(outcome.url.lastPathComponent) "
            + String(format: "%d frames, %.0f×%.0f, %.1fs, %d bytes",
                     outcome.frames, outcome.pixelSize.width, outcome.pixelSize.height,
                     outcome.seconds, fileSize(outcome.url)))

        check("it goes beside the recording, not over it",
              destination != clip && FileManager.default.fileExists(atPath: clip.path))

        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            check("the file is readable as an image", false, "no source")
            print("result:        FAIL (\(failures + 1))")
            return 1
        }
        check("it is a GIF",
              (CGImageSourceGetType(source) as String?) == UTType.gif.identifier,
              (CGImageSourceGetType(source) as String?) ?? "no type")

        let count = CGImageSourceGetCount(source)
        check("one frame per tenth of a second",
              count == seconds * Int(GIFExport.frameRate),
              "\(count) frames for \(seconds)s at \(Int(GIFExport.frameRate))fps")

        // Capped, and not stretched to fill the cap: 1600×900 must come back at
        // 16:9 with its long edge at 720, rather than 720×720 or 1600×900.
        //
        // Not asserted as exactly 720×405. The generator rounds to even pixel
        // dimensions -- 405 is odd, so it lands on 404 -- and that is
        // AVFoundation's business rather than a property of this feature. The
        // ratio is the invariant; a pixel of rounding is not.
        let ratio = outcome.pixelSize.width / max(outcome.pixelSize.height, 1)
        check("the longest edge is capped without stretching",
              max(outcome.pixelSize.width, outcome.pixelSize.height) <= GIFExport.maximumEdge
                && max(outcome.pixelSize.width, outcome.pixelSize.height) > 700
                && abs(ratio - 16.0 / 9) < 0.02,
              String(format: "%.0f×%.0f, ratio %.3f vs %.3f",
                     outcome.pixelSize.width, outcome.pixelSize.height, ratio, 16.0 / 9))

        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifProperties = fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        check("it loops forever",
              (gifProperties?[kCGImagePropertyGIFLoopCount] as? Int) == 0,
              "loopCount=\(gifProperties?[kCGImagePropertyGIFLoopCount].map { "\($0)" } ?? "none")")

        let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let frameGIF = frameProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        // The delay browsers will not silently round up. 0.083 would have been
        // written as 0.1 by every viewer and the clip would run long.
        check("each frame waits a tenth of a second",
              delay.map { abs($0 - 0.1) < 0.001 } ?? false,
              delay.map { String(format: "%.3fs", $0) } ?? "none")

        // MARK: the frames are the right frames, in the right order
        //
        // Everything above is satisfied by a GIF of thirty identical frames.
        // This is not: the fixture's colour says which second it came from, so
        // sampling the middle of each second proves both the sampling times and
        // the ordering.
        var wrong: [String] = []
        for (second, colour) in expected {
            let index = second * Int(GIFExport.frameRate) + Int(GIFExport.frameRate) / 2
            guard index < count,
                  let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                wrong.append("frame \(index) missing")
                continue
            }
            let bytes = rgba(of: frame)
            let middle = ((frame.height / 2) * frame.width + frame.width / 2) * 4
            let got = (r: Int(bytes[middle]), g: Int(bytes[middle + 1]), b: Int(bytes[middle + 2]))
            // Generous: h264 is lossy and a GIF is quantised to 256 colours, so
            // the question is which of six well-separated colours this is, not
            // whether the channel survived exactly.
            let near = abs(got.r - Int(colour.r)) < 40
                && abs(got.g - Int(colour.g)) < 40
                && abs(got.b - Int(colour.b)) < 40
            if !near {
                wrong.append("second \(second): wanted \(colour.r),\(colour.g),\(colour.b) "
                    + "got \(got.r),\(got.g),\(got.b)")
            }
        }
        check("every second of the clip lands on the right frame", wrong.isEmpty,
              wrong.joined(separator: "; "))

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    private static func copyTextCheck(into directory: URL) async throws -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let lines = ["Refund issued", "Order 48213", "Thank you"]
        let sample = directory.appendingPathComponent("copy-text-sample.png")
        try ImageEncoder.write(wordsImage(lines), to: sample)

        let recognised = await TextRecognition.text(inFileAt: sample) ?? ""
        print("recognised:    \(recognised.replacingOccurrences(of: "\n", with: " / "))")
        for line in lines {
            check("read \"\(line)\"", recognised.contains(line))
        }
        // Positions rather than equality: language correction is free to alter
        // spacing or a character, and a test that demanded the exact string
        // would fail on a future Vision revision that read it *better*.
        let positions = lines.compactMap { recognised.range(of: $0)?.lowerBound }
        check("lines came back top to bottom",
              positions.count == lines.count && positions == positions.sorted())

        // An image with nothing to read must not silently leave the previous
        // clipboard in place looking like a successful copy.
        let blank = directory.appendingPathComponent("copy-text-blank.png")
        try ImageEncoder.write(wordsImage([]), to: blank)
        check("blank image recognises nothing", await TextRecognition.text(inFileAt: blank) == nil)

        // Through the action, which is the part that reaches the pasteboard.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        let before = NSPasteboard.general.changeCount
        CopyText.run(fileAt: sample)
        // Polled rather than awaited: `CopyText.run` deliberately returns
        // immediately — that is the whole point of it — so there is nothing to
        // await, and a fixed sleep would either be flaky or slow.
        for _ in 0..<80 where NSPasteboard.general.changeCount == before {
            try await Task.sleep(for: .milliseconds(100))
        }
        let pasted = NSPasteboard.general.string(forType: .string)
        check("text reached the clipboard", pasted == recognised && !recognised.isEmpty,
              "clipboard=\"\((pasted ?? "nil").prefix(40))\"")
        check("no file came with it",
              NSPasteboard.general.string(forType: .fileURL) == nil)

        // The viewer's half of the entry points. The card's menu is deliberately
        // not exercised here: building a `PreviewCardView` asks `ShareService`
        // whether it is configured, which reads the Keychain, and a Keychain
        // read in a headless run blocks on a prompt nobody is there to answer —
        // which is why `--selftest-share-card` is not in `make test` either.
        ViewerWindowController.shared.activatesOnShow = false
        ViewerWindowController.shared.show(PreviewEntry(
            kind: .image(pointSize: CGSize(width: 600, height: 400)),
            thumbnail: NSImage(size: PreviewCardView.cardSize),
            url: sample, sourceDisplayID: CGMainDisplayID()))
        // Image I/O is intentionally off the main actor now. Wait for the real
        // window state instead of turning that performance fix into a race.
        for _ in 0..<40 where ViewerWindowController.shared.windowForTest(sample) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let viewerMenu = ViewerWindowController.shared.windowForTest(sample)?.contentView?.menu
        check("viewer offers Copy Text",
              viewerMenu?.items.contains { $0.title == "Copy Text" } == true)
        check("viewer offers Redact Sensitive Text",
              viewerMenu?.items.contains { $0.title == "Redact Sensitive Text" } == true)
        ViewerWindowController.shared.closeAll()

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// Black text on white at a size no OCR could reasonably miss.
    ///
    /// Deliberately not a screenshot of a real window: a test whose input is
    /// whatever happens to be on screen cannot assert what came back.
    private static func wordsImage(_ lines: [String]) -> CGImage {
        let size = CGSize(width: 900, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, line) in lines.enumerated() {
            // Drawn top-down, which in AppKit's upward y means subtracting.
            (line as NSString).draw(
                at: CGPoint(x: 60, y: size.height - 120 - CGFloat(index) * 110),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 64, weight: .regular),
                    .foregroundColor: NSColor.black,
                ])
        }
        image.unlockFocus()
        var box = CGRect(origin: .zero, size: size)
        // Force-unwrapped: the image was just drawn into, so a nil here is a
        // broken run rather than a condition worth reporting.
        return image.cgImage(forProposedRect: &box, context: nil, hints: nil)!
    }

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
        guard let output = await OutputPipeline.shared.process(
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
        guard let output = await OutputPipeline.shared.process(result, saveDirectoryOverride: directory)
        else { return 1 }
        await previews.present(output)
        try await Task.sleep(for: .milliseconds(500))

        print("panels:        \(previews.count)")
        print("panel state:   \(previews.debugState)")

        // The card only ever draws into a 208x132 tile, and up to `maxRetained`
        // of them are alive at once. A full-resolution still as the thumbnail is
        // ~59 MB of pixels per card that nothing ever looks at.
        //
        // Measured off the CGImage, not off `representations`: an NSImage built
        // with `NSImage(cgImage:size:)` carries an NSCGImageSnapshotRep whose
        // `pixelsWide` is the *device* backing multiple of the logical size, not
        // the bitmap's real width — measured, it answers 816 for a 408 px image.
        let entry = await PreviewEntry(output)
        let thumbnail = entry.thumbnail
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { CGSize(width: $0.width, height: $0.height) } ?? entry.thumbnail.size
        let cap = PreviewThumbnail.maximumSize
        let thumbnailOK = thumbnail.width <= cap.width + 1 && thumbnail.height <= cap.height + 1
        print(String(format: "thumbnail:     %.0fx%.0f px, cap %.0fx%.0f -> %@",
                     thumbnail.width, thumbnail.height, cap.width, cap.height,
                     (thumbnailOK ? "bounded" : "FULL-RESOLUTION STILL RETAINED") as NSString))

        // The card's Copy re-reads the staged file instead of holding the
        // capture, so the point-size guarantee has to be proved again on that
        // path — it is the one thing between a 2x capture and pasting at double
        // size, and no other check covers the card's own button.
        NSPasteboard.general.clearContents()
        entry.copyToClipboard()
        let copied = (NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil)?.first as? NSImage)?.size ?? .zero
        let copyOK = abs(copied.width - result.pointSize.width) < 1
            && abs(copied.height - result.pointSize.height) < 1
        print(String(format: "card copy:     %.0fx%.0f pt, expected %.0fx%.0f -> %@",
                     copied.width, copied.height,
                     result.pointSize.width, result.pointSize.height,
                     (copyOK ? "OK" : "WRONG LOGICAL SIZE") as NSString))

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
           let freshOutput = await OutputPipeline.shared.process(
               fresh, saveDirectoryOverride: directory)
        {
            await previews.present(freshOutput)
            try await Task.sleep(for: .milliseconds(200))

            // A second card, so the test can prove the hold is *per card* and
            // not "freeze the whole stack whenever the pointer is anywhere".
            if let second = try? await coordinator.engine.capture(.display(displayID)),
               let secondOutput = await OutputPipeline.shared.process(
                   second, saveDirectoryOverride: directory) {
                await previews.present(secondOutput)
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
            && exclusionOK && dismissed && hoverOK && thumbnailOK && copyOK
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
            await coordinator.overlay.present(windows: all)
        }
        try await Task.sleep(for: .milliseconds(400))
        defer { presentation.cancel() }

        let pickable = coordinator.overlay.pickableWindowCount
        print("windows:       \(all.count) enumerated, \(pickable) pickable")

        // The merged overlay's central rule, and the one the old Space-key test
        // used to stand in for: a window is suggested while the mouse is idle,
        // and no window is suggested the moment a drag is under way.
        //
        // They have to be mutually exclusive. The click that accepts a
        // suggestion and the press that starts a rubber band are the *same*
        // press, told apart only by how far it travels — so a suggestion still
        // standing mid-drag is one that a short drag could commit on top of the
        // rect the user was drawing, which is the merge's obvious way to fail.
        //
        // Hovered-but-not-suggested is the distinction under test, hence the two
        // different accessors: `hoveredWindow` is the raw picker, and
        // `suggestedWindowForTest` is what the view would actually offer.
        coordinator.overlay.forceHover(atAppKitGlobal: NSEvent.mouseLocation)
        let idleSuggestion = coordinator.overlay.suggestedWindowForTest
        var suppressionOK = true
        if let screen = ScreenIndex.screenUnderMouse() {
            coordinator.overlay.restartSelectionForTest(
                at: NSEvent.mouseLocation, on: screen)
            let mid = coordinator.overlay.suggestedWindowForTest
            let stillHovered = coordinator.overlay.hoveredWindow
            suppressionOK = mid == nil && stillHovered != nil
            print("suggestion:    idle=\(idleSuggestion?.displayName ?? "none") "
                + "mid-drag=\(mid?.displayName ?? "none") "
                + "(picker still holds \(stillHovered?.displayName ?? "nothing")) "
                + "\(suppressionOK ? "" : "MISMATCH")")
            coordinator.overlay.cancelSelectionForTest()
        } else {
            print("suggestion:    idle=\(idleSuggestion?.displayName ?? "none") "
                + "(no screen under pointer; suppression not exercised)")
        }

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
            await coordinator.overlay.present(windows: all.reversed())
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
                await coordinator.overlay.present(windows: withSettings)
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
        let (clickAdoptsOK, dragOverridesOK) = try await mergedGestures(coordinator, all)
        let instantOK = try await instantWindowCapture(coordinator)
        try await photographSuggestion(coordinator, all, into: directory)

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
        let pass = selfLeaked == 0 && hits == tested && tested > 0 && geometryOK && suppressionOK
            && clickAdoptsOK && dragOverridesOK && instantOK
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
            await coordinator.overlay.present(windows: windows)
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
    /// Drives the one press that now has two meanings, both ways.
    ///
    /// Under the travel threshold it is a click and commits the suggested
    /// window; over it, it is a rubber band and commits an area, ignoring the
    /// suggestion entirely. That branch is the whole merge, and it lives inside
    /// `mouseDown`/`mouseDragged`/`mouseUp` — so this goes through `dragForTest`,
    /// which synthesises real `NSEvent`s into those handlers, rather than
    /// reaching past them to the model. A hook that skipped the handlers would
    /// leave the only interesting line untested.
    ///
    /// Returns (click committed the suggested window, drag committed an area).
    private static func mergedGestures(
        _ coordinator: CaptureCoordinator, _ windows: [WindowInfo]
    ) async throws -> (clickOK: Bool, dragOK: Bool) {
        guard let screen = NSScreen.main else {
            print("gestures:      no main screen — not exercised")
            return (true, true)
        }
        // Well inside the screen, so the 120×80 drag below has room and the
        // point is over whatever is stacked in the middle of the display.
        let anchor = CGPoint(x: screen.frame.midX - 60, y: screen.frame.midY - 40)

        // MARK: click
        let clickBox = OutcomeBox()
        let clickFlag = CompletionFlag()
        Task {
            clickBox.outcome = await coordinator.overlay.present(windows: windows)
            clickFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(400))
        coordinator.overlay.forceHover(atAppKitGlobal: anchor)
        // Read the offer *before* clicking rather than asserting a particular
        // window: which window is frontmost at the middle of the screen is not
        // this test's business, and pinning it would make the test a report on
        // whatever the machine happens to have open.
        let offered = coordinator.overlay.suggestedWindowForTest
        // Zero travel — the gesture is a click.
        coordinator.overlay.dragForTest(from: anchor, to: anchor)
        _ = await clickFlag.wait(upTo: .milliseconds(600))
        coordinator.overlay.tearDown()
        try await Task.sleep(for: .milliseconds(200))

        var clickOK: Bool
        if let offered {
            if case .window(let id) = clickBox.outcome, id == offered.id {
                clickOK = true
            } else {
                clickOK = false
            }
            print("click:         over \(offered.displayName) -> "
                + "\(describe(clickBox.outcome)) \(clickOK ? "" : "MISMATCH")")
        } else {
            // Bare desktop under the anchor. The click must then do *nothing* —
            // committing a 1×1 area is exactly what the old code did with a
            // press that carried one point of hand-shake.
            clickOK = clickBox.outcome == nil
            print("click:         nothing offered -> \(describe(clickBox.outcome)) "
                + "\(clickOK ? "" : "MISMATCH — a click with no suggestion must not commit")")
        }

        // MARK: drag
        let dragBox = OutcomeBox()
        let dragFlag = CompletionFlag()
        Task {
            dragBox.outcome = await coordinator.overlay.present(windows: windows)
            dragFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(400))
        coordinator.overlay.forceHover(atAppKitGlobal: anchor)
        let size = CGSize(width: 120, height: 80)
        coordinator.overlay.dragForTest(
            from: anchor, to: CGPoint(x: anchor.x + size.width, y: anchor.y + size.height))
        _ = await dragFlag.wait(upTo: .milliseconds(600))
        coordinator.overlay.tearDown()
        try await Task.sleep(for: .milliseconds(200))

        var dragOK = false
        if case .area(_, let rect) = dragBox.outcome {
            // The rect has to start at the *press*, not at the point where the
            // gesture crossed the threshold: `beginDrag` is deliberately fed the
            // stored origin rather than the current location, and getting that
            // wrong would silently shave the first few points off every drag.
            dragOK = abs(rect.width - size.width) < 1 && abs(rect.height - size.height) < 1
                && abs(rect.minX - anchor.x) < 1 && abs(rect.minY - anchor.y) < 1
        }
        print("drag:          120×80 from \(rectString(CGRect(origin: anchor, size: .zero))) -> "
            + "\(describe(dragBox.outcome)) \(dragOK ? "" : "MISMATCH")")

        return (clickOK, dragOK)
    }

    /// Photographs the overlay while it is offering a window, so the suggestion
    /// can be looked at rather than inferred.
    ///
    /// Everything else about the merge is asserted through the model, and the
    /// model cannot tell you whether `drawSuggestion` puts a single pixel on
    /// screen. It is a treatment that was deliberately made subtle — an outline
    /// and a partial un-dim, where window mode used to punch the window clean
    /// out of the dim — and "too subtle to see" is a failure that only a picture
    /// catches. It is also the treatment whose *first* version was legible in
    /// exactly this photograph and still wrong: a wash of white read as fog.
    ///
    /// Needs the panels visible to ScreenCaptureKit, which they are not by
    /// default; `usesSharingTypeNone` is flipped for this one capture and put
    /// back, because every other test in this file depends on the default.
    private static func photographSuggestion(
        _ coordinator: CaptureCoordinator, _ windows: [WindowInfo], into directory: URL
    ) async throws {
        guard let screen = NSScreen.main, let displayID = ScreenIndex.displayID(of: screen) else {
            return
        }
        let wasHidden = OverlayPanel.usesSharingTypeNone
        OverlayPanel.usesSharingTypeNone = false
        defer { OverlayPanel.usesSharingTypeNone = wasHidden }

        let presentation = Task { await coordinator.overlay.present(windows: windows) }
        try await Task.sleep(for: .milliseconds(500))
        let anchor = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        coordinator.overlay.forceHover(atAppKitGlobal: anchor)
        try await Task.sleep(for: .milliseconds(250))
        let offering = coordinator.overlay.suggestedWindowForTest

        var options = CaptureOptions.default
        options.showsCursor = false
        let shot = try? await coordinator.engine.capture(.display(displayID), options: options)
        coordinator.overlay.tearDown()
        presentation.cancel()
        try await Task.sleep(for: .milliseconds(200))

        guard let shot else {
            print("suggestion png: capture failed")
            return
        }
        let url = directory.appendingPathComponent("suggestion-overlay.png")
        try? ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)
        print("suggestion png: \(offering?.displayName ?? "nothing offered") -> \(url.path)")
    }

    /// The ⇧⌘S path, which shows no overlay and so has no way to tell the user
    /// what it is about to take.
    ///
    /// Two halves, and the second is the one worth the code. Over a window it
    /// must capture *that* window. Over bare desktop it must capture nothing —
    /// falling through to whatever is stacked behind the pointer would be a
    /// wrong answer with no UI anywhere on screen to catch it, which is the
    /// failure this shortcut is written around.
    ///
    /// The pointer is warped, because a shortcut whose entire input is the
    /// pointer cannot be driven any other way. It is put back afterwards.
    private static func instantWindowCapture(
        _ coordinator: CaptureCoordinator
    ) async throws -> Bool {
        let restore = NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(DisplayGeometry.flipped(restore)) }

        /// The picker's own verdict at a point, which is what `captureWindow()`
        /// consults. Rebuilt per query rather than shared, so the test cannot
        /// pass off a stale hover as an answer.
        func verdict(at pointInAppKitGlobal: CGPoint) -> WindowInfo? {
            let picker = WindowPickerModel()
            picker.load(coordinator.engine.shareableContent.windows)
            picker.reRank()
            picker.updateHover(atAppKitGlobal: pointInAppKitGlobal)
            return picker.hovered
        }

        func warp(to pointInAppKitGlobal: CGPoint) async throws {
            CGWarpMouseCursorPosition(DisplayGeometry.flipped(pointInAppKitGlobal))
            try await Task.sleep(for: .milliseconds(150))
        }

        guard let screen = NSScreen.main else {
            print("instant ⇧⌘S:   no main screen — not exercised")
            return true
        }
        try await coordinator.engine.refreshContent()

        // A point with a window under it, and a point with none. Both are found
        // by asking rather than assuming: which is which depends entirely on
        // what this machine happens to have open.
        var overWindow: (point: CGPoint, window: WindowInfo)?
        var overNothing: CGPoint?
        for column in stride(from: 0.08, through: 0.92, by: 0.12) {
            for row in stride(from: 0.08, through: 0.92, by: 0.12) {
                let point = CGPoint(
                    x: screen.frame.minX + screen.frame.width * column,
                    y: screen.frame.minY + screen.frame.height * row)
                if let hit = verdict(at: point) {
                    if overWindow == nil { overWindow = (point, hit) }
                } else if overNothing == nil {
                    overNothing = point
                }
            }
        }

        var ok = true

        if let (point, expected) = overWindow {
            try await warp(to: point)
            // Re-asked after the warp: the act of moving the pointer can raise
            // nothing by itself, but the enumeration inside `captureWindow` is
            // fresh, and comparing against a verdict taken before it would be
            // comparing two different window lists.
            let expectedNow = verdict(at: NSEvent.mouseLocation) ?? expected
            let result = await coordinator.captureWindow()
            let matched = result?.sourceDescription == expectedNow.displayName
            let got = result.map {
                "\($0.sourceDescription) \(Int($0.pixelSize.width))x\(Int($0.pixelSize.height)) px"
            } ?? "nothing"
            print("instant ⇧⌘S:   over \(expectedNow.displayName) -> \(got) "
                + "\(matched ? "" : "MISMATCH")")
            ok = ok && matched
        } else {
            print("instant ⇧⌘S:   no point on this screen has a pickable window — not exercised")
        }

        guard let empty = overNothing else {
            // Not a failure: a maximised window can legitimately cover every
            // sampled point. Said out loud, because a silently unexercised half
            // is indistinguishable from a passing one.
            print("instant ⇧⌘S:   every sampled point has a window over it — "
                + "the bare-desktop half was not exercised")
            return ok
        }
        try await warp(to: empty)
        let stillEmpty = verdict(at: NSEvent.mouseLocation) == nil
        let result = await coordinator.captureWindow()
        // Only meaningful while the point really is empty; a window arriving
        // under the pointer mid-test would make a capture the correct answer.
        let refusedOK = !stillEmpty || result == nil
        print("instant ⇧⌘S:   over bare desktop -> "
            + "\(result.map { "captured \($0.sourceDescription)" } ?? "refused") "
            + "\(refusedOK ? "" : "MISMATCH — it fell through to the window behind")")
        return ok && refusedOK
    }

    private static func describe(_ outcome: OverlayController.Outcome?) -> String {
        switch outcome {
        case .none: "nothing (still presenting or cancelled without resuming)"
        case .cancelled: "cancelled"
        case .window(let id): "window \(id)"
        case .area(_, let rect): "area \(rectString(rect))"
        }
    }

    private static func systemFurnitureIsPickable(
        _ coordinator: CaptureCoordinator, _ all: [WindowInfo]
    ) async throws -> Bool {
        let menuBar = all.first { $0.layer == WindowInfo.menuBarLayer && $0.isOnScreen }
        let dock = all.first { $0.layer == WindowInfo.dockLayer && $0.isOnScreen }

        let presentation = Task {
            await coordinator.overlay.present(windows: all)
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
        // The card's own curve: half an inset past the window's, which is a
        // judgement rather than a derivation — so it is pinned here, where
        // changing it means saying so.
        let cardRadius = ImagePadding.cornerRadius(of: padded)
        let wanted = CGFloat(radius) + CGFloat(padding) / 2
        let cardOK = cardRadius.map { abs($0 - wanted) <= 3 } ?? false
        if !cardOK {
            print(String(format: "  card radius: %@ px, wanted %.0f -> MISMATCH",
                         cardRadius.map { String(format: "%.0f", $0) } ?? "none" as NSString,
                         wanted))
        }
        let ok = radiusOK && cardOK && cornerAlpha == 0 && edgeAlpha > 250
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

    // MARK: - Viewer

    /// The in-app viewer window: geometry, the one-window-per-file rule, and a
    /// photograph of the thing so it can be looked at.
    ///
    /// Geometry is the whole risk here. A viewer is trivial when the picture is
    /// small and the interesting cases are the ones where it is not: a
    /// full-screen capture is by definition exactly as large as the display it
    /// came from, so a window sized to it has its title bar off the top of the
    /// screen and no way to reach its bottom edge. Two of the three cases below
    /// exist for that.
    private static func viewerWindow(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        let coordinator = CaptureCoordinator()
        let viewer = ViewerWindowController.shared
        // Same reasoning as the Settings window's: `NSApp.activate` yanks the
        // keyboard out of whatever the person running the test is typing in.
        viewer.activatesOnShow = false
        defer { viewer.closeAll() }

        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        guard let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main else {
            print("result:        FAIL — no screen")
            return 1
        }
        let visible = screen.visibleFrame
        var failures: [String] = []

        /// Every window has to end up inside the screen it opened on. Checked for
        /// each case rather than once, because the three take different paths to a
        /// size and only one of them is capped.
        func checkFits(_ window: NSWindow, _ label: String) {
            let fits = visible.insetBy(dx: -1, dy: -1).contains(window.frame)
            print("  \(label) window \(rectString(window.frame)) "
                + "in \(rectString(visible)) -> \(fits ? "fits" : "OFF SCREEN")")
            if !fits { failures.append("\(label) window does not fit its screen") }
        }

        // MARK: a still, smaller than the screen

        let small = CGRect(x: 200, y: 200, width: 640, height: 360)
        let stillResult = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: small))
        guard let stillOutput = await OutputPipeline.shared.process(
            stillResult, saveDirectoryOverride: directory)
        else {
            print("result:        FAIL — the still did not reach the output pipeline")
            return 1
        }
        let still = await PreviewEntry(stillOutput)

        // MARK: the card's centre button

        // The wiring between the two halves. The disc in the middle of a preview
        // card is what opens this window, and it is deliberately not an
        // `NSButton`: the card decides on mouse-*up* whether a press was a click
        // on the disc or the start of a drag-out, so the only honest test drives
        // the real handlers.
        let previews = PreviewStackController()
        previews.timeout = .seconds(60)
        await previews.present(stillOutput)
        try await Task.sleep(for: .milliseconds(400))
        previews.setHoverForTest(true)
        try await Task.sleep(for: .milliseconds(200))

        if let centre = previews.newestCardCentreForTest {
            previews.clickNewestCardForTest(at: centre)
            try await Task.sleep(for: .milliseconds(400))
            let opened = viewer.openWindowCount == 1
            print("card centre:   click at \(Int(centre.x)),\(Int(centre.y)) -> "
                + "\(viewer.openWindowCount) viewer(s) \(opened ? "" : "MISMATCH")")
            if !opened { failures.append("the card's centre button did not open the viewer") }
            viewer.closeAll()
            try await Task.sleep(for: .milliseconds(200))

            // And a click that is NOT on the disc must not open anything.
            // Dragging a card out begins with a press somewhere on it, and
            // without this every one of those presses is a viewer waiting to
            // happen.
            previews.clickNewestCardForTest(at: CGPoint(x: 12, y: 12))
            try await Task.sleep(for: .milliseconds(300))
            let quiet = viewer.openWindowCount == 0
            print("card corner:   click at 12,12 -> \(viewer.openWindowCount) viewer(s) "
                + "\(quiet ? "" : "MISMATCH — a click off the disc opened one")")
            if !quiet { failures.append("a click away from the centre opened the viewer") }
            viewer.closeAll()
        } else {
            failures.append("no preview card to click")
        }

        viewer.show(still)
        try await Task.sleep(for: .milliseconds(400))

        guard let stillWindow = viewer.windowForTest(still.url) else {
            print("result:        FAIL — no window for the still")
            return 1
        }
        print("still:         \(rectString(small)) -> content "
            + "\(rectString(stillWindow.contentLayoutRect))")
        checkFits(stillWindow, "still")

        // The still viewer's picture area is the capture's own size clamped into
        // a band — see `standardPicture` and `minimumPicture`. Two things to hold
        // it to: it never swims (a capture inside the band gets its own size plus
        // the fit's margin and no more) and it never exceeds the ceiling, which
        // the full-screen case below checks.
        let stillContent = stillWindow.contentLayoutRect.size
        let stillPicture = CGSize(
            width: stillContent.width,
            height: stillContent.height - ImageEditor.chromeHeight)
        let slack = CGSize(width: stillPicture.width - small.width,
                           height: stillPicture.height - small.height)
        // "Its own size plus the margin" on each axis, unless the floor got
        // there first — a 200-point capture cannot have a 200-point window, the
        // toolbar has to fit in it.
        func hugged(_ area: CGFloat, _ capture: CGFloat, floor: CGFloat) -> Bool {
            area - capture <= ZoomingScrollView.fitPadding * 2 + 1 || abs(area - floor) <= 1
        }
        let hugs = hugged(stillPicture.width, small.width,
                          floor: ViewerWindowController.minimumPicture.width)
            && hugged(stillPicture.height, small.height,
                      floor: ViewerWindowController.minimumPicture.height)
        print(String(format: "  picture area %.0f×%.0f for a %.0f×%.0f capture -> %@",
                     stillPicture.width, stillPicture.height, small.width, small.height,
                     (hugs ? "hugs it" : "SWIMS") as NSString))
        if !hugs {
            failures.append("the viewer leaves "
                + "\(Int(slack.width))×\(Int(slack.height)) pt of empty window")
        }

        // MARK: the window's own corners
        //
        // Two checks, because the squareness has two halves and only one of them
        // is visible to a capture.
        //
        // On screen: an opaque `backgroundColor` sets `isOpaque`, and an opaque
        // window is drawn by the window server without the rounded-corner mask —
        // square corners, to the eye and to any screen-area capture of it. That
        // is a flag, so it is checked as one.
        //
        // In a window capture: ScreenCaptureKit renders the window's own layer
        // tree and masks the corners itself, so this half passes either way. It
        // is here anyway, because it is the half that ends up in a file.
        let opaque = stillWindow.isOpaque
        print("  window opaque: \(opaque) -> \(opaque ? "SQUARE ON SCREEN" : "rounded")")
        if opaque {
            failures.append("the viewer window is opaque, so macOS draws it square-cornered")
        }
        try await coordinator.engine.refreshContent()
        let viewerID = CGWindowID(stillWindow.windowNumber)
        if let shot = try? await coordinator.engine.capture(.window(viewerID)) {
            let corner = alpha(of: shot.image, atX: 1, y: 1)
            let inside = alpha(of: shot.image, atX: shot.image.width / 2,
                               y: shot.image.height / 2)
            let rounded = corner == 0 && inside == 255
            print("  window corner: alpha \(corner) at the corner, \(inside) in the middle"
                + " -> \(rounded ? "rounded" : "SQUARE")")
            if !rounded {
                failures.append("the viewer window captures with square corners")
            }
        } else {
            failures.append("could not capture the viewer's own window")
        }

        // MARK: and it follows a crop
        //
        // The same rule applied again. A window that keeps the shape of the
        // picture it used to hold leaves the cropped one floating in the middle
        // of a frame two sizes too big.
        if let editor = viewer.editorForTest(still.url) {
            let before = stillWindow.frame
            editor.addEditForTest(.crop(CGRect(x: 40, y: 30, width: 300, height: 180)))
            await editor.flushForTest()
            try await Task.sleep(for: .milliseconds(120))
            let after = stillWindow.contentLayoutRect.size
            let picture = CGSize(
                width: after.width, height: after.height - ImageEditor.chromeHeight)
            // 300×180 is under the floor, so the floor is what it gets — the
            // point is that it shrank and that the top left stayed put.
            let shrank = after.width < before.width - 10 || after.height < before.height - 10
            let anchored = abs(stillWindow.frame.maxY - before.maxY) <= 1
                && abs(stillWindow.frame.minX - before.minX) <= 1
            print(String(format: "  after a crop: picture area %.0f×%.0f -> %@, %@",
                         picture.width, picture.height,
                         (shrank ? "smaller" : "UNCHANGED") as NSString,
                         (anchored ? "top left held" : "MOVED") as NSString))
            if !shrank { failures.append("the window did not shrink to the cropped picture") }
            if !anchored { failures.append("the window jumped when it resized") }
            editor.undoForTest()
            await editor.flushForTest()
        }

        // The whole picture has to be visible when it opens. A viewer that lands
        // zoomed in on the top-left corner is technically showing the file and is
        // useless.
        if let magnification = viewer.magnificationForTest(still.url) {
            // Room for the scrollers and the odd rounding; what would fail here is
            // an opening magnification of 1 on an image larger than the window.
            let fits = magnification <= 1.02
            print(String(format: "  opens at %.3fx -> %@", magnification,
                         (fits ? "whole image visible" : "OPENS ZOOMED IN") as NSString))
            if !fits { failures.append("still opens at \(magnification)x") }
        } else {
            failures.append("still viewer is not a zooming scroll view")
        }

        // MARK: the same file again

        // One window per file. A second click on a card whose viewer is already
        // up must raise that window, not build a second one — two windows of the
        // same screenshot is never what the second click meant.
        viewer.show(still)
        try await Task.sleep(for: .milliseconds(200))
        let reopenedOK = viewer.openWindowCount == 1
            && viewer.windowForTest(still.url) === stillWindow
        print("reopen:        \(viewer.openWindowCount) window(s) "
            + "\(reopenedOK ? "— raised the existing one" : "MISMATCH — built a second")")
        if !reopenedOK { failures.append("re-opening the same file made a second window") }

        // MARK: a full-screen still

        // The case the cap exists for: as large as the display, so the natural
        // size is unusable by construction.
        let fullResult = try await coordinator.engine.capture(.display(displayID))
        guard let fullOutput = await OutputPipeline.shared.process(
            fullResult, saveDirectoryOverride: directory)
        else {
            print("result:        FAIL — the full-screen still did not reach the pipeline")
            return 1
        }
        let full = await PreviewEntry(fullOutput)
        viewer.show(full)
        try await Task.sleep(for: .milliseconds(400))
        if let fullWindow = viewer.windowForTest(full.url) {
            print("fullscreen:    image \(Int(fullResult.pointSize.width))x"
                + "\(Int(fullResult.pointSize.height)) pt")
            checkFits(fullWindow, "fullscreen")

            // The ceiling. A capture the size of the display must not ask for a
            // window the size of the display.
            let fullPicture = CGSize(
                width: fullWindow.contentLayoutRect.width,
                height: fullWindow.contentLayoutRect.height - ImageEditor.chromeHeight)
            let capped = fullPicture.width <= ViewerWindowController.standardPicture.width + 1
                && fullPicture.height <= ViewerWindowController.standardPicture.height + 1
            print(String(format: "  picture area %.0f×%.0f for the whole display -> %@",
                         fullPicture.width, fullPicture.height,
                         (capped ? "capped" : "UNCAPPED") as NSString))
            if !capped {
                failures.append("a full-screen capture opens a window of its own size")
            }
        } else {
            failures.append("no window for the full-screen still")
        }

        // MARK: a recording

        // The other content path entirely — AVPlayerView, sized from the
        // RecordingResult rather than from a decoded image.
        let clip = directory.appendingPathComponent("viewer-clip.mp4")
        try? FileManager.default.removeItem(at: clip)
        let recorder = RecordingEngine()
        var options = RecordingOptions.default
        options.capturesSystemAudio = false
        let region = CGRect(x: 200, y: 200, width: 640, height: 360)
        _ = try await recorder.start(
            .area(displayID: displayID, rectInAppKitGlobal: region), options: options, to: clip)
        try await Task.sleep(for: .milliseconds(1200))
        let recording = try await recorder.stop()
        let poster = await VideoPoster.frame(for: recording.url) ?? VideoPoster.placeholder()
        let video = PreviewEntry(
            OutputPipeline.RecordingOutput(result: recording, url: recording.url, wasSaved: false),
            poster: poster)
        viewer.show(video)
        try await Task.sleep(for: .milliseconds(500))

        if let videoWindow = viewer.windowForTest(video.url) {
            print("recording:     \(Int(recording.pointSize.width))x"
                + "\(Int(recording.pointSize.height)) pt -> content "
                + "\(rectString(videoWindow.contentLayoutRect))")
            checkFits(videoWindow, "recording")
            // Exactly the video's aspect. The first version of this padded the
            // window for the transport controls and asserted the padding was
            // there — which passed, while the window showed the clip with a black
            // band above and below it. `.inline` controls are an auto-hiding
            // overlay, so any allowance for them is pure letterboxing.
            let box = videoWindow.contentLayoutRect.size
            let wantedVideo = recording.pointSize.width / max(recording.pointSize.height, 1)
            let gotVideo = box.width / max(box.height, 1)
            let videoAspectOK = abs(wantedVideo - gotVideo) < 0.02
            print(String(format: "  aspect %.3f vs %.3f -> %@", gotVideo, wantedVideo,
                         (videoAspectOK ? "matches, no letterboxing" : "MISMATCH") as NSString))
            if !videoAspectOK {
                failures.append("recording window aspect \(gotVideo) != video aspect \(wantedVideo)")
            }
            // The player is inside the trim editor now, so the content view is
            // the container; what matters is still that a real AVPlayerView is
            // what fills the window.
            if !(videoWindow.contentView is VideoTrimEditor) {
                failures.append("recording window is not a VideoTrimEditor")
            }
            if !(videoWindow.initialFirstResponder is AVPlayerView) {
                failures.append("recording window does not hand the keyboard to the player")
            }
        } else {
            failures.append("no window for the recording")
        }

        // MARK: the two keys every window closes with

        // DuoShot is LSUIElement and has no main menu, so there is nothing
        // behind ⌘W: an equivalent that no window in the app claims is normally
        // caught by the menu bar's Close item, and here it just does nothing.
        // Escape had the same shape of bug in a different place — the still's
        // scroll view answered `cancelOperation`, so Escape worked on a
        // screenshot and silently did not on a recording.
        //
        // Both are therefore checked on the *video* window, which is the one
        // whose content view answers neither.
        if let videoWindow = viewer.windowForTest(video.url) {
            let commandW = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: videoWindow.windowNumber, context: nil,
                characters: "w", charactersIgnoringModifiers: "w",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_W))
            // `performKeyEquivalent` is the method NSApp itself calls, so this is
            // the real entry point rather than a stand-in for it.
            let claimed = commandW.map { videoWindow.performKeyEquivalent(with: $0) } ?? false
            try await Task.sleep(for: .milliseconds(200))
            let closed = viewer.windowForTest(video.url) == nil
            print("⌘W:            claimed=\(claimed) closed=\(closed) "
                + "\(claimed && closed ? "" : "MISMATCH")")
            if !(claimed && closed) { failures.append("⌘W did not close the viewer") }

            // Re-opened for the Escape half, since ⌘W just closed it.
            viewer.show(video)
            try await Task.sleep(for: .milliseconds(300))
            viewer.windowForTest(video.url)?.cancelOperation(nil)
            try await Task.sleep(for: .milliseconds(200))
            let escClosed = viewer.windowForTest(video.url) == nil
            print("Esc:           closed=\(escClosed) \(escClosed ? "" : "MISMATCH")")
            if !escClosed { failures.append("Escape did not close the viewer") }
            viewer.show(video)
            try await Task.sleep(for: .milliseconds(300))
        }

        // MARK: look at it

        // Everything above is arithmetic on frames, and none of it can tell you
        // whether the window looks like a viewer. The three are left on screen
        // together for this one shot.
        try await Task.sleep(for: .milliseconds(300))
        let shot = try await coordinator.engine.capture(.display(displayID))
        let url = directory.appendingPathComponent("viewer.png")
        try ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)
        print("wrote:         \(url.path)")

        print("windows:       \(viewer.openWindowCount) open")
        viewer.closeAll()
        try await Task.sleep(for: .milliseconds(200))
        let closedOK = viewer.openWindowCount == 0
        print("closeAll:      \(viewer.openWindowCount) left \(closedOK ? "" : "MISMATCH")")
        if !closedOK { failures.append("closeAll left windows behind") }

        for failure in failures { print("FAIL:          \(failure)") }
        print("result:        \(failures.isEmpty ? "PASS" : "FAIL")")
        return failures.isEmpty ? 0 : 1
    }

    /// Redaction: image in, image out.
    ///
    /// Headless and synthetic on purpose. What has to be proved is that the
    /// pixels under a rectangle are *gone* — not covered, not softened — and
    /// that is a claim about bytes, so the input has to be an image whose bytes
    /// are known rather than whatever happened to be on screen.
    ///
    /// The input is written at 2×, because that is where this feature is most
    /// likely to be quietly wrong: a rectangle drawn over a picture is drawn in
    /// points, the redaction happens in pixels, and on a Retina capture those
    /// differ by a factor of two — applying the drawn numbers unchanged would
    /// destroy a quarter of the intended area in the wrong corner and look
    /// perfectly plausible doing it.
    private static func editCheck(into directory: URL) async throws -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }
        func sizeString(_ size: CGSize) -> String {
            String(format: "%.0f×%.0f", size.width, size.height)
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        // Yesterday's exports, gone. `ImageEdit.exportURL` counts up from
        // "(edited)" to avoid clobbering anything, so a directory left over from
        // the last run makes this one's filenames wrong in a way that says
        // nothing about the code.
        for file in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.contains("(edited") {
            try? FileManager.default.removeItem(at: file)
        }

        // Fine stripes: every block average lands on the same mid-grey, so a
        // block that is still striped afterwards is a redaction that did not
        // happen, and one that is uniform cannot be inverted back into stripes.
        let pixels = CGSize(width: 1200, height: 800)
        let points = CGSize(width: 600, height: 400)
        let file = directory.appendingPathComponent("edit-sample.png")
        guard let original = stripedImage(
            width: Int(pixels.width), height: Int(pixels.height)) else {
            print("result:        FAIL — could not build the sample bitmap")
            return 1
        }
        try ImageEncoder.write(original, to: file, as: .png, scale: 2)

        // MARK: points to pixels

        let drawn = CGRect(x: 100, y: 50, width: 200, height: 120)
        let expected = CGRect(x: 200, y: 100, width: 400, height: 240)
        let mapped = ImageEdit.regions([drawn], atPointSize: points, inPixels: pixels)
        check("a 2× rect maps to twice its pixels", mapped == [expected],
              "\(rectString(mapped.first ?? .zero))")

        // Through the real view, which is where the point size and the pixel
        // size are read off the file rather than passed in by a test.
        guard let image = NSImage(contentsOf: file),
              let editor = ImageEditor(
                url: file, image: image, menu: NSMenu(),
                frame: CGRect(origin: .zero, size: points))
        else {
            print("result:        FAIL — the editor would not open the sample")
            return 1
        }
        check("editor reads the image as \(Int(points.width))×\(Int(points.height)) pt",
              image.size == points, "got \(sizeString(image.size))")
        check("editor reads the bitmap as \(Int(pixels.width))×\(Int(pixels.height)) px",
              editor.pixelSizeForTest == pixels, "got \(sizeString(editor.pixelSizeForTest))")

        // MARK: the toolbar
        //
        // Driven as clicks on the real buttons rather than by calling the
        // handlers, because the one bug this feature has shipped lived entirely
        // between the two: the bar's hidden pills sat at the container's origin,
        // `HUDPill.hitTest` replaced the implementation that skips hidden views,
        // and an invisible Apply sat over Redact and swallowed every press of it.
        // Every other check here passed while the button did nothing at all.
        do {
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: points),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = editor
            window.orderFrontRegardless()
            editor.layoutSubtreeIfNeeded()

            // The bar is a fixture at the top now, and the viewer opens holding
            // the pointer: until a tool is picked, a click on the picture is
            // still a click on the picture.
            check("the viewer opens with the pointer", editor.toolForTest == .pointer,
                  "\(editor.toolForTest)")
            check("so the canvas is not armed", !editor.isEditingForTest)
            let barTop = editor.barFrameForTest
            check("the bar sits at the top of the window",
                  barTop.maxY > editor.bounds.midY, rectString(barTop))
            // Above the picture, not over it: the whole point of the band. The
            // scroll view has to stop below the bar, or a permanent toolbar is a
            // permanent hole in every capture's title bar.
            check("and the picture starts below it, not under it",
                  editor.pictureFrameForTest.maxY <= barTop.minY,
                  "picture \(rectString(editor.pictureFrameForTest)) vs bar \(rectString(barTop))")

            guard let redactPill = editor.pillFrameForTest(.redact) else {
                print("result:        FAIL — the bar has no Redact button")
                return 1
            }
            let centre = CGPoint(x: redactPill.midX, y: redactPill.midY)
            let hit = editor.hitTest(centre)
            check("Redact's button hit-tests to a visible pill",
                  (hit as? HUDPill).map { !$0.isHidden } ?? false,
                  hit.map { "\(type(of: $0))\(($0 as? HUDPill)?.isHidden == true ? ", hidden" : "")" }
                    ?? "nothing")
            click(hit, at: editor.convert(centre, to: nil), in: window)
            check("clicking it arms the tool", editor.toolForTest == .redact,
                  "\(editor.toolForTest)")

            // Every pill in the bar, not only the one that was pressed: the bug
            // was one hidden pill covering one visible one, and there are nine
            // of them now.
            var covered = 0
            for x in stride(from: barTop.minX + 2, to: barTop.maxX - 2, by: 3) {
                let pill = editor.hitTest(CGPoint(x: x, y: barTop.midY)) as? HUDPill
                if pill?.isHidden == true { covered += 1 }
            }
            check("no hidden pill sits over the bar", covered == 0,
                  "\(covered) sampled points hit one")

            // Nothing about a press may move the bar. It is over the picture and
            // permanent, so a bar that re-measured itself per state would jump
            // under the pointer on its way to the next button.
            editor.chooseForTest(.crop)
            editor.addEditForTest(.crop(CGRect(x: 20, y: 20, width: 200, height: 150)))
            editor.layoutSubtreeIfNeeded()
            check("the bar does not move when the state changes",
                  editor.barFrameForTest == barTop,
                  "\(rectString(barTop)) -> \(rectString(editor.barFrameForTest))")
            editor.undoForTest()

            // The keyboard half of the same control.
            press("c", on: editor, in: window)
            check("pressing C picks the crop tool", editor.toolForTest == .crop,
                  "\(editor.toolForTest)")
            press("v", on: editor, in: window)
            check("and V puts the pointer back", editor.toolForTest == .pointer,
                  "\(editor.toolForTest)")
            press("r", on: editor, in: window)
            check("and R picks redact again", editor.toolForTest == .redact,
                  "\(editor.toolForTest)")

            // MARK: typing, end to end
            //
            // The newest and most fragile path in the editor: a click has to
            // produce a field, and ⏎ in that field has to produce an edit. Both
            // halves are wiring, which is the kind of thing that ships dead.
            press("t", on: editor, in: window)
            let spot = CGPoint(x: 120, y: 260)
            // The picture fills the view at 1×, so anywhere over it hit-tests to
            // the canvas; the click itself is placed in the canvas's own space.
            if let canvas = editor.hitTest(CGPoint(x: 200, y: 200)) {
                let inWindow = canvas.convert(spot, to: nil)
                if let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: inWindow, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    canvas.mouseDown(with: down)
                }
                let field = firstTextBox(in: canvas)
                check("clicking with the text tool opens a box", field != nil)
                if let field {
                    // Typed rather than assigned: `string = x` skips the
                    // text-input path, and with it everything that path keeps in
                    // step — attributes, layout, the stamp.
                    field.insertText("account number", replacementRange: field.selectedRange())
                    commitTyping(field, in: window)
                }
                // The edit's point is the text's *baseline*, and the click sits
                // half a cap height above it so that the pointer goes through
                // the letters rather than under them — see `beginTyping`.
                //
                // Compared with a tolerance rather than for equality: the click
                // is placed in the canvas's space, converted to the window's and
                // back through a scroll view that is no longer at the origin, so
                // the point that arrives is the one that was sent to within a
                // rounding error, and a rounding error is not a wrong place.
                // The edit's point is the *top* of the first line's box, and the
                // click sits half a line below it so the pointer goes through the
                // letters rather than under them.
                let lift = ImageEdit.textLineHeight() / 2
                var landed = false
                if case .text(let origin, let string, _) = editor.editsForTest.last {
                    landed = string == "account number"
                        && abs(origin.x - spot.x) < 0.01
                        && abs(origin.y - (spot.y + lift)) < 0.01
                }
                check("and ⏎ turns what was typed into an edit", landed,
                      editor.editsForTest.last.map { "\($0)" } ?? "no edit")
                // Still there, and no longer editable: the words stand in for
                // themselves until the render that contains them arrives, or
                // they blink out for the length of a decode.
                let standIn = firstTextBox(in: canvas)
                check("the words stay on screen while the render catches up",
                      standIn?.string == "account number" && standIn?.isEditable == false,
                      standIn.map { "editable \($0.isEditable)" } ?? "nothing left")
                await editor.flushForTest()
                check("and the stand-in goes when the render lands",
                      firstTextBox(in: canvas) == nil)

                // MARK: what is typed is the pixels that get written
                //
                // The checks that used to live here compared the box's live
                // glyphs against the renderer's, by position, size and weight.
                // There is nothing left to compare: the box draws
                // `ImageEdit.stamp`, which is the renderer's own bitmap scaled
                // the way the picture is scaled. Live glyphs at screen
                // resolution and glyphs baked into a 2× picture are two
                // rasterisations of one string at two sizes, and type hinting
                // makes them disagree by about one per cent however carefully
                // the fonts, kerning, tracking and baselines are matched — which
                // is six rounds of this report, each fixing something real and
                // none of them this.
                if let box = openField(at: CGPoint(x: 300, y: 200),
                                       on: canvas, in: window) {
                    box.insertText("Hxy", replacementRange: box.selectedRange())
                    // The renderer draws every annotation with a shadow; the box
                    // being typed in has to carry the same one, or the words
                    // change weight the moment they are committed.
                    let dressed = box.textStorage?.attribute(
                        .shadow, at: 0, effectiveRange: nil) as? NSShadow
                    check("what is being typed carries the render's shadow",
                          dressed?.shadowBlurRadius == 3
                            && dressed?.shadowOffset == CGSize(width: 0, height: -1),
                          dressed.map { "blur \($0.shadowBlurRadius)" } ?? "no shadow")

                    // Chinese input first arrives as underlined marked text.
                    // It must resize the box before a candidate is committed.
                    window.makeFirstResponder(box)
                    box.selectAll(nil)
                    let beforeMarked = box.frame.width
                    box.setMarkedText(
                        "zhongwenshuru", selectedRange: NSRange(location: 13, length: 0),
                        replacementRange: box.selectedRange())
                    check("Chinese composition stretches the input box",
                          box.hasMarkedText() && box.frame.width > beforeMarked + 20,
                          String(format: "%.1f -> %.1f pt", beforeMarked, box.frame.width))
                    box.unmarkText()

                    // MARK: and in a script with different metrics
                        //
                        // Han characters are where the two were reported to
                        // disagree — a line of Chinese that tightened the moment
                        // it was committed. Everything that could make them
                        // disagree is pinned now: the same bold system font, the
                        // same line height, kerning and tracking nailed to zero
                        // on both sides. This is the check that says so.
                        //
                        // Laid-out width, not ink: the box and the renderer use
                        // different rasterisers, and where each of them decides
                        // an antialiased edge stops differs by about a point
                        // over a line. That difference is real and it is not
                        // spacing — measuring it as spacing produced a failure
                        // that no change to the text could fix.
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("测试文字", replacementRange: box.selectedRange())
                        window.makeFirstResponder(nil)
                        if let layout = box.layoutManager, let container = box.textContainer {
                            let full = NSRange(
                                location: 0, length: (box.string as NSString).length)
                            let glyphs = layout.glyphRange(
                                forCharacterRange: full, actualCharacterRange: nil)
                            let typed = layout.boundingRect(
                                forGlyphRange: glyphs, in: container)
                            let drawn = ImageEdit.advance(of: "测试文字")
                            check("Chinese is laid out the same in both",
                                  abs(typed.width - drawn) <= 0.1,
                                  String(format: "%.2f pt typed, %.2f rendered",
                                         typed.width, drawn))
                            check("and on the same line height",
                                  abs(typed.height - ImageEdit.textLineHeight()) <= 0.1,
                                  String(format: "%.2f vs %.2f",
                                         typed.height, ImageEdit.textLineHeight()))
                        } else {
                            check("Chinese is laid out the same in both", false, "no layout")
                        }

                        // MARK: mixed scripts do not change the box's height
                        //
                        // A line of Han characters is three points shorter than
                        // a line of Latin ones. A box sized to what its text
                        // needs therefore changes height the moment the two are
                        // mixed, which is a box that twitches as you type.
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("漢字", replacementRange: box.selectedRange())
                        let hanHeight = box.bounds.height
                        box.insertText(" Test", replacementRange: box.selectedRange())
                        let mixedHeight = box.bounds.height
                        window.makeFirstResponder(nil)
                        check("mixing scripts does not change the box's height",
                              abs(hanHeight - mixedHeight) <= 0.01
                                && abs(hanHeight - ImageEdit.textLineHeight()) <= 0.01,
                              String(format: "%.2f then %.2f", hanHeight, mixedHeight))

                        // MARK: the box does not move as the script changes
                        //
                        // It used to, by a point, and a frame late: the frame was
                        // placed by asking TextKit where it had put the first
                        // baseline, and that answer is a point higher for a line
                        // of Han characters than for a line with any Latin in it.
                        // Type one letter after a Chinese character and the whole
                        // line twitched.
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("啊", replacementRange: box.selectedRange())
                        let han = box.frame.origin.y
                        box.insertText("A", replacementRange: box.selectedRange())
                        let mixed = box.frame.origin.y
                        box.selectAll(nil)
                        box.insertText("Ag", replacementRange: box.selectedRange())
                        let latin = box.frame.origin.y
                        window.makeFirstResponder(nil)
                        check("the box holds still as the script changes",
                              abs(han - mixed) < 0.01 && abs(mixed - latin) < 0.01,
                              String(format: "han %.2f, mixed %.2f, latin %.2f",
                                     han, mixed, latin))

                        // And so do the letters, which is not the same question:
                        // the frame can hold still while TextKit moves the
                        // baseline inside it, and it is the letters that anyone
                        // watches. Measured as ink on screen, in canvas
                        // coordinates.
                        func inkBaseline() -> CGFloat {
                            window.makeFirstResponder(nil)
                            return box.frame.minY + ink(of: box).bottom
                        }
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("啊", replacementRange: box.selectedRange())
                        let hanInk = inkBaseline()
                        window.makeFirstResponder(box)
                        box.insertText("A", replacementRange: box.selectedRange())
                        let mixedInk = inkBaseline()
                        check("and so do the letters in it",
                              abs(hanInk - mixedInk) <= 0.5,
                              String(format: "han ink at %.2f, mixed at %.2f",
                                     hanInk, mixedInk))

                        // MARK: the size control
                        //
                        // The size travels with the text, so a note written
                        // large stays large when the next one is written small.
                        // Both halves are checked: the box changes, and so does
                        // what comes out of the renderer.
                        let large = ImageEdit.textSizes.last ?? 56
                        let smallLine = ImageEdit.textLineHeight()
                        let largeLine = ImageEdit.textLineHeight(at: large)
                        check("a larger size is a taller line",
                              largeLine > smallLine + 4,
                              String(format: "%.0f vs %.0f", smallLine, largeLine))
                        if let ground = flatImage(
                            width: Int(pixels.width), height: Int(pixels.height)),
                           let big = ImageEdit.render(
                            ground, edits: [.text(CGPoint(x: 60, y: 200), "Ag", large)],
                            pointSize: points, cropping: false),
                           let small = ImageEdit.render(
                            ground, edits: [.text(CGPoint(x: 60, y: 200), "Ag",
                                                  ImageEdit.textSize)],
                            pointSize: points, cropping: false),
                           let bigInk = ink(of: big, against: rgba(of: ground)),
                           let smallInk = ink(of: small, against: rgba(of: ground)) {
                            check("and the render honours it",
                                  bigInk.height > smallInk.height * 1.3,
                                  String(format: "%.0f px tall vs %.0f",
                                         bigInk.height, smallInk.height))
                        } else {
                            check("and the render honours it", false, "no render")
                        }

                        // MARK: two lines
                        //
                        // ⏎ breaks the line now and ⌘⏎ finishes, because text on
                        // a screenshot is often two lines and a key that ends the
                        // sentence cannot also break it.
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("A", replacementRange: box.selectedRange())
                        // A real Return, through `keyDown`, because the point of
                        // the check is that nothing between the keyboard and the
                        // box claims that key for something else.
                        if let newline = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            characters: "\r", charactersIgnoringModifiers: "\r",
                            isARepeat: false, keyCode: 36) {
                            box.keyDown(with: newline)
                        }
                        box.insertText("B", replacementRange: box.selectedRange())
                        window.makeFirstResponder(nil)
                        check("⏎ inside the box is a line break", box.string == "A\nB",
                              box.string.replacingOccurrences(of: "\n", with: "⏎"))
                        // Not wrapped, ever: the box grows sideways instead, so
                        // the lines in it are the lines that come out. A box
                        // that wrapped would break where the renderer does not.
                        // A drag-selection used to balloon the box: AppKit
                        // lays a resizable text view out again when the drag
                        // starts, and this one's container is infinitely wide so
                        // that nothing wraps — so the box grew to something like
                        // its container's size with the selection highlight
                        // painted across all of it.
                        //
                        // Checked as the flag rather than by dragging.
                        // `NSTextView.mouseDown` runs its own event-tracking loop
                        // until it sees a real mouse-up, and a synthesised drag
                        // hangs in it forever — the test ran for ten minutes
                        // before it was killed. The flag is the whole cause.
                        // The selection is drawn per line fragment, and the
                        // fragments are as wide as the container — so whatever
                        // the box's own size is, its drawing has to be confined
                        // to it. `NSView` does not do that on its own.
                        check("the box clips its drawing to itself", box.clipsToBounds)

                        check("the box never resizes itself",
                              !box.isHorizontallyResizable && !box.isVerticallyResizable,
                              "h \(box.isHorizontallyResizable) v \(box.isVerticallyResizable)")
                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("21212122112", replacementRange: box.selectedRange())
                        box.insertNewline(nil)
                        box.insertNewline(nil)
                        window.makeFirstResponder(nil)
                        check("and empty lines do not widen it",
                              box.frame.width - inkedWidth(of: box) <= 4,
                              String(format: "%.1f pt box, %.1f pt text",
                                     box.frame.width, inkedWidth(of: box)))

                        // The box hugs its words: a selection fills the line to
                        // the end of the box, so every point of slack is a tail
                        // of highlight hanging off the end of the text.
                        check("the box is no wider than the words in it",
                              box.bounds.width - inkedWidth(of: box) <= 4,
                              String(format: "%.1f pt box, %.1f pt text",
                                     box.bounds.width, inkedWidth(of: box)))

                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText(String(repeating: "wide ", count: 40),
                                       replacementRange: box.selectedRange())
                        window.makeFirstResponder(nil)
                        check("a long line wraps at the picture's edge instead",
                              box.frame.maxX <= points.width + 1
                                && box.bounds.height > ImageEdit.textLineHeight(),
                              String(format: "%.0f×%.0f box ending at %.0f of %.0f",
                                     box.bounds.width, box.bounds.height,
                                     box.frame.maxX, points.width))
                        // And the render breaks it in the same places, which is
                        // the whole reason the box is allowed to wrap at all.
                        let boxLines = box.layoutManager.map { layout -> Int in
                            var count = 0
                            var glyph = 0
                            while glyph < layout.numberOfGlyphs {
                                var effective = NSRange()
                                _ = layout.lineFragmentRect(
                                    forGlyphAt: glyph, effectiveRange: &effective)
                                count += 1
                                glyph = max(effective.upperBound, glyph + 1)
                            }
                            return count
                        } ?? 0
                        let renderLines = ImageEdit.lines(
                            of: box.string, size: ImageEdit.textSize,
                            wrappingAt: points.width - box.frame.minX).count
                        check("and the renderer agrees about where",
                              boxLines == renderLines,
                              "\(boxLines) in the box, \(renderLines) rendered")

                        window.makeFirstResponder(box)
                        box.selectAll(nil)
                        box.insertText("A", replacementRange: box.selectedRange())
                        if let newline2 = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            characters: "\r", charactersIgnoringModifiers: "\r",
                            isARepeat: false, keyCode: 36) {
                            box.keyDown(with: newline2)
                        }
                        box.insertText("B", replacementRange: box.selectedRange())
                        window.makeFirstResponder(nil)

                        check("and the box grows to hold both lines",
                              abs(box.bounds.height - ImageEdit.textLineHeight() * 2) <= 1,
                              String(format: "%.1f pt tall", box.bounds.height))

                        if let ground = flatImage(
                            width: Int(pixels.width), height: Int(pixels.height)),
                           let two = ImageEdit.render(
                            ground, edits: [.text(CGPoint(x: 60, y: 200), "A\nB", ImageEdit.textSize)],
                            pointSize: points, cropping: false),
                           let both = ink(of: two, against: rgba(of: ground)),
                           let one = ImageEdit.render(
                            ground, edits: [.text(CGPoint(x: 60, y: 200), "A", ImageEdit.textSize)],
                            pointSize: points, cropping: false),
                           let single = ink(of: one, against: rgba(of: ground)) {
                            // The second line hangs exactly one line height below
                            // the first, which is what the box was pinned to.
                            let grew = (both.height - single.height) / (pixels.height / points.height)
                            check("the second line renders one line below the first",
                                  abs(grew - ImageEdit.textLineHeight()) <= 1.5,
                                  String(format: "%.1f pt taller, line height %.1f",
                                         grew, ImageEdit.textLineHeight()))
                        } else {
                            check("the second line renders one line below the first",
                                  false, "no render")
                        }
                    // Closed the way Escape does. `perform(Selector(...))` on a
                    // Swift method that is not `@objc` is a crash waiting for a
                    // test run, and it got one; `cancelOperation` is AppKit's
                    // own and the box overrides it.
                    box.cancelOperation(nil)
                }
                editor.undoForTest()

                // MARK: a click while typing is a full stop
                //
                // Clicking away from a note finishes it. It used to finish it
                // *and* open the next box where the click landed, which left an
                // empty box behind every time anyone clicked off a note.
                if let open = openField(at: CGPoint(x: 320, y: 320),
                                        on: canvas, in: window) {
                    open.insertText("done", replacementRange: open.selectedRange())
                    let elsewhere = NSEvent.mouseEvent(
                        with: .leftMouseDown,
                        location: canvas.convert(CGPoint(x: 120, y: 120), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)
                    if let elsewhere { canvas.mouseDown(with: elsewhere) }
                    let committed = editor.editsForTest.last
                    var landed = false
                    if case .text(_, let string, _) = committed { landed = string == "done" }
                    check("clicking away commits what was being typed", landed,
                          committed.map { "\($0)" } ?? "nothing")
                    // The box that is gone is the point: the click was a full
                    // stop, and a full stop does not open a new box.
                    check("and does not open another box",
                          firstTextBox(in: canvas)?.isEditable != true)
                    while !editor.editsForTest.isEmpty { editor.undoForTest() }
                    // The committed words stand in for themselves until the
                    // render lands; without waiting for it, the next check finds
                    // that stand-in and reads it as an open box.
                    await editor.flushForTest()
                }

                // MARK: the hover highlight
                //
                // Clicking a piece of text to correct it is not a thing anyone
                // would guess at, so the pointer passing over one has to light
                // it up. Driven as a real mouse-moved event, because the
                // tracking area and the hit test are the two halves that have
                // to meet.
                editor.addEditForTest(.text(CGPoint(x: 200, y: 150), "hover me",
                                            ImageEdit.textSize))
                if let moved = NSEvent.mouseEvent(
                    with: .mouseMoved, location: canvas.convert(CGPoint(x: 210, y: 152), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0) {
                    canvas.mouseMoved(with: moved)
                }
                check("the pointer over a piece of text lights it up",
                      editor.hoverForTest != nil,
                      editor.hoverForTest.map(rectString) ?? "nothing lit")
                if let away = NSEvent.mouseEvent(
                    with: .mouseMoved, location: canvas.convert(CGPoint(x: 500, y: 350), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0) {
                    canvas.mouseMoved(with: away)
                }
                check("and goes dark again when it moves off",
                      editor.hoverForTest == nil,
                      editor.hoverForTest.map(rectString) ?? "dark")
                while !editor.editsForTest.isEmpty { editor.undoForTest() }

                // MARK: dragging a piece of text
                //
                // A press on text is a click *or* a drag, and which one it is is
                // not known until the pointer moves. Four points of travel is
                // the line between them.
                editor.addEditForTest(.text(CGPoint(x: 200, y: 150), "move me",
                                            ImageEdit.textSize))
                let steps = editor.editsForTest.count
                drag(canvas, from: CGPoint(x: 210, y: 152),
                     to: CGPoint(x: 260, y: 122), in: window)
                if case .text(let moved, let string, _) = editor.editsForTest.last {
                    check("dragging text moves it",
                          string == "move me"
                            && abs(moved.x - 250) < 1 && abs(moved.y - 120) < 1,
                          String(format: "%@ at %.0f,%.0f", string as NSString,
                                 moved.x, moved.y))
                } else {
                    check("dragging text moves it", false, "no text")
                }
                check("and it is one step, not a delete and a re-add",
                      editor.editsForTest.count == steps,
                      "\(steps) -> \(editor.editsForTest.count)")
                check("and the box did not open",
                      firstTextBox(in: canvas) == nil)
                while !editor.editsForTest.isEmpty { editor.undoForTest() }
                await editor.flushForTest()

                // MARK: opening a box does not move the picture
                //
                // A text view asks to be scrolled into view when it takes the
                // keyboard, and this one lives inside the scroll view that holds
                // the capture — so opening a box near an edge slid the whole
                // picture. Seen from outside, the text jumps the moment you
                // click it.
                editor.addEditForTest(.text(CGPoint(x: 40, y: 40), "near the edge",
                                            ImageEdit.textSize))
                await editor.flushForTest()
                let restingScroll = editor.scrollOriginForTest
                _ = openField(at: CGPoint(x: 60, y: 30), on: canvas, in: window)
                check("opening a box near the edge does not scroll the picture",
                      abs(editor.scrollOriginForTest.x - restingScroll.x) < 0.5
                        && abs(editor.scrollOriginForTest.y - restingScroll.y) < 0.5,
                      String(format: "%.1f,%.1f -> %.1f,%.1f",
                             restingScroll.x, restingScroll.y,
                             editor.scrollOriginForTest.x, editor.scrollOriginForTest.y))
                if let open = firstTextBox(in: canvas) { open.cancelOperation(nil) }
                while !editor.editsForTest.isEmpty { editor.undoForTest() }
                await editor.flushForTest()

                // MARK: opening a piece of text again
                //
                // An annotation you can only make and never fix is half a
                // feature, and the undo stack is not an editing tool. Clicking
                // text with the text tool takes it back out of the list and puts
                // it in a box, holding the same words in the same place.
                editor.addEditForTest(.text(CGPoint(x: 200, y: 150), "typo", ImageEdit.textSize))
                let held = editor.editsForTest.count
                if let reopened = openField(at: CGPoint(x: 210, y: 152),
                                            on: canvas, in: window) {
                    check("clicking text opens it again", reopened.string == "typo",
                          reopened.string)
                    check("and takes it out of the list while it is being edited",
                          editor.editsForTest.count == held - 1,
                          "\(held) -> \(editor.editsForTest.count)")
                    reopened.setSelectedRange(NSRange(location: 4, length: 0))
                    reopened.insertText("!", replacementRange: reopened.selectedRange())
                    commitTyping(reopened, in: window)
                    if case .text(let anchor, let string, _) = editor.editsForTest.last {
                        check("the correction lands where the original was",
                              string == "typo!"
                                && abs(anchor.x - 200) < 0.01 && abs(anchor.y - 150) < 0.01,
                              String(format: "%@ at %.1f,%.1f", string as NSString,
                                     anchor.x, anchor.y))
                    } else {
                        check("the correction lands where the original was", false, "no text")
                    }
                } else {
                    check("clicking text opens it again", false, "nothing opened")
                }
                // Wound all the way back rather than a fixed number of times:
                // re-opening a piece of text is two entries in the history — the
                // removal and the retyping — and counting them here is how the
                // checks after this one started reading someone else's list.
                while !editor.editsForTest.isEmpty { editor.undoForTest() }
            } else {
                check("clicking with the text tool opens a field", false, "no canvas")
            }
            // MARK: the crop frame
            //
            // The crop tool holds a frame rather than asking for a rectangle to
            // be drawn: with nothing cropped yet the frame is the whole picture,
            // and its corners are what get pulled. One drag must leave one entry
            // on the undo stack, not one per mouse-moved event.
            press("c", on: editor, in: window)
            if let canvas = editor.hitTest(CGPoint(x: 200, y: 200)) {
                let before = editor.editsForTest.count
                drag(canvas, from: CGPoint(x: 598, y: 398),
                     to: CGPoint(x: 400, y: 300), in: window)
                let cropped = editor.editsForTest.last?.cropRect
                let wanted = CGRect(x: 0, y: 0, width: 400, height: 300)
                check("dragging a corner crops from that corner",
                      cropped.map { abs($0.width - wanted.width) < 1
                          && abs($0.height - wanted.height) < 1
                          && abs($0.minX) < 1 && abs($0.minY) < 1 } ?? false,
                      cropped.map(rectString) ?? "no crop")
                check("and the whole drag is one entry on the stack",
                      editor.editsForTest.count == before + 1,
                      "\(before) -> \(editor.editsForTest.count)")
                editor.undoForTest()
            } else {
                check("dragging a corner crops from that corner", false, "no canvas")
            }

            // MARK: the highlighter, from the button to the list
            //
            // The render check further down proves the renderer. This proves
            // there is a road to it. A tool can have a correct flattening path,
            // a pill in the bar and a key of its own and still be dead — which
            // is exactly how Redact shipped broken with every geometry
            // assertion about it green.
            if let pill = editor.pillFrameForTest(.highlight) {
                let centre = CGPoint(x: pill.midX, y: pill.midY)
                click(editor.hitTest(centre), at: editor.convert(centre, to: nil), in: window)
                check("clicking the highlighter's pill arms it",
                      editor.toolForTest == .highlight, "\(editor.toolForTest)")
            } else {
                check("the bar has a highlighter pill", false, "no pill")
            }
            press("v", on: editor, in: window)
            press("h", on: editor, in: window)
            check("and H does the same", editor.toolForTest == .highlight,
                  "\(editor.toolForTest)")
            if let canvas = editor.hitTest(CGPoint(x: 200, y: 200)) {
                let before = editor.editsForTest.count
                drag(canvas, from: CGPoint(x: 100, y: 100),
                     to: CGPoint(x: 300, y: 180), in: window)
                if case .highlight(let rect) = editor.editsForTest.last {
                    check("dragging leaves a highlight over what was dragged over",
                          abs(rect.minX - 100) < 1 && abs(rect.minY - 100) < 1
                            && abs(rect.width - 200) < 1 && abs(rect.height - 80) < 1,
                          rectString(rect))
                } else {
                    check("dragging leaves a highlight over what was dragged over", false,
                          editor.editsForTest.last.map { "\($0)" } ?? "no edit")
                }
                check("and the whole drag is one entry on the stack",
                      editor.editsForTest.count == before + 1,
                      "\(before) -> \(editor.editsForTest.count)")
                editor.undoForTest()
            } else {
                check("dragging with the highlighter leaves an edit", false, "no canvas")
            }

            press("r", on: editor, in: window)
            window.orderOut(nil)
            window.contentView = nil
        }

        // MARK: the list
        //
        // The reason any of this is undoable: an edit is an entry, not a write.
        editor.addEditForTest(.redact(drawn))
        editor.addEditForTest(.marker(CGPoint(x: 420, y: 300)))
        check("two gestures make two edits", editor.editsForTest.count == 2,
              "\(editor.editsForTest.count)")
        check("editor scales the drawn rect the same way",
              editor.pixelRegionsForTest == [expected],
              "\(rectString(editor.pixelRegionsForTest.first ?? .zero))")
        editor.undoForTest()
        check("⌘Z takes the last one back", editor.editsForTest == [.redact(drawn)],
              "\(editor.editsForTest.count) left")
        editor.redoForTest()
        check("⇧⌘Z puts it back", editor.editsForTest.count == 2,
              "\(editor.editsForTest.count)")
        editor.undoForTest()
        editor.addEditForTest(.crop(CGRect(x: 50, y: 25, width: 300, height: 200)))
        editor.redoForTest()
        // Undo then draw is a new branch, and the redone marker must not come
        // back from the dead on top of it.
        check("a new edit discards what was undone",
              editor.editsForTest.count == 2 && editor.editsForTest.last?.cropRect != nil,
              "\(editor.editsForTest.count) edits, last is \(editor.editsForTest.last.map { "\($0)" } ?? "none")")

        // MARK: the write

        let before = rgba(of: original)
        let sourceBytes = try Data(contentsOf: file)
        let exported = ImageEdit.exportURL(besides: file)
        _ = try await ImageEdit.export(
            [.redact(drawn)], of: sourceBytes, pointSize: points, to: exported)

        check("the export is named after the capture",
              exported.lastPathComponent == "edit-sample (edited).png",
              exported.lastPathComponent)
        // The whole point of exporting rather than overwriting.
        check("and the capture itself is untouched",
              (try? Data(contentsOf: file)) == sourceBytes)

        guard let source = CGImageSourceCreateWithURL(exported as CFURL, nil),
              let written = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            print("result:        FAIL — the redacted file cannot be read back")
            return 1
        }
        let after = rgba(of: written)

        check("still a PNG",
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier)
        check("still \(Int(pixels.width))×\(Int(pixels.height)) px",
              written.width == Int(pixels.width) && written.height == Int(pixels.height))
        // The DPI tag is what stands between a 2× capture and being shown at
        // double size everywhere afterwards.
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double
        check("kept its 144 dpi tag", dpi == 144, "got \(dpi.map { "\($0)" } ?? "none")")
        check("still opens at \(Int(points.width))×\(Int(points.height)) pt",
              NSImage(contentsOf: exported)?.size == points)

        // MARK: the pixels

        let width = written.width
        let block = Redaction.blockSize(width: written.width, height: written.height)
        /// Row indices from the top, which is how the bitmap is laid out; the
        /// region is in CoreGraphics' bottom-left space.
        let rows = (top: written.height - Int(expected.maxY),
                    bottom: written.height - Int(expected.minY))
        let columns = (left: Int(expected.minX), right: Int(expected.maxX))

        func sample(_ bytes: [UInt8], _ row: Int, _ column: Int) -> [UInt8] {
            let index = (row * width + column) * 4
            return Array(bytes[index..<index + 4])
        }

        var changed = 0
        var ragged = 0
        for row in rows.top..<rows.bottom {
            for column in columns.left..<columns.right {
                if sample(before, row, column) != sample(after, row, column) { changed += 1 }
                // Every pixel of a block must equal that block's top-left one.
                let anchor = (
                    row: rows.top + (row - rows.top) / block * block,
                    column: columns.left + (column - columns.left) / block * block)
                if sample(after, row, column) != sample(after, anchor.row, anchor.column) {
                    ragged += 1
                }
            }
        }
        let area = (rows.bottom - rows.top) * (columns.right - columns.left)
        // Not "most of them": a single surviving pixel of the original is a
        // pixel of whatever was worth hiding.
        check("every pixel under the rect changed", changed == area,
              "\(changed)/\(area)")
        check("the rect is \(block)px blocks of one colour", ragged == 0,
              "\(ragged) stray pixels")

        var outside = 0
        for row in 0..<written.height where row < rows.top || row >= rows.bottom {
            for column in stride(from: 0, to: width, by: 7)
            where sample(before, row, column) != sample(after, row, column) {
                outside += 1
            }
        }
        check("nothing outside the rect moved", outside == 0, "\(outside) pixels differ")

        // The whole point of averaging rather than blurring: a blur leaves the
        // stripes' period in the data, an average does not.
        let strip = (columns.left..<columns.right).map { sample(after, rows.top + 1, $0)[0] }
        let distinct = Set(strip).count
        check("no structure survives across the rect", distinct <= (columns.right - columns.left) / block + 1,
              "\(distinct) distinct values across \(strip.count) px")

        // MARK: the preview is the output
        //
        // Not "looks like": the same bytes. The editor shows the picture that
        // `render` produces and Apply writes the picture that `render` produces,
        // and this is the only check that can tell the difference between that
        // being true and being intended.
        let previewed = ImageEdit.render(
            original, edits: [.redact(drawn)], pointSize: points, cropping: false)
        check("the preview render is the written bitmap",
              previewed.map { rgba(of: $0) == after } ?? false)

        // MARK: the other three tools
        //
        // Pure renders against the pristine bitmap: what each one puts on the
        // picture, and — as much as matters — what it leaves alone.
        func changedPixels(_ edits: [ImageEdit], in box: CGRect) -> Int {
            guard let rendered = ImageEdit.render(
                original, edits: edits, pointSize: points, cropping: false) else { return -1 }
            let bytes = rgba(of: rendered)
            var count = 0
            for row in Int(pixels.height - box.maxY)..<Int(pixels.height - box.minY) {
                for column in Int(box.minX)..<Int(box.maxX)
                where sample(before, row, column) != sample(bytes, row, column) {
                    count += 1
                }
            }
            return count
        }

        let marker = CGPoint(x: 300, y: 200)
        let markerBox = CGRect(
            x: (marker.x - ImageEdit.markerRadius) * 2, y: (marker.y - ImageEdit.markerRadius) * 2,
            width: ImageEdit.markerRadius * 4, height: ImageEdit.markerRadius * 4)
        check("a marker draws inside its own circle",
              changedPixels([.marker(marker)], in: markerBox) > 0)
        check("and nowhere else",
              changedPixels([.marker(marker)], in: CGRect(x: 0, y: 0, width: 100, height: 100)) == 0)

        // The anchor is the top of the first line, so the ink hangs *below* it.
        let textAt = CGPoint(x: 100, y: 300)
        check("text draws where it was typed",
              changedPixels([.text(textAt, "SECRET", ImageEdit.textSize)],
                      in: CGRect(x: textAt.x * 2, y: (textAt.y - 26) * 2,
                                 width: 300, height: 56)) > 0)
        check("and nowhere else",
              changedPixels([.text(textAt, "SECRET", ImageEdit.textSize)],
                      in: CGRect(x: 0, y: 0, width: 100, height: 100)) == 0)

        // Where the ink actually starts, in pixels, against the point that was
        // asked for. The model's point is the left end of the baseline and the
        // text field is placed to match it, so this is the number that says
        // whether what you type sits where you clicked — and whether ⏎ moves it.
        if let inked = ImageEdit.render(
            original, edits: [.text(textAt, "H", ImageEdit.textSize)], pointSize: points, cropping: false) {
            let bytes = rgba(of: inked)
            var left = Int.max, bottom = -1
            for row in 0..<inked.height {
                for column in 0..<inked.width
                where sample(before, row, column) != sample(bytes, row, column) {
                    left = min(left, column)
                    bottom = max(bottom, row)
                }
            }
            // The bitmap's rows run from the top; this is a row index from the
            // bottom. The anchor is the top of the line box, so "H" — which has
            // no descender — puts its baseline one rounded (lineHeight −
            // descent) below it, and its ink no lower than that plus the shadow.
            let lowest = CGFloat(inked.height - bottom)
            let wanted = CGPoint(x: textAt.x * 2, y: textAt.y * 2)
            let baseline = wanted.y
                - (ImageEdit.textLineHeight() - 4.22).rounded() * 2
            let drop = baseline - lowest
            check("the first line hangs from the point that was clicked",
                  abs(CGFloat(left) - wanted.x) <= 6 && drop >= -2 && drop <= 10,
                  String(format: "ink at %d,%.0f px, baseline wanted %.0f (%.0f of shadow)",
                         left, lowest, baseline, drop))
        } else {
            check("the baseline lands on the point that was clicked", false, "no render")
        }

        let crop = CGRect(x: 50, y: 25, width: 300, height: 200)
        let cropped = ImageEdit.render(
            original, edits: [.crop(crop)], pointSize: points, cropping: true)
        check("a crop cuts the bitmap to the drawn rect at 2×",
              cropped.map { $0.width == 600 && $0.height == 400 } ?? false,
              cropped.map { "\($0.width)×\($0.height)" } ?? "nothing")
        let uncropped = ImageEdit.render(
            original, edits: [.crop(crop)], pointSize: points, cropping: false)
        check("and the preview keeps the whole picture",
              uncropped.map { $0.width == Int(pixels.width) && $0.height == Int(pixels.height) }
                ?? false,
              uncropped.map { "\($0.width)×\($0.height)" } ?? "nothing")

        // MARK: the zoom lands on a whole fraction
        //
        // A screenshot shown at 0.62 has every pixel resampled into a fraction of
        // a screen pixel, and the words being typed — drawn live at screen
        // resolution — end up on a different subpixel phase from the same words
        // already committed into the picture. One pixel per glyph, about one per
        // cent over a line, and it reads as the text loosening while you type.
        check("a fit near a whole fraction snaps to it",
              abs(ZoomingScrollView.snapped(0.55) - 0.5) < 0.001
                && abs(ZoomingScrollView.snapped(0.34) - 1.0 / 3) < 0.001,
              String(format: "0.55 -> %.3f, 0.34 -> %.3f",
                     ZoomingScrollView.snapped(0.55), ZoomingScrollView.snapped(0.34)))
        check("and one that is not stays where it is",
              abs(ZoomingScrollView.snapped(0.9) - 0.9) < 0.001
                && abs(ZoomingScrollView.snapped(1) - 1) < 0.001,
              String(format: "0.9 -> %.3f", ZoomingScrollView.snapped(0.9)))

        check("an empty list is not an edit",
              ImageEdit.render(original, edits: [], pointSize: points, cropping: true) == nil)

        // The three callout tools share gesture plumbing but have separate
        // flattening paths. Prove each one changes pixels on its own so a toolbar
        // button cannot appear functional while exporting nothing.
        let callouts: [(String, ImageEdit)] = [
            ("line", .line(CGPoint(x: 40, y: 40), CGPoint(x: 260, y: 160))),
            ("arrow", .arrow(CGPoint(x: 40, y: 160), CGPoint(x: 260, y: 40))),
            ("rectangle", .rectangle(CGRect(x: 60, y: 50, width: 180, height: 100))),
        ]
        for (name, edit) in callouts {
            let rendered = ImageEdit.render(
                original, edits: [edit], pointSize: points, cropping: true)
            check("the \(name) tool is flattened into the output",
                  rendered.map { !PixelCompare.compare($0, original).identical } == true)
        }

        // MARK: the highlighter tints without hiding
        //
        // "Changed some pixels" is what the callouts above settle for, and it is
        // not enough here: a plain filled rectangle would pass it while being
        // the one thing a highlighter must never be. The property under test is
        // the physical object's — ink over white leaves colour, ink over black
        // leaves black — which is what `.multiply` gives and what alpha does
        // not. Yellow at 0.4 over black lifts it to a muddy olive around 102,
        // and `darkestStayedDark` is the number that catches it.
        //
        // `stripedImage` is 2 px of black every 4, so one rectangle covers
        // thousands of each kind of pixel and neither sample can be a fluke.
        let band = CGRect(x: 40, y: 40, width: 300, height: 120)
        if let lit = ImageEdit.render(
            original, edits: [.highlight(band)], pointSize: points, cropping: true) {
            let after = rgba(of: lit)
            let stride = lit.width * 4
            var litWhites = 0
            var survivingInk = 0
            var muddied: (r: Int, g: Int, b: Int)?
            // Bitmap rows run from the top; the band is in bottom-left space.
            for row in (lit.height - Int(band.maxY) * 2)..<(lit.height - Int(band.minY) * 2) {
                for column in (Int(band.minX) * 2)..<(Int(band.maxX) * 2) {
                    let i = row * stride + column * 4
                    let r = Int(after[i]), g = Int(after[i + 1]), b = Int(after[i + 2])
                    if r > 200 && g > 180 && b < 90 {
                        litWhites += 1
                    } else if r < 60 && g < 60 && b < 60 {
                        survivingInk += 1
                    } else if muddied == nil {
                        // Neither the tint nor the ink: the wash has moved a
                        // pixel that should have been left where it was. Keep
                        // the first one, so a failure says what it looked like.
                        muddied = (r, g, b)
                    }
                }
            }
            check("the highlighter tints the paper", litWhites > 10_000,
                  "\(litWhites) tinted, \(survivingInk) still ink"
                  + (muddied.map { ", first muddied pixel \($0.r),\($0.g),\($0.b)" } ?? ""))
            check("and leaves the ink under it alone",
                  muddied == nil && survivingInk > 10_000,
                  muddied.map { "ink came back as \($0.r),\($0.g),\($0.b)" }
                    ?? "\(survivingInk) ink pixels untouched")
        } else {
            check("the highlighter renders", false, "nothing came back")
        }

        // MARK: applying a crop, through the editor
        //
        // The one edit that changes what "the picture" is. Driven through the
        // view because the resize afterwards — canvas, document, zoom — is the
        // part no pure render can be wrong about and the window can.
        let cropFile = directory.appendingPathComponent("edit-crop.png")
        try ImageEncoder.write(original, to: cropFile, as: .png, scale: 2)
        // Kept aside so "back to the original" can be checked as bytes rather
        // than as a size that happens to match.
        let cropSource = directory.appendingPathComponent("edit-crop-source.png")
        try? FileManager.default.removeItem(at: cropSource)
        try FileManager.default.copyItem(at: cropFile, to: cropSource)
        if let cropImage = NSImage(contentsOf: cropFile),
           let cropEditor = ImageEditor(
            url: cropFile, image: cropImage, menu: NSMenu(),
            frame: CGRect(origin: .zero, size: points)) {
            cropEditor.addEditForTest(.crop(crop))
            await cropEditor.flushForTest()
            check("a crop takes effect without anything being confirmed",
                  cropEditor.pointSizeForTest == crop.size,
                  "got \(sizeString(cropEditor.pointSizeForTest))")
            check("and the capture on disk has not moved",
                  (try? Data(contentsOf: cropFile)) == (try? Data(contentsOf: cropSource)))

            // Copy is the only thing that writes: a new file beside the capture,
            // and the same picture on the clipboard.
            NSPasteboard.general.clearContents()
            await cropEditor.copyForTest()
            let copied = ImageEdit.exportURL(besides: cropFile)
                .deletingLastPathComponent()
                .appendingPathComponent("edit-crop (edited).png")
            check("Copy writes the edited picture beside it",
                  NSImage(contentsOf: copied)?.size == crop.size,
                  "got \(NSImage(contentsOf: copied).map { sizeString($0.size) } ?? "nothing")")
            check("and puts it on the clipboard",
                  NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.isEmpty == false)
            check("and still has not touched the capture",
                  (try? Data(contentsOf: cropFile)) == (try? Data(contentsOf: cropSource)))

            cropEditor.undoForTest()
            await cropEditor.flushForTest()
            check("⌘Z puts the whole picture back on screen",
                  cropEditor.pointSizeForTest == points,
                  "got \(sizeString(cropEditor.pointSizeForTest))")
        } else {
            check("a crop takes effect without anything being confirmed", false, "no editor")
        }

        // MARK: the picture of it
        //
        // Numbers cannot say whether a marker is legible or whether the bar has
        // run off the end of the window, and this editor is four tools now. The
        // photograph is the only part of this test a person has to look at, so it
        // is taken through the real window with the real tools open over a real
        // render.
        if ScreenPermission.isGranted {
            try await photographEditor(over: original, pointSize: points, into: directory)
        } else {
            print("photo:         skipped — no screen-recording permission")
        }

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// Trimming a recording: the export, the replace, and what is left behind.
    ///
    /// Drives `VideoTrimEditor.trimForTest` rather than the handles, because the
    /// handles are AVKit's — `beginTrimming` blocks on a person dragging them,
    /// and a test that could drive that would be testing the system's UI. What
    /// belongs to DuoShot starts at the range and ends at the file, and that is
    /// exactly the span checked here.
    ///
    /// Against a real recording rather than a synthetic asset: the thing most
    /// likely to break is the interaction between a passthrough export and what
    /// `RecordingEngine` actually writes — keyframe spacing, the container, the
    /// `moov` position — and none of that survives being faked.
    private static func trimCheck(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }

        var failures: [String] = []
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures.append(label) }
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        let clip = directory.appendingPathComponent("trim-clip.mp4")
        try? FileManager.default.removeItem(at: clip)
        let recorder = RecordingEngine()
        var options = RecordingOptions.default
        options.capturesSystemAudio = false
        _ = try await recorder.start(
            .area(displayID: displayID, rectInAppKitGlobal:
                    CGRect(x: 200, y: 200, width: 640, height: 360)),
            options: options, to: clip)
        try await Task.sleep(for: .seconds(5))
        let recording = try await recorder.stop()

        let before = CMTimeGetSeconds(
            (try? await AVURLAsset(url: recording.url).load(.duration)) ?? .zero)
        let sizeBefore = fileSize(recording.url)
        print("recorded:      \(recording.url.lastPathComponent) "
            + String(format: "%.2fs, %d bytes", before, sizeBefore))
        guard before > 3 else {
            print("result:        INCONCLUSIVE — the take is too short to trim")
            return 0
        }

        let viewer = ViewerWindowController.shared
        viewer.activatesOnShow = false
        defer { viewer.closeAll() }
        var posterURL: URL?
        viewer.onVideoTrimmed = { url, _ in posterURL = url }

        let poster = await VideoPoster.frame(for: recording.url) ?? VideoPoster.placeholder()
        let entry = PreviewEntry(
            OutputPipeline.RecordingOutput(result: recording, url: recording.url, wasSaved: false),
            poster: poster)
        viewer.show(entry)
        try await Task.sleep(for: .milliseconds(600))

        guard let editor = viewer.trimEditorForTest(recording.url) else {
            print("result:        FAIL — the recording did not open in a trim editor")
            return 1
        }

        // MARK: the GIF button, pressed
        //
        // `--selftest-gif` proves the exporter. This proves there is a button
        // wired to it: a pill can sit in the bar, hit-test correctly and be
        // connected to nothing, which is exactly how the Redact button once
        // shipped dead with every geometry assertion about it green.
        //
        // Before the trim, because the trim rewrites this file underneath it.
        if let window = viewer.windowForTest(recording.url) {
            editor.layoutSubtreeIfNeeded()
            let gifFile = GIFExport.url(besides: recording.url)
            try? FileManager.default.removeItem(at: gifFile)
            let pill = editor.gifPillFrameForTest
            let centre = CGPoint(x: pill.midX, y: pill.midY)
            let hit = editor.hitTest(centre)
            check("the GIF button hit-tests to a visible pill",
                  (hit as? HUDPill).map { !$0.isHidden } ?? false,
                  hit.map { "\(type(of: $0))" } ?? "nothing")
            click(hit, at: editor.convert(centre, to: nil), in: window)
            // Polled rather than slept on: the export is off the main actor and
            // its length depends on the clip, so a fixed wait is either flaky or
            // slow. Same reasoning as `--selftest-copy-text`'s pasteboard poll.
            for _ in 0..<150 where !FileManager.default.fileExists(atPath: gifFile.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let wrote = FileManager.default.fileExists(atPath: gifFile.path)
            check("pressing it writes the GIF", wrote,
                  wrote ? "\(fileSize(gifFile)) bytes" : "nothing appeared at \(gifFile.path)")
            check("and leaves the recording alone",
                  FileManager.default.fileExists(atPath: recording.url.path))
            // Busy is shared with the trim, and the trim below would be exporting
            // out of a file this one is still reading if it were not released.
            for _ in 0..<50 where editor.isExportingForTest {
                try await Task.sleep(for: .milliseconds(100))
            }
            check("and gives the bar back when it is done", !editor.isExportingForTest)
        } else {
            check("the GIF button writes a GIF", false, "no window")
        }

        // MARK: the cut

        // A range that touches neither end, so a trim that silently did nothing
        // and one that kept the head or the tail are all distinguishable from a
        // trim that worked.
        let wanted = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 600),
            end: CMTime(seconds: 3, preferredTimescale: 600))

        // MARK: the bar's width, across the busy state
        //
        // Reported as "trim 后顶部的 trim button 变长了": the strip stays at the
        // width it needed while it was saying "Rewriting the recording…", with
        // the button back at its left end and the rest of it empty. The layout
        // passes below are not the test staging something artificial — the real
        // path sets `needsLayout` and enters the busy state in that order, and
        // the window's own display cycle flushes it while the export runs.
        editor.layoutSubtreeIfNeeded()
        let restingWidth = editor.barFrameForTest.width
        editor.trimForTest(wanted)
        editor.layoutSubtreeIfNeeded()
        let busyWidth = editor.barFrameForTest.width
        // Without this the width check below cannot fail: a bar that never
        // widens for the hint has nothing to shrink back from.
        check("the bar widens for the progress hint", busyWidth > restingWidth + 1,
              String(format: "%.0fpt resting, %.0fpt busy", restingWidth, busyWidth))

        for _ in 0..<200 where editor.isExportingForTest {
            try await Task.sleep(for: .milliseconds(100))
        }
        check("the export finished", !editor.isExportingForTest)

        // A display cycle, which is all the window gets on screen too — and not
        // a layout the test forces: `layoutSubtreeIfNeeded` lays out only what
        // has *asked* for it, and the bug is precisely that leaving the busy
        // state asks nobody. It stays red with the line below in place.
        try await Task.sleep(for: .milliseconds(200))
        editor.layoutSubtreeIfNeeded()
        check("the bar is its old width again", editor.barFrameForTest.width == restingWidth,
              String(format: "%.0fpt now, %.0fpt before the trim",
                     editor.barFrameForTest.width, restingWidth))

        let after = CMTimeGetSeconds(
            (try? await AVURLAsset(url: recording.url).load(.duration)) ?? .zero)
        print("trimmed:       " + String(format: "%.2fs -> %.2fs", before, after))

        // Generously bounded, and deliberately not an equality. A passthrough
        // export cuts on sync frames, so the result is allowed to start earlier
        // than asked and therefore to run longer than the two seconds requested;
        // what must not happen is the whole take surviving.
        check("shorter than the take", after < before - 0.5,
              String(format: "%.2fs", after))
        check("about the requested span", after >= 1.5 && after <= before - 0.5,
              String(format: "%.2fs for a 2.00s request", after))
        check("the file was replaced in place, not renamed",
              FileManager.default.fileExists(atPath: recording.url.path))
        // Not "smaller", which this cannot promise: a screen that does not move
        // costs almost nothing per second, so the seconds thrown away can weigh
        // nothing at all — measured, a 5s take of a still desktop and its own
        // middle two seconds came out within bytes of each other. What can be
        // promised is that a cut never *adds* media, and the slack is the
        // container's own index moving to the front.
        check("no larger on disk", fileSize(recording.url) <= sizeBefore + 4096,
              "\(fileSize(recording.url)) vs \(sizeBefore) bytes")

        // MARK: what it left behind

        // The export writes a dot-prefixed sibling and swaps it in. One left
        // lying next to the recording is a whole second copy of a take the user
        // asked to make shorter.
        let strays = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path))?.filter { $0.hasPrefix(".duoshot-trim-") } ?? []
        check("no temporary file left beside it", strays.isEmpty, strays.joined(separator: ", "))

        // The link path re-checks this and would remux again at upload time, so
        // a trimmed file that lost its front `moov` costs the whole file's worth
        // of work twice.
        let fastStart = MP4Layout.isFastStart(recording.url)
        check("still faststart", fastStart != false,
              fastStart.map { $0 ? "moov first" : "moov at the end" } ?? "not parseable")

        // MARK: the window

        check("the card was told", posterURL == recording.url,
              posterURL?.lastPathComponent ?? "no callback")
        let reloaded = CMTimeGetSeconds(
            editor.playerView.player?.currentItem?.duration ?? .zero)
        check("the player reloaded the trimmed file", abs(reloaded - after) < 0.2,
              String(format: "player says %.2fs, file says %.2fs", reloaded, after))

        for failure in failures { print("FAIL:          \(failure)") }
        print("result:        \(failures.isEmpty ? "PASS" : "FAIL")")
        return failures.isEmpty ? 0 : 1
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? Int } ?? 0
    }

    /// A press and a release on `view`, at a point in window coordinates.
    ///
    /// Sent to the view directly rather than through `NSApp.sendEvent`, which
    /// needs a key window and an event loop the headless tests do not run. The
    /// part worth testing is the one before this — whatever `hitTest` handed
    /// back — so what matters is that both halves go to the same view, the way
    /// AppKit's own mouse-down view does it.
    private static func click(_ view: NSView?, at point: CGPoint, in window: NSWindow) {
        guard let view else { return }
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: phase, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if phase == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
    }

    /// Opens the editor on a fresh copy of the sample, puts one of every tool on
    /// it, and photographs the window.
    ///
    /// A real screen capture rather than `cacheDisplay(in:to:)`: the toolbar is
    /// an `NSGlassEffectView`, whose material is composited by the window server
    /// and comes out of an offscreen redraw as nothing at all.
    private static func photographEditor(
        over image: CGImage, pointSize: CGSize, into directory: URL
    ) async throws {
        let file = directory.appendingPathComponent("edit-scene.png")
        try ImageEncoder.write(image, to: file, as: .png, scale: 2)
        guard let opened = NSImage(contentsOf: file),
              let editor = ImageEditor(
                url: file, image: opened, menu: NSMenu(),
                frame: CGRect(origin: .zero, size: CGSize(
                    width: pointSize.width,
                    height: pointSize.height + ImageEditor.chromeHeight)))
        else {
            print("photo:         skipped — the editor would not open the copy")
            return
        }

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        guard let screen = ScreenIndex.screen(for: displayID) ?? NSScreen.main else { return }

        // The picture's size plus the editor's own band, the way the viewer
        // builds it — a window sized to the picture alone would photograph the
        // toolbar eating into the capture, which is the thing this band exists
        // to stop.
        // Sized so the picture is shown at exactly 1:1 — the same margin the
        // viewer's own band leaves. Anything smaller displays the capture scaled
        // down, and a scaled-down picture hides sub-pixel disagreements between
        // the box and the render behind its own resampling.
        let margin = ZoomingScrollView.fitPadding * 2
        let box = CGSize(
            width: pointSize.width + margin,
            height: pointSize.height + margin + ImageEditor.chromeHeight)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: box),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "edit-scene.png"
        window.contentView = editor
        window.setFrameOrigin(CGPoint(
            x: (screen.frame.midX - box.width / 2).rounded(),
            y: (screen.frame.midY - box.height / 2).rounded()))
        window.orderFrontRegardless()
        editor.layoutSubtreeIfNeeded()
        editor.zoomToFit()

        editor.chooseForTest(.crop)
        editor.addEditForTest(.redact(CGRect(x: 60, y: 250, width: 220, height: 60)))
        editor.addEditForTest(.marker(CGPoint(x: 330, y: 280)))
        editor.addEditForTest(.text(CGPoint(x: 60, y: 150), "撒 before it leaves", ImageEdit.textSize))

        // The same words twice, side by side on the same line: once committed
        // into the picture, once still in the box.
        //
        // Photographed rather than measured through the views, and that is the
        // point. `cacheDisplay` — which every earlier version of this check used
        // — lays the text view out again into an offscreen context and *changes
        // its frame while doing it*: a box measured that way came back 1.4
        // points taller than it is on screen. Every number this check produced
        // for three rounds was an artefact of taking it. A screen capture is
        // what the person looking at the window sees.
        editor.chooseForTest(.text)
        let reportedText = "啊酒酒水酒酒水 SAAS"
        let reportedSize: CGFloat = 40
        editor.addEditForTest(.text(CGPoint(x: 30, y: 300), reportedText, reportedSize))
        await editor.flushForTest()

        // Each edit is a decode and a render off the main actor; this is the one
        // place in the test that has to wait for all of them to land.
        try await Task.sleep(for: .milliseconds(900))

        // MARK: committed, then re-opened, photographed both times
        //
        // The state the screen recording caught: click a piece of text to
        // correct it and the words move. Measured where it happens — on screen —
        // because measuring it through the views is what hid it: `cacheDisplay`
        // re-lays the text view out and changes its frame in the process.
        if let firstShot = try? await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: window.frame)),
           let canvasView = editor.hitTest(CGPoint(x: 200, y: 200)) {
            let committed = inkRows(of: firstShot.image)
            let committedCoverage = committed.first.map {
                inkCoverage(of: firstShot.image, in: $0)
            }
            // The press and the release separately: "the moment of clicking" is
            // two events, and the box appears on the second.
            let at = CGPoint(x: 50, y: 296)
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvasView.convert(at, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) {
                canvasView.mouseDown(with: down)
            }
            if let pressed = try? await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: window.frame)) {
                print("  re-open: pressed  \(inkRows(of: pressed.image).map { "\($0.top)…\($0.bottom)@\($0.left)…\($0.right)" })")
            }
            if let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: canvasView.convert(at, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) {
                canvasView.mouseUp(with: up)
            }
            // Frame by frame through the moment itself, not 250ms after it: the
            // report is about what happens *as* the click lands, and the render
            // that removes the old copy of the words takes a beat to arrive.
            var trail: [(
                description: String,
                first: (top: Int, bottom: Int, left: Int, right: Int)?,
                coverage: Double?
            )] = []
            for step in 0..<6 {
                try await Task.sleep(for: .milliseconds(40))
                guard let frame = try? await coordinator.engine.capture(
                    .area(displayID: displayID, rectInAppKitGlobal: window.frame)) else { continue }
                let rows = inkRows(of: frame.image)
                let coverage = rows.first.map { inkCoverage(of: frame.image, in: $0) }
                trail.append(("\(step * 40)ms \(rows.map { "\($0.top)…\($0.bottom)@\($0.left)…\($0.right)" })"
                    + (coverage.map { String(format: " ink %.1f", $0) } ?? ""),
                    rows.first, coverage))
            }
            print("  re-open: committed \(committed.map { "\($0.top)…\($0.bottom)@\($0.left)…\($0.right)" })")
            for frame in trail { print("           \(frame.description)") }
            // Every frame of the click, against the frame before it. The
            // shadow's last row may come and go; the words may not move.
            let start = committed.first
            let moved = trail.compactMap(\.first).compactMap { last in
                start.map {
                    max(abs($0.top - last.top), abs($0.bottom - last.bottom),
                        abs($0.left - last.left), abs($0.right - last.right))
                }
            }.max() ?? 999
            let drift = (try? await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: window.frame)))
                .flatMap { inkRows(of: $0.image).first }
                .map { last in
                    start.map {
                        max(abs($0.top - last.top), abs($0.bottom - last.bottom),
                            abs($0.left - last.left), abs($0.right - last.right))
                    } ?? 999
                } ?? 999
            let coverageDrift = committedCoverage.map { start in
                trail.compactMap(\.coverage).map { abs($0 / start - 1) }.max() ?? 999
            } ?? 999
            print("  re-open: the words moved \(max(moved, drift)) px through the click")
            print(String(format: "  re-open: ink changed %.2f%% through the click",
                         coverageDrift * 100))
        }

        let shot = try? await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: window.frame.insetBy(dx: -8, dy: -8)))
        window.orderOut(nil)
        window.contentView = nil
        guard let shot else {
            print("photo:         capture failed")
            return
        }
        let url = directory.appendingPathComponent("edit-toolbar.png")
        try? ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)
        print("wrote:         \(url.lastPathComponent) (four tools, one of each)")
    }

    /// Opens the text tool's field at a point on the canvas, the way a click
    /// does, and hands it back.
    private static func openField(
        at point: CGPoint, on canvas: NSView, in window: NSWindow
    ) -> NSTextView? {
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        canvas.mouseDown(with: down)
        // And the release, which is not a formality any more: a press on
        // existing text is a click *or* the start of a drag, and it is the
        // mouse-up that says which. Sending only the press left the canvas
        // waiting for a drag that never came, and the next test's drag was
        // interpreted as the tail of this one.
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) {
            canvas.mouseUp(with: up)
        }
        return firstTextBox(in: canvas)
    }

    /// Where a view actually draws, in its own coordinates: the leftmost column
    /// with ink in it, the lowest row, and how tall the ink is.
    ///
    /// Drawn into a bitmap rather than reasoned about from font metrics, for the
    /// reason `TextFieldInk` gives at length: a text field's insets and its
    /// vertical centring are not published, and the arithmetic version of this
    /// was wrong three times.
    private static func ink(
        of view: NSView
    ) -> (left: CGFloat, bottom: CGFloat, height: CGFloat, width: CGFloat) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0, 0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / max(view.bounds.height, 1)
        var left = Int.max, right = -1, bottom = -1, top = Int.max
        // The annotation's own red, not "anything that was drawn" — the box
        // carries the renderer's shadow now, and counting that as ink measures
        // the shadow's reach rather than where the letters are. The render side
        // is filtered the same way, so the two are comparable.
        func inked(_ column: Int, _ row: Int) -> Bool {
            guard let colour = rep.colorAt(x: column, y: row)?
                .usingColorSpace(.sRGB), colour.alphaComponent > 0.35 else { return false }
            return colour.redComponent - colour.greenComponent > 0.2
                && colour.redComponent - colour.blueComponent > 0.2
        }
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide where inked(column, row) {
                left = min(left, column)
                right = max(right, column)
                bottom = max(bottom, row)
                top = min(top, row)
            }
        }
        guard left < Int.max else { return (0, 0, 0, 0) }
        return (CGFloat(left) / scale,
                CGFloat(rep.pixelsHigh - bottom - 1) / scale,
                CGFloat(bottom - top + 1) / scale,
                CGFloat(right - left + 1) / scale)
    }

    /// The same, for a rendered bitmap.
    ///
    /// Only the annotation's own red counts as ink, not every pixel that
    /// changed: the mark carries a shadow, and a shadow is ink by the "differs
    /// from the original" test — it would report the letters as several points
    /// taller and lower than they are, which is the opposite of what a
    /// measurement is for.
    private static func ink(
        of image: CGImage, against original: [UInt8]
    ) -> (left: CGFloat, bottom: CGFloat, height: CGFloat, width: CGFloat)? {
        let width = image.width
        let bytes = rgba(of: image)
        guard bytes.count == original.count else { return nil }
        var left = Int.max, right = -1, bottom = -1, top = Int.max
        for row in 0..<image.height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                guard bytes[index..<index + 4] != original[index..<index + 4] else { continue }
                let red = Int(bytes[index]), green = Int(bytes[index + 1])
                let blue = Int(bytes[index + 2])
                guard red > 140, red - green > 60, red - blue > 60 else { continue }
                left = min(left, column)
                right = max(right, column)
                bottom = max(bottom, row)
                top = min(top, row)
            }
        }
        guard left < Int.max else { return nil }
        return (CGFloat(left), CGFloat(bottom), CGFloat(bottom - top + 1),
                CGFloat(right - left + 1))
    }

    /// One pixel's alpha, for the checks that are about a shape rather than a
    /// colour: a window's rounded corner is transparent and its middle is not.
    private static func alpha(of image: CGImage, atX x: Int, y: Int) -> Int {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                       width: image.width, height: image.height))
        return Int(pixel[3])
    }

    /// How wide the glyphs in a text view actually are.
    ///
    /// Not `usedRect(for:)`, which answers with the container's width — and the
    /// editor's container is ten million points wide so that nothing wraps.
    private static func inkedWidth(of box: NSTextView) -> CGFloat {
        guard let layout = box.layoutManager else { return 0 }
        var width: CGFloat = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var effective = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &effective)
            width = max(width, used.maxX)
            glyph = max(effective.upperBound, glyph + 1)
        }
        return width
    }

    /// ⌘⏎, which is what finishes a piece of typing now that ⏎ is a newline.
    private static func commitTyping(_ box: NSTextView, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)
        else { return }
        box.keyDown(with: event)
    }

    /// The first text box anywhere under `view`, which is how a test finds the
    /// one the editor put on screen without the editor having to hand it out.
    private static func firstTextBox(in view: NSView) -> NSTextView? {
        for subview in view.subviews {
            if let box = subview as? NSTextView { return box }
            if let found = firstTextBox(in: subview) { return found }
        }
        return nil
    }

    /// The rows of every horizontal run of annotation red in a bitmap.
    ///
    /// The measurement that has actually been telling the truth: it reads what
    /// is on the screen, so it cannot be perturbed by the act of taking it.
    private static func inkRows(
        of image: CGImage
    ) -> [(top: Int, bottom: Int, left: Int, right: Int)] {
        let bytes = rgba(of: image)
        let width = image.width
        func inkSpan(_ row: Int) -> (left: Int, right: Int)? {
            var span: (left: Int, right: Int)?
            for column in 0..<width {
                let index = (row * width + column) * 4
                let red = Int(bytes[index]), green = Int(bytes[index + 1])
                let blue = Int(bytes[index + 2])
                if red > 150, red - green > 55, red - blue > 55 {
                    if span == nil { span = (column, column) }
                    span?.right = column
                }
            }
            return span
        }
        var bands: [(top: Int, bottom: Int, left: Int, right: Int)] = []
        var run: (top: Int, bottom: Int, left: Int, right: Int)?
        for row in 0..<image.height {
            if let span = inkSpan(row) {
                if var current = run {
                    current.bottom = row
                    current.left = min(current.left, span.left)
                    current.right = max(current.right, span.right)
                    run = current
                } else {
                    run = (row, row, span.left, span.right)
                }
            } else if let current = run {
                if current.bottom - current.top > 6 { bands.append(current) }
                run = nil
            }
        }
        if let current = run, current.bottom - current.top > 6 { bands.append(current) }
        return bands
    }

    /// Red dominance inside one detected annotation band. Unlike its bounds,
    /// this changes when identical antialiased glyphs are composited twice.
    private static func inkCoverage(
        of image: CGImage,
        in band: (top: Int, bottom: Int, left: Int, right: Int)
    ) -> Double {
        let bytes = rgba(of: image)
        var coverage: Double = 0
        for row in band.top...band.bottom {
            for column in band.left...band.right {
                let offset = (row * image.width + column) * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                coverage += Double(max(0, red - max(green, blue))) / 255
            }
        }
        return coverage
    }

    /// A press, a move and a release on `view`, in that view's own coordinates.
    ///
    /// The three halves of a drag, because the interesting gestures in the image
    /// editor are all drags and the interesting bugs are in what happens between
    /// the press and the release.
    private static func drag(
        _ view: NSView, from: CGPoint, to: CGPoint, in window: NSWindow
    ) {
        let phases: [(NSEvent.EventType, CGPoint)] = [
            (.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to),
        ]
        for (phase, point) in phases {
            guard let event = NSEvent.mouseEvent(
                with: phase, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            switch phase {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    /// One unmodified keystroke, delivered to a view's `keyDown`.
    ///
    /// The characters are all this app's shortcuts look at, and `keyCode` is not
    /// worth a lookup table for a test: nothing here reads it.
    private static func press(_ character: String, on view: NSView, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 0)
        else { return }
        view.keyDown(with: event)
    }

    /// A flat white bitmap, for the measurements that need a ground with no
    /// texture of its own to argue with.
    private static func flatImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Two-pixel black-and-white vertical stripes: maximum contrast at the
    /// highest frequency the bitmap can hold, which is the hardest thing to
    /// destroy and the easiest to notice surviving.
    ///
    /// Drawn into a `CGContext` at an exact pixel count rather than through
    /// `NSImage.lockFocus`, which backs itself at the main display's scale — on
    /// a Retina Mac that quietly returns twice the bitmap that was asked for,
    /// and a 2× test whose input is already 2× proves nothing.
    private static func stripedImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for x in stride(from: 0, to: width, by: 4) {
            context.fill(CGRect(x: x, y: 0, width: 2, height: height))
        }
        return context.makeImage()
    }

    /// A CGImage's bytes in one known layout, so two of them can be compared.
    private static func rgba(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(
                x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The three share states, photographed.
    ///
    /// Written because the states cannot be reasoned about: "is the link button
    /// there, and does the ring cover the open button" is a question about
    /// pixels. It is also the only way to see them without a configured server
    /// and a real upload, since two of the three last under a second.
    ///
    /// Forces `--sharing-default` on: the preview panel is normally invisible to
    /// ScreenCaptureKit (`sharingType = .none`) so that it stays out of the next
    /// capture, which also means a screenshot of it comes back empty. That is
    /// not a bug and it is why this test has to say so explicitly.
    private static func shareCardStates(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        PreviewPanel.usesSharingTypeNone = false

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let coordinator = CaptureCoordinator()
        let previews = PreviewStackController()
        previews.timeout = .seconds(600)
        try await coordinator.engine.refreshContent()
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        let result = try await coordinator.engine.capture(
            .area(displayID: displayID,
                  rectInAppKitGlobal: CGRect(x: 300, y: 300, width: 520, height: 360)))
        guard let output = await OutputPipeline.shared.process(
            result, saveDirectoryOverride: directory)
        else {
            print("result:        FAIL — pipeline returned nothing")
            return 1
        }
        await previews.present(output)
        try await Task.sleep(for: .milliseconds(300))
        // The action bar only exists while the pointer is over the stack, and
        // there is no pointer here.
        previews.setHoverForTest(true)
        try await Task.sleep(for: .milliseconds(300))

        // What the link button does once an upload has finished. Asserted here
        // because "clicking it did nothing" was a real report, and the only part
        // that can be checked without a pointer is whether the write happens.
        let link = LinkdropLink(
            key: "clipboardcheck",
            pageURL: URL(string: "https://s.example.com/clipboardcheck")!,
            fileURL: URL(string: "https://s.example.com/f/clipboardcheck.png")!)
        NSPasteboard.general.clearContents()
        Clipboard.write(link: link.pageURL)
        let pasted = NSPasteboard.general.string(forType: .string)
        print("clipboard:     \(pasted ?? "nil")")
        if pasted != link.pageURL.absoluteString {
            print("result:        FAIL — the link did not reach the clipboard")
            return 1
        }

        // Hover matters as much as the state: the card is a different thing
        // with the pointer on it, and the uploading case is shown in two
        // different places depending on which it is.
        // "idle" is captured further down as the card is *born*, never by
        // pushing `nil`: a real card is never told it has no share state, and a
        // test that says so tests a path nothing takes.
        let states: [(String, ShareService.State?, Bool)] = [
            ("uploading-resting", .uploading(0.62), false),
            ("uploading", .uploading(0.62), true),
            ("done", .done(LinkdropLink(
                key: "a7Kd9xQ2mZ01",
                pageURL: URL(string: "https://s.example.com/a7Kd9xQ2mZ01")!,
                fileURL: URL(string: "https://s.example.com/f/a7Kd9xQ2mZ01.png")!)), true),
            ("failed", .failed("No network connection.", retryable: true), true),
        ]

        guard let frame = previews.panelFrames.first else {
            print("result:        FAIL — no card on screen")
            return 1
        }
        print("configured:    \(ShareService.shared.isConfigured)")
        print("card frame:    \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")

        // As constructed, before anything touches its share state.
        previews.setHoverForTest(true)
        try await Task.sleep(for: .milliseconds(300))
        let born = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: frame.insetBy(dx: -12, dy: -12)))
        try ImageEncoder.write(
            born.image, to: directory.appendingPathComponent("share-card-idle.png"),
            as: .png, scale: born.scale)
        print("wrote:         share-card-idle.png (as constructed)")

        for (name, state, hovering) in states {
            previews.setShareStateForTest(state)
            previews.setHoverForTest(hovering)
            try await Task.sleep(for: .milliseconds(350))

            let shot = try await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: frame.insetBy(dx: -12, dy: -12)))
            let url = directory.appendingPathComponent("share-card-\(name).png")
            try ImageEncoder.write(shot.image, to: url, as: .png, scale: shot.scale)
            print("wrote:         \(url.lastPathComponent)")
        }

        print("result:        PASS")
        return 0
    }

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
            guard let output = await OutputPipeline.shared.process(
                result, saveDirectoryOverride: directory) else { continue }
            await previews.present(output)
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
            if let output = await OutputPipeline.shared.process(
                result, saveDirectoryOverride: directory) {
                await previews.present(output)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let beforeExpiry = previews.panelFrames
        previews.expireOldestForTest()
        try await Task.sleep(for: .milliseconds(400))
        let afterResult = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: rects[2]))
        if let output = await OutputPipeline.shared.process(
            afterResult, saveDirectoryOverride: directory) {
            await previews.present(output)
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

        // The grey bar admits what it is doing once a start drags on. In
        // production that is rare and unrepeatable, so this is the only place
        // the word can be looked at — and it has to fit the clock's slot without
        // reaching the divider, since the bar cannot widen for it.
        try await Task.sleep(for: .milliseconds(1000))
        try await shoot("hud-slow-start", frame: starting)

        hud.beginRecording(elapsed: { 754 })
        // Nothing about the window is supposed to move here — only the contents
        // colour in — but the colour transition is animated, so the shot still
        // has to wait for it to land.
        try await Task.sleep(for: .milliseconds(350))
        guard let running = hud.frameForTest else { return 1 }
        try await shoot("hud-recording", frame: running)
        for line in hud.debugSubviewFrames { print("    hud: \(line)") }
        hud.hide()

        // The same bar for a take whose microphone was refused. It is the only
        // way this state is ever looked at: producing it for real needs the TCC
        // grant to be missing, which no test can arrange. The slot is added at
        // `showStarting` — the bar cannot widen once it is up — so a wrong width
        // here shows as a clipped or floating indicator rather than as a crash.
        let micOff = RecordingHUD()
        micOff.showStarting(on: screen, under: anchor, microphoneOff: true)
        micOff.beginRecording(elapsed: { 754 }, microphoneOff: true)
        try await Task.sleep(for: .milliseconds(350))
        guard let micOffFrame = micOff.frameForTest else { return 1 }
        try await shoot("hud-recording-mic-off", frame: micOffFrame)
        for line in micOff.debugSubviewFrames { print("    mic: \(line)") }
        micOff.hide()

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
        // The starting and running states are one window that never moves. This
        // is the invariant the grey phase buys: it holds the running bar's exact
        // shape from the moment it appears, so the take beginning is a change of
        // colour and nothing else. A geometry difference of any kind here is the
        // "third bar" coming back.
        if !starting.equalTo(running) {
            failures.append("the bar changed shape when the take started: "
                + "\(rectString(starting)) -> \(rectString(running))")
        }
        // The mic-off bar is the same bar with one more thing in it: same
        // height, same top edge, and wider — an indicator squeezed into the
        // width the clock already had would overlap the divider.
        if abs(micOffFrame.height - running.height) >= 0.5
            || abs(micOffFrame.maxY - running.maxY) >= 0.5 {
            failures.append("the mic-off bar is placed differently: \(rectString(micOffFrame))")
        }
        if micOffFrame.width <= running.width {
            failures.append("the mic-off bar made no room for the indicator")
        }
        print("placement:     anchor \(rectString(anchor))")
        print("               toolbar \(rectString(bar))")
        print("               hud starting \(rectString(starting)) running \(rectString(running))")

        // The hand-over, frame by frame.
        //
        // Every still above can be right while the motion between them is not,
        // and the motion is the whole point: the toolbar and the HUD are two
        // one window changing what it is for. A filmstrip is the only way to see
        // whether that reads as one object — whether the glass ever doubles up,
        // blinks out, or shows two bars of different widths at once.
        //
        // Capturing is not free (~50 ms a frame here), so these are labelled
        // with the time they were actually taken rather than an assumed cadence.
        try await Task.sleep(for: .milliseconds(400))
        let handover = SelectionToolbar()
        handover.show(under: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(400))
        guard let outgoing = handover.frameForTest else { return 1 }
        // Wide enough for the bar at both widths, so a frame mid-morph is shown
        // rather than cropped.
        let stage = outgoing.union(running).insetBy(dx: -16, dy: -16)

        let morphing = RecordingHUD()
        let clock = Date()
        // The real sequence: the selection gives its window away and the take
        // adopts it. Nothing is dismissed here, which is the point.
        morphing.showStarting(on: screen, under: anchor, adopting: handover.handOver())
        var strip: [String] = []
        for index in 0..<10 {
            if index == 6 { morphing.beginRecording(elapsed: { 754 }) }
            let elapsed = Int(Date().timeIntervalSince(clock) * 1000)
            let shot = try await engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: stage))
            let name = String(format: "morph-%02d-%dms.png", index, elapsed)
            try? ImageEncoder.write(
                shot.image, to: directory.appendingPathComponent(name), as: .png,
                scale: shot.scale)
            strip.append("\(elapsed)ms")
        }
        morphing.hide()
        print("hand-over:     \(strip.joined(separator: " "))  -> morph-*.png in \(directory.path)")

        // The same hand-over again, this time watched rather than photographed.
        //
        // A still capture takes ~50 ms, so the filmstrip above cannot see a hole
        // one frame wide — and a one-frame hole is exactly what shipped: the
        // arriving face used to be scheduled from the departing face's completion
        // handler, which fires a run-loop turn late, leaving a composited frame
        // of Liquid Glass with nothing in it. It was reported by eye. This
        // samples what the render server is drawing every 8 ms instead.
        try await Task.sleep(for: .milliseconds(500))
        let watched = SelectionToolbar()
        watched.show(under: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(300))
        let inked = RecordingHUD()
        inked.showStarting(on: screen, under: anchor, adopting: watched.handOver())
        var lowest: Float = 2
        var lowestAt = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 0.45 {
            let ink = inked.faceInkForTest
            if ink < lowest {
                lowest = ink
                lowestAt = Int(Date().timeIntervalSince(started) * 1000)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        inked.hide()
        print(String(format: "crossfade ink: least %.2f at %dms (1.0 = one opaque face)",
                     lowest, lowestAt))
        // The dissolve's opacities are complements, so the honest expectation is
        // 1.00 flat; the margin is for sampling landing between frames. Anything
        // materially below it means the two faces are no longer covering for each
        // other — a dip if it is small, the bar blanking out if it is near zero.
        //
        // Verified to respond, the way the exclusion tests are: with the arrival
        // delayed to begin exactly as the departure ends — the arrangement that
        // shipped — this reported `least 0.01 at 160ms` and failed. A check that
        // cannot fail would be worse than none here, since the bug it guards was
        // invisible to every other test in the suite and was found by eye.
        if lowest < 0.85 {
            failures.append(String(
                format: "the bar goes near-empty mid-hand-over: ink fell to %.2f at %dms",
                lowest, lowestAt))
        }

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.joined(separator: "; "))")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Pixel mapping

    /// Where a pointer position lands inside a backdrop frame.
    ///
    /// This is the one piece of the loupe that a single-display machine cannot
    /// test for real, and it is also the piece most likely to be wrong. The flip
    /// is against the *covered rect's* own maxY, not the primary screen's height,
    /// and on one screen at the origin those are the same number — so the classic
    /// mistake produces identical results here and garbage on anyone's second
    /// monitor. Feeding synthetic geometry in is the only honest substitute for
    /// the hardware:
    ///
    ///   - a primary screen at the origin, 1x and 2x;
    ///   - a screen to the *left* of it, so x is negative;
    ///   - a screen *above* it, so y runs past the primary's height — the case
    ///     the wrong pivot gets wrong by exactly the offset between them;
    ///   - a 160 pt patch, which is what the loupe actually reads most of the
    ///     time and has an offset on every machine.
    private static func pixelMappingCheck() -> Int32 {
        var failures: [String] = []
        func check(_ expected: CGPoint, _ got: CGPoint, _ description: String) {
            let ok = abs(expected.x - got.x) < 0.01 && abs(expected.y - got.y) < 0.01
            print("  \(ok ? "ok  " : "FAIL") \(description)"
                + (ok ? "" : " — expected \(Int(expected.x)),\(Int(expected.y))"
                    + " got \(Int(got.x)),\(Int(got.y))"))
            if !ok { failures.append(description) }
        }

        func pixel(_ point: CGPoint, in covered: CGRect, scale: CGFloat) -> CGPoint {
            DisplayGeometry.pixel(ofAppKitGlobal: point, in: covered, scale: scale)
        }

        // Primary, 1x: the top-left of the image is the top-left of the screen.
        let primary = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        check(CGPoint(x: 0, y: 0), pixel(CGPoint(x: 0, y: 1000), in: primary, scale: 1),
              "the screen's top-left corner is pixel 0,0")
        check(CGPoint(x: 0, y: 1000), pixel(CGPoint(x: 0, y: 0), in: primary, scale: 1),
              "and its bottom-left corner is the last row")
        check(CGPoint(x: 100, y: 250), pixel(CGPoint(x: 100, y: 750), in: primary, scale: 1),
              "a point 250 pt below the top is 250 px down")

        // Primary, 2x: everything doubles, nothing else changes.
        check(CGPoint(x: 200, y: 500), pixel(CGPoint(x: 100, y: 750), in: primary, scale: 2),
              "the same point at 2x is twice as far in")

        // A screen to the left: x is negative in global space, never in the image.
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        check(CGPoint(x: 0, y: 0), pixel(CGPoint(x: -1440, y: 900), in: left, scale: 2),
              "a screen left of the origin still starts at pixel 0,0")
        check(CGPoint(x: 80, y: 100), pixel(CGPoint(x: -1400, y: 850), in: left, scale: 2),
              "and offsets come off its own minX")

        // A screen above: y runs past the primary's height. Flipping against the
        // primary's 1000 pt instead of this screen's own maxY would put every
        // pixel 900 pt out — the bug this exists for.
        let above = CGRect(x: 0, y: 1000, width: 1600, height: 900)
        check(CGPoint(x: 0, y: 0), pixel(CGPoint(x: 0, y: 1900), in: above, scale: 1),
              "a screen above the origin maps its own top edge to row 0")
        check(CGPoint(x: 0, y: 900), pixel(CGPoint(x: 0, y: 1000), in: above, scale: 1),
              "and its own bottom edge to its last row")
        check(CGPoint(x: 0, y: 450), pixel(CGPoint(x: 0, y: 1450), in: above, scale: 1),
              "a point halfway up it is halfway down the image")

        // A patch: same arithmetic, a covered rect that is not a screen at all.
        let patch = CGRect(x: 784, y: 479, width: 160, height: 160)
        check(CGPoint(x: 160, y: 160), pixel(CGPoint(x: 864, y: 559), in: patch, scale: 2),
              "the centre of a 160 pt patch is the centre of its image")
        check(CGPoint(x: 0, y: 0), pixel(CGPoint(x: 784, y: 639), in: patch, scale: 2),
              "and its top-left corner is pixel 0,0")

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Latch cancellation

    /// `SCKLatch.wait` polls with `Task.sleep`, and a cancelled task cannot
    /// sleep — the sleep throws immediately. If the loop swallowed that and
    /// went round again, the poll would degenerate into a full-speed spin for
    /// the rest of the timeout: a whole core burnt for up to 15 s on a stop,
    /// 120 s on a permission wait. So cancellation must read as a timeout,
    /// promptly.
    ///
    /// Reverse control: put `try? await Task.sleep` back in `wait` and the
    /// cancelled case below runs to its full 3 s deadline instead of returning
    /// at once — the elapsed-time assertion goes red.
    private static func latchCancelCheck() async -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        // Positive controls first: the latch still does its actual job.
        let opened = SCKLatch()
        opened.signal()
        check((try? await opened.wait(timeout: .seconds(1))) == true,
              "a signalled latch reports true")

        struct Boom: Error {}
        let failed = SCKLatch()
        failed.signal(Boom())
        var threw = false
        do { _ = try await failed.wait(timeout: .seconds(1)) } catch { threw = true }
        check(threw, "a latch signalled with an error throws")

        // The case under test: cancelled while waiting on a latch that never
        // opens. Must come back long before the 3 s deadline, reporting timeout.
        let never = SCKLatch()
        let started = ContinuousClock.now
        let waiter = Task { try? await never.wait(timeout: .seconds(3)) }
        waiter.cancel()
        let result = await waiter.value
        let elapsed = started.duration(to: .now)
        check(result == false, "a cancelled wait reports timeout, not success")
        check(elapsed < .seconds(1),
              "and returns promptly (\(elapsed.milliseconds) ms of a 3000 ms deadline)")

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Selection zones

    /// The grab-zone arithmetic: which handle a point belongs to, and what each
    /// one does to the rect.
    ///
    /// Headless on purpose. It is eight near-identical cases of min/max, the kind
    /// of thing where a transposed pair looks fine until someone drags the one
    /// corner nobody tried — and it needs no window server, so unlike the gesture
    /// test it also runs on a locked screen.
    private static func selectionZonesCheck() -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let zones = SelectionZones(rect: rect)

        // Every handle claims the point it is named after. AppKit's y is up, so
        // "top" is the higher edge — the classic place to get this backwards.
        let probes: [(SelectionZones.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
        for (handle, point) in probes {
            check(zones.handle(at: point) == handle,
                  "\(handle) is the handle at its own corner or edge midpoint")
        }
        check(zones.handle(at: CGPoint(x: rect.midX, y: rect.midY)) == nil,
              "the middle belongs to no handle, so a press there is a move")
        check(zones.handle(at: CGPoint(x: rect.minX - 40, y: rect.midY)) == nil,
              "well outside belongs to no handle either")
        check(zones.interior.contains(CGPoint(x: rect.midX, y: rect.midY))
                && !zones.interior.contains(CGPoint(x: rect.minX, y: rect.midY)),
              "the interior holds the middle and not the edge")

        // No two zones overlap. This is what lets the cursor rects be laid out
        // without depending on AppKit's undefined behaviour for overlapping ones.
        var overlaps: [String] = []
        let all = SelectionZones.Handle.allCases
        for (index, one) in all.enumerated() {
            for other in all.dropFirst(index + 1) {
                let shared = zones.zone(one).intersection(zones.zone(other))
                if !shared.isEmpty { overlaps.append("\(one)/\(other)") }
            }
        }
        check(overlaps.isEmpty, "no two grab zones overlap\(overlaps.isEmpty ? "" : ": " + overlaps.joined(separator: " "))")

        // What each handle does. Every case names the sides that must NOT move,
        // which is the half that a transposition breaks.
        let cases: [(SelectionZones.Handle, CGPoint, CGRect)] = [
            (.left, CGPoint(x: 150, y: 0),
             CGRect(x: 150, y: 200, width: 350, height: 300)),
            (.right, CGPoint(x: 600, y: 0),
             CGRect(x: 100, y: 200, width: 500, height: 300)),
            (.top, CGPoint(x: 0, y: 400),
             CGRect(x: 100, y: 200, width: 400, height: 200)),
            (.bottom, CGPoint(x: 0, y: 150),
             CGRect(x: 100, y: 150, width: 400, height: 350)),
            (.topLeft, CGPoint(x: 150, y: 400),
             CGRect(x: 150, y: 200, width: 350, height: 200)),
            (.topRight, CGPoint(x: 600, y: 400),
             CGRect(x: 100, y: 200, width: 500, height: 200)),
            (.bottomLeft, CGPoint(x: 150, y: 150),
             CGRect(x: 150, y: 150, width: 350, height: 350)),
            (.bottomRight, CGPoint(x: 600, y: 150),
             CGRect(x: 100, y: 150, width: 500, height: 350)),
        ]
        for (handle, to, expected) in cases {
            let got = SelectionZones.resized(rect, by: handle, to: to)
            check(got == expected,
                  "\(handle) dragged to \(Int(to.x)),\(Int(to.y)) gives "
                    + "\(rectString(expected))\(got == expected ? "" : " — got \(rectString(got))")")
        }

        // Through the opposite side: parks at the minimum, leaves that side alone.
        // A normalising version of this flipped the rect to the far side of the
        // anchor instead, and came out 200 pt wide.
        let minimum = SelectionModel.minimumSide
        let crossed = SelectionZones.resized(rect, by: .left, to: CGPoint(x: rect.maxX + 200, y: 0))
        check(crossed.width == minimum && crossed.maxX == rect.maxX
                && crossed.minY == rect.minY && crossed.height == rect.height,
              "the left edge dragged past the right stops \(Int(minimum))pt short of it")
        let crossedUp = SelectionZones.resized(rect, by: .bottom, to: CGPoint(x: 0, y: rect.maxY + 200))
        check(crossedUp.height == minimum && crossedUp.maxY == rect.maxY,
              "and the bottom edge dragged past the top does the same")

        // A selection too small to hold a full-width ring still has a middle to
        // grab, or it could be resized and never moved again.
        let tiny = SelectionZones(rect: CGRect(x: 0, y: 0, width: 21, height: 21))
        check(tiny.grab < 8 && !tiny.interior.isEmpty,
              "a 21pt selection shrinks its grab band instead of becoming all handles")

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Size readout placement

    /// Whether the size readout stays readable — which means staying out from
    /// under the loupe.
    ///
    /// The loupe is a subview and the readout is painted by `draw`, so wherever
    /// the two overlap the glass wins and the digits are simply gone. They
    /// overlapped by default: the readout sits under the rect's bottom edge and
    /// the loupe sits 18 pt below-right of the pointer, and on any drag whose
    /// moving corner is the bottom-left one those are the same place. Reported
    /// as "the preview block covers the size".
    ///
    /// Geometry first, because it can enumerate the corner cases a live drag
    /// cannot reach, then one real drag — the placement is only worth anything
    /// if the frames it computes are the frames on screen.
    private static func badgePlacementCheck() async throws -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let box = CGSize(width: 70, height: 23)
        let loupeSize = SelectionLoupeView.size

        /// The loupe where `placeLoupe` would put it for a pointer at `pointer`,
        /// with the same 18 pt gap and the same two flips. Duplicated on purpose:
        /// a test that asked the view for the answer would agree with a wrong
        /// answer.
        func loupe(at pointer: CGPoint, flippedX: Bool = false, flippedY: Bool = false) -> CGRect {
            let gap: CGFloat = 18
            let x = flippedX ? pointer.x - gap - loupeSize.width : pointer.x + gap
            let y = flippedY ? pointer.y + gap : pointer.y - gap - loupeSize.height
            return CGRect(origin: CGPoint(x: x, y: y), size: loupeSize)
        }

        func frame(_ highlight: CGRect, _ glass: CGRect?) -> CGRect {
            OverlayView.badgeFrame(
                boxSize: box, near: highlight, in: bounds, avoiding: glass)
        }

        // Nothing to dodge: below the rect, centred on it. The fallback must not
        // have become the normal case.
        let plain = frame(CGRect(x: 400, y: 300, width: 300, height: 200), nil)
        check(plain.midX == 550 && plain.maxY == 294,
              "with no loupe the readout is centred under the rect (\(rectString(plain)))")

        // The reported bug, at the size it was reported: dragged down and to the
        // left, so the pointer — and the loupe — is on the bottom-left corner.
        let downLeft = CGRect(x: 400, y: 300, width: 200, height: 200)
        let glassDownLeft = loupe(at: CGPoint(x: downLeft.minX, y: downLeft.minY))
        let dodged = frame(downLeft, glassDownLeft)
        check(!dodged.intersects(glassDownLeft),
              "a down-left drag puts the readout clear of the loupe (\(rectString(dodged)))")
        check(dodged.minY >= downLeft.maxY,
              "and clear means above the rect, where it can stay for the whole drag")

        // Same collision from the other side: near the right screen edge the
        // loupe flips left, onto the rect it is measuring.
        let nearRight = CGRect(x: 1300, y: 300, width: 200, height: 200)
        let glassFlipped = loupe(at: CGPoint(x: nearRight.maxX, y: nearRight.minY), flippedX: true)
        let dodgedRight = frame(nearRight, glassFlipped)
        check(!dodgedRight.intersects(glassFlipped),
              "a loupe flipped to the left of the pointer is dodged too (\(rectString(dodgedRight)))")

        // No room below: the pre-existing flip still happens, loupe or no loupe.
        let atBottom = CGRect(x: 400, y: 10, width: 300, height: 200)
        check(frame(atBottom, nil).minY >= atBottom.maxY,
              "a rect against the bottom of the screen puts its readout above")

        // Both bands under the glass. A short rect against the screen bottom:
        // below does not fit at all, and the loupe — flipped upwards, because
        // the pointer is near the bottom — covers what is left.
        let short = CGRect(x: 400, y: 30, width: 300, height: 10)
        let glassShort = loupe(at: CGPoint(x: short.minX, y: short.minY), flippedY: true)
        let pushed = frame(short, glassShort)
        check(!pushed.intersects(glassShort),
              "with both bands blocked the readout slides sideways (\(rectString(pushed)))")

        // Whatever it dodges, it stays on the screen. A readout pushed off the
        // edge is worse than one behind glass: at least the glass moves.
        let everywhere: [(CGRect, CGRect?)] = [
            (CGRect(x: 400, y: 300, width: 300, height: 200), nil),
            (downLeft, glassDownLeft), (nearRight, glassFlipped), (short, glassShort),
            (CGRect(x: 0, y: 0, width: 40, height: 40),
             loupe(at: .zero, flippedY: true)),
            (CGRect(x: 1560, y: 960, width: 40, height: 40),
             loupe(at: CGPoint(x: 1600, y: 1000), flippedX: true)),
        ]
        let escaped = everywhere.map { frame($0.0, $0.1) }.filter { !bounds.contains($0) }
        check(escaped.isEmpty,
              "every placement stays on screen\(escaped.isEmpty ? "" : " — \(escaped.map(rectString).joined(separator: " "))")")

        // --- and now the same question, asked of a live drag ------------------
        guard ScreenPermission.isGranted, LoginSession.noDisplaysHint == nil,
              let screen = NSScreen.main
        else {
            print("  skip live drag (no screen permission or no displays)")
            print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
            return failures.isEmpty ? 0 : 1
        }

        let coordinator = CaptureCoordinator()
        let overlay = coordinator.overlay
        let flag = CompletionFlag()
        Task {
            _ = await overlay.present(windows: [], suggestsWindows: false)
            flag.markDone()
        }
        try await Task.sleep(for: .milliseconds(200))

        // Down and to the left, the direction that collides. The pointer is
        // seeded first because the loupe only appears once the backdrop it
        // magnifies has arrived.
        let from = CGPoint(x: screen.frame.midX + 120, y: screen.frame.midY + 120)
        let to = CGPoint(x: screen.frame.midX - 80, y: screen.frame.midY - 80)
        overlay.forcePointerForTest(at: from)
        var waited = 0
        while !overlay.hasBackdropForTest, waited < 2000 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        check(overlay.hasBackdropForTest, "the backdrop arrived (in \(waited)ms)")
        // Read straight back, with no sleep in between. The overlay polls the
        // real mouse every 120 ms and a poll overwrites the forced pointer, which
        // moves the loupe to wherever the mouse happens to be sitting — measured,
        // and it made the check below pass for the wrong reason.
        overlay.forceDragForTest(from: from, to: to, on: screen)

        if let pair = overlay.loupeAndBadgeForTest {
            print("  loupe: \(rectString(pair.loupe))  readout: \(rectString(pair.badge))")
            check(abs(pair.loupe.minX - to.x) < 60 && abs(pair.loupe.maxY - to.y) < 60,
                  "the loupe is beside the corner being dragged, so these frames are this gesture's")
            check(!pair.loupe.intersects(pair.badge),
                  "mid-drag, the loupe and the readout do not overlap on screen")
            check(screen.frame.contains(pair.badge), "and the readout is on the screen")
        } else {
            check(false, "the loupe and the readout both have frames mid-drag")
        }

        overlay.cancelSelectionForTest()
        overlay.tearDown()
        _ = await flag.wait(upTo: .seconds(2))

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Loupe

    /// Whether the loupe magnifies the pixels it claims to.
    ///
    /// The interesting failure is not "nothing drew" — it is drawing the *wrong*
    /// pixels, which looks entirely plausible in a screenshot. Every step between
    /// the pointer and the photograph can be wrong in a way that still fills the
    /// glass: a y-flip against the primary screen instead of this one, points
    /// where pixels were meant, a display origin left out.
    ///
    /// So the pointer is put at the exact centre of four known colours. A loupe
    /// centred on that corner has to show all four, one per quadrant, in the same
    /// arrangement — which pins the flip, the scale and the offset at once.
    ///
    /// It caught the bug it was written for on its first run: the loupe came back
    /// mirrored, because the draw flipped the CTM to account for the image being
    /// top-down when `draw(_:in:)` had already done that. Verified to still
    /// respond — reinstating that flip reports all four quadrants on the wrong
    /// colour, naming which one each landed on.
    private static func loupe(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let coordinator = CaptureCoordinator()
        let overlay = coordinator.overlay
        try await coordinator.engine.refreshContent()

        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        /// Four solid colours meeting at the centre of `target`, named as the user
        /// sees them. AppKit's y is up, so "top" is the higher one.
        func quadrants(of target: CGRect, rotated: Bool) -> [(name: String, colour: NSColor, corner: CGRect)] {
            let colours: [NSColor] = [
                NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1),
            ]
            let corners = [
                CGRect(x: target.minX, y: target.midY, width: target.width / 2, height: target.height / 2),
                CGRect(x: target.midX, y: target.midY, width: target.width / 2, height: target.height / 2),
                CGRect(x: target.minX, y: target.minY, width: target.width / 2, height: target.height / 2),
                CGRect(x: target.midX, y: target.minY, width: target.width / 2, height: target.height / 2),
            ]
            let names = ["top-left", "top-right", "bottom-left", "bottom-right"]
            // Rotated by one, for the freshness check: every quadrant changes, so
            // "it noticed" and "it noticed correctly" are the same assertion.
            let order = rotated ? [3, 0, 1, 2] : [0, 1, 2, 3]
            return (0..<4).map {
                (name: names[$0], colour: colours[order[$0]], corner: corners[$0])
            }
        }

        /// Which of the four colours a patch of the loupe's glass is nearest.
        ///
        /// A mean rather than a per-pixel tolerance: saturated Display P3 values
        /// clip on conversion to sRGB — P3 green lands on (8,255,3) — while the
        /// same green under a 10% white grid line is representable and converts
        /// honestly to (70,255,58). Neighbouring pixels 60 apart with nothing
        /// wrong. See `PixelCompare.meanColour`.
        func nearest(
            _ image: CGImage, in region: CGRect,
            among expected: [(name: String, colour: NSColor, corner: CGRect)]
        ) -> (name: String, mean: (r: Double, g: Double, b: Double))? {
            guard let mean = PixelCompare.meanColour(image, in: region) else { return nil }
            let best = expected.min {
                func distance(_ colour: NSColor) -> Double {
                    guard let srgb = colour.usingColorSpace(.sRGB) else { return .infinity }
                    let dr = mean.r - srgb.redComponent * 255
                    let dg = mean.g - srgb.greenComponent * 255
                    let db = mean.b - srgb.blueComponent * 255
                    return dr * dr + dg * dg + db * db
                }
                return distance($0.colour) < distance($1.colour)
            }
            guard let best else { return nil }
            return (best.name, mean)
        }

        // One presentation covers every screen; the pointer is then moved onto
        // each in turn. Which matters because the mapping from a pointer position
        // to a pixel is per-display — it flips against *that* screen's own maxY —
        // and on a single-display machine the offset it could get wrong is
        // identically zero. This loop is the only part of that gap a test can
        // close without a second monitor plugged in.
        let flag = CompletionFlag()
        Task {
            _ = await overlay.present(windows: [], suggestsWindows: false)
            flag.markDone()
        }
        try await Task.sleep(for: .milliseconds(250))
        print("screens:       \(NSScreen.screens.count)")

        for (index, screen) in NSScreen.screens.enumerated() {
            let label = NSScreen.screens.count > 1 ? " (screen \(index + 1))" : ""
            let target = CGRect(
                x: (screen.frame.midX - 120).rounded(), y: (screen.frame.midY - 120).rounded(),
                width: 240, height: 240)
            let centre = CGPoint(x: target.midX, y: target.midY)
            var expected = quadrants(of: target, rotated: false)
            var patches = expected.map { plainWindow(colour: $0.colour, frame: $0.corner) }
            // Let them composite before the pointer lands: the backdrop is taken
            // the moment the pointer is seeded, so without this the photograph can
            // be of the desktop as it was a frame before these windows appeared —
            // seen once, as a first run that failed all four quadrants and then
            // passed three times in a row.
            try await Task.sleep(for: .milliseconds(400))

            overlay.forcePointerForTest(at: centre)
            var waited = 0
            while !overlay.hasBackdropForTest, waited < 2000 {
                try await Task.sleep(for: .milliseconds(50))
                waited += 50
            }
            check(overlay.hasBackdropForTest, "the backdrop arrived\(label) (in \(waited)ms)")
            overlay.forcePointerForTest(at: centre)
            // Long enough for the fresh patch, not just the base frame.
            //
            // The base is taken when the pointer is first seeded, which is inside
            // `present` — before these colour windows existed — so what the glass
            // reads below comes from the patch. That is the better test of the two
            // anyway: a patch's covered rect is a 160 pt square at an arbitrary
            // offset, which is the arithmetic a second display would exercise,
            // where a whole-screen frame on a single-display machine has an offset
            // of exactly zero. Measured at 300 ms this raced the capture and
            // failed three runs in four.
            try await Task.sleep(for: .milliseconds(1000))

            guard let displayID = ScreenIndex.displayID(of: screen),
                  let loupeFrame = overlay.loupeFrameForTest
            else {
                check(false, "the loupe is on screen\(label)")
                patches.forEach { $0.orderOut(nil) }
                continue
            }
            print("  loupe\(label): \(rectString(loupeFrame))  pointer: "
                + "\(Int(centre.x)),\(Int(centre.y))")

            /// The four quadrants of the glass, sampled well inside so the grid
            /// lines and the reticle are not part of the answer.
            func glassQuadrant(_ index: Int, scale: CGFloat) -> CGRect {
                let glass = CGRect(
                    x: 1 * scale, y: 1 * scale,
                    width: (loupeFrame.width - 2) * scale, height: (loupeFrame.width - 2) * scale)
                let half = glass.width / 2
                return CGRect(
                    x: glass.minX + (index % 2 == 0 ? 0 : half),
                    y: glass.minY + (index < 2 ? 0 : half),
                    width: half, height: half
                ).insetBy(dx: 12 * scale, dy: 12 * scale)
            }

            /// Photographs the loupe and reports which colour each quadrant of
            /// the glass is nearest.
            func readGlass(_ name: String) async throws -> [String] {
                let shot = try await coordinator.engine.capture(
                    .area(displayID: displayID, rectInAppKitGlobal: loupeFrame))
                try? ImageEncoder.write(
                    shot.image, to: directory.appendingPathComponent(name), as: .png,
                    scale: shot.scale)
                return (0..<4).compactMap {
                    nearest(shot.image, in: glassQuadrant($0, scale: shot.scale), among: expected)
                        .map(\.name)
                }
            }

            // The pointer sits at the exact centre of four known colours, so the
            // glass has to show all four, one per quadrant, in the same
            // arrangement — which pins the flip, the scale and the display offset
            // at once, since any mirror moves at least two of them. It caught the
            // bug it was written for on its first run: the loupe came back
            // vertically mirrored, because the draw flipped the CTM to account for
            // the image being top-down when `draw(_:in:)` had already done that.
            let seen = try await readGlass("loupe\(index == 0 ? "" : "-screen\(index + 1)").png")
            for (position, name) in seen.enumerated() {
                check(name == expected[position].name,
                      "the glass's \(expected[position].name) quadrant shows "
                        + "the \(expected[position].name) colour\(label)")
            }

            // And from further back, because the loupe has to be readable *beside*
            // the pointer, next to the crosshair and the dim.
            if index == 0, let wide = try? await coordinator.engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal:
                        CGRect(x: centre.x - 300, y: centre.y - 300, width: 600, height: 600))) {
                try? ImageEncoder.write(
                    wide.image, to: directory.appendingPathComponent("loupe-in-context.png"),
                    as: .png, scale: wide.scale)
            }

            // --- and the photograph has to stay current -----------------------
            //
            // The backdrop is a photograph, so it goes stale; a loupe over a
            // playing video used to show the pixels as they were when the
            // selection started. The fix is a small patch re-taken wherever the
            // pointer comes to rest, and this is the check that says so: the four
            // colours are rotated by one *underneath* a stationary pointer, and
            // the loupe has to come to agree. Every quadrant changes, so noticing
            // and noticing correctly are the same assertion.
            patches.forEach { $0.orderOut(nil) }
            expected = quadrants(of: target, rotated: true)
            patches = expected.map { plainWindow(colour: $0.colour, frame: $0.corner) }
            try await Task.sleep(for: .milliseconds(300))
            // Nudged and put back: the patch is re-taken once the pointer has been
            // still for 0.3 s, and a pointer that never moved has nothing to be
            // still after.
            overlay.forcePointerForTest(at: CGPoint(x: centre.x + 1, y: centre.y))
            overlay.forcePointerForTest(at: centre)
            try await Task.sleep(for: .milliseconds(900))

            let refreshed = try await readGlass("loupe-refreshed\(index == 0 ? "" : "-screen\(index + 1)").png")
            for (position, name) in refreshed.enumerated() {
                check(name == expected[position].name,
                      "the loupe followed the pixels changing under it: "
                        + "\(expected[position].name) quadrant\(label)")
            }

            patches.forEach { $0.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(150))
        }

        overlay.tearDown()
        _ = await flag.wait(upTo: .seconds(2))

        print("images:        loupe*.png in \(directory.path)")
        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.count) of the above")")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Recording border

    /// Photographs the border of an area take over black and over white, and
    /// measures how far its light carries on each.
    ///
    /// This border has been wrong twice, both times for one reason: it was
    /// designed against one background and then met another. A solid red line
    /// vanished on red content. Warm light on its own would vanish on a white
    /// document — which is exactly what the shade beyond the glow is for. So this
    /// does not only take a picture. It samples the luminance profile outward
    /// from the edge and requires that *something* separates the region from its
    /// surroundings at both extremes.
    private static func regionOutline(into directory: URL) async throws -> Int32 {
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

        let region = CGRect(
            x: (screen.frame.midX - 260).rounded(), y: (screen.frame.midY - 180).rounded(),
            width: 520, height: 360)
        let reach = RecordingRegionOutlineView.outset
        // The backdrop has to be wider than the light reaches, or the profile
        // would be measured half against a known colour and half against
        // whatever is on the desktop.
        let stage = region.insetBy(dx: -(reach + 26), dy: -(reach + 26))

        /// Distance outward from the recorded edge, in points.
        let bands: [(name: String, from: CGFloat, to: CGFloat)] = [
            ("edge  1-5pt", 1, 5),
            ("near  6-12pt", 6, 12),
            ("far  13-20pt", 13, 20),
        ]
        let referenceBand: (from: CGFloat, to: CGFloat) = (32, 42)

        var failures: [String] = []
        print("region:        \(rectString(region))  light reaches \(Int(reach))pt")

        for (name, backdrop) in [("black", NSColor.black), ("white", NSColor.white)] {
            let backing = plainWindow(colour: backdrop, frame: stage)
            let outline = RecordingRegionOutline()
            outline.show(around: region)
            try await Task.sleep(for: .milliseconds(450))

            let shot = try await engine.capture(
                .area(displayID: displayID, rectInAppKitGlobal: stage))
            try? ImageEncoder.write(
                shot.image, to: directory.appendingPathComponent("outline-on-\(name).png"),
                as: .png, scale: shot.scale)

            /// A strip of the captured image, `from`–`to` points above the
            /// region's top edge, kept clear of the corners where two edges' light
            /// adds up. Image coordinates run downward from the top of `stage`.
            func strip(from: CGFloat, to: CGFloat) -> CGRect {
                let scale = shot.scale
                let top = (stage.maxY - (region.maxY + to)) * scale
                let bottom = (stage.maxY - (region.maxY + from)) * scale
                return CGRect(
                    x: (region.minX - stage.minX + 80) * scale, y: top,
                    width: (region.width - 160) * scale, height: bottom - top)
            }

            guard let reference = PixelCompare.meanLuminance(
                shot.image, in: strip(from: referenceBand.from, to: referenceBand.to))
            else {
                failures.append("could not sample the \(name) backdrop")
                outline.hide()
                backing.orderOut(nil)
                continue
            }

            var strongest = 0.0
            var profile: [String] = []
            for band in bands {
                guard let mean = PixelCompare.meanLuminance(
                    shot.image, in: strip(from: band.from, to: band.to))
                else { continue }
                let delta = mean - reference
                strongest = max(strongest, abs(delta))
                profile.append(String(format: "%@ %+.0f", band.name, delta))
            }
            print("on \(name):\(String(repeating: " ", count: max(1, 9 - name.count)))"
                + "backdrop \(Int(reference))  →  \(profile.joined(separator: "   "))")

            // 12 is about where a band stops being arguable in a screenshot. The
            // sign is deliberately not checked: on black the light does the work
            // and the deltas are positive, on white the shade does and they are
            // negative, and requiring a particular direction on a particular
            // backdrop would be writing the current design into the test rather
            // than the requirement.
            if strongest < 12 {
                failures.append(String(
                    format: "the border is invisible on %@: strongest band differs by only %.1f",
                    name, strongest))
            }

            outline.hide()
            backing.orderOut(nil)
            try await Task.sleep(for: .milliseconds(200))
        }

        print("images:        outline-on-black.png, outline-on-white.png in \(directory.path)")
        print("result:        \(failures.isEmpty ? "PASS" : "FAIL — \(failures.joined(separator: "; "))")")
        return failures.isEmpty ? 0 : 1
    }

    /// A flat rectangle of colour to put the border against.
    ///
    /// `.floating`, so it sits above the desktop and below the border's own
    /// `.statusBar` panel. `.normal` would belong to a background application and
    /// anything coming forward would cover it — measured before, on the magenta
    /// window in `recordHUD`, where it turned into an intermittent failure that
    /// blamed the wrong thing.
    private static func plainWindow(colour: NSColor, frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = colour
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    /// A preview card that is already on screen when a take starts must not
    /// reach the video.
    ///
    /// This is the half of the screen-sharing change that had no evidence. The
    /// card is `.readOnly` here — the shipping configuration when the
    /// preference is on and no take is running — so the only thing keeping it
    /// out is its window ID in `excludedWindowIDs`, named at the moment the
    /// filter is built. A card raised *during* a take is the other case and
    /// stays `.none`; nothing else can reach it.
    ///
    /// The card is made detectable by photographing a magenta window into it
    /// and then closing that window, so the only magenta left anywhere is the
    /// card itself.
    private static func previewInRecording(
        into directory: URL, seconds: Double, excludes: Bool = true
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.main
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()

        // Before the marker window exists — see `waitUntilStageClear`.
        let stage = await waitUntilStageClear(on: displayID, upTo: .seconds(3))
        print("stage:         "
            + (stage.leftover == 0 ? "clear" : "STILL \(stage.leftover) px magenta")
            + " after \(stage.waited.milliseconds) ms")

        let coordinator = CaptureCoordinator()
        try await coordinator.engine.refreshContent()
        let previews = PreviewStackController()
        previews.timeout = .seconds(120)
        // The card must be capturable for this to mean anything; the flag above
        // has already forced that, and this says the take is not running yet.
        previews.isRecordingActive = { false }

        // Fill a card with magenta by photographing a magenta window.
        let marker = makePlainMagentaWindow(on: screen)
        try await Task.sleep(for: .milliseconds(500))
        let shot = try await coordinator.engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: marker.frame))
        guard let output = await OutputPipeline.shared.process(
            shot, saveDirectoryOverride: directory) else {
            print("result:        FAIL — could not stage the marker capture")
            return 1
        }
        await previews.present(output)
        // Closed before recording, so the card is the only magenta on screen.
        marker.orderOut(nil)
        try await Task.sleep(for: .milliseconds(600))

        guard let cardFrame = previews.containerFrame else {
            print("result:        FAIL — no preview panel")
            return 1
        }
        print("card:          \(rectString(cardFrame)) sharingType=readOnly")

        // Control: a screenshot with nothing excluded must see the card. If it
        // cannot, the card is not really there and the video's silence would
        // prove nothing.
        var bare = CaptureOptions.default
        bare.excludedWindowIDs = []
        let still = try await coordinator.engine.capture(
            .display(displayID), options: bare)
        let stillMagenta = PixelCompare.count(still.image, matching: PixelCompare.isDebugMagenta)
        print("still capture: \(stillMagenta) px magenta (the card, seen by a screenshot)")

        // Now record, naming the card the way `RecordingCoordinator` does.
        var options = RecordingOptions.default
        options.capturesSystemAudio = false
        options.capturesMicrophone = false
        options.excludedWindowIDs = excludes ? previews.panelWindowIDs : []
        print("excluding:     \(excludes ? "the card's window ID" : "NOTHING — negative control")")
        let url = directory.appendingPathComponent("preview-in-recording.mp4")
        try? FileManager.default.removeItem(at: url)

        let engine = RecordingEngine()
        try await engine.refreshContent()
        _ = try await engine.start(.display(displayID), options: options, to: url)
        try await Task.sleep(for: .seconds(seconds))
        let result = try await engine.stop()
        previews.dismissAll()

        let asset = AVURLAsset(url: result.url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(
            at: CMTime(seconds: duration.seconds * 0.6, preferredTimescale: 600))
        try? ImageEncoder.write(
            frame, to: directory.appendingPathComponent("preview-in-recording.png"),
            as: .png, scale: result.scale)
        let videoMagenta = PixelCompare.count(frame, matching: PixelCompare.isDebugMagenta)
        print("video:         \(videoMagenta) px magenta in the recording")

        var failures: [String] = []
        if stillMagenta < 500 {
            failures.append("the card was not visible to a screenshot (\(stillMagenta) px), "
                + "so the video proves nothing")
        }
        let leaked = videoMagenta > max(stillMagenta / 20, 100)
        if excludes {
            if leaked { failures.append("the card reached the video (\(videoMagenta) px)") }
            print("result:        \(failures.isEmpty ? "PASS — on screen, .readOnly, and excluded from the take" : "FAIL — \(failures.joined(separator: "; "))")")
            return failures.isEmpty ? 0 : 1
        }
        // Negative control: with nothing excluded the card MUST be recorded,
        // or the positive result above is vacuous.
        if !leaked {
            failures.append("nothing excluded and the card still did not reach the video "
                + "(\(videoMagenta) px) — the assertion above cannot fail")
        }
        print("result:        \(failures.isEmpty ? "PASS — recorded, as an unexcluded .readOnly card must be" : "FAIL — \(failures.joined(separator: "; "))")")
        return failures.isEmpty ? 0 : 1
    }

    /// What the selection overlay tells ScreenCaptureKit, in all four states.
    ///
    /// The property that matters is the third row: with the preference on, a
    /// take being written must still force the overlay back to `.none`. A
    /// `.readOnly` overlay raised during a recording lands in the video and
    /// cannot be excluded afterwards — `SCContentFilter` is fixed when the
    /// stream starts and the panel does not exist yet at that point. That is
    /// the one combination where the convenience would cost the user a ruined
    /// recording, so it is asserted rather than trusted.
    private static func overlaySharing() async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        let coordinator = CaptureCoordinator()
        let overlay = coordinator.overlay
        let preferences = Preferences.shared
        let restore = preferences.overlayVisibleToScreenSharing
        defer { preferences.overlayVisibleToScreenSharing = restore }

        var failures: [String] = []

        func check(visible: Bool, recording: Bool, expected: NSWindow.SharingType) async {
            preferences.overlayVisibleToScreenSharing = visible
            overlay.isRecordingActive = { recording }
            let flag = CompletionFlag()
            Task {
                _ = await overlay.present(windows: [])
                flag.markDone()
            }
            try? await Task.sleep(for: .milliseconds(160))
            let actual = overlay.sharingTypesForTest
            overlay.tearDown()
            _ = await flag.wait(upTo: .seconds(2))
            try? await Task.sleep(for: .milliseconds(120))

            let ok = !actual.isEmpty && actual.allSatisfy { $0 == expected }
            let names = actual.map { $0 == NSWindow.SharingType.none ? "none" : "readOnly" }
            print("  \(ok ? "ok  " : "FAIL") preference=\(visible ? "visible" : "hidden") "
                + "recording=\(recording) -> \(names.joined(separator: ",")) "
                + "(want \(expected == NSWindow.SharingType.none ? "none" : "readOnly"))")
            if !ok { failures.append("visible=\(visible) recording=\(recording)") }
        }

        await check(visible: false, recording: false, expected: .none)
        await check(visible: false, recording: true, expected: .none)
        await check(visible: true, recording: false, expected: .readOnly)
        // The one that protects a take in progress.
        await check(visible: true, recording: true, expected: .none)

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
                windows: [], suggestsWindows: false, requiresConfirmation: true)
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
        // Gone from the toolbar, and yet not gone. Committing hands the window on
        // instead of dismissing it: the recorder adopts this exact panel, so the
        // bar the user pressed Record on is the one they later press Stop on. If
        // this ever comes back nil, that bar is being thrown away and rebuilt —
        // the two-windows-pretending-to-be-one arrangement this replaced.
        let handedOver = overlay.takeHandedOverBar()
        check(handedOver != nil, "the bar was handed over rather than dismissed")
        check(handedOver?.isVisible == true, "and is still on screen, waiting to be adopted")
        check(handedOver?.role == .selection,
              "still at the selection's level until the take re-levels it")
        check(overlay.takeHandedOverBar() == nil, "and only one owner can claim it")
        handedOver?.dismiss()
        overlay.tearDown()
        try await Task.sleep(for: .milliseconds(120))

        // --- dragging an armed selection moves it ----------------------------
        let moveFlag = CompletionFlag()
        Task {
            _ = await overlay.present(
                windows: [], suggestsWindows: false, requiresConfirmation: true)
            moveFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))
        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(100))
        let beforeMove = overlay.selectionRectForTest
        let barBeforeMove = overlay.toolbarFrameForTest

        let shift = CGVector(dx: 40, dy: -30)
        overlay.dragForTest(
            from: CGPoint(x: selection.midX, y: selection.midY),
            to: CGPoint(x: selection.midX + shift.dx, y: selection.midY + shift.dy))
        try await Task.sleep(for: .milliseconds(100))
        let afterMove = overlay.selectionRectForTest

        check(overlay.isArmedForTest, "dragging from inside keeps the selection armed")
        check(overlay.toolbarIsVisibleForTest, "and keeps its bar")
        if let before = beforeMove, let after = afterMove {
            print("  moved: \(rectString(before)) -> \(rectString(after))")
            check(after.size == before.size, "the size is unchanged by a move")
            check(abs(after.minX - (before.minX + shift.dx)) < 1
                    && abs(after.minY - (before.minY + shift.dy)) < 1,
                  "it moved by exactly the drag")
        } else {
            check(false, "there is a selection to move")
        }
        // The bar hangs off the selection, so it has to have come along.
        if let before = barBeforeMove, let after = overlay.toolbarFrameForTest {
            check(abs(after.midX - (before.midX + shift.dx)) < 1,
                  "the bar followed the selection")
        }

        // Off the edge: clamped as a translation, so the rect stays whole. Letting
        // it be cut by the screen edge would silently change the size the user
        // picked, which is the one thing a move must not do.
        overlay.dragForTest(
            from: CGPoint(x: (afterMove ?? selection).midX, y: (afterMove ?? selection).midY),
            to: CGPoint(x: screen.frame.maxX + 4000, y: screen.frame.minY - 4000))
        try await Task.sleep(for: .milliseconds(100))
        if let shoved = overlay.selectionRectForTest, let before = beforeMove {
            print("  shoved off-screen: \(rectString(shoved))")
            check(shoved.size == before.size, "a move pushed off the edge keeps its size")
            check(screen.frame.contains(shoved), "and stays on the screen")
        }

        // --- and dragging an edge resizes it ---------------------------------
        //
        // All eight handles, because the arithmetic is eight near-identical cases
        // and a transposed pair is exactly the sort of thing that looks fine
        // until someone drags the one corner nobody tried. Each is checked for
        // the side it moved *and* for the three it must not have.
        // Deliberately not whatever the move cases left behind: that rect is
        // jammed into the screen's corner, where half these pulls would be
        // clamped by the display edge and the test would be measuring the clamp.
        let base = selection
        let pulls: [(name: String, grab: CGPoint, to: CGPoint, expect: CGRect)] = [
            ("left edge", CGPoint(x: base.minX, y: base.midY),
             CGPoint(x: base.minX + 50, y: base.midY),
             CGRect(x: base.minX + 50, y: base.minY, width: base.width - 50, height: base.height)),
            ("right edge", CGPoint(x: base.maxX, y: base.midY),
             CGPoint(x: base.maxX + 30, y: base.midY),
             CGRect(x: base.minX, y: base.minY, width: base.width + 30, height: base.height)),
            ("top edge", CGPoint(x: base.midX, y: base.maxY),
             CGPoint(x: base.midX, y: base.maxY - 40),
             CGRect(x: base.minX, y: base.minY, width: base.width, height: base.height - 40)),
            ("bottom edge", CGPoint(x: base.midX, y: base.minY),
             CGPoint(x: base.midX, y: base.minY - 20),
             CGRect(x: base.minX, y: base.minY - 20, width: base.width, height: base.height + 20)),
            ("top-left", CGPoint(x: base.minX, y: base.maxY),
             CGPoint(x: base.minX + 25, y: base.maxY - 15),
             CGRect(x: base.minX + 25, y: base.minY,
                    width: base.width - 25, height: base.height - 15)),
            ("top-right", CGPoint(x: base.maxX, y: base.maxY),
             CGPoint(x: base.maxX - 25, y: base.maxY - 15),
             CGRect(x: base.minX, y: base.minY,
                    width: base.width - 25, height: base.height - 15)),
            ("bottom-left", CGPoint(x: base.minX, y: base.minY),
             CGPoint(x: base.minX + 25, y: base.minY + 15),
             CGRect(x: base.minX + 25, y: base.minY + 15,
                    width: base.width - 25, height: base.height - 15)),
            ("bottom-right", CGPoint(x: base.maxX, y: base.minY),
             CGPoint(x: base.maxX - 25, y: base.minY + 15),
             CGRect(x: base.minX, y: base.minY + 15,
                    width: base.width - 25, height: base.height - 15)),
        ]
        for pull in pulls {
            overlay.forceSelection(base, on: screen)
            overlay.confirmForTest()
            try await Task.sleep(for: .milliseconds(60))
            overlay.dragForTest(from: pull.grab, to: pull.to)
            try await Task.sleep(for: .milliseconds(60))
            let got = overlay.selectionRectForTest ?? .zero
            let matches = abs(got.minX - pull.expect.minX) < 2 && abs(got.minY - pull.expect.minY) < 2
                && abs(got.width - pull.expect.width) < 2 && abs(got.height - pull.expect.height) < 2
            print("  \(pull.name): \(rectString(got))"
                + (matches ? "" : "  expected \(rectString(pull.expect))"))
            check(matches, "dragging the \(pull.name) resizes exactly that side")
            check(overlay.isArmedForTest, "the \(pull.name) drag left it armed")
        }

        // Dragged past its own opposite edge, a rect must stop rather than turn
        // inside out. `SelectionModel.minimumSide` is the floor.
        overlay.forceSelection(base, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(60))
        overlay.dragForTest(
            from: CGPoint(x: base.minX, y: base.midY),
            to: CGPoint(x: base.maxX + 200, y: base.midY))
        try await Task.sleep(for: .milliseconds(60))
        if let collapsed = overlay.selectionRectForTest {
            print("  pulled through itself: \(rectString(collapsed))")
            // Precisely: parked at the minimum against an untouched right edge.
            // "Still has some size" was the first version of this assertion and
            // it passed on a rect that had flipped to the far side of the anchor
            // and come out 200 pt wide.
            check(abs(collapsed.width - SelectionModel.minimumSide) < 1
                    && abs(collapsed.maxX - base.maxX) < 1
                    && abs(collapsed.height - base.height) < 1,
                  "a resize dragged through the opposite edge stops at the minimum")
        }

        // And a drag that starts *outside* still means "start again": the old rect
        // is replaced by the one just drawn, which re-arms at mouse-up.
        let outside = CGPoint(x: selection.maxX + 80, y: selection.maxY + 80)
        overlay.dragForTest(from: outside, to: CGPoint(x: outside.x + 60, y: outside.y + 40))
        try await Task.sleep(for: .milliseconds(120))
        if let replaced = overlay.selectionRectForTest {
            print("  redrawn: \(rectString(replaced))")
            check(abs(replaced.minX - outside.x) < 2 && abs(replaced.minY - outside.y) < 2
                    && abs(replaced.width - 60) < 2 && abs(replaced.height - 40) < 2,
                  "a drag from outside drew a new selection rather than moving the old one")
        } else {
            check(false, "a drag from outside produced a selection")
        }
        overlay.tearDown()
        try await Task.sleep(for: .milliseconds(120))
        check(await moveFlag.wait(upTo: .seconds(2)), "tearDown resumed that presentation")

        // --- a new drag disarms ----------------------------------------------
        let secondFlag = CompletionFlag()
        Task {
            _ = await overlay.present(
                windows: [], suggestsWindows: false, requiresConfirmation: true)
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
            stillBox.outcome = await overlay.present(windows: [])
            stillFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))
        overlay.forceSelection(selection, on: screen)
        overlay.confirmForTest()
        let stillResumed = await stillFlag.wait(upTo: .seconds(2))
        check(stillResumed, "without requiresConfirmation, one confirm still commits")
        check(!overlay.toolbarIsVisibleForTest, "and no toolbar appears for screenshots")
        check(overlay.takeHandedOverBar() == nil, "and nothing is handed over either")
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

            let flag = CompletionFlag()
            let box = OutcomeBox()
            // Set by the paths that confirm a selection, so the outcome can be
            // checked. The paths that are *supposed* to cancel leave it false.
            var expectsConfirmation = false
            Task {
                box.outcome = await overlay.present(windows: windows)
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
                    _ = await overlay.present(windows: windows)
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
            _ = await overlay.present(windows: windows)
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
            if let output = await OutputPipeline.shared.process(result) {
                await previews.present(output)
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

        // 1b. isAcceptable is hit for every keypress while recording a
        // shortcut, so it must not trap and must make the right call for the
        // two interesting classes: bare F-keys are fine, bare letters are not.
        // (The kVK_F* codes are scattered — F1 = 122, F20 = 90 — which is why
        // this is worth pinning: a range over them traps at construction.)
        let acceptableCases: [(KeyCombo, Bool, String)] = [
            (KeyCombo(keyCode: UInt16(kVK_F1), modifiers: []), true, "bare F1"),
            (KeyCombo(keyCode: UInt16(kVK_F20), modifiers: []), true, "bare F20"),
            (KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: []), false, "bare A"),
            (KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]), true, "⌘A"),
            (KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command]), false, "⌘Q"),
            (KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [.command]), false, "⌘⎋"),
        ]
        for (candidate, expected, label) in acceptableCases {
            let got = candidate.isAcceptable
            print("acceptable:    \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) -> \(got)")
            if got != expected {
                failures.append("isAcceptable(\(label)) = \(got), expected \(expected)")
            }
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

        // 2b. The seen-actions migration. `bind(nil, to:)` stores a cleared
        // binding as absence, so absence alone cannot tell "cleared on purpose"
        // from "did not exist when this dictionary was written" — the ledger
        // does, and these fixtures pin its three obligations: seed the new
        // action, never resurrect, never steal.
        let comboL = KeyCombo(keyCode: UInt16(kVK_ANSI_L), modifiers: [.shift, .command])
        let legacy: [HotKeyAction: KeyCombo] = [.captureArea: combo]
        let seeded = Preferences.migratedHotkeys(legacy, seen: nil)
        print("migration:     pre-ledger dict -> captureScrolling "
            + (seeded[.captureScrolling]?.displayString ?? "<unbound>"))
        if seeded[.captureScrolling] != comboL {
            failures.append("migration did not seed ⌘⇧L for the new action")
        }
        if seeded[.captureArea] != combo {
            failures.append("migration disturbed an existing binding")
        }
        if seeded[.captureWindow] != nil {
            failures.append("migration resurrected a binding cleared before the ledger existed")
        }
        let clearedAfterSeen = Preferences.migratedHotkeys(
            legacy, seen: Set(HotKeyAction.allCases))
        if clearedAfterSeen[.captureScrolling] != nil {
            failures.append("migration resurrected a deliberately cleared ⌘⇧L")
        }
        let conflicted = Preferences.migratedHotkeys([.captureFullscreen: comboL], seen: nil)
        if conflicted[.captureScrolling] != nil {
            failures.append("migration bound ⌘⇧L twice")
        }
        if conflicted[.captureFullscreen] != comboL {
            failures.append("migration stole the user's ⌘⇧L from captureFullscreen")
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

        // 5. Duplicate combos. Carbon registers a combo once, so two actions
        // holding one means the second registration is refused and that action
        // silently never fires — and which of the two lost was decided by
        // Dictionary iteration order, i.e. it could change from launch to
        // launch. Recording a combo must therefore take it off whoever held it.
        // The user's real bindings are restored at the end of the block.
        let originalHotkeys = preferences.hotkeys
        let contested = KeyCombo(keyCode: UInt16(kVK_ANSI_6), modifiers: [.shift, .command])
        let bystander = KeyCombo(keyCode: UInt16(kVK_ANSI_7), modifiers: [.shift, .command])
        preferences.hotkeys = [:]
        preferences.bind(bystander, to: .captureWindow)
        preferences.bind(contested, to: .captureArea)
        preferences.bind(contested, to: .recordArea)
        let holders = HotKeyAction.allCases.filter { preferences.hotkeys[$0] == contested }
        print("steal:         \(contested.displayString) held by "
            + "\(holders.isEmpty ? "<nobody>" : holders.map(\.rawValue).joined(separator: ", "))")
        if holders != [.recordArea] {
            failures.append("\(contested.displayString) is claimed by \(holders.count) actions")
        }
        if preferences.hotkeys[.captureWindow] != bystander {
            failures.append("stealing a combo disturbed an unrelated binding")
        }
        preferences.bind(nil, to: .recordArea)
        if preferences.hotkeys[.recordArea] != nil {
            failures.append("clearing a binding left it in place")
        }
        if preferences.hotkeys[.captureWindow] != bystander {
            failures.append("clearing a binding took another one with it")
        }
        preferences.hotkeys = originalHotkeys

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

    // MARK: - Scrolling capture

    /// The stitcher against frames whose provenance is exact: every row of the
    /// source is a unique colour, so the only way the output can equal the
    /// source is for every measured shift to have been right. Headless — no
    /// screen involved, so this can never be INCONCLUSIVE.
    ///
    /// `broken` sabotages the shift search inside the stitcher and the run must
    /// FAIL; `make test` treats a green `--broken` run as BROKEN.
    private static func scrollStitchCheck(into directory: URL, broken: Bool) async throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }

        let width = 400
        let frameRows = 600
        let sourceRows = 3000
        let step = 380
        guard let source = uniqueRowImage(width: width, height: sourceRows) else {
            print("could not build the source image")
            return 2
        }

        /// Rows [offset, offset+frameRows) of the source, top-down — what a
        /// capture of the region would see with the content scrolled by
        /// `offset`. `stickyHeaderRows` paints a fixed banner over the top,
        /// the shape of a pinned page header.
        func frame(at offset: Int, stickyHeaderRows: Int = 0) -> CaptureResult? {
            guard var image = source.cropping(to: CGRect(
                x: 0, y: offset, width: width, height: frameRows)) else { return nil }
            if stickyHeaderRows > 0 {
                guard let bannered = paintingBanner(over: image, rows: stickyHeaderRows)
                else { return nil }
                image = bannered
            }
            return CaptureResult(
                image: image,
                pointSize: CGSize(width: CGFloat(width) / 2, height: CGFloat(frameRows) / 2),
                scale: 2,
                sourceDisplayID: CGMainDisplayID(),
                sourceDescription: "stitch test",
                capturedAt: Date())
        }

        // 1. The full run: seed, scroll in 380-row steps, land exactly on the
        // bottom. Every verdict is asserted, then the finished picture is
        // compared byte-for-byte against the unscrolled source.
        var config = ScrollStitcher.Config()
        config.brokenOverlapSearchForTest = broken
        let stitcher = ScrollStitcher(config: config)
        print("source:        \(width)×\(sourceRows), frames of \(frameRows) rows, step \(step)"
            + (broken ? "  [BROKEN SEARCH]" : ""))

        guard let first = frame(at: 0) else { return 2 }
        let seeded = await stitcher.append(first)
        check(seeded == .seeded, "first frame -> \(seeded), expected seeded")

        var offset = 0
        while offset < sourceRows - frameRows {
            let next = min(offset + step, sourceRows - frameRows)
            guard let capture = frame(at: next) else { return 2 }
            let verdict = await stitcher.append(capture)
            let expected = ScrollStitcher.Verdict.appended(
                newRows: next - offset, totalRows: next + frameRows)
            check(verdict == expected, "frame@\(next) -> \(verdict), expected \(expected)")
            offset = next
        }

        // A frame that did not move, a frame scrolled back up through stitched
        // content, a frame from a rescaled display. None of them may grow the
        // canvas.
        if let still = frame(at: offset) {
            let verdict = await stitcher.append(still)
            check(verdict == .skippedIdentical, "duplicate frame -> \(verdict)")
        }
        if let up = frame(at: offset - step) {
            let verdict = await stitcher.append(up)
            check(verdict == .repositioned(totalRows: sourceRows),
                  "scrolled-up frame -> \(verdict), "
                  + "expected repositioned(totalRows: \(sourceRows))")
        }

        // Recovery after losing the thread — the "no response after the Scroll
        // slower hint" bug. A fling leaves a gap (rejected, correctly), and
        // then the user goes back to somewhere already stitched: far from the
        // last aligned frame, so frame-to-frame alignment cannot see it. The
        // stitcher must relocate against the whole canvas and resume — and it
        // must NOT "relocate" a frame whose content the canvas has never seen.
        if let gone = frame(at: 0), let flung = frame(at: 2000) {
            let gapped = ScrollStitcher()
            _ = await gapped.append(flung)
            let fling = await gapped.append(gone)
            check(fling == .rejected(.cannotAlign),
                  "a fling past the whole band -> \(fling)")
        }
        if let ret = frame(at: 600) {
            // `stitcher` has the full source stitched and its last aligned
            // frame at 2020; position 600 is over 1400 rows away — far outside
            // frame-to-frame range, squarely inside the canvas.
            let verdict = await stitcher.append(ret)
            check(verdict == .repositioned(totalRows: sourceRows),
                  "returning deep into stitched content -> \(verdict), "
                  + "expected repositioned(totalRows: \(sourceRows))")
        }
        if let narrow = source.cropping(to: CGRect(x: 0, y: 0, width: 200, height: frameRows)) {
            let verdict = await stitcher.append(CaptureResult(
                image: narrow, pointSize: CGSize(width: 100, height: 300), scale: 2,
                sourceDisplayID: CGMainDisplayID(), sourceDescription: "stitch test",
                capturedAt: Date()))
            check(verdict == .rejected(.mismatchedFrame), "narrow frame -> \(verdict)")
        }

        // MARK: relocation on a mostly-blank page
        //
        // Returning to somewhere already stitched on a page that is three
        // quarters whitespace, after some of its lines finished loading.
        //
        // The whole-frame budget is 25 % of *every* row, and 60 changed rows out
        // of 600 is 10 % — comfortably inside it. But every one of those 60 is a
        // row that carries information, and a shortlist drawn from the
        // informative rows alone sees 40 % of its sample disagree. Any absolute
        // threshold applied to that sample throws this frame away while the
        // check it is meant to be pre-filtering for would have taken it. The
        // shortlist must therefore rank, never reject.
        //
        // Verified by reverting: with the candidate list gated on
        // `mismatches <= Int((1 - revisitMatchRatio) * Double(anchorCount))`
        // this reports rejected(.cannotAlign) and the run goes red.
        let sparseRows = 2400
        if let page = sparsePageImage(width: width, height: sparseRows) {
            func pageFrame(at offset: Int, disturbing: Set<Int> = []) -> CaptureResult? {
                guard var image = page.cropping(to: CGRect(
                    x: 0, y: offset, width: width, height: frameRows)) else { return nil }
                if !disturbing.isEmpty {
                    guard let touched = disturbingRows(of: image, rows: disturbing)
                    else { return nil }
                    image = touched
                }
                return CaptureResult(
                    image: image,
                    pointSize: CGSize(width: CGFloat(width) / 2, height: CGFloat(frameRows) / 2),
                    scale: 2, sourceDisplayID: CGMainDisplayID(),
                    sourceDescription: "sparse page", capturedAt: Date())
            }

            let sparse = ScrollStitcher(config: config)
            var at = 0
            if let seed = pageFrame(at: 0) { _ = await sparse.append(seed) }
            while at < sparseRows - frameRows {
                let next = min(at + step, sparseRows - frameRows)
                guard let capture = pageFrame(at: next) else { return 2 }
                _ = await sparse.append(capture)
                at = next
            }

            // Two out of every five text lines, spread through the frame.
            let settled = Set((0..<frameRows).filter { $0 % 4 == 0 && ($0 / 4) % 5 < 2 })
            print("sparse page:   \(settled.count) of \(frameRows) rows changed "
                + "(\(settled.count * 100 / frameRows)% of all rows, "
                + "40% of the informative ones)")

            // Every jump below has to be longer than frame-to-frame alignment
            // can reach — a frame overlapping the cursor by `minOverlapRows` or
            // more is handled by `shift` and never gets near `relocate`. The
            // cursor sits at 1800 after the loop, so 400 is 1400 rows away and
            // relocation is the only road to it. An earlier draft of this test
            // jumped 400 rows, stayed green with the fix reverted, and proved
            // nothing at all.
            if let changed = pageFrame(at: 400, disturbing: settled) {
                let verdict = await sparse.append(changed)
                check(verdict == .repositioned(totalRows: sparseRows),
                      "sparse page, settled lines -> \(verdict), "
                      + "expected repositioned(totalRows: \(sparseRows))")
            }
            // The fixture itself: an untouched frame, equally far away, must
            // relocate too. If this one fails the check above says nothing about
            // budgets — it says the page is unmatchable.
            if let clean = pageFrame(at: 1700) {
                let verdict = await sparse.append(clean)
                check(verdict == .repositioned(totalRows: sparseRows),
                      "sparse page, unchanged frame -> \(verdict), "
                      + "expected repositioned(totalRows: \(sparseRows))")
            }
            // And the other direction: dropping the threshold must not make
            // relocation take anything at all. Content this canvas has never
            // seen still has to be refused — the ranking only decides *which*
            // 64 candidates get the full comparison, never whether one passes.
            if let alien = uniqueRowImage(width: width, height: frameRows) {
                let verdict = await sparse.append(CaptureResult(
                    image: alien,
                    pointSize: CGSize(width: CGFloat(width) / 2, height: CGFloat(frameRows) / 2),
                    scale: 2, sourceDisplayID: CGMainDisplayID(),
                    sourceDescription: "sparse page", capturedAt: Date()))
                check(verdict == .rejected(.cannotAlign),
                      "sparse page, content never seen -> \(verdict), "
                      + "expected rejected(.cannotAlign)")
            }
        }

        if let result = await stitcher.finalize(
            sourceDisplayID: CGMainDisplayID(), sourceDescription: "Scrolling Capture") {
            print("stitched:      \(result.image.width)×\(result.image.height) px, "
                + "\(Int(result.pointSize.width))×\(Int(result.pointSize.height)) pt @\(Int(result.scale))x")
            try? ImageEncoder.write(
                result.image, to: directory.appendingPathComponent("scroll-stitch.png"), scale: 2)
            check(result.image.width == width && result.image.height == sourceRows,
                  "stitched size \(result.image.width)×\(result.image.height), "
                  + "expected \(width)×\(sourceRows)")
            if result.image.height == sourceRows {
                let comparison = PixelCompare.compare(result.image, source)
                print("pixel diff:    \(comparison.summary)")
                check(comparison.identical, "stitched output differs from the source")
            }
        } else {
            failures.append("finalize returned nil")
        }

        if !broken {
            // 1a. Both directions. Start mid-document, scroll *up* (prepend),
            // scroll back down through stitched content (reposition, no
            // growth), then past the old frontier (append). The finished
            // picture must equal the source strip exactly — any double-counted
            // or dropped band changes the pixels.
            let both = ScrollStitcher()
            if let f380 = frame(at: 380), let f0 = frame(at: 0),
               let f380b = frame(at: 380), let f760 = frame(at: 760) {
                _ = await both.append(f380)
                let upward = await both.append(f0)
                check(upward == .appended(newRows: 380, totalRows: 980),
                      "upward scroll -> \(upward), expected appended(newRows: 380, totalRows: 980)")
                let back = await both.append(f380b)
                check(back == .repositioned(totalRows: 980),
                      "scrolling back down inside the stitch -> \(back)")
                let past = await both.append(f760)
                check(past == .appended(newRows: 380, totalRows: 1360),
                      "past the old frontier -> \(past)")
                if let result = await both.finalize(
                    sourceDisplayID: CGMainDisplayID(), sourceDescription: "Scrolling Capture"),
                   let expected = source.cropping(to: CGRect(
                    x: 0, y: 0, width: width, height: 1360)) {
                    let comparison = PixelCompare.compare(result.image, expected)
                    print("both-way diff: \(comparison.summary)")
                    check(comparison.identical, "both-way output differs from the source")
                } else {
                    failures.append("both-way finalize failed")
                }
            }

            // 1b. Chat-shaped content — the case the unique-row source cannot
            // represent, learned from a real mis-stitched capture (2026-08-02):
            // text lines whose *segment means* are identical (same ink
            // density) while their pixels differ, separated by flat
            // background. Row signatures alone cannot tell a one-row shift
            // from the true one here — only pixels can — so this is the leg
            // that keeps the stitcher honest about verifying its shift.
            let chatRows = 1600
            if let chat = chatLikeImage(width: width, height: chatRows) {
                func chatFrame(at offset: Int) -> CaptureResult? {
                    guard let crop = chat.cropping(to: CGRect(
                        x: 0, y: offset, width: width, height: frameRows)) else { return nil }
                    return CaptureResult(
                        image: crop,
                        pointSize: CGSize(
                            width: CGFloat(width) / 2, height: CGFloat(frameRows) / 2),
                        scale: 2, sourceDisplayID: CGMainDisplayID(),
                        sourceDescription: "stitch test", capturedAt: Date())
                }
                let chatStitcher = ScrollStitcher()
                // 374, not a round number: six rows *up* from the last frame,
                // with the frame's top rows flat — the phase where a wrong
                // positive shift can align text lines class-for-class and only
                // their pixels disagree.
                if let f0 = chatFrame(at: 0), let f1 = chatFrame(at: 380),
                   let up = chatFrame(at: 374) {
                    _ = await chatStitcher.append(f0)
                    let verdict = await chatStitcher.append(f1)
                    check(verdict == .appended(newRows: step, totalRows: 980),
                          "chat-shaped scroll -> \(verdict), "
                          + "expected appended(newRows: \(step), totalRows: 980)")
                    let upVerdict = await chatStitcher.append(up)
                    check(upVerdict == .repositioned(totalRows: 980),
                          "chat-shaped upward scroll inside the stitch -> \(upVerdict), "
                          + "expected repositioned(totalRows: 980)")
                    if let result = await chatStitcher.finalize(
                        sourceDisplayID: CGMainDisplayID(),
                        sourceDescription: "Scrolling Capture"),
                       let expected = chat.cropping(to: CGRect(
                        x: 0, y: 0, width: width, height: 980)) {
                        let comparison = PixelCompare.compare(result.image, expected)
                        print("chat diff:     \(comparison.summary)")
                        check(comparison.identical, "chat-shaped output differs from the source")
                    } else {
                        failures.append("chat-shaped finalize failed")
                    }
                } else {
                    failures.append("could not build the chat-shaped frames")
                }
            } else {
                failures.append("could not build the chat-shaped source")
            }

            // 2. A sticky header: a 40-row banner pinned over every frame. It
            // must appear exactly once, with the content below it complete.
            let headerRows = 40
            let sticky = ScrollStitcher()
            for off in [0, 380, 760] {
                guard let capture = frame(at: off, stickyHeaderRows: headerRows) else { return 2 }
                let verdict = await sticky.append(capture)
                let expected: ScrollStitcher.Verdict = off == 0
                    ? .seeded
                    : .appended(newRows: step, totalRows: off + frameRows)
                check(verdict == expected, "sticky frame@\(off) -> \(verdict), expected \(expected)")
            }
            if let result = await sticky.finalize(
                sourceDisplayID: CGMainDisplayID(), sourceDescription: "Scrolling Capture"),
               let expected = bannerExpectation(
                source: source, width: width, rows: 760 + frameRows, headerRows: headerRows) {
                let comparison = PixelCompare.compare(result.image, expected)
                print("sticky diff:   \(comparison.summary)")
                check(comparison.identical, "sticky-header output differs from expectation")
            } else {
                failures.append("sticky-header finalize or expectation failed")
            }

            // 1c. Revisit-refresh — the frozen-fade bug: rows captured
            // mid-animation (a chat streaming in renders arriving lines at
            // half opacity) stay wrong forever if the canvas interior is
            // never written. Scrolling back over settled content must heal
            // exactly the rows that changed.
            if let dimmed = dimmingRows(of: source, from: 500, to: 560) {
                let healer = ScrollStitcher()
                func dimFrame(at offset: Int) -> CaptureResult? {
                    guard let crop = dimmed.cropping(to: CGRect(
                        x: 0, y: offset, width: width, height: frameRows)) else { return nil }
                    return CaptureResult(
                        image: crop,
                        pointSize: CGSize(
                            width: CGFloat(width) / 2, height: CGFloat(frameRows) / 2),
                        scale: 2, sourceDisplayID: CGMainDisplayID(),
                        sourceDescription: "stitch test", capturedAt: Date())
                }
                if let d0 = dimFrame(at: 0), let d380 = dimFrame(at: 380),
                   let revisit = frame(at: 190) {
                    _ = await healer.append(d0)
                    _ = await healer.append(d380)
                    let verdict = await healer.append(revisit)
                    check(verdict == .repositioned(totalRows: 980),
                          "revisiting settled content -> \(verdict)")
                    if let result = await healer.finalize(
                        sourceDisplayID: CGMainDisplayID(),
                        sourceDescription: "Scrolling Capture"),
                       let expected = source.cropping(to: CGRect(
                        x: 0, y: 0, width: width, height: 980)) {
                        let comparison = PixelCompare.compare(result.image, expected)
                        print("heal diff:     \(comparison.summary)")
                        check(comparison.identical,
                              "revisit did not heal the mid-animation rows")
                    } else {
                        failures.append("heal finalize failed")
                    }
                }
            } else {
                failures.append("could not build the dimmed source")
            }

            // 1d. The refresh must never stamp a sticky *footer* into the
            // canvas interior: its rows differ from the content there by
            // construction, and they are exactly the rows revisit-refresh is
            // forbidden to touch.
            if let footered = paintingBottomBanner(over: source, rows: 40) {
                let guarded = ScrollStitcher()
                func footFrame(at offset: Int) -> CaptureResult? {
                    guard let crop = footered.cropping(to: CGRect(
                        x: 0, y: offset, width: width, height: frameRows - 40)),
                        let framed = paintingBottomBanner(over: crop, rows: 40)
                    else { return nil }
                    return CaptureResult(
                        image: framed,
                        pointSize: CGSize(
                            width: CGFloat(width) / 2,
                            height: CGFloat(frameRows - 40) / 2),
                        scale: 2, sourceDisplayID: CGMainDisplayID(),
                        sourceDescription: "stitch test", capturedAt: Date())
                }
                _ = await guarded.append(footFrame(at: 0)!)
                _ = await guarded.append(footFrame(at: 380)!)
                let verdict = await guarded.append(footFrame(at: 190)!)
                check(verdict == .repositioned(totalRows: 940),
                      "footered revisit -> \(verdict)")
                if let result = await guarded.finalize(
                    sourceDisplayID: CGMainDisplayID(),
                    sourceDescription: "Scrolling Capture") {
                    // The banner belongs at the very bottom and nowhere else.
                    // The match is a tight triple, not "reddish": the unique-row
                    // source legitimately sweeps through red on one channel.
                    let bytes = rgba(of: result.image)
                    var strayBannerRows = 0
                    for row in 0..<(result.image.height - 40) {
                        let p = (row * result.image.width + result.image.width / 2) * 4
                        if abs(Int(bytes[p]) - 204) <= 6,
                           abs(Int(bytes[p + 1]) - 26) <= 6,
                           abs(Int(bytes[p + 2]) - 26) <= 6 {
                            strayBannerRows += 1
                        }
                    }
                    check(strayBannerRows == 0,
                          "no footer rows stamped mid-canvas (found \(strayBannerRows))")
                } else {
                    failures.append("footered finalize failed")
                }
            } else {
                failures.append("could not build the footered source")
            }

            // 2b. The sticky header, scrolling *up*: revealed rows must slot
            // in under the banner, never above it.
            let stickyUp = ScrollStitcher()
            if let f380 = frame(at: 380, stickyHeaderRows: 40),
               let f0 = frame(at: 0, stickyHeaderRows: 40) {
                _ = await stickyUp.append(f380)
                let verdict = await stickyUp.append(f0)
                check(verdict == .appended(newRows: step, totalRows: 980),
                      "sticky upward -> \(verdict), expected appended(newRows: \(step), totalRows: 980)")
                if let result = await stickyUp.finalize(
                    sourceDisplayID: CGMainDisplayID(), sourceDescription: "Scrolling Capture"),
                   let expected = bannerExpectation(
                    source: source, width: width, rows: 980, headerRows: 40) {
                    let comparison = PixelCompare.compare(result.image, expected)
                    print("sticky-up diff:\(comparison.summary)")
                    check(comparison.identical, "sticky upward output differs from expectation")
                } else {
                    failures.append("sticky upward finalize or expectation failed")
                }
            }

            // 3. The cap. Past maxCanvasBytes the stitcher must surrender the
            // session rather than the machine.
            var small = ScrollStitcher.Config()
            small.maxCanvasBytes = width * 4 * 1000
            let capped = ScrollStitcher(config: small)
            if let f0 = frame(at: 0), let f1 = frame(at: 380), let f2 = frame(at: 760) {
                _ = await capped.append(f0)
                let under = await capped.append(f1)
                check(under == .appended(newRows: step, totalRows: 980),
                      "under-cap append -> \(under)")
                let over = await capped.append(f2)
                check(over == .canvasFull(totalRows: 1360), "over-cap append -> \(over)")
            }
        }

        return report(failures)
    }

    /// Every row its own colour, with no near-period anywhere: red and green
    /// encode the row index exactly, and blue is the high byte of a
    /// multiplicative hash. The hash matters — `(row * k) & 0xFF` for any `k`
    /// repeats every 256 rows, and with the stitcher comparing rows within a
    /// tolerance, rows 256 apart (red off by 1, green off by 1, blue off by 0)
    /// counted as "the same row" and legitimised a wrong shift.
    private static func uniqueRowImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        for row in 0..<height {
            let colour = rowColour(row)
            context.setFillColor(CGColor(
                srgbRed: colour.redComponent, green: colour.greenComponent,
                blue: colour.blueComponent, alpha: 1))
            // The context is bottom-up; top-down row i lives at CG y = height-1-i.
            context.fill(CGRect(x: 0, y: height - 1 - row, width: width, height: 1))
        }
        return context.makeImage()
    }

    /// Chat-shaped content: 14-row "text lines" on a 40-row rhythm over a flat
    /// dark background, where every text row carries *exactly* the same ink
    /// fraction in every sampled segment — so all text rows share one segment
    /// mean, like real prose does — but the ink sits at line-specific
    /// positions, so their pixels differ. Signature comparison finds these
    /// rows interchangeable; only pixel comparison can align them.
    private static func chatLikeImage(width: Int, height: Int) -> CGImage? {
        let bg: (UInt8, UInt8, UInt8) = (30, 30, 32)
        let ink: (UInt8, UInt8, UInt8) = (220, 220, 225)
        func mix(_ a: Int, _ b: Int, _ c: Int) -> UInt64 {
            var x = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15
            x ^= UInt64(truncatingIfNeeded: b) &* 0xBF58_476D_1CE4_E5B9
            x ^= UInt64(truncatingIfNeeded: c) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            x = x &* 0xD6E8_FEB8_6659_FD93
            x ^= x >> 27
            return x
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let block = row / 40
            let inBlock = row % 40
            let isText = inBlock < 14
            for x in 0..<width {
                let p = (row * width + x) * 4
                var colour = bg
                if isText {
                    // The stitcher samples every 4th pixel and averages 25
                    // samples per segment. Each segment-aligned run of 25
                    // sampled cells gets *exactly* 7 ink cells — same mean in
                    // every segment of every text row, matching how two lines
                    // of prose average out the same — at positions derived
                    // from (line, row-in-line, segment), so the pixels differ.
                    let cell = x / 4
                    let group = cell / 25
                    let slot = cell % 25
                    let seed = mix(block, inBlock, group)
                    let base = Int(seed % 25)
                    var step = 1 + Int((seed >> 8) % 24)
                    if step % 5 == 0 { step += 1 }
                    var isInk = false
                    for k in 0..<7 where (base + k * step) % 25 == slot {
                        isInk = true
                    }
                    if isInk { colour = ink }
                }
                bytes[p] = colour.0
                bytes[p + 1] = colour.1
                bytes[p + 2] = colour.2
                bytes[p + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// A page shaped like prose: paper, with one line of "text" every fourth
    /// row. Three quarters of it carries no information at all.
    ///
    /// That ratio is the point. The stitcher's whole-frame budget is a share of
    /// *every* row, and a blank row matches whatever it is laid against, so
    /// those rows enlarge the allowance without ever spending it. Any check
    /// that samples only the rows that mean something is therefore working
    /// against a much smaller effective budget than the one it was derived
    /// from. `uniqueRowImage` cannot show this — every row of it is
    /// informative, so the two budgets agree and the gap never opens.
    private static func sparsePageImage(width: Int, height: Int) -> CGImage? {
        let paper: (UInt8, UInt8, UInt8) = (250, 250, 246)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for x in 0..<width {
                let p = (row * width + x) * 4
                var colour = paper
                if row % 4 == 0 {
                    // Ink whose density varies by segment as well as by row, so
                    // the row is informative under both of the stitcher's
                    // measures: horizontal contrast for the pixel pass, and a
                    // spread across the signature's components for the
                    // signature pass.
                    let segment = x * 4 / width
                    let seed = (row &* 2_654_435_761 &+ segment &* 40_503) & 0x7FFF
                    if (x &+ seed) % (2 + segment) == 0 {
                        colour = (UInt8(seed & 0x7F), UInt8((seed >> 4) & 0x7F),
                                  UInt8((seed >> 8) & 0x7F))
                    }
                }
                bytes[p] = colour.0
                bytes[p + 1] = colour.1
                bytes[p + 2] = colour.2
                bytes[p + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// Repaints the given top-down rows — the shape of a page whose lazy
    /// content finished arriving between two visits to the same place.
    ///
    /// Saturated on purpose. These rows have to stay *informative*, or they
    /// simply drop out of the anchor sample, and the fixture would then be
    /// applying no pressure at all.
    private static func disturbingRows(of image: CGImage, rows: Set<Int>) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.07, blue: 0.07, alpha: 1))
        for row in rows {
            context.fill(CGRect(
                x: 0, y: image.height - 1 - row, width: image.width, height: 1))
        }
        return context.makeImage()
    }

    /// Rows [from, to) at half brightness — the shape of a streaming chat's
    /// fade-in caught mid-animation.
    private static func dimmingRows(of image: CGImage, from: Int, to: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
        context.fill(CGRect(
            x: 0, y: image.height - to, width: image.width, height: to - from))
        return context.makeImage()
    }

    private static func paintingBottomBanner(over image: CGImage, rows: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: rows))
        return context.makeImage()
    }

    private static func paintingBanner(over image: CGImage, rows: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: image.height - rows, width: image.width, height: rows))
        return context.makeImage()
    }

    /// What the sticky-header run should produce: the banner once, then the
    /// source from under it down to the last frame's bottom edge.
    private static func bannerExpectation(
        source: CGImage, width: Int, rows: Int, headerRows: Int
    ) -> CGImage? {
        guard let body = source.cropping(to: CGRect(
            x: 0, y: headerRows, width: width, height: rows - headerRows)),
            let context = CGContext(
                data: nil, width: width, height: rows,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
        context.setShouldAntialias(false)
        context.draw(body, in: CGRect(x: 0, y: 0, width: width, height: rows - headerRows))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: rows - headerRows, width: width, height: headerRows))
        return context.makeImage()
    }

    /// The whole session, on the live screen: a borderless window of ours whose
    /// scroll view is driven programmatically — `scroll(to:)`, never synthesized
    /// wheel events — while the real coordinator loop captures and stitches.
    /// Content is the unique-row pattern in *points*, so every stitched row can
    /// be traced back to exactly one document row and compared.
    ///
    /// INCONCLUSIVE (exit 0, like every other INCONCLUSIVE in this file) when
    /// the region is not static before the run — the same stability sandwich as
    /// `--selftest-rect`.
    private static func scrollFlowCheck(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let screen = NSScreen.main,
              let displayID = ScreenIndex.displayID(of: screen) else {
            print("no main screen")
            return 2
        }

        // Geometry, all in points. The window is 460×400 with the region inset
        // 30 pt on every side, so the region's top edge sits 30 pt below the
        // window's — the row at the top of the stitch is document row 30.
        let windowSize = CGSize(width: 460, height: 400)
        let inset: CGFloat = 30
        let documentHeight: CGFloat = 2000
        let scrollStep: CGFloat = 120
        let scrollEnd: CGFloat = 1200
        let windowFrame = CGRect(
            x: (screen.visibleFrame.midX - windowSize.width / 2).rounded(),
            y: (screen.visibleFrame.midY - windowSize.height / 2).rounded(),
            width: windowSize.width, height: windowSize.height)
        let region = windowFrame.insetBy(dx: inset, dy: inset)
        let regionHeight = region.height   // 340
        let topDocumentRow = Int(inset)

        let window = NSWindow(
            contentRect: windowFrame, styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: windowSize))
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        let document = UniqueRowsDocumentView(frame: CGRect(
            x: 0, y: 0, width: windowSize.width, height: documentHeight))
        scrollView.documentView = document
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func scroll(to offset: CGFloat) {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scroll(to: 0)
        try await Task.sleep(for: .milliseconds(600))

        // The stability sandwich, plus a geometry sanity probe: the centre of
        // the region must show the document row the mapping predicts, or every
        // later assertion would be measuring the wrong thing.
        let engine = CaptureEngine()
        try await engine.refreshContent()
        var probeOptions = CaptureOptions.default
        probeOptions.showsCursor = false
        let first = try await engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: region), options: probeOptions)
        try await Task.sleep(for: .milliseconds(150))
        let second = try await engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: region), options: probeOptions)
        let drift = PixelCompare.compare(first.image, second.image)
        guard drift.isSamePicture else {
            print("live drift:    \(drift.summary)")
            print("result:        INCONCLUSIVE — the region is not static; re-run")
            // Exit 0: `make test` counts any non-zero exit as a failure, and
            // "the screen moved" is not one. The harness counts the printed
            // INCONCLUSIVE instead.
            return 0
        }
        let scale = first.scale
        print("region:        \(Int(region.width))x\(Int(regionHeight)) pt @\(Int(scale))x")

        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("  \(condition ? "ok  " : "FAIL") \(description)")
            if !condition { failures.append(description) }
        }

        let probeBytes = rgba(of: first.image)
        let probeRow = Int((regionHeight / 2) * scale)
        let probeDocRow = topDocumentRow + Int(regionHeight / 2)
        check(pixel(probeBytes, width: first.image.width, x: first.image.width / 2,
                    y: probeRow, matches: rowColour(probeDocRow)),
              "the geometry probe sees document row \(probeDocRow) mid-region")
        if !failures.isEmpty {
            print("result:        FAIL")
            return 1
        }

        // --- the scroll-style toolbar, clicked for real --------------------
        // The armed bar's `.scroll` face lays its Start pill out in its own
        // branch, and a layout branch nobody has ever hit is exactly how the
        // editor's Redact button died while every geometry assertion passed.
        // So: a synthesized click on whatever hit-testing returns at the
        // pill's centre, asserted on the consequence — `present()` resuming.
        let overlay = OverlayController()
        let armSelection = CGRect(x: 240, y: 260, width: 420, height: 300)
        let armBox = OutcomeBox()
        let armFlag = CompletionFlag()
        Task {
            armBox.outcome = await overlay.present(
                windows: [], suggestsWindows: false, requiresConfirmation: true,
                toolbarStyle: .scroll)
            armFlag.markDone()
        }
        try await Task.sleep(for: .milliseconds(140))
        overlay.forceSelection(armSelection, on: screen)
        overlay.confirmForTest()
        try await Task.sleep(for: .milliseconds(120))
        check(overlay.toolbarIsVisibleForTest, "the scroll-style bar is on screen once armed")

        func findPill(_ view: NSView) -> HUDPill? {
            if let pill = view as? HUDPill { return pill }
            for sub in view.subviews {
                if let found = findPill(sub) { return found }
            }
            return nil
        }
        let barPanel = NSApp.windows
            .compactMap { $0 as? FloatingBarPanel }
            .first { $0.isVisible }
        if let barPanel, let face = barPanel.contentView,
           let pill = findPill(face) {
            let centre = pill.convert(
                CGPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
            let hit = face.superview?.hitTest(centre) ?? face.hitTest(centre)
            check(hit is HUDPill, "the Start pill is what hit-testing returns "
                + "(got \(hit.map { "\(type(of: $0))" } ?? "nothing"))")
            click(hit, at: centre, in: barPanel)
        } else {
            check(false, "the armed bar has a pill to click")
        }
        let started = await armFlag.wait(upTo: .seconds(2))
        check(started, "clicking Start resumes present()")
        if case .area(_, let rect)? = armBox.outcome {
            check(rect == armSelection, "the outcome carries the armed rect")
        } else {
            check(false, "the outcome is .area (got \(String(describing: armBox.outcome)))")
        }
        overlay.takeHandedOverBar()?.dismiss()
        overlay.tearDown()
        try await Task.sleep(for: .milliseconds(200))

        // --- the session, ended through the toggle -------------------------
        let scroller = ScrollCaptureCoordinator(engine: engine, overlay: OverlayController())
        var results: [CaptureResult] = []
        scroller.onResult = { results.append($0) }

        scroller.startForTest(displayID: displayID, rectInAppKitGlobal: region)
        check(scroller.isActive, "the session is active")
        check(scroller.hudIsVisibleForTest, "the session bar is on screen")

        /// Waits for the stitch to reach the height this scroll position
        /// implies, instead of guessing with sleeps.
        func waitForRows(_ target: Int, upTo timeout: Duration) async -> Int {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var rows = 0
            while ContinuousClock.now < deadline {
                rows = await scroller.stitchedRowsForTest()
                if rows >= target { return rows }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return rows
        }

        let seeded = await waitForRows(Int(regionHeight * scale), upTo: .seconds(3))
        check(seeded >= Int(regionHeight * scale), "the first frame seeded \(seeded) rows")

        var offset: CGFloat = 0
        while offset < scrollEnd {
            offset += scrollStep
            scroll(to: offset)
            let target = Int((regionHeight + offset) * scale) - Int(scale)
            let rows = await waitForRows(target, upTo: .seconds(3))
            if rows < target {
                failures.append("position \(Int(offset)) never got stitched (\(rows)/\(target) rows)")
                break
            }
        }

        // The same binding again is the toggle that finishes it.
        await scroller.perform(.captureScrolling)
        check(!scroller.isActive, "the toggle ended the session")
        check(!scroller.hudIsVisibleForTest, "the bar came down with it")
        check(results.count == 1, "exactly one capture was delivered (got \(results.count))")

        if let result = results.first {
            check(result.sourceDescription == "Scrolling Capture",
                  "it is labelled Scrolling Capture")
            let expectedHeight = regionHeight + scrollEnd
            check(abs(result.pointSize.height - expectedHeight) <= 2,
                  "it is \(Int(result.pointSize.height)) pt tall (expected \(Int(expectedHeight)))")
            check(abs(result.pointSize.width - region.width) <= 1,
                  "it is \(Int(result.pointSize.width)) pt wide (expected \(Int(region.width)))")
            try? ImageEncoder.write(
                result.image, to: directory.appendingPathComponent("scroll-flow.png"),
                scale: result.scale)

            // Twenty rows sampled across the full height, each mapped back to
            // the one document row that can be there.
            let stitched = rgba(of: result.image)
            let totalPoints = Int(result.pointSize.height)
            var mismatches = 0
            for i in 0..<20 {
                let pointRow = 4 + i * (totalPoints - 8) / 20
                let pixelRow = min(
                    Int((CGFloat(pointRow) + 0.5) * result.scale), result.image.height - 1)
                let docRow = topDocumentRow + pointRow
                if !pixel(stitched, width: result.image.width, x: result.image.width / 2,
                          y: pixelRow, matches: rowColour(docRow)) {
                    mismatches += 1
                }
            }
            check(mismatches == 0, "sampled rows match their document rows (\(mismatches)/20 off)")
        }

        // --- scrolling up on a real window, then cancel --------------------
        // Starts mid-document and scrolls the content *up*: the stitch must
        // grow by prepending, on real captures with real dithering — the
        // headless legs prove the algorithm, this proves it against the
        // window server.
        scroll(to: 600)
        try await Task.sleep(for: .milliseconds(400))
        scroller.startForTest(displayID: displayID, rectInAppKitGlobal: region)
        _ = await waitForRows(Int(regionHeight * scale), upTo: .seconds(3))
        scroll(to: 600 - scrollStep)
        let upRows = await waitForRows(
            Int((regionHeight + scrollStep) * scale) - Int(scale), upTo: .seconds(3))
        check(upRows >= Int((regionHeight + scrollStep) * scale) - Int(scale),
              "scrolling up grew the stitch to \(upRows) rows")
        await scroller.cancel()
        check(!scroller.isActive, "cancel ended the second session")
        check(!scroller.hudIsVisibleForTest, "cancel took the bar down")
        check(results.count == 1, "cancel delivered nothing (still \(results.count))")

        print("result:        \(failures.isEmpty ? "PASS" : "FAIL")")
        return failures.isEmpty ? 0 : 1
    }

    /// The flow test's document: every point row its own colour, flipped so
    /// row 0 is the top and the clip offset reads as "rows scrolled past".
    private final class UniqueRowsDocumentView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let start = max(0, Int(dirtyRect.minY))
            let end = min(Int(bounds.height), Int(dirtyRect.maxY.rounded(.up)))
            for row in start..<end {
                SelfTest.rowColour(row).setFill()
                NSRect(x: 0, y: CGFloat(row), width: bounds.width, height: 1).fill()
            }
        }
    }

    /// The colour that identifies a row in both scroll tests — red and green
    /// encode the row index exactly; blue is the high byte of a multiplicative
    /// hash, chosen because it has no small period (see `uniqueRowImage`).
    private static func rowColour(_ row: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(row & 0xFF) / 255,
            green: CGFloat((row >> 8) & 0xFF) / 255,
            blue: CGFloat(Int((UInt32(truncatingIfNeeded: row) &* 2_654_435_761) >> 24)) / 255,
            alpha: 1)
    }

    /// ±5 per channel: the window server's colour-management dithering wobbles
    /// single pixels ±1–3 (measured 2026-08-02), and the row identity is
    /// carried by blue jumps of 97 per row, so ±5 cannot confuse two rows.
    private static func pixel(
        _ bytes: [UInt8], width: Int, x: Int, y: Int, matches colour: NSColor
    ) -> Bool {
        let index = (y * width + x) * 4
        guard index + 2 < bytes.count,
              let srgb = colour.usingColorSpace(.sRGB) else { return false }
        let expected = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
        return abs(Int(bytes[index]) - expected[0]) <= 5
            && abs(Int(bytes[index + 1]) - expected[1]) <= 5
            && abs(Int(bytes[index + 2]) - expected[2]) <= 5
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

        // --- a trigger arriving during the finalise -------------------------
        // `stop` hands control back for as long as the writer takes to close the
        // file, which is seconds for a long take. The state used to read `.idle`
        // for that whole window, so a hotkey landing in it walked past the guard
        // in `perform` and built a second stream on top of one still tearing
        // down.
        await recorder.perform(.recordFullscreen)
        check(recorder.isRecording, "a third recording started")
        try await Task.sleep(for: .seconds(1))
        let stopping = Task { await recorder.stop() }
        // Lets `stop` run as far as its first suspension, which is inside the
        // finalise. If the scheduler hands control back before it gets there the
        // trigger below simply acts as the toggle it is, and every assertion
        // still holds — the state is never `.idle` with a live take either way.
        await Task.yield()
        check(recorder.hasTakeInFlight, "the take counts as in flight while it finalises")
        await recorder.perform(.recordFullscreen)
        check(!recorder.isRecording, "a trigger during the finalise started nothing")
        await stopping.value
        check(!recorder.hasTakeInFlight, "the finalise finished and the state is idle again")
        check(outputs.count == 2, "the third take produced one more output (got \(outputs.count))")

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
        let size = RecordingHUDView.barSize()
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
        plainWindow: Bool, statusItem useStatusItem: Bool, excludeIDs: Bool = false
    ) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return permissionHint() }
        if let hint = LoginSession.noDisplaysHint {
            FileHandle.standardError.write(Data("error: \(hint)\n".utf8))
            return 2
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        FloatingBarPanel.usesSharingTypeNone = sharingNone
        RecordingHUDView.debugFillsMagenta = true

        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        let screen = ScreenIndex.screen(for: displayID)

        // Before this test's own magenta exists — see `waitUntilStageClear`.
        let stage = await waitUntilStageClear(on: displayID, upTo: .seconds(3))
        print("stage:         "
            + (stage.leftover == 0 ? "clear" : "STILL \(stage.leftover) px magenta")
            + " after \(stage.waited.milliseconds) ms")

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
            // Named in the filter only now, because the window has to exist
            // before it can be named — which is the whole reason this only
            // works in the hud-first ordering.
            if excludeIDs {
                let id = status?.button?.window?.windowNumber ?? plain?.windowNumber
                    ?? hud.windowIDs.first.map(Int.init)
                options.excludedWindowIDs = id.map { [CGWindowID($0)] } ?? []
                print("excluding:     window \(id.map(String.init) ?? "<none>") from the stream")
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
            else { "FloatingBarPanel (.recording: .statusBar, nonactivating)" }
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
        if excludeIDs {
            print("result:        \(leaked ? "FAIL" : "PASS") — "
                + (leaked
                    ? "named in excludingWindows and recorded anyway (\(magenta) px)"
                    : "on screen, .readOnly, and kept out of the video by its window ID"))
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

    /// Blocks until the display shows no debug magenta at all, and reports what
    /// it found on arrival.
    ///
    /// The pre-flight for every magenta-counting recording test. The suite runs
    /// them back to back as separate processes, and one run (2026-08-01) had
    /// `hud absent (.none)` and `plain window recorded` fail *together* —
    /// magenta in a video whose own surface was `.none`-hidden, the same shape
    /// as the M9 transient the plan never explained. Both tests passed 3×
    /// standalone and on every suite rerun, which is what leftovers from the
    /// previous test look like and a product bug does not. Until the stage is
    /// proven empty, a magenta count cannot be attributed to this test's
    /// surface at all.
    ///
    /// Returns whatever count it last saw, so the caller's log line finally
    /// says what was on stage before the test began — if the transient strikes
    /// again, the run itself names the contamination instead of leaving it a
    /// mystery to re-derive.
    private static func waitUntilStageClear(
        on displayID: CGDirectDisplayID, upTo timeout: Duration
    ) async -> (leftover: Int, waited: Duration) {
        let engine = CaptureEngine()
        var options = CaptureOptions.default
        options.excludedWindowIDs = []
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        var count = -1
        while true {
            guard
                let still = try? await engine.capture(.display(displayID), options: options)
            else { break }
            count = PixelCompare.count(still.image, matching: PixelCompare.isDebugMagenta)
            if count == 0 { break }
            guard ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return (count, started.duration(to: .now))
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
