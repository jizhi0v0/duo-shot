import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Our own encoder, kept as a first-class path rather than a fallback.
///
/// `SCScreenshotConfiguration.fileURL` lets SCK write the file itself, which is
/// cheaper — but two things make a local encoder necessary anyway:
///
/// 1. **DPI stamping.** A 2× capture produces a CGImage with twice the point
///    dimensions. Without `kCGImagePropertyDPI*` the file opens at double its
///    logical size in every viewer.
/// 2. **JPEG quality control**, which the SCK writer does not expose.
///
/// All functions are `nonisolated` and synchronous: no isolation boundary, so
/// non-Sendable `CGImage` is a non-issue. Encoding moves off-main (`@concurrent`)
/// only once it is on a latency-sensitive path.
enum ImageEncoder {
    nonisolated static func write(
        _ image: CGImage,
        to url: URL,
        as contentType: UTType = .png,
        scale: CGFloat = 1,
        quality: Double = 0.9
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, contentType.identifier as CFString, 1, nil
        ) else {
            throw CaptureError.encodingFailed("could not create destination for \(contentType.identifier)")
        }

        // 72 dpi is the reference for 1 point == 1 pixel, so a 2× image is 144 dpi.
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * Double(scale),
            kCGImagePropertyDPIHeight: 72.0 * Double(scale),
        ]
        if contentType == .jpeg || contentType == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodingFailed("finalize failed for \(url.path)")
        }
    }
}
