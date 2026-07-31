import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

// =============================================================================
// The ONLY file in this project permitted to use `@unchecked Sendable`.
//
// ScreenCaptureKit ships almost no Sendable annotations: `SCScreenshotConfiguration`
// is NS_SWIFT_SENDABLE, but `SCScreenshotOutput`, `SCContentFilter`, `SCWindow`,
// `SCDisplay`, `SCRunningApplication`, `SCShareableContent`, `SCStream` and
// `SCRecordingOutput` are not (verified against the macOS 26.5 SDK headers;
// there are no .apinotes adding them).
//
// We deliberately wrap the *completion-handler* variants rather than calling the
// auto-generated `async` ones. That puts the isolation boundary somewhere we
// control, lets us snapshot into a Sendable type inside the callback, and keeps
// the compiler diagnostics comprehensible.
//
// Every function here is `nonisolated`. Combined with NonisolatedNonsendingByDefault
// (SE-0461) they run on the *caller's* executor, so a MainActor-isolated
// `SCContentFilter` passed in never leaves its isolation region.
// =============================================================================

nonisolated enum CaptureError: Error, LocalizedError {
    case emptyOutput
    case noDisplays
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    case noImageProduced
    case encodingFailed(String)
    case recordingStartTimedOut(Double)
    case recordingNotRunning

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            "ScreenCaptureKit returned neither an output nor an error."
        case .noDisplays:
            "No displays reported by ScreenCaptureKit."
        case .displayNotFound(let id):
            "No SCDisplay for display ID \(id)."
        case .windowNotFound(let id):
            "No SCWindow for window ID \(id)."
        case .recordingNotRunning:
            "No recording is running."
        case .noImageProduced:
            "Capture succeeded but produced no image."
        case .encodingFailed(let why):
            "Image encoding failed: \(why)."
        case .recordingStartTimedOut(let seconds):
            "ScreenCaptureKit never answered startCapture within \(seconds)s."
        }
    }
}

/// Immutable snapshot of `SCScreenshotOutput`.
///
/// SCK fires its completion on an internal queue. We copy out the immutable
/// fields there and share nothing else, so `@unchecked` is honest rather than a
/// silencer. `CGImage` itself is an immutable CF type.
// `nonisolated` on the type opts the whole thing out of the module's default
// MainActor isolation (SE-0466). Required: these are built inside SCK completion
// handlers, which fire on an internal queue.
nonisolated struct SCKOutput: @unchecked Sendable {
    let sdrImage: CGImage?
    let hdrImage: CGImage?
    let fileURL: URL?

    /// The image we actually want to hand to the rest of the app.
    var image: CGImage? { sdrImage ?? hdrImage }
}

/// Carries a live, non-Sendable SCK object across the completion-handler boundary.
///
/// Honest because SCK constructs these fresh per call and the receiving side
/// immediately pins them to `@MainActor` (see `ShareableContentCache`). Nothing
/// else ever touches the boxed value.
nonisolated struct SCKBox<Value>: @unchecked Sendable {
    let value: Value
}

enum SCKBridge {
    // MARK: - Screenshots

    static func captureScreenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> SCKOutput {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            ) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let output else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                    return
                }
                continuation.resume(
                    returning: SCKOutput(
                        sdrImage: output.sdrImage,
                        hdrImage: output.hdrImage,
                        // Declared `assign` (not `strong`) in the SDK, so it
                        // imports as NSURL? rather than bridging to URL?. Read
                        // it here, inside the callback, while `output` is alive.
                        fileURL: output.fileURL as URL?
                    )
                )
            }
        }
    }

    // MARK: - Content enumeration

    /// Everything shareable on the system. Requires the Screen Recording grant.
    static func shareableContent(
        excludingDesktopWindows: Bool = true,
        onScreenWindowsOnly: Bool = true
    ) async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }

    /// The plain enumeration, kept alongside the filtered one for diagnostics:
    /// they can disagree, and when displays go missing it matters which.
    static func allShareableContent() async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }

    /// Only *our own* process's windows.
    ///
    /// macOS 14.4+. Dramatically cheaper than the full enumeration and — the
    /// reason we use it — it requires no TCC round-trip, so finding our overlay
    /// panels to exclude them can never be affected by the monthly re-prompt.
    static func currentProcessShareableContent() async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Recording
