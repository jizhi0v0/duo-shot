import CoreGraphics
import Foundation

/// Centres a capture on a backdrop with a margin around it.
///
/// `nonisolated` and synchronous, like `ImageEncoder`: no isolation boundary, so
/// the non-Sendable `CGImage` never has to cross one.
nonisolated enum ImagePadding {
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

        if let backdrop {
            context.draw(backdrop, in: aspectFill(backdrop, into: canvas))
        } else {
            context.setFillColor(fallbackFill)
            context.fill(canvas)
        }

        // Drawn over the backdrop, not composited onto a cleared canvas: a
        // window with rounded corners or a translucent titlebar is meant to show
        // the wallpaper through, which is most of the point of this feature.
        context.draw(image, in: CGRect(
            x: inset, y: inset, width: image.width, height: image.height))

        return context.makeImage()
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
