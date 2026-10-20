import AVFoundation
import CoreGraphics
import DuoShotCLIWire
import Foundation

/// Puts a take's clicks into its movie file as a timed metadata track
/// (`ClickTimeline`), after `SCRecordingOutput` has finished writing it.
///
/// **A post-process, because the file is not ours while it is being written.**
/// `SCRecordingOutput` writes and finalises the movie itself; there is no point
/// at which a track can be added to it. So the finished file is remuxed:
/// every audio and video sample is copied as it is — no decode, no encode —
/// into a new file beside it with the metadata track added, the copy is
/// checked against the original, and only then does it replace it. Any
/// failure leaves the original exactly as it was.
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
nonisolated enum ClickTimelineEmbedder {
    struct Geometry: Sendable {
        /// The recorded area, global points, origin top-left.
        let regionInCGGlobal: CGRect
        /// The encoded frame size.
        let pixelSize: CGSize
    }

    struct Report: Sendable {
        let clicks: Int
        /// How movie time zero was found: "frame-spacing" or "writer-start".
        let method: String
        let anchorError: Double?
        /// Host-clock seconds of movie time zero.
        let anchorHostTime: Double
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Embeds, or leaves the file alone and says why. Never throws.
    @concurrent
    static func embed(
        in url: URL, events: [ClickRecorder.Event], frameHostTimes: [Double],
        writerStart: Double?, geometry: Geometry, failForTest: Bool = false
    ) async -> Result<Report, Failure> {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let movieTimes = try await videoMovieTimes(of: asset)
            guard let anchor = anchor(
                hostTimes: frameHostTimes, movieTimes: movieTimes, writerStart: writerStart)
            else { throw Failure(message: "no frame times to anchor the clicks to") }

            let marks: [(Double, ClickMark)] = events.compactMap { event in
                let t = event.timestamp - anchor.offset
                guard t >= 0, t < duration.seconds else { return nil }
                return (t, mark(for: event, geometry: geometry))
            }
            guard !marks.isEmpty else {
                return .success(Report(clicks: 0, method: anchor.method, anchorError: anchor.meanError,
                                       anchorHostTime: anchor.offset))
            }

            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(".duoshot-clicks-\(UUID().uuidString.prefix(8))")
                .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            defer { try? FileManager.default.removeItem(at: destination) }
            try await remux(asset, duration: duration, marks: marks, to: destination,
                            fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
            try await confirmSameMedia(asset, as: destination, movieTimes: movieTimes)
            if failForTest { throw Failure(message: "failing on purpose (self-test)") }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: destination)
            return .success(Report(clicks: marks.count, method: anchor.method, anchorError: anchor.meanError,
                                   anchorHostTime: anchor.offset))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
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
    static func videoMovieTimes(of asset: AVURLAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let segments = try await track.load(.segments)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "cannot read the video samples") }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let media = CMSampleBufferGetPresentationTimeStamp(sample)
            for segment in segments where !segment.isEmpty
                && CMTimeRangeContainsTime(segment.timeMapping.source, time: media) {
                times.append((media - segment.timeMapping.source.start
                              + segment.timeMapping.target.start).seconds)
                break
            }
        }
        return times.sorted()
    }

    private static func packetCount(of asset: AVURLAsset, mediaType: AVMediaType) async throws -> Int {
        var count = 0
        for track in try await asset.loadTracks(withMediaType: mediaType) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw Failure(message: "cannot read \(mediaType.rawValue)") }
            while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        }
        return count
    }

    /// The copy must hold the same media at the same times, or it is not used.
    private static func confirmSameMedia(
        _ original: AVURLAsset, as copyURL: URL, movieTimes: [Double]
    ) async throws {
        let copy = AVURLAsset(url: copyURL)
        let (before, after) = (try await original.load(.duration), try await copy.load(.duration))
        // The container's duration may move by less than a frame: measured on a
        // 1.2 s take, the copy ended 0.6 ms earlier (on the audio track's end
        // rather than the last frame's display end). The samples themselves —
        // every byte, every video frame's movie time — are compared exactly
        // below, so this only guards against a copy that is truly shorter.
        guard abs(before.seconds - after.seconds) < 0.02 else {
            throw Failure(message: "the copy's duration differs (\(before.seconds) vs \(after.seconds))")
        }
        let copyTimes = try await videoMovieTimes(of: copy)
        guard copyTimes.count == movieTimes.count,
              zip(copyTimes, movieTimes).allSatisfy({ abs($0 - $1) < 0.000_5 })
        else { throw Failure(message: "the copy's video frames are not at the original's times") }
        for type in [AVMediaType.audio, .video] {
            let (a, b) = (try await packetCount(of: original, mediaType: type),
                          try await packetCount(of: copy, mediaType: type))
            guard a == b else {
                throw Failure(message: "the copy has \(b) \(type.rawValue) samples, the original \(a)")
            }
        }
    }

    // MARK: - The remux

    private struct Lane {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false
    }

    private static func remux(
        _ asset: AVURLAsset, duration: CMTime, marks: [(Double, ClickMark)],
        to destination: URL, fileType: AVFileType
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
            lanes.append(Lane(reader: reader, output: output, input: input))
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
        writer.startSession(atSourceTime: .zero)

        var metadataDone = false
        while !metadataDone || lanes.contains(where: { !$0.finished }) {
            var moved = false
            for index in lanes.indices where !lanes[index].finished {
                while lanes[index].input.isReadyForMoreMediaData {
                    guard let sample = lanes[index].output.copyNextSampleBuffer() else {
                        lanes[index].input.markAsFinished()
                        lanes[index].finished = true
                        break
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
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(message: "could not finish: \(writer.error?.localizedDescription ?? "?")")
        }
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