//
// A screenshot is one call with one completion handler. A recording is a live
// session with two delegate protocols reporting on queues we do not choose, and
// it has to be startable, stoppable and observable from MainActor code. That is
// a different shape, and it lives here for the same reason the rest does: this
// is where SCK's missing Sendability is allowed to be dealt with.
// =============================================================================

/// A one-shot flag an async caller can wait on.
///
/// **Polled, not parked on a continuation, and that is the whole point.** SCK
/// may simply never fire `recordingOutputDidFinishRecording:`; a continuation
/// waiting on it would hang forever, and `await`-ing such a continuation cannot
/// be cancelled out of by a racing timeout task. This is the same lesson the
/// overlay lifecycle test learned the hard way — a flag you can poll survives
/// the callback not happening, a continuation does not.
nonisolated final class SCKLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var failure: (any Error)?

    var signalled: Bool { lock.withLock { isSignalled } }
    var error: (any Error)? { lock.withLock { failure } }

    /// First call wins: a failure arriving after a success is not allowed to
    /// rewrite history, and vice versa.
    func signal(_ error: (any Error)? = nil) {
        lock.withLock {
            guard !isSignalled else { return }
            isSignalled = true
            failure = error
        }
    }

    /// Returns true if the latch opened before the deadline. Throws if it opened
    /// with an error.
    @discardableResult
    func wait(timeout: Duration, poll: Duration = .milliseconds(20)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            let (opened, failure) = lock.withLock { (isSignalled, self.failure) }
            if opened {
                if let failure { throw failure }
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: poll)
        }
    }
}

