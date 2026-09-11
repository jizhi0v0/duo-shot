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
