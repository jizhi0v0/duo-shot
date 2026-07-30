import CoreGraphics
import Foundation

/// Byte-level comparison of two CGImages.
///
/// Used by the geometry self-tests: the way to prove `sourceRect` math is right
/// without a human eyeballing PNGs is to capture the same region two ways — once
/// via `sourceRect`, once by capturing everything and cropping — and assert the
/// pixels are identical.
enum PixelCompare {
    struct Result {
        let identical: Bool
        let differingPixels: Int
        let totalPixels: Int
        let maxChannelDelta: Int
        /// Mean absolute channel difference over *every* pixel, 0–255.
        let meanAbsoluteDifference: Double
        let note: String?

        var differingFraction: Double {
            Double(differingPixels) / Double(max(totalPixels, 1))
        }

        /// Whether the two images are the same picture.
        ///
        /// Max channel delta alone is a poor discriminator: anti-aliased text
        /// over a blurred backdrop legitimately differs by more than any small
        /// bound on a handful of pixels, while a misplaced rect is obvious in
        /// aggregate — measured, the rejected "global" reading of `sourceRect`
        /// put 83% of pixels at delta 255. So judge on how much of the image
        /// differs and by how much on average, not on the single worst pixel.
        var isSamePicture: Bool {
            identical || (differingFraction < 0.05 && meanAbsoluteDifference < 1.0)
        }

        var summary: String {
            if let note { return note }
            if identical { return "identical (\(totalPixels) px)" }
            return String(
                format: "%d/%d px differ (%.2f%%), max channel delta %d, mean abs diff %.3f",
                differingPixels, totalPixels, differingFraction * 100,
                maxChannelDelta, meanAbsoluteDifference)
        }
    }

    /// Normalises both images into premultiplied RGBA8 sRGB before comparing, so
    /// a difference in the source color space or alpha layout is not mistaken
    /// for a geometry error.
    static func compare(_ lhs: CGImage, _ rhs: CGImage) -> Result {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return Result(
                identical: false, differingPixels: 0, totalPixels: 0, maxChannelDelta: 0,
                meanAbsoluteDifference: .infinity,
                note: "size mismatch: \(lhs.width)x\(lhs.height) vs \(rhs.width)x\(rhs.height)")
        }
        guard
            let a = normalized(lhs),
            let b = normalized(rhs)
        else {
            return Result(identical: false, differingPixels: 0, totalPixels: 0,
                          maxChannelDelta: 0, meanAbsoluteDifference: .infinity,
                          note: "could not rasterise for comparison")
        }

        let total = lhs.width * lhs.height
        var differing = 0
        var maxDelta = 0
        var deltaSum = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for pixel in 0..<total {
                    let base = pixel * 4
                    var pixelDiffers = false
                    for channel in 0..<4 {
                        let delta = abs(Int(pa[base + channel]) - Int(pb[base + channel]))
                        if delta != 0 {
                            pixelDiffers = true
                            maxDelta = max(maxDelta, delta)
                            deltaSum += delta
                        }
                    }
                    if pixelDiffers { differing += 1 }
                }
            }
        }

        return Result(
            identical: differing == 0,
            differingPixels: differing,
            totalPixels: total,
            maxChannelDelta: maxDelta,
            meanAbsoluteDifference: Double(deltaSum) / Double(max(total * 4, 1)),
            note: nil)
    }

    /// Counts pixels satisfying a predicate over (r, g, b).
    ///
    /// Used to hunt for the debug magenta the overlay draws inside the selection
    /// edge: the dim itself has a hole exactly where the selection is, so a
    /// leaked overlay is invisible in a plain image comparison. A distinctive
    /// colour drawn *inside* the captured region is the only reliable tell.
    static func count(
        _ image: CGImage, matching predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> Int {
        guard let pixels = normalized(image) else { return 0 }
        var matches = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if predicate(pixels[index], pixels[index + 1], pixels[index + 2]) { matches += 1 }
        }
        return matches
    }

    /// Near-pure magenta: high red and blue, low green.
    static func isDebugMagenta(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        r > 200 && b > 200 && g < 80
    }

    /// Mean Rec. 709 luminance, 0–255. Used to verify the overlay's dim actually
    /// renders: eyeballing a screenshot cannot reliably tell 28% black apart from
    /// no dim at all.
    static func meanLuminance(_ image: CGImage, in region: CGRect? = nil) -> Double? {
        let target: CGImage
        if let region {
            let clamped = region.intersection(
                CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
                  let cropped = image.cropping(to: clamped)
            else { return nil }
            target = cropped
        } else {
            target = image
        }
        guard let pixels = normalized(target), !pixels.isEmpty else { return nil }
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
        }
        return sum / Double(pixels.count / 4)
    }

    private static func normalized(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? pixels : nil
    }
}
