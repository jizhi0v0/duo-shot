import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Destroying part of a capture before it can leave the machine.
///
/// The premise of the whole share story is the one `TextRecognition` states: a
/// screenshot is whatever happened to be on screen — a password manager, a
/// medical record, somebody else's message — and the moment it becomes a link it
/// is out of the author's hands. This is the tool for the case where all of it
/// is worth sending except one rectangle.
///
/// Two rules make the difference between a redaction and a decoration:
///
/// 1. **The pixels are averaged away, not covered up.** Nothing here composites
///    a black bar or a blur over the original: a bar in a PNG is still an image
///    with the original bytes underneath it in every format that has layers, and
///    a Gaussian blur is a convolution — reversible, and demonstrably so on the
///    kind of high-contrast text a screenshot is full of. Block averaging throws
///    the information out. There is nothing left to recover because there is
///    nothing left.
/// 2. **The block is coarse and scales with the image**, so a redaction applied
///    to a 5K capture is as unreadable as one applied to a 640-point window
///    rather than a fine mosaic that a human eye can still resolve into letters.
///
/// All of it is `nonisolated` and the file half is `@concurrent`, for the reason
/// `ImageEncoder` gives: a 5K bitmap is tens of megabytes to average and
/// re-encode, and none of that belongs on the main thread.
nonisolated enum Redaction {
    /// One over this many of the image's short side is a block. Chosen against
    /// the thing being hidden rather than against taste: body text in a 2×
    /// capture is around 28 px tall, so a block has to be comfortably taller
    /// than a glyph for the glyph to stop existing — at 1440 px this gives 36.
    private static let shortSideDivisor = 40.0
    /// The floor for a small image, where the divisor alone would produce blocks
    /// a few pixels across and a legible mosaic.
    private static let minimumBlock = 12

    /// Regions are in **image pixel coordinates with the origin at the bottom
    /// left** — CoreGraphics' own user space, and what an unflipped `NSView`
    /// hands its caller, so the viewer's drag needs a scale and nothing else. A
    /// rect in view coordinates would be wrong the moment the window was zoomed.
    ///
    /// Blocks are aligned to each region's own origin rather than to a grid over
    /// the whole image, so a region's edge is exactly where the user put it and
    /// the block that straddles it is averaged from the part inside.
    ///
    /// Returns nil rather than the original when there is nothing to do: every
    /// caller here is about to overwrite a file, and "no regions" must not be
    /// spelled the same way as "redacted".
    static func pixelate(_ image: CGImage, regions: [CGRect]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, !regions.isEmpty else { return nil }

        // Fixed sRGB + premultipliedLast rather than the source's layout, for the
        // reason `ImagePadding.pad` gives: a capture can arrive in display P3 or
        // without an alpha channel, and averaging bytes is only meaningful once
        // it is known what the bytes mean.
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }

        let rowBytes = context.bytesPerRow
        let pixels = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        let block = blockSize(width: width, height: height)

        for region in regions {
            // The bitmap's row 0 is the top one, so a bottom-left rect has to be
            // turned upside down before it can be indexed.
            let clamped = region.integral.intersection(
                CGRect(x: 0, y: 0, width: width, height: height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { continue }
            let left = Int(clamped.minX)
            let right = Int(clamped.maxX)
            let top = height - Int(clamped.maxY)
            let bottom = height - Int(clamped.minY)

            for blockTop in stride(from: top, to: bottom, by: block) {
                let blockBottom = min(blockTop + block, bottom)
                for blockLeft in stride(from: left, to: right, by: block) {
                    let blockRight = min(blockLeft + block, right)
                    fill(pixels, rowBytes: rowBytes,
                         left: blockLeft, right: blockRight,
                         top: blockTop, bottom: blockBottom)
                }
            }
        }

        return context.makeImage()
    }

    /// Scales rectangles drawn over a picture at its point size into the
    /// bitmap's own pixels.
    ///
    /// Lives here rather than in the view that does the dragging because it is
    /// the piece a 2× capture can silently get wrong, and a pure function is the
    /// only shape of it a self-test can hold still: at 144 dpi a rectangle over
    /// the left half of the picture is over the left half of twice as many
    /// pixels, and applying the drawn numbers unchanged would redact a quarter
    /// of the area in the wrong corner.
    ///
    /// Both spaces have their origin at the bottom left, so this is a scale and
    /// never a flip.
    static func regions(
        _ rects: [CGRect], atPointSize points: CGSize, inPixels pixels: CGSize
    ) -> [CGRect] {
        let scale = CGSize(
            width: pixels.width / max(points.width, 1),
            height: pixels.height / max(points.height, 1))
        return rects.map {
            CGRect(x: $0.minX * scale.width, y: $0.minY * scale.height,
                   width: $0.width * scale.width, height: $0.height * scale.height)
        }
    }

    /// Replaces one block with its own mean colour.
    ///
    /// The alpha channel is averaged along with the rest: a capture with
    /// transparent corners — a window shot keeps its rounded ones — would
    /// otherwise get a hard opaque square where the redaction met the corner.
    private static func fill(
        _ pixels: UnsafeMutablePointer<UInt8>, rowBytes: Int,
        left: Int, right: Int, top: Int, bottom: Int
    ) {
        var totals = (r: 0, g: 0, b: 0, a: 0)
        let count = (right - left) * (bottom - top)
        guard count > 0 else { return }

        for row in top..<bottom {
            var index = row * rowBytes + left * 4
            for _ in left..<right {
                totals.r += Int(pixels[index])
                totals.g += Int(pixels[index + 1])
                totals.b += Int(pixels[index + 2])
                totals.a += Int(pixels[index + 3])
                index += 4
            }
        }

        let mean = (
            r: UInt8(totals.r / count), g: UInt8(totals.g / count),
            b: UInt8(totals.b / count), a: UInt8(totals.a / count))
        for row in top..<bottom {
            var index = row * rowBytes + left * 4
            for _ in left..<right {
                pixels[index] = mean.r
                pixels[index + 1] = mean.g
                pixels[index + 2] = mean.b
                pixels[index + 3] = mean.a
                index += 4
            }
        }
    }

    static func blockSize(width: Int, height: Int) -> Int {
        max(minimumBlock, Int((Double(min(width, height)) / shortSideDivisor).rounded()))
    }

    // MARK: - The file

    enum Failure: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Could not read \(name) to redact it."
            case .unwritable(let name): "Could not write the redacted \(name)."
            }
        }
    }

    /// Redacts the staged file **in place**, and deliberately so.
    ///
    /// The obvious alternative — write "name (redacted).png" beside the original
    /// — is the one thing this feature must not do. A redaction exists because
    /// one of the two files is dangerous, and leaving both on disk under names
    /// that differ by a parenthesis means the dangerous one is a mis-click away
    /// from the share button, the drag-out, the Copy, and the OCR. Every one of
    /// those consumers reads this URL and nothing else, so overwriting it is what
    /// makes them all agree. It is not undoable, and the caller is expected to
    /// have said so.
    ///
    /// Written to a sibling and swapped with `replaceItemAt` rather than
    /// truncated in place: a crash halfway through an in-place rewrite would
    /// leave a half-redacted file, which is the failure that matters here — it
    /// still holds the original bytes and no longer looks like it does.
    ///
    /// Same format and same DPI as it found. The DPI is the load-bearing half:
    /// it is what stands between a 2× capture and being displayed at double size
    /// everywhere afterwards — the concern `Reencoder` in `LinkdropGate` exists
    /// for, and this path re-encodes every capture rather than only the ones in
    /// an unusual format.
    @concurrent
    static func apply(regions: [CGRect], toFileAt url: URL, quality: Double = 0.95)
        async throws -> sending CGImage
    {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadable(name) }

        guard let redacted = pixelate(image, regions: regions) else {
            throw Failure.unwritable(name)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil }
            ?? 72
        var options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        // High rather than the capture default: this is a second trip through a
        // lossy encoder for the parts of the image nobody asked to change, and
        // the ringing that buys is the price of the bytes underneath the
        // rectangle being gone.
        let contentType = UTType(type as String)
        if contentType == .jpeg || contentType == .heic {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".duoshot-redact-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(url.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, type, 1, nil) else { throw Failure.unwritable(name) }
        CGImageDestinationAddImage(destination, redacted, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unwritable(name)
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unwritable(name)
        }
        return redacted
    }
}
