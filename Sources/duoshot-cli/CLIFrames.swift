import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import DuoShotCLIWire
import ImageIO

/// `DuoShot cli frames`: stills out of a video file, for an agent that has to
/// look at what a recording shows.
///
/// Runs in the client. A file needs no Screen Recording grant and no running
/// app, so it is not behind "Allow command-line capture" either.
///
/// `nonisolated` with one `@concurrent` entry point, like `GIFExport`: every
/// frame is decoded and most are re-encoded, and the images never leave this
/// type — what comes back is a `Report`, which is file paths and numbers.
package enum CLIFrames {
    package enum Selection: Sendable {
        case at([Double])
        case every(Double)
        case scene(threshold: Double)
    }

    package struct Job: Sendable {
        var video: URL
        var directory: URL
        var selection: Selection
        /// Video pixels, origin top-left.
        var crop: CLIRect?
        var tile: (columns: Int, rows: Int)?
    }

    // The output's shape lives beside the wire format, where the app's
    // self-test can decode it without linking any of this.
    package typealias Report = CLIFramesReport
    package typealias Frame = CLIFramesReport.Frame
    package typealias Sheet = CLIFramesReport.Sheet
    package typealias Change = CLIFramesReport.Change

    package struct Failure: LocalizedError {
        let message: String
        package var errorDescription: String? { message }
    }

    /// The default `--scene` threshold, 0–255: how far the grey level of any
    /// one cell of a `thumbnailSide`² grid has to move away from the last
    /// settled frame.
    ///
    /// One cell, not the mean of all of them. The mean is what the first
    /// version used, and on a real recording the only content change — a few
    /// lines of text in a 1080p frame — scored 6.0 against a default of 8:
    /// a small change is a small fraction of the frame, whatever it means. And
    /// against the last *settled* frame rather than the one before: a toast
    /// fading out over a second moves each frame by less than any threshold,
    /// and only adds up to something against where it started.
    ///
    /// 60, the maintainer's call after acceptance: on a real screen recording
    /// a block of text arriving scored 105, a small counter ticking in a corner
    /// 20–26 and a scroll 24–69 frame on frame — 24 reported the counter as
    /// news.
    package static let defaultSceneThreshold = 60.0

    /// A sheet's longest edge. Claude scales down any image past 2576 px, and a
    /// request carrying more than 20 images refuses any image past 2000 px
    /// (platform.claude.com/docs/en/build-with-claude/vision) — so a sheet made
    /// for an agent to read stays inside the smaller of the two.
    package static let maximumSheetEdge = 2000.0

    private static let thumbnailSide = 64
    private static let labelHeight = 24

    @concurrent
    package static func run(_ job: Job) async throws -> Report {
        let asset = AVURLAsset(url: job.video)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw Failure(message: "cannot read \(job.video.path): \(error.localizedDescription)")
        }
        guard let track = tracks.first, duration.seconds > 0 else {
            throw Failure(message: "\(job.video.path) has no video track")
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let bounds = CGRect(x: 0, y: 0, width: shown.width.rounded(), height: shown.height.rounded())

        var crop: CGRect?
        if let requested = job.crop?.cgRect.integral {
            guard bounds.contains(requested) else {
                throw Failure(message: """
                    crop \(Int(requested.minX)),\(Int(requested.minY)),\
                    \(Int(requested.width)),\(Int(requested.height)) is outside the \
                    \(Int(bounds.width))x\(Int(bounds.height)) video
                    """)
            }
            crop = requested
        }

        var report = Report(video: job.video.path, duration: duration.seconds)
        let times: [Double]
        var sceneStills: [Still]?
        switch job.selection {
        case .at(let requested):
            if let late = requested.first(where: { $0 < 0 || $0 > duration.seconds }) {
                throw Failure(message: String(
                    format: "%.3f s is outside the video (0–%.3f s)", late, duration.seconds))
            }
            times = requested
        case .every(let step):
            times = Array(stride(from: 0, to: duration.seconds, by: step))
        case .scene(let threshold):
            // The reader hands frames over as stored; the crop is in the
            // orientation the video is *shown* in. Rather than guess at the
            // mapping for a rotated video, say so.
            guard transform.isIdentity else {
                throw Failure(message: "--scene does not handle rotated video")
            }
            let (changes, kept) = try scan(asset: asset, track: track, crop: crop,
                                           threshold: threshold)
            report.changes = changes
            report.threshold = threshold
            sceneStills = kept
            times = []
        }

        try FileManager.default.createDirectory(
            at: job.directory, withIntermediateDirectories: true)
        let stills: [Still]
        if let sceneStills {
            stills = sceneStills
        } else if transform.isIdentity {
            stills = try frames(of: asset, track: track, at: times, crop: crop,
                                duration: duration.seconds)
        } else {
            stills = try await framesOneByOne(of: asset, at: times, crop: crop)
        }

        report.frames = try stills.enumerated().map { index, still in
            let url = job.directory.appendingPathComponent(
                String(format: "frame-%04d-%.3fs.png", index + 1, still.time))
            try writePNG(still.image, to: url)
            return Frame(path: url.path, time: still.time)
        }
        if let tile = job.tile {
            report.sheets = try writeSheets(stills, tile: tile, into: job.directory)
        }
        return report
    }

    // MARK: - Stills

    private struct Still {
        let image: CGImage
        let time: Double
    }

    /// The frame on screen at each time — the last one whose presentation
    /// time is at or before it — from one pass of an `AVAssetReader`.
    ///
    /// Not `AVAssetImageGenerator`, which is what this used to be: with zero
    /// tolerance, one batch asking for two *adjacent* frames failed the second
    /// with "Cannot Decode" (each alone worked). Reproduced on two real
    /// recordings and on the self-test's own fixture (1.0 and 1.0333 s). `--scene`
    /// produces adjacent times all the time. A reader decodes forward once and
    /// has nothing to seek.
    private static func frames(
        of asset: AVURLAsset, track: AVAssetTrack, at times: [Double], crop: CGRect?,
        duration: Double
    ) throws -> [Still] {
        let (reader, output) = try openReader(asset: asset, track: track)
        // A hair of slack for times printed to fewer digits than the timescale.
        let slack = 0.0001
        let wanted = times.enumerated().sorted { $0.element < $1.element }
        var found = [Still?](repeating: nil, count: times.count)
        var next = 0
        var previous: (buffer: CVPixelBuffer, time: Double)?
        while next < wanted.count, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            while next < wanted.count, wanted[next].element + slack < time {
                guard let previous else {
                    throw Failure(message: String(
                        format: "no frame at %.3f s: the first frame is at %.3f s",
                        wanted[next].element, time))
                }
                found[wanted[next].offset] = try still(previous.buffer, at: previous.time, crop: crop)
                next += 1
            }
            previous = (buffer, time)
        }
        // At or after the last frame, and inside the video: still that frame.
        while next < wanted.count, let previous, wanted[next].element <= duration + slack {
            found[wanted[next].offset] = try still(previous.buffer, at: previous.time, crop: crop)
            next += 1
        }
        reader.cancelReading()
        return try found.enumerated().map { index, still in
            guard let still else {
                throw Failure(message: String(format: "no frame at %.3f s", times[index]))
            }
            return still
        }
    }

    /// For a rotated video, where the reader's stored orientation is not the
    /// one the crop is written in: one generator per time, which is the case
    /// that always worked.
    private static func framesOneByOne(
        of asset: AVURLAsset, at times: [Double], crop: CGRect?
    ) async throws -> [Still] {
        var stills: [Still] = []
        for time in times {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let requested = CMTime(seconds: time, preferredTimescale: 600)
            let image: CGImage
            let actual: CMTime
            do {
                (image, actual) = try await generator.image(at: requested)
            } catch {
                throw Failure(message: String(
                    format: "no frame at %.3f s: %@", time, error.localizedDescription))
            }
            var kept = image
            if let crop {
                guard let cut = image.cropping(to: crop) else {
                    throw Failure(message: String(format: "cannot crop the frame at %.3f s", time))
                }
                kept = cut
            }
            stills.append(Still(image: kept, time: actual.seconds))
        }
        return stills
    }

    private static func openReader(
        asset: AVURLAsset, track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure(message: "cannot read frames: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(message: "cannot read frames: \(reader.error?.localizedDescription ?? "?")")
        }
        return (reader, output)
    }

    /// A decoded frame as an image of its own (the buffer goes back to the
    /// decoder's pool), in the colour space the video declares, cropped.
    private static func still(_ buffer: CVPixelBuffer, at time: Double, crop: CGRect?) throws -> Still {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate)
        let declared = attachments.flatMap {
            CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue()
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = declared ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base, width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let image = context.makeImage()
        else { throw Failure(message: String(format: "cannot read the frame at %.3f s", time)) }
        guard let crop else { return Still(image: image, time: time) }
        guard let cut = image.cropping(to: crop) else {
            throw Failure(message: String(format: "cannot crop the frame at %.3f s", time))
        }
        return Still(image: cut, time: time)
    }

    // MARK: - Scene changes

    /// Reads every frame in order and scores each against the last settled
    /// one, keeping a still of the first frame — the state the changes are
    /// changes *from* — and of each change, from the same decode.
    private static func scan(
        asset: AVURLAsset, track: AVAssetTrack, crop: CGRect?, threshold: Double
    ) throws -> (changes: [Change], stills: [Still]) {
        let (reader, output) = try openReader(asset: asset, track: track)

        // `reference` is the last frame the picture settled on. A change is
        // reported the first time any cell has moved past the threshold away
        // from it — the frame an abrupt change lands on, or the frame a slow
        // one has added up by. It is then followed until two consecutive frames
        // agree (`settled`), and that frame becomes the new reference. While it
        // moves, only a jump of twice the threshold from one frame to the next
        // is a change of its own: every frame of a scroll is not news.
        //
        // `settled` is 3 grey levels, under the ~4 a frame a one-second fade
        // moves by, so a fade is followed to its end rather than settling half
        // way and being reported twice.
        let settled = 3.0
        var stills: [Still] = []
        var reference: [Double]?
        var previous: [Double]?
        var moving = false
        var stillFrames = 0
        var changes: [Change] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let thumbnail = thumbnail(buffer, crop: crop) else {
                throw Failure(message: "crop is outside the stored frame")
            }
            if let reference, let previous {
                let fromReference = largestDifference(reference, thumbnail)
                let fromPrevious = largestDifference(previous, thumbnail)
                if !moving, fromReference > threshold {
                    changes.append(Change(time: time, score: (fromReference * 100).rounded() / 100))
                    stills.append(try still(buffer, at: time, crop: crop))
                    moving = true
                    stillFrames = 0
                } else if moving, fromPrevious > 2 * threshold {
                    changes.append(Change(time: time, score: (fromPrevious * 100).rounded() / 100))
                    stills.append(try still(buffer, at: time, crop: crop))
                    stillFrames = 0
                } else if moving {
                    stillFrames = fromPrevious < settled ? stillFrames + 1 : 0
                    if stillFrames >= 2 {
                        moving = false
                    }
                }
            }
            if stills.isEmpty { stills.append(try still(buffer, at: time, crop: crop)) }
            if reference == nil || (!moving && stillFrames >= 2) {
                reference = thumbnail
                stillFrames = 0
            }
            previous = thumbnail
        }
        guard reader.status == .completed, !stills.isEmpty else {
            throw Failure(message: "reading frames failed: \(reader.error?.localizedDescription ?? "no frames")")
        }
        return (changes, stills)
    }

    private static func largestDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// The region as a `thumbnailSide`² grid of mean luma, 0–255, each cell
    /// averaged over a 4×4 lattice of its pixels.
    private static func thumbnail(_ buffer: CVPixelBuffer, crop: CGRect?) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let region = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
        guard CGRect(x: 0, y: 0, width: width, height: height).contains(region) else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let side = thumbnailSide
        var grid = [Double](repeating: 0, count: side * side)
        let cellWidth = region.width / Double(side)
        let cellHeight = region.height / Double(side)
        for row in 0..<side {
            for column in 0..<side {
                var sum = 0.0
                for sy in 0..<4 {
                    // Rows run downwards in the buffer, as they do in the crop.
                    let y = min(height - 1, Int(region.minY + (Double(row) + (Double(sy) + 0.5) / 4) * cellHeight))
                    for sx in 0..<4 {
                        let x = min(width - 1, Int(region.minX + (Double(column) + (Double(sx) + 0.5) / 4) * cellWidth))
                        let p = pixels + y * stride + x * 4  // BGRA
                        sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                    }
                }
                grid[row * side + column] = sum / 16
            }
        }
        return grid
    }

    // MARK: - Contact sheets

    private static func writeSheets(
        _ stills: [Still], tile: (columns: Int, rows: Int), into directory: URL
    ) throws -> [Sheet] {
        guard let first = stills.first else { return [] }
        let columns = tile.columns, rows = tile.rows
        let frameWidth = Double(first.image.width), frameHeight = Double(first.image.height)
        let label = Double(labelHeight)
        // Down to fit the longest edge, never up.
        let scale = min(
            1,
            maximumSheetEdge / (Double(columns) * frameWidth),
            (maximumSheetEdge / Double(rows) - label) / frameHeight)
        guard scale > 0 else { throw Failure(message: "--tile \(columns)x\(rows) cannot fit in \(Int(maximumSheetEdge)) px") }
        let cellWidth = max(1, Int(frameWidth * scale))
        let cellHeight = max(1, Int(frameHeight * scale))
        let pitch = cellHeight + labelHeight

        var sheets: [Sheet] = []
        let perSheet = columns * rows
        for start in stride(from: 0, to: stills.count, by: perSheet) {
            let cells = Array(stills[start..<min(start + perSheet, stills.count)])
            let width = columns * cellWidth, height = rows * pitch
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure(message: "cannot make a \(width)x\(height) sheet") }
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high

            for (index, cell) in cells.enumerated() {
                // Left to right, then top to bottom. The context is bottom-left.
                let x = (index % columns) * cellWidth
                let bottom = height - (index / columns + 1) * pitch
                context.draw(cell.image, in: CGRect(
                    x: x, y: bottom + labelHeight, width: cellWidth, height: cellHeight))
                drawLabel(String(format: "t=%.3fs", cell.time), in: context,
                          at: CGPoint(x: x + 6, y: bottom + 7))
            }
            guard let image = context.makeImage() else {
                throw Failure(message: "cannot render a sheet")
            }
            let url = directory.appendingPathComponent(
                String(format: "sheet-%02d.png", sheets.count + 1))
            try writePNG(image, to: url)
            sheets.append(Sheet(
                path: url.path, times: cells.map(\.time),
                cellScale: (Double(cellWidth) / frameWidth * 1000).rounded() / 1000))
        }
        return sheets
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, "public.png" as CFString, 1, nil)
        else { throw Failure(message: "cannot write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "cannot write \(url.path)")
        }
    }

    private static func drawLabel(_ text: String, in context: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
