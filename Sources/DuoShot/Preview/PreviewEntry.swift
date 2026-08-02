import AVFoundation
import AppKit

/// What one card in the preview stack shows, independent of whether it came
/// from a screenshot or a recording.
///
/// The stack used to take `OutputPipeline.Output` directly, which is a
/// screenshot by construction: it carries a `CaptureResult` the card draws and a
/// drag source that hands over PNG bytes. A recording has neither — it is a file
/// that was never in memory — so the card needs a description both can satisfy.
struct PreviewEntry {
    enum Kind {
        /// A still. Carries only its *point* size, not the capture: the file on
        /// disk is the copy of record, and holding the CGImage as well meant up
        /// to `PreviewStackController.maxRetained` full-resolution bitmaps — ~59 MB
        /// each at 5K — alive for the length of a card's timeout, for one button.
        case image(pointSize: CGSize)
        case video(RecordingResult)
    }

    let kind: Kind
    /// What the card draws: a downsampled still, or a recording's poster frame.
    let thumbnail: NSImage
    /// Where the file lives now. The card's reveal, open, copy and drag all use
    /// this, so it must be the post-move URL, never the staged one.
    let url: URL
    let sourceDisplayID: CGDirectDisplayID
    /// A recording whose take ended badly. The card says so, because the file
    /// looks ordinary and the user would otherwise discover the truncation only
    /// on playback.
    var isIncomplete = false
    /// The save into the user's save folder threw. The card says so, because
    /// everything else about the capture looks like it worked and the file is
    /// sitting in staging waiting to be pruned.
    var saveFailed = false

    var isVideo: Bool {
        if case .video = kind { true } else { false }
    }

    /// The duration pill on a video card. nil for stills, which need no label —
    /// the thumbnail already says what they are.
    var badge: String? {
        if case .video(let result) = kind { result.durationDescription } else { nil }
    }

    /// Kept here rather than at the call site so the stack never has to know
    /// which of the two `Clipboard.write` overloads a card needs.
    func copyToClipboard() {
        switch kind {
        case .image(let pointSize): Clipboard.write(fileAt: url, pointSize: pointSize)
        case .video(let result): Clipboard.write(result)
        }
    }
}

extension PreviewEntry {
    init(_ output: OutputPipeline.Output) async {
        self.init(
            kind: .image(pointSize: output.result.pointSize),
            thumbnail: await PreviewThumbnail.of(output.result),
            url: output.url,
            sourceDisplayID: output.result.sourceDisplayID,
            saveFailed: output.saveFailed)
    }

    /// `poster` is passed in rather than derived here because extracting it
    /// decodes a frame off disk — see `VideoPoster.frame(for:)`, which is async
    /// for that reason.
    init(_ output: OutputPipeline.RecordingOutput, poster: NSImage) {
        self.init(
            kind: .video(output.result),
            thumbnail: poster,
            url: output.url,
            sourceDisplayID: output.result.sourceDisplayID,
            isIncomplete: output.isIncomplete,
            saveFailed: output.saveFailed)
    }
}

/// The still a screenshot card shows.
enum PreviewThumbnail {
    /// Twice the card and no larger, for the reason `VideoPoster.maximumSize`
    /// gives: this image is only ever drawn into a 208×132 tile.
    ///
    /// A capture's own `nsImage` wraps the full-resolution CGImage, so handing it
    /// to the card meant every redraw of the tile resampled a 5K bitmap, and the
    /// stack kept up to `PreviewStackController.maxRetained` of them.
    static let maximumSize = CGSize(
        width: PreviewCardView.cardSize.width * 2,
        height: PreviewCardView.cardSize.height * 2)

    /// Returns the capture scaled to fit `maximumSize`, falling back to its own
    /// `nsImage` when it is already smaller or the scale-down fails: an
    /// oversized thumbnail is a far better outcome than a blank card.
    ///
    /// The cap is read here, on the main actor where it lives, and handed to
    /// the off-main half as a plain value.
    static func of(_ result: CaptureResult) async -> NSImage {
        await downsample(result, cap: maximumSize)
    }

    /// `@concurrent` for the same reason `StagingStore.encode` is: the
    /// scale-down decodes the full capture once, which is tens of milliseconds
    /// at 5K, and under NonisolatedNonsendingByDefault a plain nonisolated
    /// async function would run it on the caller's executor — main. The card
    /// already arrives after the encode, so this adds no visible latency.
    @concurrent
    private static func downsample(_ result: CaptureResult, cap: CGSize) async -> sending NSImage {
        scaled(result.image, cap: cap) ?? result.nsImage
    }

    /// The same scale-down for an image that is not a fresh capture: a still that
    /// has just been redacted in place, whose card must stop showing the pixels
    /// the file no longer contains.
    ///
    /// Synchronous and `nonisolated` because its one caller is already off the
    /// main actor — `ImageEditor.commit` does the rewrite and the thumbnail
    /// in a single hop rather than sending a 5K bitmap back and forth.
    nonisolated static func image(_ source: CGImage, cap: CGSize) -> NSImage {
        scaled(source, cap: cap)
            ?? NSImage(
                cgImage: source,
                size: CGSize(width: source.width, height: source.height))
    }

    /// nil when there is nothing to do or the context cannot be made, so each
    /// caller can fall back to the image it already has: an oversized thumbnail
    /// is a far better outcome than a blank card.
    private nonisolated static func scaled(_ source: CGImage, cap: CGSize) -> NSImage? {
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        guard width > 0, height > 0 else { return nil }
        let ratio = min(cap.width / width, cap.height / height)
        guard ratio < 1 else { return nil }

        let size = CGSize(
            width: max(1, (width * ratio).rounded()),
            height: max(1, (height * ratio).rounded()))
        // Fixed sRGB + premultipliedLast rather than the source's layout, for the
        // reason `ImagePadding.pad` gives: a capture can arrive in display P3 or
        // without an alpha channel, and one known-good destination keeps this
        // predictable.
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

/// The still a video card shows.
enum VideoPoster {
    /// Twice the card so the tile stays sharp on Retina, and no larger: this
    /// image is only ever drawn at card size.
    private static let maximumSize = CGSize(
        width: PreviewCardView.cardSize.width * 2,
        height: PreviewCardView.cardSize.height * 2)

    /// The first frame, or nil if the file cannot be read.
    ///
    /// Asked for with a generous tolerance on purpose. An exact seek makes
    /// AVFoundation decode forward from the preceding keyframe, and a screen
    /// recording's keyframes are far apart — the frame at t=0 is a keyframe
    /// anyway, so precision buys nothing and costs a decode.
    static func frame(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let (image, _) = try? await generator.image(at: .zero) else {
            Log.record.error("no poster frame for \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Shown when the poster frame cannot be produced — a take that stopped
    /// before its first frame reached disk, say. A card with a film glyph is a
    /// far better outcome than no card at all: the file exists either way, and
    /// the card is the only route to it that does not involve Finder.
    static func placeholder() -> NSImage {
        let size = PreviewCardView.cardSize
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        if let glyph = NSImage(systemSymbolName: "film", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: 28, weight: .regular)) {
            let box = NSRect(
                x: (size.width - glyph.size.width) / 2,
                y: (size.height - glyph.size.height) / 2,
                width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.55)
        }
        image.unlockFocus()
        return image
    }
}