/// One recording: an `SCStream` plus the `SCRecordingOutput` writing it to disk.
///
/// `@unchecked Sendable` is honest here in the narrow sense the rest of this
/// file uses it: every mutable field is behind `lock`, and the two SCK objects
/// are only ever handed back to SCK.
nonisolated final class SCKRecordingSession: NSObject, @unchecked Sendable,
    SCStreamDelegate, SCRecordingOutputDelegate
{
    nonisolated struct Stats: Sendable {
        let duration: TimeInterval
        let fileSize: Int
    }

    let outputURL: URL

    /// Opened by `recordingOutputDidStartRecording:` — the writer is live.
    let writerStarted = SCKLatch()
    /// Opened by `recordingOutputDidFinishRecording:` — the file is finalised
    /// and playable. **Not** the same event as the stream stopping: the stream
    /// stops delivering frames, then the writer flushes and closes the file.
    let writerFinished = SCKLatch()

    private let lock = NSLock()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var isStopping = false
    /// Last non-zero counters. `SCRecordingOutput` has no documented behaviour
    /// after finalisation, so the running total is kept rather than trusted to
    /// still be readable at the end.
    private var lastStats = Stats(duration: 0, fileSize: 0)
    private var unexpectedStop: (@Sendable (any Error) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    /// Called when the stream or the writer dies on its own — display
    /// disconnected, disk full, Screen Recording revoked mid-recording.
    func onUnexpectedStop(_ handler: @escaping @Sendable (any Error) -> Void) {
        lock.withLock { unexpectedStop = handler }
    }

    /// Builds the stream, attaches the writer, and starts capturing.
    ///
    /// `nonisolated` under NonisolatedNonsendingByDefault, so it runs on the
    /// caller's executor: the non-Sendable `SCContentFilter` never leaves the
    /// MainActor region it was built in. Same trick as `captureScreenshot`.
    ///
    /// **`startCapture` is given a deadline, and that is not defensive
    /// programming.** Measured 2026-07-31: with `captureMicrophone = true` and
    /// the microphone grant still undecided, the completion handler is never
    /// called at all — not late, never — while the stream itself starts, the
    /// writer opens the file and frames flow. `replayd` sits waiting on a TCC
    /// prompt nobody answered. Awaiting that continuation is an unbounded hang
    /// with a recording running behind it and no way for the user to stop it.
    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        recording: SCRecordingOutputConfiguration,
        timeout: Duration = .seconds(10)
    ) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        // Throws before the stream is running, which is the good case: a bad
        // output URL or codec fails here rather than half a second into a take.
        try stream.addRecordingOutput(output)
        lock.withLock {
            self.stream = stream
            self.recordingOutput = output
        }

        let started = SCKLatch()
        stream.startCapture { error in started.signal(error) }

        guard try await started.wait(timeout: timeout) else {
            // Tear the half-started stream down, or it keeps writing to a file
            // nobody is holding a handle to.
            lock.withLock { isStopping = true }
            stream.stopCapture { _ in }
            lock.withLock {
                self.stream = nil
                self.recordingOutput = nil
            }
            throw CaptureError.recordingStartTimedOut(timeout.seconds)
        }
    }

    /// Applies a new configuration to the running stream.
    ///
    /// Whether an audio change mid-take is safe for the *file* — not just for
    /// the stream — is not something the SDK header or the documentation
    /// answers, so `--selftest-record-audio-switch` measures it rather than this
    /// comment asserting it.
    func update(configuration: SCStreamConfiguration, timeout: Duration = .seconds(5)) async throws {
        guard let stream = lock.withLock({ self.stream }) else {
            throw CaptureError.recordingNotRunning
        }
        let updated = SCKLatch()
        stream.updateConfiguration(configuration) { error in updated.signal(error) }
        guard try await updated.wait(timeout: timeout) else {
            throw CaptureError.recordingStartTimedOut(timeout.seconds)
        }
    }

    /// Live counters, safe to poll from the HUD's timer.
    var stats: Stats {
        lock.withLock {
            guard let recordingOutput else { return lastStats }
            let time = recordingOutput.recordedDuration
            let seconds = time.isNumeric ? time.seconds : lastStats.duration
            let size = recordingOutput.recordedFileSize
            // Monotonic on purpose: see `lastStats`.
            let stats = Stats(
                duration: max(seconds, lastStats.duration),
                fileSize: max(size, lastStats.fileSize))
            lastStats = stats
            return stats
        }
    }

    /// Stops the stream and waits for the writer to finalise the file.
    ///
    /// The counters are sampled *before* stopping, because the only moment the
    /// writer is guaranteed to still be able to answer is while it is running.
    @discardableResult
    func stop(finaliseTimeout: Duration = .seconds(15)) async throws -> Stats {
        let stream: SCStream? = lock.withLock {
            guard !isStopping else { return nil }
            isStopping = true
            return self.stream
        }
        guard let stream else { return stats }

        let sampled = stats

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                stream.stopCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            // `attemptToStopStreamState` means it had already stopped — which is
            // exactly the case where the file still needs to be finalised, so
            // this is logged and stepped over rather than thrown.
            Log.record.notice(
                "stopCapture reported \(error.localizedDescription, privacy: .public); continuing to finalise")
        }

        let finalised = try await writerFinished.wait(timeout: finaliseTimeout)
        if !finalised {
            Log.record.error(
                "writer never reported finishing after \(finaliseTimeout.seconds, privacy: .public)s")
        }
        lock.withLock {
            self.stream = nil
            self.recordingOutput = nil
        }
        return sampled
    }

    // MARK: - SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.record.notice("writer started -> \(self.outputURL.lastPathComponent, privacy: .public)")
        writerStarted.signal()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Log.record.notice("writer finished -> \(self.outputURL.lastPathComponent, privacy: .public)")
        writerFinished.signal()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Log.record.error("writer failed: \(error.localizedDescription, privacy: .public)")
        // Both latches, so a failure before the writer ever started does not
        // leave `start()` waiting out its whole timeout for a start that will
        // never come.
        writerStarted.signal(error)
        writerFinished.signal(error)
        reportUnexpectedStop(error)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.record.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        reportUnexpectedStop(error)
    }

    private func reportUnexpectedStop(_ error: any Error) {
        let handler: (@Sendable (any Error) -> Void)? = lock.withLock {
            guard !isStopping else { return nil }
            return unexpectedStop
        }
        handler?(error)
    }
}

extension Duration {
    /// For log lines that want a number rather than "1.5 seconds".
    nonisolated var seconds: Double {
        let (whole, atto) = components
        return Double(whole) + Double(atto) / 1e18
    }
}
