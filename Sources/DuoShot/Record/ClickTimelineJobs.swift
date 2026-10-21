import Foundation

/// Adds click timelines to takes that have already been saved.
///
/// **After the save, not before it.** The embed is a full copy of the movie —
/// measured at 3–5 s per GB — and a twenty-minute take at a typical
/// screen bitrate is several GB. Done before the take was handed to the output
/// pipeline, it held up the card and the save by tens of seconds, and a quit in
/// that window could leave the take in staging, unsaved, with a hidden copy of
/// it orphaned beside it. So a take is saved and announced exactly as it was
/// before timelines existed, and the timeline follows: the job works on the
/// saved file, swaps the copy in only if the file is still the one it started
/// from (`ClickTimelineEmbedder`), and otherwise leaves it alone.
///
/// **One at a time.** Each job is a copy the size of its take; two at once
/// double the disk the free-space check allowed for, and the next take can be
/// recording meanwhile. A take starting never waits for a job.
///
/// **Anything that replaces, moves or deletes a take stops its job first**
/// (`stop`, called by `VideoTrim` and `CaptureTrash`). `replaceItemAt` with
/// the original gone simply moves the copy into place, so a delete landing
/// between the job's last check and its swap would bring the take back, and a
/// trim landing there would be undone under a card that says it was trimmed.
///
/// Quitting cancels every job and starts no new one; the takes are already
/// saved, and what is lost is their timeline. A copy a crash or a kill leaves
/// behind is removed at the next launch (`sweep`).
final class ClickTimelineJobs {
    static let shared = ClickTimelineJobs(workDirectory: StagingStore.shared.directory)

    /// Where every copy is written: staging, which nothing syncs. The launch
    /// sweep covers exactly this.
    let workDirectory: URL
    /// Free space a copy must leave; raised by the self-test to take the
    /// low-space path on a disk that has room.
    var reserve = ClickTimelineEmbedder.defaultReserve

    private struct Job {
        let path: String
        let cancellation: ClickTimelineEmbedder.Cancellation
        let task: Task<Result<ClickTimelineEmbedder.Report, ClickTimelineEmbedder.Failure>, Never>
    }

    private var running: [UUID: Job] = [:]
    /// The last job queued; the next one starts when it ends.
    private var tail: Task<Void, Never>?
    private var isQuitting = false
    private var active = 0
    /// The most jobs that were ever copying at once, for the self-test.
    private(set) var peakActiveForTest = 0

    init(workDirectory: URL) {
        self.workDirectory = workDirectory
    }

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
        let previous = tail
        let workDirectory = workDirectory, reserve = reserve
        let task = Task { () -> Result<ClickTimelineEmbedder.Report, ClickTimelineEmbedder.Failure> in
            await previous?.value
            active += 1
            peakActiveForTest = max(peakActiveForTest, active)
            defer { active -= 1 }
            return await ClickTimelineEmbedder.embed(
                in: url, pending, workDirectory: workDirectory, reserve: reserve,
                cancellation: cancellation, fault: fault, failForTest: failForTest)
        }
        tail = Task { _ = await task.value }
        running[id] = Job(path: path, cancellation: cancellation, task: task)
        // With "save to disk" off the take stays in staging, where a capture
        // made meanwhile would prune it from under the copy.
        StagingStore.inUse.insert(path)
        defer {
            running[id] = nil
            if !running.values.contains(where: { $0.path == path }) { StagingStore.inUse.remove(path) }
        }
        let outcome = await task.value
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

    /// Stops the job on `url`, if there is one, and returns once it has
    /// stopped: after this, the job will not touch the file.
    func stop(_ url: URL) async {
        let path = url.standardizedFileURL.path
        let jobs = running.values.filter { $0.path == path }
        for job in jobs { job.cancellation.cancel() }
        for job in jobs { _ = await job.task.value }
    }

    /// `stop`, for callers off the main actor.
    static func stop(_ url: URL) async {
        await shared.stop(url)
    }

    /// For quitting: stop every job and start no more.
    func cancelAll() {
        isQuitting = true
        for job in running.values { job.cancellation.cancel() }
    }

    func waitUntilIdle(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !running.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Removes the hidden copies an interrupted embed or trim left in
    /// `directories`. Only files those write: the name carries
    /// `ClickTimelineEmbedder.sweepPrefix` or `VideoTrim.sweepPrefix`.
    @discardableResult
    static func sweep(_ directories: [URL]) -> Int {
        var removed = 0
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names where name.hasPrefix(ClickTimelineEmbedder.sweepPrefix)
                || name.hasPrefix(VideoTrim.sweepPrefix) {
                if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 {
            Log.record.notice("removed \(removed, privacy: .public) copy(ies) an interrupted click timeline or trim left")
        }
        return removed
    }
}
