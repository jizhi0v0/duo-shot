import AVFoundation
import AppKit
import CryptoKit
import QuartzCore
import DuoShotCLIWire

/// `--selftest-click-timeline <dir>`: a real take of a fixture while real
/// clicks are posted at it, and what ends up in the movie.
///
/// The fixture flips between red and blue on every left mouse-down it
/// receives, so the frame a click shows up in can be found in the video and
/// set against the time the timeline gives that click — which is what checks
/// the mapping from the host clock to the movie's timeline, rather than the
/// mapping checking itself.
enum ClickTimelineSelfTest {
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        print("  \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
        if !condition { failures.append(label) }
    }

    static func run(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else {
            print("result:        FAIL — no Screen Recording grant")
            return 1
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.screens[0]
        guard let displayID = ScreenIndex.displayID(of: screen) else { return 1 }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 120, y: visible.minY + 120, width: 400, height: 300)
        let fixture = FlipWindow(frame: frame)
        let outsider = FlipWindow(frame: CGRect(x: frame.maxX + 80, y: frame.minY, width: 160, height: 120))
        defer {
            fixture.orderOut(nil)
            outsider.orderOut(nil)
        }
        try await Task.sleep(for: .milliseconds(500))
        let region = DisplayGeometry.flipped(frame)
        let scale = screen.backingScaleFactor

        print("(1) a take with clicks posted at it")
        let url = directory.appendingPathComponent("clicks.mp4")
        let before = directory.appendingPathComponent("clicks-before-embedding.mp4")
        try? FileManager.default.removeItem(at: url)
        let engine = RecordingEngine()
        engine.copyBeforeEmbeddingForTest = before
        var options = RecordingOptions.default
        // On, so the untouched-samples check covers an audio track too.
        options.capturesSystemAudio = true
        options.showsMouseClicks = false
        // The pointer moving into the picture before each click is a change of
        // its own, and would be the one `--scene` reports.
        options.showsCursor = false
        let recording = try await engine.start(
            .area(displayID: displayID, rectInAppKitGlobal: frame), options: options, to: url)

        // Global points, origin top-left: where each click is posted.
        let insideA = CGPoint(x: region.minX + 100, y: region.minY + 80)
        let insideB = CGPoint(x: region.minX + 300, y: region.minY + 220)
        let outside = DisplayGeometry.flipped(CGPoint(x: outsider.frame.midX, y: outsider.frame.midY))
        var posted: [(point: CGPoint, host: Double, button: CGMouseButton, inside: Bool)] = []
        try await Task.sleep(for: .milliseconds(500))
        for (point, button, inside) in [(insideA, CGMouseButton.left, true), (insideB, .left, true),
                                        (outside, .left, false), (insideA, .right, true),
                                        (insideB, .left, true)] {
            let host = try await postClick(at: point, button: button)
            posted.append((point, host, button, inside))
            try await Task.sleep(for: .milliseconds(550))
        }
        // A change nobody clicked for, well over a second after the last click.
        try await Task.sleep(for: .milliseconds(700))
        fixture.flip()
        try await Task.sleep(for: .milliseconds(600))
        let result = try await engine.stop()
        let report = engine.lastEmbedReportForTest

        let clicks = try await ClickTimeline.read(from: url)
        let downs = clicks.filter { $0.phase == "down" }
        check(report != nil && result.clicks == 10 && clicks.count == 10 && downs.count == 5,
              "the timeline is in the movie: 5 downs and 5 ups",
              "result.clicks=\(result.clicks) read=\(clicks.count) method=\(report?.method ?? "none") failure=\(engine.lastEmbedFailureForTest ?? "-")")
        guard let anchor = report?.anchorHostTime, downs.count == posted.count else {
            return finish()
        }
        print(String(format: "  anchored by %@, mean error %.3f ms",
                     report?.method ?? "?", (report?.anchorError ?? .nan) * 1000))

        // The anchor against ScreenCaptureKit's own log of when each frame was:
        // with the right anchor, every frame in the movie lands on a host time
        // the stream actually delivered. A wrong one lands between frames.
        // (An error of exactly one whole frame on a perfectly steady rate would
        // still land on frames; the picture check below bounds that side.)
        // 1 ms, because the movie keeps sample times in 1/600 s: a right
        // anchor still misses by up to 0.83 ms.
        let hostFrames = recording.completeFrameHostTimes
        let movieFrames = try await ClickTimelineEmbedder.videoMovieTimes(of: AVURLAsset(url: url))
        let misses = movieFrames.map { m in hostFrames.map { abs($0 - (m + anchor)) }.min() ?? 1 }
        let worst = misses.max() ?? 1
        check(!movieFrames.isEmpty && worst < 0.001,
              "every frame of the movie lands on a frame the stream delivered, at that host time",
              String(format: "%d frames, worst miss %.3f ms", movieFrames.count, worst * 1000))

        print("(2) each click at its time and its place")
        let frameInterval = 1.0 / Double(options.frameRate)
        for (index, (click, truth)) in zip(downs, posted).enumerated() {
            let expected = truth.host - anchor
            check(abs(click.t - expected) < frameInterval,
                  "click \(index + 1): the event's own time, within one frame of when it was posted",
                  String(format: "timeline %.4f s, posted %.4f s, off by %.1f ms", click.t, expected,
                         (click.t - expected) * 1000))
            let px = (truth.point.x - region.minX) * scale, py = (truth.point.y - region.minY) * scale
            check(abs(click.x - truth.point.x) <= 0.5 && abs(click.y - truth.point.y) <= 0.5
                    && abs(click.px - px) <= 1 && abs(click.py - py) <= 1,
                  "click \(index + 1): exact position, global points and video pixels",
                  String(format: "(%.1f,%.1f) pt (%.1f,%.1f) px, posted (%.1f,%.1f) pt (%.1f,%.1f) px",
                         click.x, click.y, click.px, click.py, truth.point.x, truth.point.y, px, py))
            check(click.outside == !truth.inside && click.button == (truth.button == .left ? "left" : "right"),
                  "click \(index + 1): \(truth.inside ? "inside" : "outside, flagged"), \(click.button)")
        }

        // The picture agrees with the mapping. Each flip of the fixture is
        // logged on the host clock as it happens; on the movie's timeline that
        // is `host - anchor`, and the first frame showing it cannot come before
        // it — a wrong anchor puts frames ahead of what they show — and comes
        // within the draw, composite and capture latency (measured 39–74 ms).
        let colours = try await centreColours(of: url)
        var movieChanges: [Double] = []
        for (previous, next) in zip(colours, colours.dropFirst()) where previous.colour != next.colour {
            movieChanges.append(next.t)
        }
        let flips: [Double] = fixture.flipLog.map { $0.0 - anchor }
        let flipText = flips.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        let changeText = movieChanges.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        print("  fixture flips at [\(flipText)], movie changes at [\(changeText)]")
        check(movieChanges.count == flips.count, "every flip of the fixture is in the movie",
              "\(flips.count) flips, \(movieChanges.count) changes")
        for (index, flip) in flips.enumerated() {
            let shown: Double? = movieChanges.first { $0 >= flip - frameInterval }
            var detail = "no change found"
            var good = false
            if let shown {
                let lag = shown - flip
                good = lag >= 0 && lag <= 0.1
                detail = String(format: "%.1f ms after", lag * 1000)
            }
            let label = String(format: "flip %d at %.3f s: shown in the first frame after it, not before", index + 1, flip)
            check(good, label, detail)
        }

        print("(3) the original samples are untouched")
        let original = try await mediaDigest(of: before)
        let embedded = try await mediaDigest(of: url)
        check(!original.isEmpty && original == embedded,
              "every audio and video sample byte-identical, at the same movie times",
              "\(original.map { "\($0.key): \($0.value.prefix(40))" }) vs \(embedded.map { "\($0.key): \($0.value.prefix(40))" })")

        print("(4) a trim shifts the clicks or drops them, never keeps them as they were")
        let trimmed = directory.appendingPathComponent("clicks-trimmed.mp4")
        try? FileManager.default.removeItem(at: trimmed)
        try FileManager.default.copyItem(at: url, to: trimmed)
        let cut = 1.3
        _ = try await VideoTrim.apply(
            range: CMTimeRange(start: CMTime(seconds: cut, preferredTimescale: 600),
                               end: CMTime(seconds: result.duration, preferredTimescale: 600)),
            toFileAt: trimmed)
        let kept = try await ClickTimeline.read(from: trimmed)
        let expected = clicks.filter { $0.t >= cut }
        check(kept.count == expected.count && zip(kept, expected).allSatisfy {
                abs($0.t - ($1.t - cut)) < 0.002 && $0.x == $1.x && $0.y == $1.y },
              "trimmed at \(cut) s: \(expected.count) clicks kept, each \(cut) s earlier",
              "\(kept.map { String(format: "%.3f", $0.t) }) vs \(expected.map { String(format: "%.3f", $0.t - cut) })")

        print("(5) frames --scene says which change followed a click")
        let scene = directory.appendingPathComponent("clicks-scene")
        try? FileManager.default.removeItem(at: scene)
        let run = await CLISelfTest.client(["frames", url.path, "--out", scene.path, "--scene"], socket: "")
        let framesReport = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        let changes = framesReport?.changes ?? []
        let leftInside = zip(downs, posted).filter { $0.1.inside && $0.1.button == .left }.map(\.0)
        for click in leftInside {
            let change = changes.first { $0.time >= click.t - frameInterval && $0.time <= click.t + 0.2 }
            check(change.map { $0.hasTimeline && ($0.afterClickMs ?? -1) >= 0 && ($0.afterClickMs ?? 1e9) < 200
                      && abs(($0.click?.t ?? -1) - click.t) < 0.001 } ?? false,
                  String(format: "the change after the click at %.3f s says after_click_ms and which click", click.t),
                  change.map { "change \($0.time), after_click_ms \($0.afterClickMs.map { "\($0)" } ?? "null")" } ?? run.summary)
        }
        let lastClick = downs.map(\.t).max() ?? 0
        let spontaneous = changes.first { $0.time > lastClick + 1.0 }
        check(spontaneous.map { $0.hasTimeline && $0.afterClickMs == nil && $0.click == nil } ?? false,
              "the change nobody clicked for says after_click_ms null",
              spontaneous.map { "change \($0.time): \($0.afterClickMs.map { "\($0)" } ?? "null")" } ?? "no such change: \(changes.map(\.time))")
        let ringed = framesReport?.frames.filter { $0.clickRings != nil } ?? []
        let ringPixel = ringed.first.flatMap { frame -> String? in
            guard let ring = frame.clickRings?.first,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: frame.path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let radius = max(10, Double(min(image.width, image.height)) * 0.025)
            return pixel(of: image, x: Int(ring.x + radius), y: Int(ring.y))
        }
        check(!ringed.isEmpty && framesReport?.clickRingsNote != nil && ringPixel == "magenta",
              "frames near a click carry a ring, and the JSON says it was drawn",
              "\(ringed.count) ringed, ring pixel \(ringPixel ?? "?")")
        check(framesReport?.clicks?.count == 5, "frames lists the 5 clicks",
              "\(framesReport?.clicks?.count ?? -1)")

        print("(6) a timeline that cannot be embedded costs nothing")
        let failing = directory.appendingPathComponent("clicks-failing.mp4")
        let failingBefore = directory.appendingPathComponent("clicks-failing-before.mp4")
        try? FileManager.default.removeItem(at: failing)
        let failingEngine = RecordingEngine()
        failingEngine.embedFailsForTest = true
        failingEngine.copyBeforeEmbeddingForTest = failingBefore
        _ = try await failingEngine.start(
            .area(displayID: displayID, rectInAppKitGlobal: frame), options: options, to: failing)
        try await Task.sleep(for: .milliseconds(400))
        _ = try await postClick(at: insideA, button: .left)
        try await Task.sleep(for: .milliseconds(600))
        let failed = try? await failingEngine.stop()
        let intact = try await mediaDigest(of: failing) == mediaDigest(of: failingBefore)
        let noTrack = try await AVURLAsset(url: failing).loadTracks(withMediaType: .metadata).isEmpty
        check(failed != nil && intact && noTrack && failingEngine.lastEmbedFailureForTest != nil,
              "the recording comes back exactly as it was written, without a timeline",
              "result=\(failed != nil) intact=\(intact) noTrack=\(noTrack) failure=\(failingEngine.lastEmbedFailureForTest ?? "nil")")
        return finish()
    }

