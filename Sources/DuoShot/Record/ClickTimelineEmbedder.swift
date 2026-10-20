import AVFoundation
import CoreGraphics
import DuoShotCLIWire
import Darwin
import Foundation
import Synchronization

/// Puts a take's clicks into its movie file as a timed metadata track
/// (`ClickTimeline`), after `SCRecordingOutput` has finished writing it.
///
/// **A post-process, because the file is not ours while it is being written.**
/// `SCRecordingOutput` writes and finalises the movie itself; there is no point
/// at which a track can be added to it. So the finished file is remuxed:
/// every audio and video sample is copied as it is — no decode, no encode —
/// into a new file in a work directory (staging) with the metadata track
/// added, the copy is
/// checked against the original (`confirmSameMedia`), flushed to disk, and
/// only then swapped in. Any failure, a change to the file meanwhile, or a
/// cancellation leaves the original exactly as it was.
///
/// **The copy is never written beside the take.** The save folder can be one
/// a sync client watches, and a hidden file there is still a file: measured
/// on an iCloud Drive folder, a `.duoshot-clicks-*` copy was picked up and
/// uploading within ten seconds while it was still growing, so every take went
/// up twice and a crash left gigabytes syncing to every device. Staging is
/// not synced, and `replaceItemAt` from it into the iCloud folder, measured the
/// same day, kept the item's File Provider identifier and document ID, made no
/// conflict copy, and uploaded once. That needs both on one volume; when they
/// are not, the take keeps no timeline rather than getting a copy beside it.
///
/// **Why a remux with `AVAssetWriter`, measured on a real take.** Copying the
/// tracks with `AVMutableMovie` (`insertTimeRange(..., copySampleData: true)`)
/// and a passthrough `AVAssetExportSession` both dropped the last two AAC
/// packets (2112 PCM frames — the codec's priming count, applied twice); the
/// remux kept all 453 packets and decoded to byte-identical PCM, with the
/// video's movie times unchanged to the last digit — provided the writer's
/// movie timescale is the source's (at 600 the audio's leading edit rounded
/// 1.1 ms short). One reader per track, pumped from one thread: several
/// outputs of one reader on one thread deadlock on interleaving.
///
/// **The time mapping.** The file does not keep capture times: its samples
/// start near zero, and an edit list maps media time to movie time. Clicks
/// carry `NSEvent.timestamp`, host-clock seconds — the clock ScreenCaptureKit
/// stamps its frames with. So the session records the host time of every
/// complete frame the stream delivers (`SCKRecordingSession`), and here those
/// are lined up with the movie times of the file's own video samples by their
/// spacing; the matching frame's host time minus its movie time is the host
/// time of movie time zero. Measured: the stream delivered exactly the frames
/// the file holds, 14 of 14, and the first of them is movie time zero (27.8 ms
/// after the writer reported starting). A click at host time `h` is then at
/// movie time `h - anchor`.
///
/// **Only what the picture shows.** A click outside the recorded area — or,
/// for an isolated take, outside the window — is not stored at all, and a take
/// that hides the pointer gets no timeline: a shared file must not carry more
/// than its pixels do (a PIN pad or an on-screen keyboard beside the region).
nonisolated enum ClickTimelineEmbedder {
    struct Geometry: Sendable {
        /// The recorded area, global points, origin top-left.
        let regionInCGGlobal: CGRect
        /// The encoded frame size.
        let pixelSize: CGSize
    }

    /// Everything a take leaves for its timeline, carried on its result until
    /// the file has been saved and can be worked on.
    struct Pending: Sendable {
        let events: [ClickRecorder.Event]
        let frameHostTimes: [Double]
        let writerStart: Double?
        let geometry: Geometry
        /// The take shows the pointer. Off, there is no timeline at all.
        let showsCursor: Bool
    }

    struct Report: Sendable {
        let clicks: Int
        /// How movie time zero was found: "frame-spacing" or "writer-start".
        let method: String
        let anchorError: Double?
        /// Host-clock seconds of movie time zero.
        let anchorHostTime: Double
        /// Why nothing was embedded although nothing failed, if so.
        var skipped: String?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Set from anywhere to stop an embed that is running; it gives up at the
    /// next sample and leaves the original alone.
    final class Cancellation: Sendable {
        private let flag = Mutex(false)
        init() {}
        func cancel() { flag.withLock { $0 = true } }
        var isCancelled: Bool { flag.withLock { $0 } }
    }

    /// For the self-test of `confirmSameMedia`: damage the copy on purpose.
    enum Fault: String, Sendable, CaseIterable {
        case dropVideoSample = "a dropped video sample"
        case shiftVideoFrame = "frames from the third on shifted by 1/600 s"
        case loseAudioTail = "the last audio packet lost"
        case changeEditList = "a different edit list"
        case none
    }

    /// Embeds, or leaves the file alone and says why. Never throws.
    @concurrent
    static func embed(
        in url: URL, _ pending: Pending, workDirectory: URL, reserve: Int64 = defaultReserve,
        cancellation: Cancellation = Cancellation(),
        fault: Fault = .none, failForTest: Bool = false
    ) async -> Result<Report, Failure> {
        do {
            // Cancelled while it waited its turn.
            guard !cancellation.isCancelled else { throw Failure(message: "cancelled") }
            let identity = try fileIdentity(url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let movieTimes = try await videoMovieTimes(of: asset, cancellation: cancellation)
            guard let anchor = anchor(
                hostTimes: pending.frameHostTimes, movieTimes: movieTimes,
                writerStart: pending.writerStart)
            else { throw Failure(message: "no frame times to anchor the clicks to") }
            var report = Report(clicks: 0, method: anchor.method, anchorError: anchor.meanError,
                                anchorHostTime: anchor.offset)
            guard pending.showsCursor else {
                report.skipped = "the take hides the pointer"
                return .success(report)
            }

            let marks: [(Double, ClickMark)] = pending.events.compactMap { event in
                let t = event.timestamp - anchor.offset
                guard t >= 0, t < duration.seconds else { return nil }
                let mark = mark(for: event, geometry: pending.geometry)
                return mark.outside ? nil : (t, mark)
            }
            guard !marks.isEmpty else {
                report.skipped = "no clicks inside the recorded area"
                return .success(report)
            }
            if let reason = try roomForCopy(of: url, size: identity.size, in: workDirectory, reserve: reserve) {
                report.skipped = reason
                return .success(report)
            }

            let destination = workDirectory
                .appendingPathComponent("\(sweepPrefix)\(UUID().uuidString.prefix(8))")
                .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            defer { try? FileManager.default.removeItem(at: destination) }
            try await remux(asset, duration: duration, marks: marks, to: destination,
                            fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4,
                            cancellation: cancellation, fault: fault)
            try await confirmSameMedia(asset, as: AVURLAsset(url: destination), cancellation: cancellation)
            try fullSync(destination)
            #if DUOSHOT_SELFTEST
            if failForTest { throw Failure(message: "failing on purpose (self-test)") }
            #endif
            guard !cancellation.isCancelled else { throw Failure(message: "cancelled") }
            // Trimmed, moved or deleted since this started: whatever it is now,
            // it is no longer the file the copy was made from.
            guard try fileIdentity(url) == identity else {
                throw Failure(message: "the file changed while its timeline was being added")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: destination)
            report = Report(clicks: marks.count, method: anchor.method, anchorError: anchor.meanError,
                            anchorHostTime: anchor.offset)
            return .success(report)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }

    /// Free space the copy must leave behind it, on top of its own size: about
    /// 27 minutes of recording at a typical screen bitrate (750 MB per two
    /// minutes, measured). A take can start while a timeline is being added,
    /// and it records into staging, the same volume as the copy, so a copy
    /// that left the disk near full would end the next take, not this one.
    static let defaultReserve: Int64 = 10 << 30

    /// Nil when the copy can be made; otherwise why not. Never beside the take
    /// (see the type's comment), so the work directory has to be on the take's
    /// own volume for `replaceItemAt` to swap rather than fail.
    private static func roomForCopy(
        of url: URL, size: off_t, in workDirectory: URL, reserve: Int64
    ) throws -> String? {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        var folder = stat(), work = stat()
        guard stat(url.deletingLastPathComponent().path, &folder) == 0,
              stat(workDirectory.path, &work) == 0
        else { throw Failure(message: "cannot read the volume of the take or of staging") }
        guard folder.st_dev == work.st_dev else {
            return "the take is on another volume than staging"
        }
        let available = try workDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= Int64(size) + reserve else {
            return "not enough free space: \(available >> 20) MB free, the copy needs \(Int64(size) >> 20) MB and leaves \(reserve >> 20) MB"
        }
        return nil
    }

    /// The prefix of every copy this writes, for the sweep at launch: a copy
    /// left by a crash or a kill is hidden, so nothing else ever removes it.
    static let sweepPrefix = ".duoshot-clicks-"

    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, modified: timespec

        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private static func fileIdentity(_ url: URL) throws -> Identity {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw Failure(message: "the file is gone") }
        return Identity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modified: info.st_mtimespec)
    }

    /// To the disk, not the drive's cache: the swap that follows is atomic,
    /// and must not make the only copy one that a power cut can lose.
    private static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure(message: "cannot open the copy to flush it") }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw Failure(message: "cannot flush the copy to disk")
        }
    }

    // MARK: - The mapping

    /// Host time of movie time zero.
    ///
    /// Lines the frames up by their spacing: the offset `k` into the stream's
    /// frames at which `host[k+i] - host[k]` best matches `movie[i] - movie[0]`.
    /// When the stream and the file hold the same number of frames that is
    /// k = 0, as measured; spacing alone cannot tell offsets apart on a steady
    /// frame rate, so ties go to the earliest frame not long before the writer
    /// started. The writer-start rule on its own is the fallback.
    static func anchor(
        hostTimes: [Double], movieTimes: [Double], writerStart: Double?
    ) -> (offset: Double, method: String, meanError: Double?)? {
        guard let firstMovie = movieTimes.first, let firstHost = hostTimes.first else { return nil }
        let n = min(30, movieTimes.count)
        if n >= 3, hostTimes.count >= n {
            var scored: [(k: Int, error: Double)] = []
            for k in 0...(hostTimes.count - n) {
                var error = 0.0
                for i in 0..<n {
                    error += abs((hostTimes[k + i] - hostTimes[k]) - (movieTimes[i] - firstMovie))
                }
                scored.append((k, error / Double(n)))
            }
            let best = scored.map(\.error).min() ?? .infinity
            if best < 0.002 {
                let earliest = writerStart.map { $0 - 0.05 } ?? -.infinity
                let candidates = scored.filter { $0.error <= best + 0.0005 }
                let chosen = hostTimes.count == movieTimes.count
                    ? candidates.first { $0.k == 0 } ?? candidates[0]
                    : candidates.first { hostTimes[$0.k] >= earliest } ?? candidates[0]
                return (hostTimes[chosen.k] - firstMovie, "frame-spacing", chosen.error)
            }
        }
        let first = writerStart.flatMap { start in hostTimes.first { $0 >= start } } ?? firstHost
        return (first - firstMovie, "writer-start", nil)
    }

    static func mark(for event: ClickRecorder.Event, geometry: Geometry) -> ClickMark {
        let point = event.locationInCGGlobal
        let region = geometry.regionInCGGlobal
        let scaleX = region.width > 0 ? geometry.pixelSize.width / region.width : 1
        let scaleY = region.height > 0 ? geometry.pixelSize.height / region.height : 1
        return ClickMark(
            phase: event.isDown ? "down" : "up", button: event.button,
            clickCount: event.clickCount, x: point.x, y: point.y,
            px: (point.x - region.minX) * scaleX, py: (point.y - region.minY) * scaleY,
            outside: !region.contains(point))
    }

    // MARK: - Reading the file

    /// Every video sample's presentation time on the movie's timeline: media
    /// time mapped through the track's edit list.
    static func videoMovieTimes(
        of asset: AVURLAsset, cancellation: Cancellation? = nil
    ) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        return try await samples(of: track, in: asset, cancellation: cancellation).map(\.time).sorted()
    }

    /// One sample as the copy check sees it.
    struct Sample: Equatable {
        /// Movie time, through the edit list.
        let time: Double
        let duration: Double
        let size: Int
    }

    /// Every sample of a track, in decode order, read raw (no output settings
    /// — a raw reader reports media time, which is mapped here).
    /// Reading a multi-gigabyte take's tables takes seconds, so a quit is
    /// listened for here too, not only while copying.
    static func samples(
        of track: AVAssetTrack, in asset: AVURLAsset, cancellation: Cancellation? = nil
    ) async throws -> [Sample] {
        let segments = try await track.load(.segments)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "cannot read the samples") }
        var samples: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            if cancellation?.isCancelled == true {
                reader.cancelReading()
                throw Failure(message: "cancelled")
            }
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            var timingCount = 0
            CMSampleBufferGetSampleTimingInfoArray(
                buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &timingCount)
            for index in 0..<count {
                // Audio buffers carry many packets under one timing entry, and
                // the original and the copy are chunked differently: a packet's
                // time is the entry's plus its place in the run.
                var info = index < timingCount ? timing[index] : timing.first ?? CMSampleTimingInfo()
                if timingCount == 1, count > 1 {
                    info.presentationTimeStamp = info.presentationTimeStamp
                        + CMTimeMultiply(info.duration, multiplier: Int32(index))
                }
                let media = info.presentationTimeStamp
                var time = media.seconds
                for segment in segments where !segment.isEmpty
                    && CMTimeRangeContainsTime(segment.timeMapping.source, time: media) {
                    time = (media - segment.timeMapping.source.start
                            + segment.timeMapping.target.start).seconds
                    break
                }
                samples.append(Sample(
                    time: (time * 1_000_000).rounded() / 1_000_000,
                    duration: (info.duration.seconds * 1_000_000).rounded() / 1_000_000,
                    size: CMSampleBufferGetSampleSize(buffer, at: index)))
            }
        }
        return samples
    }

    /// The copy holds the same media as the original, or it is not used.
    ///
    /// Compared, for every audio and video track in turn: the number of
    /// samples; each sample's size, duration and presentation time on the
    /// movie's timeline (all but the duration of the very last, which the
    /// format leaves to the writer); and the track's edit list as movie-time
    /// ranges, which bounds how much of that last sample is shown.
    /// Bytes are not hashed — that would read the whole file a third time —
    /// but a passthrough copy cannot change a sample's content without its
    /// size, and the self-test hashes them. The movie's overall duration is
    /// not compared: it is derived from the tracks, which are.
    static func confirmSameMedia(
        _ original: AVURLAsset, as copy: AVURLAsset, cancellation: Cancellation? = nil
    ) async throws {
        for type in [AVMediaType.video, .audio] {
            let mine = try await original.loadTracks(withMediaType: type)
            let theirs = try await copy.loadTracks(withMediaType: type)
            guard mine.count == theirs.count else {
                throw Failure(message: "the copy has \(theirs.count) \(type.rawValue) track(s), the original \(mine.count)")
            }
            for (a, b) in zip(mine, theirs) {
                let (first, second) = (try await samples(of: a, in: original, cancellation: cancellation),
                                       try await samples(of: b, in: copy, cancellation: cancellation))
                guard first.count == second.count else {
                    throw Failure(message: "the copy has \(second.count) \(type.rawValue) samples, the original \(first.count)")
                }
                // The last sample's duration is the one number a writer makes
                // up: the format stores no end for it, and two writers given
                // the same samples closed it at 1/600 s and at 50 ms. What is
                // shown of it is bounded by the edit list, compared below.
                let last = first.count - 1
                let differs = { (i: Int) -> Bool in
                    i == last
                        ? first[i].time != second[i].time || first[i].size != second[i].size
                        : first[i] != second[i]
                }
                if let index = first.indices.first(where: differs) {
                    throw Failure(message: """
                        \(type.rawValue) sample \(index) differs: \(first[index]) vs \(second[index])
                        """)
                }
                let (edits, copied) = (try await a.load(.segments), try await b.load(.segments))
                let describe = { (segments: [AVAssetTrackSegment]) -> [String] in
                    segments.map {
                        String(format: "%@%.4f+%.4f", $0.isEmpty ? "empty " : "",
                               $0.timeMapping.target.start.seconds, $0.timeMapping.target.duration.seconds)
                    }
                }
                guard describe(edits) == describe(copied) else {
                    throw Failure(message: "the \(type.rawValue) edit list differs: \(describe(edits)) vs \(describe(copied))")
                }
            }
        }
    }

    // MARK: - The remux

    private struct Lane {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let mediaType: AVMediaType
        var finished = false
        var appended = 0
        let total: Int
    }

    private static func remux(
        _ asset: AVURLAsset, duration: CMTime, marks: [(Double, ClickMark)],
        to destination: URL, fileType: AVFileType, cancellation: Cancellation, fault: Fault
    ) async throws {
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        // The source's, or the leading edit of the audio is rounded to the
        // writer's default 600 and the sound moves against the picture.
        writer.movieTimeScale = duration.timescale

        var lanes: [Lane] = []
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            let (formats, transform) = try await track.load(.formatDescriptions, .preferredTransform)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            guard writer.canAdd(input) else { throw Failure(message: "cannot copy a \(track.mediaType.rawValue) track") }
            writer.add(input)
            let total = fault == .loseAudioTail && track.mediaType == .audio
                ? try await samples(of: track, in: asset).count : 0
            lanes.append(Lane(reader: reader, output: output, input: input,
                              mediaType: track.mediaType, total: total))
        }

        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                ClickTimeline.identifier.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_UTF8 as String,
        ]
        var format: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format)
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        metadataInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw Failure(message: "the container takes no metadata track") }
        writer.add(metadataInput)

        var groups = metadataGroups(marks, until: duration)
        for lane in lanes where !lane.reader.startReading() {
            throw Failure(message: "cannot read: \(lane.reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw Failure(message: "cannot write: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: fault == .changeEditList
                            ? CMTime(value: 1, timescale: 10) : .zero)

        var metadataDone = false
        while !metadataDone || lanes.contains(where: { !$0.finished }) {
            if cancellation.isCancelled {
                writer.cancelWriting()
                throw Failure(message: "cancelled")
            }
            var moved = false
            for index in lanes.indices where !lanes[index].finished {
                while lanes[index].input.isReadyForMoreMediaData {
                    guard var sample = lanes[index].output.copyNextSampleBuffer() else {
                        lanes[index].input.markAsFinished()
                        lanes[index].finished = true
                        break
                    }
                    let isVideo = lanes[index].mediaType == .video
                    let real = CMSampleBufferGetNumSamples(sample) > 0
                    if real {
                        lanes[index].appended += CMSampleBufferGetNumSamples(sample)
                        switch fault {
                        case .dropVideoSample where isVideo && lanes[index].appended == 2:
                            continue
                        case .shiftVideoFrame where isVideo && lanes[index].appended >= 3:
                            sample = shifted(sample, by: CMTime(value: 1, timescale: 600)) ?? sample
                        case .loseAudioTail where !isVideo && lanes[index].appended >= lanes[index].total:
                            continue
                        default:
                            break
                        }
                    }
                    guard lanes[index].input.append(sample) else {
                        throw Failure(message: "copy failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    moved = true
                }
            }
            if !metadataDone {
                while metadataInput.isReadyForMoreMediaData {
                    guard !groups.isEmpty else {
                        metadataInput.markAsFinished()
                        metadataDone = true
                        break
                    }
                    guard adaptor.append(groups.removeFirst()) else {
                        throw Failure(message: "metadata failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    moved = true
                }
            }
            if writer.status == .failed {
                throw Failure(message: "copy failed: \(writer.error?.localizedDescription ?? "?")")
            }
            if !moved { try await Task.sleep(for: .milliseconds(1)) }
        }
        // No `endSession(atSourceTime:)`: it stretches each track's last
        // sample to that time, so a take whose audio outlasts its video got a
        // longer last frame in the copy, and the copy check — rightly — refused
        // it. Left to itself the writer ends every track where its samples do,
        // as the original's did.
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(message: "could not finish: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    /// For `Fault.shiftVideoFrame`: the same sample, later.
    private static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = timing.presentationTimeStamp + offset
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    /// One group per instant, empty groups in between (see `ClickTimeline`).
    private static func metadataGroups(
        _ marks: [(Double, ClickMark)], until duration: CMTime
    ) -> [AVTimedMetadataGroup] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var instants: [(start: CMTime, marks: [ClickMark])] = []
        for (t, mark) in marks.sorted(by: { $0.0 < $1.0 }) {
            let start = CMTime(seconds: t, preferredTimescale: 60_000)
            if let last = instants.last, start < last.start + ClickTimeline.markDuration {
                instants[instants.count - 1].marks.append(mark)
            } else {
                instants.append((start, [mark]))
            }
        }
        var groups: [AVTimedMetadataGroup] = []
        var cursor = CMTime.zero
        for instant in instants {
            if instant.start > cursor {
                groups.append(AVTimedMetadataGroup(
                    items: [], timeRange: CMTimeRange(start: cursor, end: instant.start)))
            }
            let items = instant.marks.map { mark -> AVMetadataItem in
                let item = AVMutableMetadataItem()
                item.identifier = ClickTimeline.identifier
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                item.value = String(decoding: (try? encoder.encode(mark)) ?? Data(), as: UTF8.self) as NSString
                return item
            }
            let end = min(instant.start + ClickTimeline.markDuration, duration)
            let start = max(instant.start, cursor)
            guard end > start else { continue }
            groups.append(AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: start, end: end)))
            cursor = end
        }
        if duration > cursor {
            groups.append(AVTimedMetadataGroup(items: [], timeRange: CMTimeRange(start: cursor, end: duration)))
        }
        return groups
    }
}
