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
    let pointSize: CGSize
    let pixelSize: CGSize
    let scale: CGFloat
    let sourceDescription: String
    let startedAt: Date

    fileprivate let session: SCKRecordingSession

    var url: URL { session.outputURL }

    fileprivate init(
        session: SCKRecordingSession, request: RecordingRequest, options: RecordingOptions,
        pointSize: CGSize, pixelSize: CGSize, scale: CGFloat, sourceDescription: String
    ) {
        self.session = session
        self.request = request
        self.options = options
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
        if options.capturesMicrophone, !MicrophonePermission.isGranted {
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
        guard try await session.writerStarted.wait(timeout: .seconds(5)) else {
            _ = try? await session.stop()
            throw RecordingError.writerNeverStarted
        }
        let writerLatency = captureStarted.duration(to: .now).milliseconds
        let captureLatency = started.duration(to: captureStarted).milliseconds

        let index = content.displayIDs.firstIndex(of: displayID).map { $0 + 1 } ?? 1
        let recording = ActiveRecording(
            session: session,
            request: request,
            options: options,
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

    func stop() async throws -> RecordingResult {
        guard let recording = active else { throw RecordingError.notRecording }
        active = nil

        let stats = try await recording.session.stop()
        let url = recording.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingError.fileMissing(url)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? stats.fileSize
        guard size > 0 else { throw RecordingError.emptyFile(url) }

        // The duration comes from the finished file, not from the writer.
        // `SCRecordingOutput.recordedDuration` lags: measured 2026-07-31 it
        // reported exactly 3.00 s for takes the container puts at 3.51 s and
        // 3.65 s — round to the tenth in both cases, so it is quantised as well
        // as behind. It is fine for a live HUD counter and wrong for the number
        // stamped on a finished recording.
        let duration = await Self.assetDuration(of: url) ?? stats.duration

        let result = RecordingResult(
            url: url,
            duration: duration,
            fileSize: size,
            pixelSize: recording.pixelSize,
            pointSize: recording.pointSize,
            scale: recording.scale,
            sourceDisplayID: recording.request.displayID,
            sourceDescription: recording.sourceDescription,
            startedAt: recording.startedAt)

        Log.record.notice("""
            recording finished \(url.lastPathComponent, privacy: .public) \
            \(result.durationDescription, privacy: .public) \
            \(size / 1024, privacy: .public) KB
            """)
        return result
    }

    /// Stops and deletes. Used by the cancel path, where the user has said the
    /// take is not wanted.
    func cancel() async {
        guard let recording = active else { return }
        active = nil
        _ = try? await recording.session.stop()
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
