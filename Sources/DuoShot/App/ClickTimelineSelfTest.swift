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
        var options = RecordingOptions.default
        // On, so the untouched-samples check covers an audio track too.
        options.capturesSystemAudio = true
        options.showsMouseClicks = false
        // The pointer stays in the picture: a take that hides it gets no
        // timeline at all (checked in (7)).
        options.showsCursor = true
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
        // The take as the recorder wrote it, before anything was added.
        try? FileManager.default.removeItem(at: before)
        try FileManager.default.copyItem(at: url, to: before)
        guard let pending = result.clickTimeline else {
            check(false, "the take hands over its clicks")
            return finish()
        }
        var report: ClickTimelineEmbedder.Report?
        var failure = "-"
        switch await ClickTimelineJobs.shared.run(pending, into: url) {
        case .success(let value): report = value
        case .failure(let value): failure = value.message
        }

        let clicks = try await ClickTimeline.read(from: url)
        let downs = clicks.filter { $0.phase == "down" }
        let insidePosted = posted.filter(\.inside)
        check(report?.clicks == 8 && clicks.count == 8 && downs.count == 4,
              "the timeline is in the movie: the 4 clicks inside, down and up",
              "embedded=\(report?.clicks ?? -1) read=\(clicks.count) method=\(report?.method ?? "none") failure=\(failure)")
        let outsidePoint = posted.first { !$0.inside }?.point ?? .zero
        check(!clicks.contains { abs($0.x - outsidePoint.x) < 1 && abs($0.y - outsidePoint.y) < 1 }
                && !clicks.contains { $0.outside },
              "the click outside the recorded area is not stored at all")
        guard let anchor = report?.anchorHostTime, downs.count == insidePosted.count else {
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
        for (index, (click, truth)) in zip(downs, insidePosted).enumerated() {
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
            check(!click.outside && click.button == (truth.button == .left ? "left" : "right"),
                  "click \(index + 1): inside, \(click.button)")
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
            toFileAt: trimmed, workDirectory: StagingStore.shared.directory)
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
        let leftInside = zip(downs, insidePosted).filter { $0.1.button == .left }.map(\.0)
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
        check(framesReport?.clicks?.count == 4, "frames lists the 4 clicks",
              "\(framesReport?.clicks?.count ?? -1)")

        print("(6) a timeline that cannot be embedded costs nothing")
        let failing = directory.appendingPathComponent("clicks-failing.mp4")
        try? FileManager.default.removeItem(at: failing)
        try FileManager.default.copyItem(at: before, to: failing)
        let failingOutcome = await ClickTimelineJobs.shared.run(pending, into: failing, failForTest: true)
        var intact = try await mediaDigest(of: failing) == mediaDigest(of: before)
        var noTrack = try await AVURLAsset(url: failing).loadTracks(withMediaType: .metadata).isEmpty
        let failedMessage: String? = if case .failure(let f) = failingOutcome { f.message } else { nil }
        check(failedMessage != nil && intact && noTrack,
              "the recording stays exactly as it was written, without a timeline",
              "intact=\(intact) noTrack=\(noTrack) failure=\(failedMessage ?? "nil")")

        print("(7) a take that hides the pointer gets no timeline")
        let hidden = directory.appendingPathComponent("clicks-no-pointer.mp4")
        try? FileManager.default.removeItem(at: hidden)
        var hiddenOptions = options
        hiddenOptions.showsCursor = false
        let hiddenEngine = RecordingEngine()
        _ = try await hiddenEngine.start(
            .area(displayID: displayID, rectInAppKitGlobal: frame), options: hiddenOptions, to: hidden)
        try await Task.sleep(for: .milliseconds(400))
        _ = try await postClick(at: insideA, button: .left)
        try await Task.sleep(for: .milliseconds(600))
        let hiddenResult = try await hiddenEngine.stop()
        var hiddenSkipped: String?
        if let hiddenPending = hiddenResult.clickTimeline,
           case .success(let hiddenReport) = await ClickTimelineJobs.shared.run(hiddenPending, into: hidden) {
            hiddenSkipped = hiddenReport.skipped
        }
        noTrack = try await AVURLAsset(url: hidden).loadTracks(withMediaType: .metadata).isEmpty
        check(noTrack && hiddenSkipped != nil, "no metadata track, and it says why",
              "noTrack=\(noTrack) skipped=\(hiddenSkipped ?? "nil")")

        print("(8) the copy is checked, and a bad one is never swapped in")
        for fault in ClickTimelineEmbedder.Fault.allCases where fault != .none {
            let damaged = directory.appendingPathComponent("clicks-fault.mp4")
            try? FileManager.default.removeItem(at: damaged)
            try FileManager.default.copyItem(at: before, to: damaged)
            let outcome = await ClickTimelineJobs.shared.run(pending, into: damaged, fault: fault)
            intact = try await mediaDigest(of: damaged) == mediaDigest(of: before)
            let message: String? = if case .failure(let f) = outcome { f.message } else { nil }
            check(message != nil && intact, "\(fault.rawValue): refused, original untouched",
                  message ?? "swapped in")
        }

        print("(9) a cancelled timeline (quitting) leaves the take and no copy")
        let cancelled = directory.appendingPathComponent("clicks-cancelled.mp4")
        try? FileManager.default.removeItem(at: cancelled)
        try FileManager.default.copyItem(at: before, to: cancelled)
        let cancellation = ClickTimelineEmbedder.Cancellation()
        cancellation.cancel()
        let cancelOutcome = await ClickTimelineJobs.shared.run(pending, into: cancelled, cancellation: cancellation)
        intact = try await mediaDigest(of: cancelled) == mediaDigest(of: before)
        let leftovers = [directory, ClickTimelineJobs.shared.workDirectory].flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [])
                .filter { $0.hasPrefix(ClickTimelineEmbedder.sweepPrefix) }
        }
        let cancelMessage: String? = if case .failure(let f) = cancelOutcome { f.message } else { nil }
        check(cancelMessage == "cancelled" && intact && leftovers.isEmpty,
              "cancelled: original untouched, no copy left behind",
              "\(cancelMessage ?? "not cancelled"), intact=\(intact), leftovers \(leftovers)")

        print("(10) staging leaves a take alone while its timeline is added")
        let stagingDirectory = directory.appendingPathComponent("staging-prune", isDirectory: true)
        try? FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let store = StagingStore(directory: stagingDirectory)
        let older = stagingDirectory.appendingPathComponent("older-take.mp4")
        let newer = stagingDirectory.appendingPathComponent("newer-take.mp4")
        FileManager.default.createFile(atPath: older.path, contents: Data(count: 1024))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: older.path)
        // Sparse: 3 GiB to the byte budget, nothing on disk.
        FileManager.default.createFile(atPath: newer.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: newer) {
            try handle.truncate(atOffset: 3 << 30)
            try handle.close()
        }
        StagingStore.inUse.insert(older.standardizedFileURL.path)
        store.prune()
        let keptWhileInUse = FileManager.default.fileExists(atPath: older.path)
        StagingStore.inUse.remove(older.standardizedFileURL.path)
        store.prune()
        let prunedAfter = !FileManager.default.fileExists(atPath: older.path)
        try? FileManager.default.removeItem(at: stagingDirectory)
        check(keptWhileInUse && prunedAfter,
              "a take in use survives a prune that removes it once it is not",
              "kept while in use: \(keptWhileInUse), pruned after: \(prunedAfter)")

        print("(11) the launch sweep removes what an interrupted timeline or trim left, and only that")
        let sweepDirectory = directory.appendingPathComponent("sweep", isDirectory: true)
        try? FileManager.default.removeItem(at: sweepDirectory)
        try FileManager.default.createDirectory(at: sweepDirectory, withIntermediateDirectories: true)
        let orphan = sweepDirectory.appendingPathComponent(ClickTimelineEmbedder.sweepPrefix + "orphan.mp4")
        // A trim's export, and the sibling AVFoundation writes beside it.
        let trimOrphan = sweepDirectory.appendingPathComponent(VideoTrim.sweepPrefix + "orphan.mp4")
        let trimSibling = sweepDirectory.appendingPathComponent(
            VideoTrim.sweepPrefix + "orphan.mp4.sb-1a2b3c4d-AbCdEf")
        let keeper = sweepDirectory.appendingPathComponent("someone-elses.mp4")
        for file in [orphan, trimOrphan, trimSibling, keeper] {
            FileManager.default.createFile(atPath: file.path, contents: Data(count: 16))
        }
        let swept = ClickTimelineJobs.sweep([sweepDirectory])
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: sweepDirectory.path)) ?? []).sorted()
        check(swept == 3 && left == [keeper.lastPathComponent],
              "the orphaned copy and trim export removed, the other file kept",
              "removed \(swept), left \(left.joined(separator: ", "))")
        try? FileManager.default.removeItem(at: sweepDirectory)

        try await jobContract(directory: directory, before: before, insideA: insideA, insideB: insideB,
                              pending: pending, duration: result.duration)
        return finish()
    }

    /// (12)–(17): the background job as the app runs it.
    private static func jobContract(
        directory: URL, before: URL, insideA: CGPoint, insideB: CGPoint,
        pending: ClickTimelineEmbedder.Pending, duration: Double
    ) async throws {
        let staging = ClickTimelineJobs.shared.workDirectory
        func copies() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [])
                .filter { $0.hasPrefix(ClickTimelineEmbedder.sweepPrefix) })
        }
        func fresh(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: before, to: url)
            return url
        }
        /// Until a copy appears in staging — the job is mid-copy — or 30 s.
        func waitForCopy() async -> Bool {
            let start = copies()
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if !copies().subtracting(start).isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        func hasTrack(_ url: URL) async -> Bool {
            !((try? await AVURLAsset(url: url).loadTracks(withMediaType: .metadata)) ?? []).isEmpty
        }
        typealias Outcome = Result<ClickTimelineEmbedder.Report, ClickTimelineEmbedder.Failure>
        func message(_ outcome: Outcome) -> String {
            switch outcome {
            case .success(let report): "embedded \(report.clicks)\(report.skipped.map { ", skipped: \($0)" } ?? "")"
            case .failure(let failure): failure.message
            }
        }

        print("(12) a take stopped through the coordinator is saved, then gets its timeline, copied in staging")
        let saveFolder = directory.appendingPathComponent("saved", isDirectory: true)
        try? FileManager.default.removeItem(at: saveFolder)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let preferences = Preferences.shared
        let saved = (preferences.copyToClipboard, preferences.playsSound, preferences.recordingShowsCursor,
                     preferences.recordingMicrophone, preferences.recordingShowsClicks)
        preferences.copyToClipboard = false
        preferences.playsSound = false
        preferences.recordingShowsCursor = true
        preferences.recordingMicrophone = false
        preferences.recordingShowsClicks = false
        defer {
            preferences.copyToClipboard = saved.0
            preferences.playsSound = saved.1
            preferences.recordingShowsCursor = saved.2
            preferences.recordingMicrophone = saved.3
            preferences.recordingShowsClicks = saved.4
        }
        let recorder = RecordingCoordinator(overlay: OverlayController())
        recorder.saveDirectoryOverride = saveFolder
        var outputs: [OutputPipeline.RecordingOutput] = []
        recorder.onResult = { outputs.append($0) }
        await recorder.perform(.recordFullscreen)
        if recorder.isRecording {
            try await Task.sleep(for: .milliseconds(800))
            _ = try await postClick(at: insideA, button: .left)
            try await Task.sleep(for: .milliseconds(500))
            _ = try await postClick(at: insideB, button: .left)
            try await Task.sleep(for: .milliseconds(800))
            await recorder.perform(.recordFullscreen)
        }
        let take = outputs.first?.url
        let jobs = ClickTimelineJobs.shared
        var sawJob = false, copyInStaging = false
        var strangers: Set<String> = []
        let startCopies = copies()
        let deadline = ContinuousClock.now + .seconds(60)
        while take != nil, ContinuousClock.now < deadline {
            if !jobs.isIdle { sawJob = true }
            if !copies().subtracting(startCopies).isEmpty { copyInStaging = true }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: saveFolder.path)) ?? []
            strangers.formUnion(names.filter { $0 != take?.lastPathComponent })
            if sawJob, jobs.isIdle { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        var savedClicks: [CLIClick]?
        if let take { savedClicks = try? await ClickTimeline.read(from: take) }
        check(take?.deletingLastPathComponent().standardizedFileURL == saveFolder.standardizedFileURL
                && savedClicks?.count == 4,
              "saved to the save folder, and its 2 clicks (down and up) are in it afterwards",
              "take \(take?.lastPathComponent ?? "none"), clicks \(savedClicks?.count ?? -1)")
        check(sawJob && copyInStaging && strangers.isEmpty,
              "the copy was made in staging, and nothing but the take ever appeared in the save folder",
              "job seen \(sawJob), copy in staging \(copyInStaging), other files in the save folder \(strangers.sorted())")

        print("(13) a file changed while its timeline is copied is left alone")
        let changed = try fresh("clicks-changed.mp4")
        let changedJob = Task { await ClickTimelineJobs.shared.run(pending, into: changed) }
        let changedInFlight = await waitForCopy()
        // The same bytes, touched: only the identity differs.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: changed.path)
        let changedOutcome = await changedJob.value
        var intact = try await mediaDigest(of: changed) == mediaDigest(of: before)
        var track = await hasTrack(changed)
        check(changedInFlight && message(changedOutcome).contains("changed") && intact && !track,
              "refused, the file as it was, no track",
              "in flight \(changedInFlight): \(message(changedOutcome)), intact=\(intact), track=\(track)")

        print("(14) quitting stops a job that is copying, and starts no more")
        let quitting = ClickTimelineJobs(workDirectory: staging)
        let quitFile = try fresh("clicks-quit.mp4")
        let quitJob = Task { await quitting.run(pending, into: quitFile) }
        let quitInFlight = await waitForCopy()
        let copiesAtQuit = copies()
        quitting.cancelAll()
        let quitOutcome = await quitJob.value
        let afterQuit = await quitting.run(pending, into: quitFile)
        intact = try await mediaDigest(of: quitFile) == mediaDigest(of: before)
        track = await hasTrack(quitFile)
        let leftover = copies().intersection(copiesAtQuit)
        check(quitInFlight && message(quitOutcome) == "cancelled" && message(afterQuit) == "DuoShot is quitting"
                && intact && !track && leftover.isEmpty && quitting.isIdle,
              "the running job cancelled, the take untouched, its copy gone; the next one refused",
              "in flight \(quitInFlight): \(message(quitOutcome)); then \(message(afterQuit)); intact=\(intact) track=\(track) leftover \(leftover.sorted())")

        print("(15) a trim and a delete stop the job on their file first")
        let trimFile = try fresh("clicks-trim-during-job.mp4")
        let trimJob = Task { await ClickTimelineJobs.shared.run(pending, into: trimFile) }
        let trimInFlight = await waitForCopy()
        let cut = 1.0
        _ = try await VideoTrim.apply(
            range: CMTimeRange(start: CMTime(seconds: cut, preferredTimescale: 600),
                               end: CMTime(seconds: duration, preferredTimescale: 600)),
            toFileAt: trimFile, workDirectory: StagingStore.shared.directory)
        let trimOutcome = await trimJob.value
        let trimmedLength = (try? await AVURLAsset(url: trimFile).load(.duration).seconds) ?? 0
        check(trimInFlight && message(trimOutcome) == "cancelled" && trimmedLength < duration - cut / 2,
              "trim: the job was cancelled, the trim stands",
              String(format: "in flight %@: %@, %.2f s of %.2f s", "\(trimInFlight)", message(trimOutcome),
                     trimmedLength, duration))

        let deleteFile = try fresh("clicks-delete-during-job.mp4")
        let deleteJob = Task { await ClickTimelineJobs.shared.run(pending, into: deleteFile) }
        let deleteInFlight = await waitForCopy()
        let binned = await CaptureTrash.delete(deleteFile)
        let deleteOutcome = await deleteJob.value
        let resurrected = FileManager.default.fileExists(atPath: deleteFile.path)
        if let binned { try? FileManager.default.removeItem(at: binned) }
        check(deleteInFlight && binned != nil && message(deleteOutcome) == "cancelled" && !resurrected,
              "delete: the job was cancelled, the take stays in the Trash",
              "in flight \(deleteInFlight): \(message(deleteOutcome)), binned \(binned != nil), back in place \(resurrected)")

        print("(16) without room for the copy and a take after it, no copy is made")
        let cramped = ClickTimelineJobs(workDirectory: staging)
        cramped.reserve = Int64.max / 4
        let crampedFile = try fresh("clicks-low-space.mp4")
        let crampedCopies = copies()
        let crampedOutcome = await cramped.run(pending, into: crampedFile)
        track = await hasTrack(crampedFile)
        intact = try await mediaDigest(of: crampedFile) == mediaDigest(of: before)
        let skippedForSpace: Bool = if case .success(let r) = crampedOutcome {
            r.skipped?.contains("free space") == true
        } else { false }
        check(skippedForSpace && !track && intact && copies() == crampedCopies,
              "skipped, and says why; the take as it was",
              "\(message(crampedOutcome)), track=\(track), intact=\(intact)")

        print("(17) two jobs never copy at once")
        let serial = ClickTimelineJobs(workDirectory: staging)
        let first = try fresh("clicks-serial-1.mp4"), second = try fresh("clicks-serial-2.mp4")
        async let one = serial.run(pending, into: first)
        async let two = serial.run(pending, into: second)
        let (oneOutcome, twoOutcome) = await (one, two)
        let firstTrack = await hasTrack(first), secondTrack = await hasTrack(second)
        let bothTracks = firstTrack && secondTrack
        check(serial.peakActiveForTest == 1 && bothTracks,
              "both embedded, one after the other",
              "peak at once \(serial.peakActiveForTest); \(message(oneOutcome)); \(message(twoOutcome))")
    }

    // MARK: - Quit timing (a measurement, not in `make test`)

    /// `--selftest-click-timeline-quit <dir> [GB]`: how long a large take's
    /// timeline takes, and how long a quit waits for one being cancelled.
    ///
    /// The large take is made without encoding: three seconds of a window that
    /// shows a different noise image every frame, recorded for real, then its
    /// compressed samples written back to back with shifted times until the
    /// file is the size asked for.
    static func quitTiming(into directory: URL, gigabytes: Double) async throws -> Int32 {
        guard ScreenPermission.isGranted else { return 1 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.screens[0]
        guard let displayID = ScreenIndex.displayID(of: screen) else { return 1 }
        let frame = CGRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 60,
                           width: 900, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let images = (0..<8).map { noiseImage(width: 900, height: 600, seed: UInt64($0 + 1)) }

        let source = directory.appendingPathComponent("quit-source.mp4")
        try? FileManager.default.removeItem(at: source)
        var options = RecordingOptions.default
        options.capturesSystemAudio = false
        let engine = RecordingEngine()
        _ = try await engine.start(.area(displayID: displayID, rectInAppKitGlobal: frame),
                                   options: options, to: source)
        for index in 0..<180 {
            view.image = images[index % images.count]
            view.display()
            try await Task.sleep(for: .milliseconds(16))
        }
        _ = try await engine.stop()
        let sourceBytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0

        let large = directory.appendingPathComponent("quit-large.mp4")
        let target = Int(gigabytes * 1_000_000_000)
        let copies = max(1, target / max(sourceBytes, 1))
        let started = Date()
        try await repeatVideo(of: source, times: copies, to: large)
        let largeBytes = (try FileManager.default.attributesOfItem(atPath: large.path)[.size] as? Int) ?? 0
        print(String(format: "large take:    %.2f GB (%d copies of a %.1f MB take), built in %.1f s",
                     Double(largeBytes) / 1e9, copies, Double(sourceBytes) / 1e6, Date().timeIntervalSince(started)))

        // A timeline for it: its own frame times as the host clock, one click.
        let movieTimes = try await ClickTimelineEmbedder.videoMovieTimes(of: AVURLAsset(url: large))
        let region = DisplayGeometry.flipped(frame)
        let pending = ClickTimelineEmbedder.Pending(
            events: [ClickRecorder.Event(timestamp: 1000 + 1.0,
                                         locationInCGGlobal: CGPoint(x: region.midX, y: region.midY),
                                         isDown: true, button: "left", clickCount: 1)],
            frameHostTimes: movieTimes.map { $0 + 1000 }, writerStart: nil,
            geometry: .init(regionInCGGlobal: region,
                            pixelSize: CGSize(width: frame.width * screen.backingScaleFactor,
                                              height: frame.height * screen.backingScaleFactor)),
            showsCursor: true)

        let fullStart = Date()
        let full = await ClickTimelineJobs.shared.run(pending, into: large)
        let fullTime = Date().timeIntervalSince(fullStart)
        let fullText: String = switch full {
        case .success(let report): "embedded \(report.clicks)"
        case .failure(let failure): "failed: \(failure.message)"
        }
        print(String(format: "full embed:    %.1f s for %.2f GB (%.2f s/GB), %@",
                     fullTime, Double(largeBytes) / 1e9, fullTime / (Double(largeBytes) / 1e9), fullText))

        // The quit: cancel one second into an embed and time the unwinding.
        var info = stat()
        stat(large.path, &info)
        let identityBefore = (info.st_ino, info.st_size, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
        let cancellation = ClickTimelineEmbedder.Cancellation()
        let job = Task { await ClickTimelineJobs.shared.run(pending, into: large, cancellation: cancellation) }
        try await Task.sleep(for: .seconds(1))
        let cancelAt = Date()
        cancellation.cancel()
        let outcome = await job.value
        let unwind = Date().timeIntervalSince(cancelAt)
        stat(large.path, &info)
        let identityAfter = (info.st_ino, info.st_size, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
        let leftovers = [directory, ClickTimelineJobs.shared.workDirectory].flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [])
                .filter { $0.hasPrefix(ClickTimelineEmbedder.sweepPrefix) }
        }
        let message: String = if case .failure(let f) = outcome { f.message } else { "finished anyway" }
        print(String(format: "quit:          cancelled 1 s in, unwound in %.3f s (%@); file unchanged: %@; copies left: %d",
                     unwind, message, identityBefore == identityAfter ? "yes" : "NO", leftovers.count))
        try? FileManager.default.removeItem(at: large)
        try? FileManager.default.removeItem(at: source)
        let ok = unwind < 1 && identityBefore == identityAfter && leftovers.isEmpty
        print("result:        \(ok ? "PASS" : "FAIL")")
        return ok ? 0 : 1
    }

    private static func noiseImage(width: Int, height: Int, seed: UInt64) -> NSImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state = seed &* 0x9E3779B97F4A7C15
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[i + 1] = UInt8(truncatingIfNeeded: state >> 32)
            bytes[i + 2] = UInt8(truncatingIfNeeded: state >> 40)
        }
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) } ?? NSImage()
    }

    /// The source's video samples, `times` times over, each run later than the
    /// last by the source's duration. Passthrough: nothing is encoded.
    @concurrent private static func repeatVideo(of source: URL, times: Int, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let (formats, duration) = (try await track.load(.formatDescriptions), try await asset.load(.duration))
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        // Each run starts where the last one's decode times end, so the joins
        // are seamless: no sample's duration depends on the gap after it.
        let timings = try await ClickTimelineEmbedder.samples(of: track, in: asset)
        let span = CMTime(seconds: timings.reduce(0) { $0 + $1.duration }, preferredTimescale: 600)
        _ = duration
        for run in 0..<times {
            let offset = CMTimeMultiply(span, multiplier: Int32(run))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                var count = 0
                CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
                var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
                CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
                for index in timing.indices {
                    timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
                    if timing[index].decodeTimeStamp.isValid {
                        timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset
                    }
                }
                var shifted: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                    sampleTimingArray: &timing, sampleBufferOut: &shifted)
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                guard let shifted, input.append(shifted) else {
                    throw NSError(domain: "repeatVideo", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "append failed in run \(run): \(writer.error?.localizedDescription ?? "no copy")"])
                }
            }
        }
        input.markAsFinished()
        // No endSession, like the remux: it would stretch the last frame.
        await writer.finishWriting()
        if writer.status != .completed {
            throw NSError(domain: "repeatVideo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "finish failed: \(writer.error?.localizedDescription ?? "?")"])
        }
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
