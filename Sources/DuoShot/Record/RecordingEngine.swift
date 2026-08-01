import AVFoundation
import AppKit
import ScreenCaptureKit

nonisolated enum RecordingError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case displayNotFound(CGDirectDisplayID)
    case writerNeverStarted
    case fileMissing(URL)
    case emptyFile(URL)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already in progress."
        case .notRecording:
            "No recording is in progress."
        case .displayNotFound(let id):
            LoginSession.noDisplaysHint.map { "No SCDisplay for display ID \(id) — \($0)." }
                ?? "No SCDisplay for display ID \(id)."
        case .writerNeverStarted:
            "ScreenCaptureKit never reported that the recording had started."
        case .fileMissing(let url):
            "The recording produced no file at \(url.path)."
        case .emptyFile(let url):
            "The recording produced an empty file at \(url.path)."
        }
    }
}

/// A recording that is currently running.
///
/// Handed out by `RecordingEngine.start` so the caller has exactly one object to
/// poll for the HUD's timer and exactly one to stop.
final class ActiveRecording {
    let request: RecordingRequest
    let options: RecordingOptions
    /// The take asked for the microphone and is running without it.
    ///
    /// `options` holds what the stream was actually built with, so the request
    /// is otherwise unrecoverable once `start` has dropped it — and a silent
    /// downgrade is the one failure the user cannot notice until the take is
    /// over and the narration is missing. The HUD shows it.
    let microphoneDenied: Bool
    let pointSize: CGSize
    let pixelSize: CGSize
    let scale: CGFloat
    let sourceDescription: String
    let startedAt: Date

    fileprivate let session: SCKRecordingSession

    var url: URL { session.outputURL }

    fileprivate init(
        session: SCKRecordingSession, request: RecordingRequest, options: RecordingOptions,
        microphoneDenied: Bool, pointSize: CGSize, pixelSize: CGSize, scale: CGFloat,
        sourceDescription: String
    ) {
        self.session = session
        self.request = request
        self.options = options
        self.microphoneDenied = microphoneDenied
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.scale = scale
        self.sourceDescription = sourceDescription
        self.startedAt = .now
    }

    /// What the writer says it has written so far. Falls back to wall-clock for
    /// the elapsed time, so the HUD keeps counting even if the counter stalls.
    var elapsed: TimeInterval {
        max(session.stats.duration, Date.now.timeIntervalSince(startedAt))
    }

    var fileSize: Int { session.stats.fileSize }

    /// Fires when the recording dies on its own rather than being stopped.
    func onUnexpectedStop(_ handler: @escaping @Sendable (any Error) -> Void) {
        session.onUnexpectedStop(handler)
    }
}

/// Builds filters and stream configurations, and owns the one running recording.
///
/// `@MainActor` for the same reason `CaptureEngine` is: it does no CPU work of
/// its own but needs `NSScreen` and live `SCDisplay` objects.
final class RecordingEngine {
    private let content: ShareableContentCache
    private var active: ActiveRecording?

    init(content: ShareableContentCache = ShareableContentCache()) {
        self.content = content
    }

    var isRecording: Bool { active != nil }
    var current: ActiveRecording? { active }

    func refreshContent() async throws {
        try await content.refresh()
    }

    // MARK: - Start

    /// Whether a take built from these options will run without the microphone
    /// it asked for.
    ///
    /// `start` settles this question below, and this is the same predicate — but
    /// the answer is needed before the stream exists, because the HUD is on
    /// screen by then and has to be laid out for the mic-off indicator. One
    /// predicate rather than two readings of the TCC status that could disagree.
    static func microphoneWillBeDropped(_ options: RecordingOptions) -> Bool {
        options.capturesMicrophone && !MicrophonePermission.isGranted
    }

