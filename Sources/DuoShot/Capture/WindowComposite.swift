import CoreGraphics

/// Puts windows that were captured one at a time back into the arrangement they
/// had on screen — a tooltip over the panel it belongs to
/// (`CaptureEngine.withAdornments`).
///
/// `nonisolated` with a `@concurrent` entry point, for the same reason as
/// `ImagePadding`: the bottom layer is a whole window capture, tens of megabytes
/// at 5K, and none of that belongs on the main thread.
nonisolated enum WindowComposite {
    /// `layers` back to front. Every rect is in CG global points, origin top
    /// left, and `canvas` has to contain all of them.
    @concurrent
    static func composited(
        _ layers: [(image: CGImage, rect: CGRect)], canvas: CGRect, scale: CGFloat
    ) async -> CGImage? {
        compose(layers, canvas: canvas, scale: scale)
    }

    /// `image` kept only where `shape` has alpha — a region of the screen cut to
    /// the outline of the window it holds (`CaptureEngine.shaped`). The shape is
    /// drawn at the image's size, so a crop a pixel off still lines up.
    @concurrent
    static func masking(_ image: CGImage, to shape: CGImage) async -> CGImage? {
        masked(image, to: shape)
    }

    static func masked(_ image: CGImage, to shape: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(shape, in: rect)
        // Source-in: the image, scaled by the alpha already there — the shape's.
        context.setBlendMode(.sourceIn)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Returns nil only if the bitmap context cannot be created, which the caller
    /// treats as "keep the window without what was over it".
    static func compose(
        _ layers: [(image: CGImage, rect: CGRect)], canvas: CGRect, scale: CGFloat
    ) -> CGImage? {
        let width = Int((canvas.width * scale).rounded())
        let height = Int((canvas.height * scale).rounded())
        // The bottom layer's colour space when it is an RGB one, so compositing a
        // tooltip does not also convert the whole window out of display P3. The
        // pixel layout is fixed regardless — see `ImagePadding.pad` for what
        // reusing a capture's own layout does to the corners.
        let space = layers.first?.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        for layer in layers {
            // CG global is top-left; the bitmap context is bottom-left.
            context.draw(layer.image, in: CGRect(
                x: (layer.rect.minX - canvas.minX) * scale,
                y: (canvas.maxY - layer.rect.maxY) * scale,
                width: layer.rect.width * scale,
                height: layer.rect.height * scale))
        }
        return context.makeImage()
    }
}
