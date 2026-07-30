import CoreGraphics
import Foundation

/// Centres a capture on a backdrop with a margin around it.
///
/// `nonisolated` and synchronous, like `ImageEncoder`: no isolation boundary, so
/// the non-Sendable `CGImage` never has to cross one.
nonisolated enum ImagePadding {
    // Both are fractions of the margin, so the shadow scales with the padding
    // instead of being clipped by it. At the extremes the shadow reaches
    // `drop + blur` = 0.73 of the margin below the window and `blur - drop` =
    // 0.37 above it, which stays inside the canvas at every padding setting.
    private static let shadowBlur: CGFloat = 0.55
    private static let shadowDrop: CGFloat = 0.18

    /// Returns `image` inset by `padding` points on every side, over `backdrop`.
    ///
    /// The backdrop is aspect-*filled* into the finished canvas rather than
    /// tiled or letterboxed: it is scenery, and a visible seam or a bar of dead
    /// colour would read as a bug. `fallbackFill` covers the canvas when there is
    /// no backdrop to draw, so a failed wallpaper grab degrades to a flat colour
    /// instead of losing the padding altogether.
    ///
    /// Returns nil only if the bitmap context cannot be created, which the caller
    /// treats as "keep the unpadded image".
    static func pad(
        _ image: CGImage,
        by padding: CGFloat,
        scale: CGFloat,
        backdrop: CGImage?,
        fallbackFill: CGColor
    ) -> CGImage? {
        let inset = Int((padding * scale).rounded())
        guard inset > 0 else { return image }

        let width = image.width + inset * 2
        let height = image.height + inset * 2

        // Fixed sRGB + premultipliedLast rather than deriving from the source:
        // a capture can arrive in a display P3 or an alpha-less layout, and
        // reusing that as the destination makes the drawn wallpaper and the
        // window disagree about colour, or drops the window's rounded corners to
        // black. One known-good destination format keeps that predictable.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high

        // The outer edge follows the window's own curve at a constant distance:
        // `radius + inset` is the one value that keeps the two arcs concentric,
        // so the margin is the same width at the corners as along the sides.
        // Anything less and the gap pinches at the corners; anything more and it
        // bulges. A square window gets a square card, which is also right.
        let outerRadius = cornerRadius(of: image).map { $0 + CGFloat(inset) } ?? 0
        if outerRadius > 0 {
            context.addPath(CGPath(
                roundedRect: canvas, cornerWidth: outerRadius, cornerHeight: outerRadius,
                transform: nil))
            context.clip()
        }

        if let backdrop {
            context.draw(backdrop, in: aspectFill(backdrop, into: canvas))
        } else {
            context.setFillColor(fallbackFill)
            context.fill(canvas)
        }

        // Drawn over the backdrop, not composited onto a cleared canvas: a
        // window with rounded corners or a translucent titlebar is meant to show
        // the wallpaper through, which is most of the point of this feature.
        //
        // The shadow is set on the context rather than drawn, so Core Graphics
        // traces the ALPHA of the image about to be drawn. That is what makes
        // this correct without knowing anything about the window: a capture
        // already carries its own corner shape, and the radius is neither
        // constant across macOS releases nor across apps — measured 2026-07-30,
        // 18 pt for WeChat's alert and 24 pt for Claude's window, both with a
        // clean antialiased ramp from alpha 0 to 255 across the curve. Masking
        // to a radius of our own would either double-round those corners or
        // square off a shape that was already right; shadowing the alpha gets
        // every window, every version, and non-rectangular windows too, for free.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -CGFloat(inset) * Self.shadowDrop),
            blur: CGFloat(inset) * Self.shadowBlur,
            color: CGColor(gray: 0, alpha: 0.38))
        context.draw(image, in: CGRect(
            x: inset, y: inset, width: image.width, height: image.height))
        context.restoreGState()

        return context.makeImage()
    }

    /// The window's own corner radius in pixels, read off its alpha channel.
    ///
    /// This is the answer to "can you get the window's corner radius", and it is
    /// yes — just not by asking anyone. The top row of a rounded window is
    /// transparent until the curve ends, so the first fully opaque pixel along
    /// it *is* the radius. Measured 2026-07-30: 36 px for WeChat's alert, 48 px
    /// for Claude's window and DuoTranslator's popup — 18 pt against 24 pt on
    /// the same display, on the same OS, in the same minute. No constant could
    /// have covered those, and the next macOS will not make it easier.
    ///
    /// Nil for a square window, and also for one whose top row stays transparent
    /// implausibly far in: a square card is a better answer than one wrapped
    /// around a radius that has nothing to do with the window.
    static func cornerRadius(of image: CGImage) -> CGFloat? {
        let limit = min(image.width / 4, 256)
        guard limit > 1 else { return nil }

        var row = [UInt8](repeating: 0, count: limit * 4)
        let read = row.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: limit, height: 1, bitsPerComponent: 8,
                bytesPerRow: limit * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // One row tall, and the context is bottom-up, so the image is drawn
            // with its top edge on that row and everything below it clipped away.
            context.draw(image, in: CGRect(
                x: 0, y: 1 - CGFloat(image.height),
                width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard read else { return nil }

        for x in 0..<limit where row[x * 4 + 3] > 250 {
            return x > 0 ? CGFloat(x) : nil
        }
        return nil
    }

    private static func aspectFill(_ image: CGImage, into canvas: CGRect) -> CGRect {
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else { return canvas }
        let scale = max(canvas.width / size.width, canvas.height / size.height)
        let filled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: canvas.midX - filled.width / 2,
            y: canvas.midY - filled.height / 2,
            width: filled.width,
            height: filled.height
        )
    }
}
