import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decides whether a file can be shared, and fixes it when the fix is cheap.
///
/// Exists because "it opens here" and "it opens for the person you sent it to"
/// are different claims, and nothing on the sender's machine will ever tell them
/// apart. A HEIC still and an HEVC recording both open instantly in Preview and
/// QuickTime, and are both unopenable for most of the people a link reaches.
public enum LinkdropGate {
    public struct Plan: Sendable {
        public let fileURL: URL
        public let descriptor: LinkdropDescriptor
        /// `fileURL` was produced by this gate and must be deleted after the
        /// upload -- `LinkdropUploader` does that. An original is never
        /// temporary; a re-encode always is.
        public let isTemporary: Bool
    }

    public enum Outcome: Sendable {
        case ok(Plan)
        case refused(String)
    }

    /// What a browser will display inline. Everything else is either converted
    /// or refused.
    ///
    /// SVG is absent on purpose and must stay absent: it is a document format
    /// that can carry script, so serving one inline from a share domain is
    /// stored XSS against every other link ever shared from it. The server side
    /// enforces this too -- neither end is allowed to be the only check.
    private static let webImages: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let convertibleImages: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]
    private static let containers: Set<String> = ["mp4", "m4v", "mov"]

    // MARK: - Stills

    public static func plan(
        image url: URL, pointSize: CGSize? = nil, ephemeral: Bool = false
    ) -> Outcome {
        let ext = url.pathExtension.lowercased()

        if webImages.contains(ext) {
            return .ok(Plan(
                fileURL: url,
                descriptor: descriptor(for: url, ext: ext, pointSize: pointSize,
                                       ephemeral: ephemeral),
                isTemporary: false))
        }

        // Worth rescuing rather than refusing: a format preference away, better
        // on disk, and a few hundred milliseconds to re-encode one still. The
        // file the user keeps is untouched -- only the copy that leaves changes.
        if convertibleImages.contains(ext) {
            guard let converted = Reencoder.toPNG(url) else {
                return .refused("Could not convert this \(ext.uppercased()) image for upload.")
            }
            return .ok(Plan(
                fileURL: converted,
                descriptor: descriptor(for: converted, ext: "png", pointSize: pointSize,
                                       ephemeral: ephemeral),
                isTemporary: true))
        }

        return .refused("\(ext.isEmpty ? "Files with no extension" : ext.uppercased())"
                        + " cannot be shared as images.")
    }

    // MARK: - Video

    public static func plan(
        video url: URL, pointSize: CGSize? = nil, duration: Double? = nil,
        ephemeral: Bool = false
    ) async -> Outcome {
        let ext = url.pathExtension.lowercased()
        guard containers.contains(ext) else {
            return .refused("\(ext.uppercased()) is not a container browsers can play.")
        }

        let codecs = await codecs(of: url)

        // Transcoding is minutes of work and needs its own UI and its own
        // progress. Refusing with a sentence naming the cause is the honest
        // version of "not yet"; uploading it anyway is the dishonest one.
        if let video = codecs.video, video != .h264 {
            return .refused("This video is \(video.label), which most browsers cannot play. "
                            + "Re-record or export it as H.264.")
        }
        // A silent video is a normal thing to share. A video whose audio only
        // Apple platforms can decode is not -- and it is invisible to whoever
        // made it, because it plays perfectly here.
        if let audio = codecs.audio, audio != .aac {
            return .refused("This video's audio is \(audio.label), so it would be silent "
                            + "for most people who open the link.")
        }

        var descriptor = descriptor(for: url, ext: ext, pointSize: pointSize, ephemeral: ephemeral)
        descriptor.kind = .video
        descriptor.duration = duration

        // A recorder that streams to disk has to append its index, so the file
        // it leaves behind makes a player fetch the tail before it can show a
        // frame. Rewriting the container puts the index in front. It is not a
        // transcode and it does not touch the file the user keeps -- same rule
        // as the HEIC conversion above: only the copy that leaves changes.
        if MP4Layout.isFastStart(url) == false,
           let rewritten = await MP4Layout.makeFastStartCopy(of: url) {
            return .ok(Plan(fileURL: rewritten, descriptor: descriptor, isTemporary: true))
        }

        return .ok(Plan(fileURL: url, descriptor: descriptor, isTemporary: false))
    }

    // MARK: - Codecs

    public enum Codec: Equatable, Sendable {
        case h264
        case hevc
        case aac
        case other(String)

        public var label: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .aac: "AAC"
            case .other(let tag): tag
            }
        }
    }

    public struct Codecs: Sendable {
        public var video: Codec?
        public var audio: Codec?
    }

    /// What is actually inside the container.
    ///
    /// The reason this is public: a recorder's *settings* saying H.264 and the
    /// file *being* H.264 are different facts, and only this one can be checked.
    public static func codecs(of url: URL) async -> Codecs {
        let asset = AVURLAsset(url: url)
        return Codecs(
            video: await subType(of: asset, .video).map(classify),
            audio: await subType(of: asset, .audio).map(classify))
    }

    private static func subType(
        of asset: AVURLAsset, _ mediaType: AVMediaType
    ) async -> FourCharCode? {
        guard let track = try? await asset.loadTracks(withMediaType: mediaType).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let first = descriptions.first
        else { return nil }
        return CMFormatDescriptionGetMediaSubType(first)
    }

    private static func classify(_ subType: FourCharCode) -> Codec {
        switch subType {
        case kCMVideoCodecType_H264: .h264
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: .hevc
        case kAudioFormatMPEG4AAC: .aac
        default: .other(fourCharString(subType))
        }
    }

    public static func fourCharString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    // MARK: -

    private static func descriptor(
        for url: URL, ext: String, pointSize: CGSize?, ephemeral: Bool
    ) -> LinkdropDescriptor {
        LinkdropDescriptor(
            ext: ext, name: url.lastPathComponent, kind: .image,
            width: pointSize.map { Int($0.width.rounded()) },
            height: pointSize.map { Int($0.height.rounded()) },
            ephemeral: ephemeral)
    }
}

/// Re-encodes a still into PNG.
///
/// Small enough to own rather than depend on. The one thing it must not lose is
/// the DPI tag: that is what stands between a 2x capture and being displayed at
/// double size, and the point of this file is that the copy which leaves the
/// machine is not degraded.
enum Reencoder {
    static func toPNG(_ url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let dpi = self.dpi(of: source) ?? 72
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkdrop-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("png")

        guard let sink = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(sink, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(sink) else {
            LinkdropLog.gate.error("PNG re-encode failed for \(url.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination
    }

    private static func dpi(of source: CGImageSource) -> CGFloat? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let value = properties[kCGImagePropertyDPIWidth] as? CGFloat, value > 0
        else { return nil }
        return value
    }
}
