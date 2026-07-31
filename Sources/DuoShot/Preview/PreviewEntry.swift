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
        case image(CaptureResult)
        case video(RecordingResult)
    }

    let kind: Kind
    /// What the card draws: the capture itself, or a recording's poster frame.
    let thumbnail: NSImage
    /// Where the file lives now. The card's reveal, open and drag all use this,
    /// so it must be the post-move URL, never the staged one.
    let url: URL
    let sourceDisplayID: CGDirectDisplayID
    /// A recording whose take ended badly. The card says so, because the file
    /// looks ordinary and the user would otherwise discover the truncation only
    /// on playback.
    var isIncomplete = false

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
        case .image(let result): Clipboard.write(result, fileURL: url)
        case .video(let result): Clipboard.write(result)
        }
    }
}

extension PreviewEntry {
    init(_ output: OutputPipeline.Output) {
        self.init(
            kind: .image(output.result),
            thumbnail: output.result.nsImage,
            url: output.url,
            sourceDisplayID: output.result.sourceDisplayID)
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
            isIncomplete: output.isIncomplete)
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