    private static func finish() -> Int32 {
        if failures.isEmpty {
            print("result:        PASS")
            return 0
        }
        print("result:        FAIL — \(failures.count): \(failures.joined(separator: "; "))")
        return 1
    }

    // MARK: - Clicks

    /// Moves there, presses and releases; returns the host time just before
    /// the press was posted. Global points, origin top-left.
    static func postClick(at point: CGPoint, button: CGMouseButton) async throws -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(80))
        let (down, up): (CGEventType, CGEventType) = button == .left
            ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        let host = SCKRecordingSession.hostNow
        CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point,
                mouseButton: button)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(40))
        CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point,
                mouseButton: button)?.post(tap: .cghidEventTap)
        return host
    }

    /// A borderless window that flips between blue and yellow on each left
    /// mouse-down it receives.
    final class FlipWindow: NSWindow {
        private var red = true
        /// Host times of each flip, and what caused it.
        private(set) var flipLog: [(Double, String)] = []

        init(frame: CGRect) {
            super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            isOpaque = true
            hasShadow = false
            level = .floating
            isReleasedWhenClosed = false
            backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            contentView = FlipView(window: self)
            orderFrontRegardless()
        }

        /// Blue and yellow: nearly 200 grey levels apart, so `--scene` at its
        /// default sees every flip (red and blue are only ~47 apart).
        var colour: NSColor {
            red ? NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                : NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        }

        /// The view paints the colour itself: a window background changed under
        /// a content view that covers it reached the screen seconds late, or not
        /// at all, in the first run of this test.
        func flip(_ reason: String = "direct") {
            flipLog.append((SCKRecordingSession.hostNow, reason))
            red.toggle()
            contentView?.needsDisplay = true
            contentView?.displayIfNeeded()
            // Push the drawing to the window server now rather than whenever
            // this run-loop turn ends; from inside a mouse event that was
            // measured to be seconds later.
            CATransaction.flush()
        }

        private final class FlipView: NSView {
            weak var owner: FlipWindow?
            init(window: FlipWindow) {
                owner = window
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { nil }
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                (owner?.colour ?? .black).setFill()
                bounds.fill()
            }
            override func mouseDown(with event: NSEvent) { owner?.flip("mouseDown") }
            override func rightMouseDown(with event: NSEvent) {}
        }
    }

    // MARK: - Reading the movie

    /// The colour at the centre of every frame, with its movie time.
    static func centreColours(of url: URL) async throws -> [(t: Double, colour: String)] {
        // A decoding output reports movie time already; only the raw one
        // (no output settings) reports media time that needs the edit list.
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var colours: [(Double, String)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let p = base + (CVPixelBufferGetHeight(buffer) / 2) * row + (CVPixelBufferGetWidth(buffer) / 2) * 4
            let (b, g, r) = (Int(p[0]), Int(p[1]), Int(p[2]))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            colours.append((t, b > r + 80 && b > g + 80 ? "blue"
                : r > b + 80 && g > b + 80 ? "yellow" : "other(\(r),\(g),\(b))"))
        }
        return colours.sorted { $0.0 < $1.0 }
    }

    /// Per media type: the number of samples, a hash of their bytes, and the
    /// movie times of the video's. Equal digests mean the same media.
    static func mediaDigest(of url: URL) async throws -> [String: String] {
        let asset = AVURLAsset(url: url)
        var digest: [String: String] = [:]
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                reader.startReading()
                var hash = SHA256()
                var count = 0
                while let sample = output.copyNextSampleBuffer() {
                    count += CMSampleBufferGetNumSamples(sample)
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var bytes = [UInt8](repeating: 0, count: length)
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
                    hash.update(data: bytes)
                }
                let sha = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
                var entry = "\(count) samples sha \(sha)"
                if type == .video {
                    let times = try await ClickTimelineEmbedder.videoMovieTimes(of: asset)
                    entry += " times \(times.map { String(format: "%.4f", $0) }.joined(separator: ","))"
                }
                digest[type.rawValue] = entry
            }
        }
        return digest
    }

    static func pixel(of image: CGImage, x: Int, y: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "?" }
        // Shift the image so the wanted pixel (top-left origin) lands on (0, 0).
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                       width: image.width, height: image.height))
        let (r, g, b) = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        if r > 180, b > 180, g < 90 { return "magenta" }
        return "(\(r),\(g),\(b))"
    }
}
