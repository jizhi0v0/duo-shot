import CoreGraphics
import Foundation

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
/// This is only the pixel operation. Which rectangles, in what order, and when
/// any of it reaches the file is `ImageEdit`'s — a redaction is one entry in an
/// undoable list now, and the list is flattened onto the staged file once.
///
/// All of it is `nonisolated`, for the reason `ImageEncoder` gives: a 5K bitmap
/// is tens of megabytes to average, and none of that belongs on the main thread.
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
}
