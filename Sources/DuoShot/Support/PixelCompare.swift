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
        /// put 83% of pixels at delta 255. So the *aggregate* is the hard gate,
        /// never the single worst pixel.
        ///
        /// Past that gate a difference qualifies two ways, and it needs both
        /// clauses because recompositing comes in two shapes:
        ///
        /// - **Narrow and deep** — a caret blinked, a clock ticked. Few pixels,
        ///   any depth.
        /// - **Wide and shallow** — the region sits over a large vibrancy
        ///   surface (a sidebar, a translucent toolbar), which samples its
        ///   backdrop from a different area in the two capture paths. Measured
        ///   2026-07-30 over Safari: 20.4% of pixels differing, max channel
        ///   delta 5, i.e. invisible to anyone looking at it — and rejected by a
        ///   5%-of-pixels rule that only ever anticipated the first shape.
        ///
        /// A misplaced rect is neither: it is wide *and* deep, so the mean
        /// catches it three orders of magnitude before either clause matters.
        var isSamePicture: Bool {
            guard !identical else { return true }
            guard meanAbsoluteDifference < 1.0 else { return false }
            return differingFraction < 0.05 || maxChannelDelta <= 16
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

    /// Mean sRGB of a region, 0–255 per channel.
    ///
    /// The counting predicate above is the wrong tool for asking "is this patch
    /// this colour" on a wide-gamut display, and it took a while to see why:
    /// saturated Display P3 values are outside sRGB and *clip* on conversion —
    /// P3 green lands on (8,255,3) — while the same green mixed with a little
    /// white is representable and converts honestly to (70,255,58). Neighbouring
    /// pixels therefore land 60 apart with nothing wrong, so per-pixel tolerances
    /// either fail on grid lines and antialiasing or are so loose they prove
    /// nothing. An average is stable under both.
    static func meanColour(
        _ image: CGImage, in region: CGRect? = nil
    ) -> (r: Double, g: Double, b: Double)? {
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
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum.r += Double(pixels[index])
            sum.g += Double(pixels[index + 1])
            sum.b += Double(pixels[index + 2])
        }
        let count = Double(pixels.count / 4)
        return (sum.r / count, sum.g / count, sum.b / count)
    }

    /// Whether an image came back with nothing in it at all — every pixel
    /// transparent and black.
    ///
    /// The one thing a window capture can reliably say about itself without
    /// knowing what it was supposed to contain. A screenshot of a window that
    /// is on screen is never legitimately empty, whatever produced the emptiness,
    /// so this is a sound trigger for "try the other way round" — see
    /// `CaptureEngine.captureIsolated`.
    ///
    /// Answered from a 64×64 downscale rather than the real bitmap: the source
    /// can be a 5K window, and this runs on every window capture. Averaging is
    /// deliberate — content anywhere in the frame lifts *some* output pixel off
    /// zero, where point-sampling a grid could fall between the glyphs. The
    /// failure it can have is calling a nearly-empty image blank, which costs
    /// one extra capture and nothing else.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        // Could not rasterise: say "not blank", so a failure here can never
        // trigger the retry path on an image nobody has actually looked at.
        guard drawn else { return false }
        return pixels.allSatisfy { $0 == 0 }
    }

    /// Mean alpha of the pixels that are more than half opaque, 0–255, and how
    /// many there are.
    ///
    /// Instrumentation, not a rule. "Is the window translucent" was asked three
    /// times about this popup and answered three different ways from outside the
    /// app — every capture taken by a probe came back solid while the saved file
    /// showed the wallpaper through the panel. Guessing at the difference had
    /// run out of road, so the number is taken on the real path instead, from
    /// the image the compositor is actually handed.
    ///
    /// Measured on the same 64×64 downscale as `isBlank`, so it costs the same
    /// nothing and, being an average, it cannot report a solid panel as
    /// translucent by landing between glyphs.
    nonisolated static func bodyOpacity(_ image: CGImage) -> (pixels: Int, meanAlpha: Int) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return (0, -1) }
        var count = 0, sum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 128 {
            count += 1
            sum += Int(pixels[index + 3])
        }
        return (count, count > 0 ? sum / count : 0)
    }

    /// The part of an image that was actually drawn, in image pixels, or nil
    /// when that is the whole image (or none of it).
    ///
    /// A window's frame is not the same thing as what the window puts on screen.
    /// Measured 2026-08-04 on DuoUpdater's popup: the window is 360×217 pt and
    /// the panel inside it is 258×173, leaving 80 pt of nothing down the right
    /// edge — which a screenshot then framed, and DuoShot's own padding framed
    /// again. An ordinary window has no such border: every Finder window
    /// measured came back drawn edge to edge, which is why this can be applied
    /// unconditionally.
    ///
    /// Alpha zero exactly, not "nearly transparent": the rule is *never drawn*,
    /// so the faintest edge of a shadow or an antialiased corner keeps its
    /// column. Anything looser would start cropping picture.
    ///
    /// Measured on a downscale, and rounded **outward** — a capture can be 15
    /// megapixels and this runs on the main thread. The error is therefore
    /// always a few leftover transparent pixels, never a cropped glyph.
    nonisolated static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let long = max(image.width, image.height)
        guard long > 0 else { return nil }
        let divisor = max(1, Int((Double(long) / 256).rounded(.up)))
        let width = max(1, image.width / divisor)
        let height = max(1, image.height / divisor)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }

        // One cell of slack on every side, then back to image pixels. The
        // context is bottom-up, so the y range flips on the way out.
        let scaleX = Double(image.width) / Double(width)
        let scaleY = Double(image.height) / Double(height)
        let left = max(0, Int((Double(minX) - 1) * scaleX))
        let right = min(image.width, Int((Double(maxX) + 2) * scaleX.rounded(.up)))
        let bottom = max(0, Int((Double(minY) - 1) * scaleY))
        let top = min(image.height, Int((Double(maxY) + 2) * scaleY.rounded(.up)))
        let rect = CGRect(x: left, y: image.height - top,
                          width: right - left, height: top - bottom)
        guard rect.width >= 1, rect.height >= 1,
              rect != CGRect(x: 0, y: 0, width: image.width, height: image.height)
        else { return nil }
        return rect
    }

    /// Alpha at one pixel, 0–255, with the origin at the **top** left.
    ///
    /// `normalized` draws into a bottom-up context, so its first row is the
    /// image's last one; the flip happens here rather than at every call site.
    static func alpha(_ image: CGImage, atX x: Int, y: Int) -> Int? {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y),
              let pixels = normalized(image)
        else { return nil }
        let row = image.height - 1 - y
        return Int(pixels[(row * image.width + x) * 4 + 3])
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
