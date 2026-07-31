import AppKit

/// The loupe: the pixels under the pointer, magnified, with their coordinates and
/// colour.
///
/// It exists for one job — putting a selection edge on the pixel you meant. At
/// 1× a boundary between two similar tones is a guess, and a screenshot tool that
/// makes you guess is one you take twice.
///
/// A subview of the overlay rather than drawing inside it: the overlay view is the
/// size of a whole screen, and moving the loupe with the pointer must not mean
/// redrawing 5K worth of dim every time the mouse moves. It also inherits the
/// overlay panel's exclusion from captures for free, so it can never photograph
/// itself into a screenshot.
final class SelectionLoupeView: NSView {
    /// Pixels across the glass. Odd on purpose: there has to be a middle pixel
    /// for the pointer to be *on*, or the reticle straddles two of them and the
    /// loupe cannot answer the only question it is asked.
    private static let pixelsAcross = 21
    /// Points per magnified pixel. 6 is large enough to aim at with a mouse and
    /// small enough that 21 of them still fit beside the pointer.
    private static let magnification: CGFloat = 6
    private static let glassSide = CGFloat(pixelsAcross) * magnification
    private static let captionHeight: CGFloat = 18
    private static let inset: CGFloat = 1

    static var size: CGSize {
        CGSize(width: glassSide + inset * 2, height: glassSide + captionHeight + inset * 2)
    }

    /// The photograph to magnify, and where the pointer is in it. Setting either
    /// redraws — the loupe is small, so a full redraw per mouse move is cheap.
    var backdrop: BackdropCache.Frame? {
        didSet { needsDisplay = true }
    }
    var pointInAppKitGlobal: CGPoint? {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The pointer is over the overlay, and the overlay is what is being aimed
    /// with. A loupe that ate clicks would make the tool unusable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let backdrop, let point = pointInAppKitGlobal,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let glass = CGRect(
            x: Self.inset, y: Self.captionHeight + Self.inset,
            width: Self.glassSide, height: Self.glassSide)
        let centre = DisplayGeometry.pixel(
            ofAppKitGlobal: point, in: backdrop.covers, scale: backdrop.scale)

        // The source window, in image pixels, centred on the pointer's pixel.
        let half = CGFloat(Self.pixelsAcross) / 2
        let source = CGRect(
            x: centre.x.rounded(.down) - half.rounded(.down),
            y: centre.y.rounded(.down) - half.rounded(.down),
            width: CGFloat(Self.pixelsAcross), height: CGFloat(Self.pixelsAcross))

        context.saveGState()
        context.clip(to: glass)
        // Nearest neighbour: the whole point is to see pixels as pixels. Any
        // smoothing here turns a hard edge into a gradient, which is precisely
        // the ambiguity the loupe is meant to remove.
        context.interpolationQuality = .none
        // Drawn by offsetting the whole image rather than cropping it: cropping
        // near an edge of the screen would silently clamp, and the reticle would
        // stop agreeing with the pointer. Off-image area simply stays empty.
        //
        // And drawn with no transform at all. The first version flipped the CTM
        // to "convert" between the image's top-down rows and this view's
        // bottom-up points, which mirrored the loupe vertically: `draw(_:in:)`
        // already renders a CGImage upright, so the flip was a second one.
        // `--selftest-loupe` caught it — the four colours came back in the wrong
        // two rows. What is left is one placement: put the image's own rect where
        // the wanted pixel lands in the middle of the glass.
        let scale = Self.magnification
        let width = CGFloat(backdrop.image.width) * scale
        let height = CGFloat(backdrop.image.height) * scale
        context.draw(
            backdrop.image,
            in: CGRect(
                x: glass.minX - source.minX * scale,
                y: glass.maxY + source.minY * scale - height,
                width: width, height: height))
        context.restoreGState()

