import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turning a take into an animated GIF.
///
/// Exists because of where these recordings go. A bug report, a pull request, a
/// chat with somebody who is not going to click a link — and half of those
/// places will not take an MP4 at all, or will take it and show a black
/// rectangle with a play button nobody presses. A GIF plays itself, inline,
/// everywhere, which for a five-second demonstration of a broken button is the
/// entire difference between the recording being watched and not.
///
/// The trade is honest and one-directional: this is a transcode, unlike
/// `VideoTrim`, and the file it writes is bigger, coarser and capped at 256
/// colours. It is written *beside* the recording rather than over it for
/// exactly that reason — the MP4 remains the real artefact, and this is a copy
/// made for somewhere that cannot show one.
///
/// `@concurrent` for the reason `VideoTrim`'s comment gives: this decodes every
/// frame it keeps and re-encodes all of them, and none of that belongs on the
/// main thread.
nonisolated enum GIFExport {
    enum Failure: LocalizedError {
        case unreadable(String)
        case noFrames(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) could not be read."
            case .noFrames(let name): "No frames could be taken from \(name)."
            case .unwritable(let name): "The GIF of \(name) could not be written."
            }
        }
    }

    struct Outcome: Sendable, Equatable {
        var url: URL
        var frames: Int
        var pixelSize: CGSize
        var seconds: TimeInterval
    }

    /// Ten, and the delay below is a tenth of a second, which is not a
    /// coincidence.
    ///
    /// The GIF format stores delays in hundredths, and essentially every browser
    /// silently clamps anything under 0.05 s up to 0.1 s -- a legacy of pages
    /// that shipped "as fast as possible" spinners. Choosing 12 fps would write
    /// 0.083 and get 0.1 anyway, so the file would claim one duration and play
    /// at another, and a five-second clip would run for six. Ten frames a second
    /// is the fastest rate this format actually keeps.
    static let frameRate: Double = 10
    static let frameDelay: Double = 1 / frameRate

    /// Longest edge in pixels. A full-screen Retina take is 5120 across; at 256
    /// colours and no interframe compression worth the name, a GIF of that is
    /// tens of megabytes and no chat window will show it at full size anyway.
    static let maximumEdge: CGFloat = 720

    /// Past this the format stops being the right answer -- a minute at ten
    /// frames a second is 600 full frames -- and the honest response is to say
    /// so rather than to spend two minutes producing something unusable.
    static let maximumSeconds: TimeInterval = 30

    /// Where the GIF for a recording goes: beside it, same stem.
    static func url(besides source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("gif")
    }

    /// - Parameter range: the part worth keeping, or nil for the whole take.
    @concurrent
    static func write(
        _ source: URL, to destination: URL, range: CMTimeRange? = nil
    ) async throws -> Outcome {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            throw Failure.unreadable(name)
        }

        let wanted = range ?? CMTimeRange(start: .zero, duration: duration)
        let start = max(0, wanted.start.seconds)
        let span = min(
            max(wanted.duration.seconds, 1 / frameRate),
            min(duration.seconds - start, maximumSeconds))
        guard span > 0 else { throw Failure.noFrames(name) }

        let count = max(1, Int((span * frameRate).rounded()))
        let times = (0..<count).map {
            CMTime(seconds: start + Double($0) / frameRate, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Fits *within* the box and keeps the aspect ratio, so this is a ceiling
        // on the longest edge rather than a size.
        generator.maximumSize = CGSize(width: maximumEdge, height: maximumEdge)
        // Half a frame either way. Demanding an exact time makes the generator
        // decode forward from the preceding sync frame for every single
        // request, which on a screen recording's multi-second keyframe spacing
        // is most of the clip decoded once per frame kept.
        let tolerance = CMTime(seconds: 1 / (frameRate * 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for await result in generator.images(for: times) {
            // A frame that cannot be produced is skipped rather than fatal: the
            // last requested time can land a hair past the final sample, and
            // failing the whole export over the tail of the clip would be a
            // strange thing to do to somebody who just wants a GIF.
            if case .success(requestedTime: _, image: let image, actualTime: _) = result {
                frames.append(image)
            }
        }
        guard let first = frames.first else { throw Failure.noFrames(name) }

        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw Failure.unwritable(name) }
        // Loop count 0 is "forever". Absent, most viewers play once and leave a
        // still frame, which for a demonstration of a bug is the whole point
        // missed.
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                // Both, deliberately. The clamped one is what old viewers read
                // and the unclamped one is the truth; writing only the second
                // leaves the first defaulting somewhere slower.
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ],
        ] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(writer, frame, frameProperties) }
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unwritable(name)
        }

        return Outcome(
            url: destination, frames: frames.count,
            pixelSize: CGSize(width: first.width, height: first.height),
            seconds: Double(frames.count) * frameDelay)
    }
}
