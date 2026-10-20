import Foundation

/// Adds click timelines to takes that have already been saved.
///
/// **After the save, not before it.** The embed is a full copy of the movie —
/// measured at about 2.8 s per GB — and a twenty-minute take at a typical
/// screen bitrate is several GB. Done before the take was handed to the output
/// pipeline, it held up the card and the save by tens of seconds, and a quit in
/// that window could leave the take in staging, unsaved, with a hidden copy of
/// it orphaned beside it. So a take is saved and announced exactly as it was
/// before timelines existed, and the timeline follows: the job works on the
/// saved file, swaps the copy in only if the file is still the one it started
/// from (`ClickTimelineEmbedder`), and otherwise leaves it alone.
///
/// Quitting cancels every job and starts no new one; the takes are already
/// saved, and what is lost is their timeline. A copy a crash or a kill leaves
/// behind is removed at the next launch (`sweep`).
final class ClickTimelineJobs {
    static let shared = ClickTimelineJobs()

    private var running: [UUID: ClickTimelineEmbedder.Cancellation] = [:]
    private var isQuitting = false

    var isIdle: Bool { running.isEmpty }

    /// For a take the user just saved: in the background.
    func start(_ pending: ClickTimelineEmbedder.Pending, into url: URL) {
        Task { _ = await run(pending, into: url) }
    }

    /// For the command line, which returns the movie with its timeline, and
    /// for the self-tests.
    func run(
        _ pending: ClickTimelineEmbedder.Pending, into url: URL,
        cancellation: ClickTimelineEmbedder.Cancellation = .init(),
        fault: ClickTimelineEmbedder.Fault = .none, failForTest: Bool = false
    ) async -> Result<ClickTimelineEmbedder.Report, ClickTimelineEmbedder.Failure> {
        guard !isQuitting else {
            Log.record.notice("click timeline not added: DuoShot is quitting; the take is saved without it")
            return .failure(.init(message: "DuoShot is quitting"))
        }
        let id = UUID()
        let path = url.standardizedFileURL.path
        running[id] = cancellation
        // With "save to disk" off the take stays in staging, where a capture
        // made meanwhile would prune it from under the copy.
        StagingStore.inUse.insert(path)
        defer {
            running[id] = nil
            StagingStore.inUse.remove(path)
        }
        let outcome = await ClickTimelineEmbedder.embed(
            in: url, pending, cancellation: cancellation, fault: fault, failForTest: failForTest)
        switch outcome {
        case .success(let report):
            Log.record.notice("""
                click timeline: \(report.clicks, privacy: .public) event(s) in \
                \(url.lastPathComponent, privacy: .public), anchored by \
                \(report.method, privacy: .public)\(report.skipped.map { "; none stored: \($0)" } ?? "", privacy: .public)
                """)
        case .failure(let failure):
            Log.record.error("""
                click timeline not added to \(url.lastPathComponent, privacy: .public), \
                the take is kept as it was: \(failure.message, privacy: .public)
                """)
        }
        return outcome
    }

    /// For quitting: stop every job and start no more.
    func cancelAll() {
        isQuitting = true
        for cancellation in running.values { cancellation.cancel() }
    }

    func waitUntilIdle(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !running.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Removes the hidden copies an interrupted embed left in `directories`.
    /// Only files this writes: the name carries `sweepPrefix`.
    @discardableResult
    static func sweep(_ directories: [URL]) -> Int {
        var removed = 0
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names where name.hasPrefix(ClickTimelineEmbedder.sweepPrefix) {
                if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 {
            Log.record.notice("removed \(removed, privacy: .public) copy(ies) an interrupted click timeline left")
        }
        return removed
    }
}