    func start(
        _ request: RecordingRequest,
        options: RecordingOptions = .default,
        to url: URL
    ) async throws -> ActiveRecording {
        guard active == nil else { throw RecordingError.alreadyRecording }

        let displayID = request.displayID
        if content.scDisplay(for: displayID) == nil {
            try await content.refresh()
        }
        guard let display = content.scDisplay(for: displayID) else {
            throw RecordingError.displayNotFound(displayID)
        }

        // Settle the microphone question here rather than letting SCK discover
        // it: an undecided grant makes `startCapture` hang forever (see
        // `MicrophonePermission`). A take without narration is a far better
        // outcome than a take that never starts, so this degrades rather than
        // fails — the Settings toggle is where the user is actually asked.
        var options = options
        let microphoneDenied = Self.microphoneWillBeDropped(options)
        if microphoneDenied {
            Log.record.error("""
                microphone requested but the grant is \
                \(MicrophonePermission.statusDescription, privacy: .public); \
                recording without it
                """)
            options.capturesMicrophone = false
            options.microphoneDeviceID = nil
        }

        let excluded = try await content.ownWindows(matching: options.excludedWindowIDs)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        // Defaults to YES on this initialiser — same trap as the screenshot path.
        filter.includeMenuBar = options.includeMenuBar
        let scale = CGFloat(filter.pointPixelScale)

        let region: CGRect
        let sourceRect: CGRect?
        switch request {
        case .area(_, let rectInAppKitGlobal):
            sourceRect = DisplayGeometry.sourceRect(
                fromAppKitGlobal: rectInAppKitGlobal, on: displayID)
            region = sourceRect ?? .zero
        case .display:
            sourceRect = nil
            region = filter.contentRect
        }

        let pixelSize = Self.encodablePixelSize(of: region, scale: scale)
        let configuration = streamConfiguration(
            pixelSize: pixelSize, sourceRect: sourceRect, options: options)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.videoCodecType = options.videoCodec
        recordingConfiguration.outputFileType = options.fileType
        // Pinned rather than left to the default, for the same reason
        // `filter.includeMenuBar` is: a default that decides something this
        // visible should be stated where it can be read.
        //
        // YES mixes system audio and the microphone into ONE track. Measured
        // 2026-07-31 on macOS 27.0, a take with both sources came back as a
        // single AAC 48 kHz stereo track, which is the behaviour a screen
        // recorder wants — NO produces one track per source, and many players
        // pick a single audio track rather than summing them, so narration
        // would go missing for anyone who did not open it in an editor.
        //
        // Two guards, because they answer different questions and one of them
        // is not optional.
        //
        // `#available` is a RUNTIME check: the symbol still has to exist when
        // the file is compiled. The property is absent from the macOS 26 SDK
        // entirely, so a build with Xcode 26 fails on this line no matter what
        // the availability check says. Caught on a Mac mini running 26.5 —
        // it compiles here only because this machine has the 27 SDK, which is
        // exactly the kind of breakage that does not show up until someone
        // else builds it.
        //
        // `compiler(>=6.4)` stands in for "built against the macOS 27 SDK".
        // It is a proxy — the toolchain and the SDK ship together — and it is
        // the mechanism Swift actually offers; there is no `#if sdk(...)`.
        //
        // Skipping it on macOS 26 costs nothing: measured 2026-07-31 on a Mac
        // mini running 26.5, a take with system audio and the microphone both
        // on came back as one AAC 48 kHz stereo track there too. Mixing is what
        // 26 already did; 27 added the ability to turn it OFF, not the mixing.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            recordingConfiguration.mixesAudioWithMicrophone = true
        }
        #endif

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let session = SCKRecordingSession(outputURL: url)
        let started = ContinuousClock.now
        try await session.start(
            filter: filter, configuration: configuration, recording: recordingConfiguration)
        let captureStarted = ContinuousClock.now

        // `startCapture` returning is not the same as the file existing. Wait for
        // the writer, so a caller that stops after 200 ms cannot produce a file
        // that was never opened.
        //
        // The two halves are timed separately because they fail slowly for
        // completely different reasons and the sum cannot tell them apart.
        // Measured 2026-07-31, takes on this machine came in at 126–243 ms while
        // two outliers hit 3887 ms and 4280 ms — and with one number there was
        // no way to say whether ScreenCaptureKit was slow to start or the writer
        // was waiting on a first frame that a still screen never produced
        // (`SCFrameStatusIdle` is a documented state, so no frame is a thing
        // that happens).
        // `wait` *throws* when the writer reported a startup error — and by
        // then `startCapture` has already returned, so the stream is live.
        // Both exits must stop the session: an error that skipped the teardown
        // would leave an SCStream capturing with no `active` handle to stop
        // it by.
        //
        // And both must delete the file, as `cancel()` does. A start that
        // throws hands the caller no recording, so nothing will ever finish or
        // reveal this URL — but the writer may already have put a header on
        // disk, and a retried start reserves a *new* name, so every failed
        // attempt would otherwise leave an unopenable stub in staging with
        // nobody left holding a reference to it.
        let writerStarted: Bool
        do {
            writerStarted = try await session.writerStarted.wait(timeout: .seconds(5))
        } catch {
            _ = await session.stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard writerStarted else {
            _ = await session.stop()
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.writerNeverStarted
        }
        let writerLatency = captureStarted.duration(to: .now).milliseconds
        let captureLatency = started.duration(to: captureStarted).milliseconds

        let index = content.displayIDs.firstIndex(of: displayID).map { $0 + 1 } ?? 1
        let recording = ActiveRecording(
            session: session,
            request: request,
            options: options,
            microphoneDenied: microphoneDenied,
            pointSize: region.size,
            pixelSize: CGSize(width: pixelSize.width, height: pixelSize.height),
            scale: scale,
            sourceDescription: request.kind == "area" ? "Area" : "Display \(index)")
        active = recording

        Log.record.notice("""
            recording \(request.kind, privacy: .public) started \
            \(pixelSize.width, privacy: .public)x\(pixelSize.height, privacy: .public) px \
            scale=\(scale, privacy: .public) fps<=\(options.frameRate, privacy: .public) \
            audio=\(options.capturesSystemAudio, privacy: .public) \
            mic=\(options.capturesMicrophone, privacy: .public) \
            in \(started.duration(to: .now).milliseconds, privacy: .public) ms \
            (startCapture \(captureLatency, privacy: .public) ms + \
            first frame \(writerLatency, privacy: .public) ms)
            """)
        return recording
    }