        drawGrid(in: glass)
        drawReticle(in: glass)
        drawCaption(
            below: glass,
            point: CGPoint(x: point.x.rounded(), y: point.y.rounded()),
            colour: colour(atPixel: centre))
    }

    /// A grid, but only once each cell is big enough for the lines not to become
    /// the picture.
    private func drawGrid(in glass: CGRect) {
        guard Self.magnification >= 4 else { return }
        NSColor(white: 1, alpha: 0.10).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for step in 1..<Self.pixelsAcross {
            let offset = CGFloat(step) * Self.magnification
            path.move(to: CGPoint(x: glass.minX + offset + 0.5, y: glass.minY))
            path.line(to: CGPoint(x: glass.minX + offset + 0.5, y: glass.maxY))
            path.move(to: CGPoint(x: glass.minX, y: glass.minY + offset + 0.5))
            path.line(to: CGPoint(x: glass.maxX, y: glass.minY + offset + 0.5))
        }
        path.stroke()
    }

    /// Crosshair arms to the centre cell, and the cell itself outlined.
    ///
    /// The arms are the half of this that was missing at first, and the loupe was
    /// much harder to use without them: a single small square in the middle of a
    /// field of squares is something you have to *find*, and the whole promise of
    /// a loupe is that you can see where you are without looking for it. They stop
    /// short of the cell rather than crossing it — the one pixel being aimed at is
    /// the only thing here that must not be covered.
    ///
    /// Everything is drawn dark-then-light, the pairing the old border used, for
    /// the same reason: these lines land on magnified content of every possible
    /// colour, including white.
    private func drawReticle(in glass: CGRect) {
        let middle = CGFloat(Self.pixelsAcross / 2) * Self.magnification
        let cell = CGRect(
            x: glass.minX + middle, y: glass.minY + middle,
            width: Self.magnification, height: Self.magnification)
        // Magnification is even, so the cell's centre lands on an integer and the
        // half-point keeps the hairline on one row of pixels rather than two.
        let midX = cell.midX.rounded() + 0.5
        let midY = cell.midY.rounded() + 0.5
        let gap: CGFloat = 3

        let arms = NSBezierPath()
        arms.move(to: CGPoint(x: glass.minX, y: midY))
        arms.line(to: CGPoint(x: cell.minX - gap, y: midY))
        arms.move(to: CGPoint(x: cell.maxX + gap, y: midY))
        arms.line(to: CGPoint(x: glass.maxX, y: midY))
        arms.move(to: CGPoint(x: midX, y: glass.minY))
        arms.line(to: CGPoint(x: midX, y: cell.minY - gap))
        arms.move(to: CGPoint(x: midX, y: cell.maxY + gap))
        arms.line(to: CGPoint(x: midX, y: glass.maxY))

        let outline = NSBezierPath(rect: cell.insetBy(dx: -0.5, dy: -0.5))

        NSColor(white: 0, alpha: 0.55).setStroke()
        arms.lineWidth = 3
        arms.stroke()
        outline.lineWidth = 3
        outline.stroke()

        NSColor(white: 1, alpha: 0.95).setStroke()
        arms.lineWidth = 1
        arms.stroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawCaption(below glass: CGRect, point: CGPoint, colour: NSColor?) {
        var text = "\(Int(point.x)), \(Int(point.y))"
        if let colour, let srgb = colour.usingColorSpace(.sRGB) {
            text += String(
                format: "  #%02X%02X%02X",
                Int((srgb.redComponent * 255).rounded()),
                Int((srgb.greenComponent * 255).rounded()),
                Int((srgb.blueComponent * 255).rounded()))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        // A swatch as well as the digits: a hex triple is something you compare,
        // and a colour is something you recognise.
        let swatchSide: CGFloat = 8
        let swatchGap: CGFloat = 5
        let totalWidth = measured.width + (colour == nil ? 0 : swatchSide + swatchGap)
        var x = (bounds.width - totalWidth) / 2
        let y = (Self.captionHeight - measured.height) / 2 + Self.inset
        if let colour {
            colour.setFill()
            let swatch = CGRect(
                x: x, y: y + (measured.height - swatchSide) / 2,
                width: swatchSide, height: swatchSide)
            NSBezierPath(rect: swatch).fill()
            NSColor(white: 1, alpha: 0.3).setStroke()
            NSBezierPath(rect: swatch.insetBy(dx: 0.5, dy: 0.5)).stroke()
            x += swatchSide + swatchGap
        }
        (text as NSString).draw(at: CGPoint(x: x.rounded(), y: y.rounded()),
                                withAttributes: attributes)
    }

    /// One pixel out of the photograph.
    ///
    /// Cropped to 1×1 first, then drawn into a 1×1 context: `CGImage.cropping`
    /// works in the image's own top-down space, so the row arithmetic that made
    /// the magnified view come out mirrored cannot be got wrong here either.
    ///
    /// And a 1×1 context rather than reading the whole image's bytes, because this
    /// runs on every mouse move: normalising a 5K frame to answer a question about
    /// one pixel would be tens of megabytes of work per frame.
    private func colour(atPixel pixel: CGPoint) -> NSColor? {
        guard let backdrop else { return nil }
        let x = Int(pixel.x.rounded(.down)), y = Int(pixel.y.rounded(.down))
        guard (0..<backdrop.image.width).contains(x),
              (0..<backdrop.image.height).contains(y),
              let one = backdrop.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var pixels: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            srgbRed: CGFloat(pixels[0]) / 255, green: CGFloat(pixels[1]) / 255,
            blue: CGFloat(pixels[2]) / 255, alpha: 1)
    }
}