    // There is deliberately no way to change a running take's configuration.
    //
    // `SCStream.updateConfiguration` exists and succeeds, and the SDK documents
    // what it costs — in the discussion of `removeRecordingOutput`, of all
    // places, where nobody looking for it would think to read:
    //
    //   "In case client update the stream configuration during recording,
    //    recording will be stopped as well."
    //
    // Measured 2026-07-31, that is exactly what happens: the first real
    // configuration change ends the take. `updateConfiguration` reports success,
    // `active` still points at a recording and the HUD keeps counting, while
    // `SCRecordingOutput` finalises the file roughly 100 ms later and everything
    // after that instant is lost.
    //
    // A version of this file briefly carried an `updateAudio` that toggled the
    // microphone mid-take, built on the reading that only *removing the last
    // audio source* was destructive. That reading came from a run where the
    // microphone grant was missing, so the two harmless-looking switches before
    // it were no-ops the stream never applied — one real change, one death, and
    // a conclusion drawn from the coincidence. Toggling audio during a take is
    // not a thing this API can do; the toolbar therefore offers it only *before*
    // one starts.
    //
    // Doing it anyway would mean giving up `SCRecordingOutput` and writing the
    // `.screen` / `.audio` / `.microphone` buffers into an `AVAssetWriter`
    // ourselves — three independent format descriptions and clocks to reconcile.

    // MARK: - Stop

    /// How a take ended.
    ///
    /// Three independent facts used to be collapsed into one `throws`: whether
    /// the writer reported a failure, whether anything reached disk, and
    /// whether the caller gets a result. `engine.stop()` threw at the first,
    /// so the second was never asked and the third was always "nothing" — a
    /// take could be forty seconds of real content and be discarded without
    /// being opened.
    enum Outcome {
        case finished(RecordingResult)
        /// The writer failed or never finalised, but there is a file with bytes
        /// in it. Whether it plays is the caller's to find out; with movie
        /// fragments it often would, and either way it is the user's only copy.
        case salvaged(RecordingResult, failure: (any Error)?)
        /// Nothing usable. The URL is still handed back so the caller can log
        /// it and leave it alone rather than delete the evidence.
        case lost(url: URL, failure: (any Error)?)
    }

    /// Ends the take and reports what came of it. Never throws.
    func finish() async -> Outcome {
        guard let recording = active else {
            return .lost(url: URL(fileURLWithPath: "/dev/null"), failure: RecordingError.notRecording)
        }
        active = nil

        let report = await recording.session.stop()
        let url = recording.url
        if let failure = report.writerFailure {
            Log.record.error("""
                writer failed for \(url.lastPathComponent, privacy: .public): \
                \(failure.localizedDescription, privacy: .public)
                """)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard FileManager.default.fileExists(atPath: url.path), size > 0 else {
            Log.record.error("""
                nothing on disk for \(url.lastPathComponent, privacy: .public) \
                (\(size, privacy: .public) bytes)
                """)
            return .lost(url: url, failure: report.writerFailure)
        }

        // The duration comes from the finished file, not from the writer.
        // `SCRecordingOutput.recordedDuration` lags: measured 2026-07-31 it
        // reported exactly 3.00 s for takes the container puts at 3.51 s and
        // 3.65 s — round to the tenth in both cases, so it is quantised as well
        // as behind. It is fine for a live HUD counter and wrong for the number
        // stamped on a finished recording.
        //
        // A file the container cannot parse at all is the signal that the take
        // is unplayable, and it is reported as salvaged-with-no-duration rather
        // than deleted: an unplayable file can still be repaired, and only the
        // user can decide it is worthless.
        let duration = await Self.assetDuration(of: url)

        let result = RecordingResult(
            url: url,
            duration: duration ?? report.stats.duration,
            fileSize: size,
            pixelSize: recording.pixelSize,
            pointSize: recording.pointSize,
            scale: recording.scale,
            sourceDisplayID: recording.request.displayID,
            sourceDescription: recording.sourceDescription,
            startedAt: recording.startedAt)

        let intact = report.writerFailure == nil && report.finalised && duration != nil
        Log.record.notice("""
            recording \(intact ? "finished" : "SALVAGED", privacy: .public) \
            \(url.lastPathComponent, privacy: .public) \
            \(result.durationDescription, privacy: .public) \
            \(size / 1024, privacy: .public) KB \
            playable=\(duration != nil, privacy: .public)
            """)
        return intact ? .finished(result) : .salvaged(result, failure: report.writerFailure)
    }

    /// The throwing shape, kept for the self-tests that only care about the
    /// happy path.
    func stop() async throws -> RecordingResult {
        switch await finish() {
        case .finished(let result), .salvaged(let result, _):
            return result
        case .lost(let url, let failure):
            throw failure ?? RecordingError.fileMissing(url)
        }
    }

    func cancel() async {
        guard let recording = active else { return }
        active = nil
        _ = await recording.session.stop()
        try? FileManager.default.removeItem(at: recording.url)
        Log.record.notice("recording cancelled and discarded")
    }

    /// Clears the engine's idea of what is running, without touching the stream.
    /// For the path where SCK has already stopped on its own.
    func forget() {
        active = nil
    }

    /// What the container says, or nil if it cannot be read.
    private static func assetDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else {
            return nil
        }
        return duration.seconds
    }

    // MARK: - Configuration

    private func streamConfiguration(
        pixelSize: (width: Int, height: Int), sourceRect: CGRect?, options: RecordingOptions
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        if let sourceRect {
            // Documented as "in points in the display's logical coordinate
            // system" — the same wording the screenshot API uses, which M1
            // measured to mean *content-local, from (0,0)*. Verified separately
            // for streams by `--selftest-record`, because identical prose in two
            // headers has already meant two different things in this SDK.
            configuration.sourceRect = sourceRect
        }
        // A *minimum interval*, so this caps the rate rather than setting it.
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.showsCursor = options.showsCursor
        configuration.showMouseClicks = options.showsMouseClicks
        configuration.capturesAudio = options.capturesSystemAudio
        // Our own shutter sound and any UI noise would otherwise land in the
        // recording of our own screen.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.capturesMicrophone
        configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        // The SDK caps this at 8 and warns that more costs memory. Recording
        // hands frames straight to the writer, so headroom against a hitch is
        // worth more here than in a preview stream.
        configuration.queueDepth = 8
        // Without this the buffers come out in **the display's** colour space —
        // the SDK says so outright: "If not set the output buffer uses the same
        // color space as the display" (SCStream.h:288). The writer then tags the
        // file BT.709 regardless, so on any display whose profile is not sRGB the
        // recording is wrong: measured on an LG UltraFine, pure magenta
        // (255,0,255) on screen came out (218,90,245) in the file. Desaturated,
        // hue-shifted, and invisible to whoever recorded it because their own
        // player shows the same shift in reverse.
        //
        // This is also the answer to M9's open question in
        // eager-shimmying-crayon.md — "为什么会得到 0，尚未查明", the run that
        // counted zero magenta twice and full magenta the next time. It was never
        // about which windows a stream renders. The window was always there; its
        // colour depended on the display profile in effect, and an exact-match
        // magenta predicate flips with it.
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.streamName = "DuoShot Recording"
        // `pixelFormat` is left at its BGRA default on purpose: the SDK notes
        // `showMouseClicks` "currently applies when pixelFormat is set to BGRA".
        return configuration
    }

    /// Pixel dimensions rounded **down to even numbers**.
    ///
    /// H.264 is defined on 16×16 macroblocks and chroma is subsampled 4:2:0, so
    /// an odd width or height has no legal encoding — the encoder either pads
    /// silently or refuses. A drag-selected region is arbitrary and on a 1×
    /// display lands on an odd number half the time, so this cannot be left to
    /// chance. Losing at most one pixel per axis is invisible; a take that fails
    /// to start is not.
    private static func encodablePixelSize(
        of region: CGRect, scale: CGFloat
    ) -> (width: Int, height: Int) {
        let (width, height) = DisplayGeometry.pixelSize(of: region, scale: scale)
        return (max(2, width - width % 2), max(2, height - height % 2))
    }
}
