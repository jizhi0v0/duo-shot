import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One reversible thing done to a capture before it becomes a link.
///
/// The list of these *is* the edit: the whole list is flattened onto the staged
/// file after every change to it, always from the capture's own bytes rather
/// than from what is on disk now. That is what makes ⌘Z possible on a feature
/// whose whole point — see `Redaction` — is that it destroys pixels
/// irrecoverably: undo does not recover anything, it writes a shorter list onto
/// the same untouched source. The destruction becomes permanent when the window
/// closes and those bytes go out of memory.
///
/// Every rectangle and point here is in **image points with the origin at the
/// bottom left** — the space the user drew in, which is the editor's canvas, and
/// which is not the bitmap's pixels on a 2× capture. `render` holds the one
/// scale that separates the two, so nothing upstream has to think about it.
nonisolated enum ImageEdit: Equatable {
    /// Averaged away, not covered up. `Redaction` owns the how and the why.
    case redact(CGRect)
    /// A numbered dot. The number is not stored: it is the marker's position in
    /// the list, worked out at render time, so undoing the second of three
    /// renumbers the third rather than leaving a gap.
    case marker(CGPoint)
    /// A line of text, positioned by the left end of its baseline — the point
    /// the pointer was at when the field opened, and the point CoreText draws
    /// from. Anything else has to be undone by both halves separately, which is
    /// how text ends up landing somewhere other than where it was typed.
    case text(CGPoint, String)
    /// What survives. Applied last and only once — the *last* crop in the list
    /// wins, so cropping twice is a correction rather than a compounding.
    case crop(CGRect)

    var cropRect: CGRect? {
        if case .crop(let rect) = self { rect } else { nil }
    }

    /// The same edit, somewhere else.
    ///
    /// Exists for one caller and one reason: a crop takes effect as soon as it is
    /// made, so everything drawn afterwards is drawn on the cropped picture,
    /// while the list stays in the original's coordinates. The offset between the
    /// two is the crop's origin.
    func moved(by offset: CGPoint) -> ImageEdit {
        guard offset != .zero else { return self }
        switch self {
        case .redact(let rect):
            return .redact(rect.offsetBy(dx: offset.x, dy: offset.y))
        case .marker(let point):
            return .marker(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
        case .text(let point, let string):
            return .text(CGPoint(x: point.x + offset.x, y: point.y + offset.y), string)
        case .crop(let rect):
            return .crop(rect.offsetBy(dx: offset.x, dy: offset.y))
        }
    }

    // MARK: - How they are drawn
    //
    // Shared with the editor rather than private, because the text field the
    // user types into has to sit exactly where the text will be rendered, and
    // the two agreeing by coincidence is how annotations end up jumping a few
    // points when they are committed.

    /// Points, at the image's own scale: a marker on a 5K capture is the same
    /// size relative to the picture as one on a small window shot.
    static let markerRadius: CGFloat = 13
    static let textSize: CGFloat = 20
    /// Breathing room around the field the text is typed into. Only the field
    /// uses it — the rendered text is anchored on its baseline, not on a box.
    static let textInset: CGFloat = 3

    /// Annotation red, and the white a marker's number is set in. Marks have to
    /// survive being drawn over a screenshot of anything at all — a white
    /// spreadsheet, a black terminal — and what buys that is the shadow in
    /// `setShadow`, not an outline: two rounds of looking at outlined text and a
    /// ringed disc said the same thing both times.
    static let inkColor = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let haloColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

/// The undo stack, which is the whole reason the edits are a list.
///
/// A plain pair of arrays rather than `UndoManager`: what is being undone here
/// is not a scattering of property changes across an object graph but one
/// append-only list, and the responder-chain machinery that makes `UndoManager`
/// worth its weight would have to be fought to keep ⌘Z from reaching the text
/// field being typed into.
nonisolated struct EditList: Equatable {
    private(set) var edits: [ImageEdit] = []
    private var undone: [ImageEdit] = []

    var isEmpty: Bool { edits.isEmpty }
    var canUndo: Bool { !edits.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    /// The crop in force, which is the last one added and not the first: a
    /// second crop is a correction of the first.
    var crop: CGRect? { edits.compactMap(\.cropRect).last }

    mutating func push(_ edit: ImageEdit) {
        edits.append(edit)
        // The branch that was undone is gone the moment a new edit is made,
        // which is what every editor does and what nobody is surprised by.
        undone.removeAll()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let last = edits.popLast() else { return false }
        undone.append(last)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let last = undone.popLast() else { return false }
        edits.append(last)
        return true
    }

    mutating func clear() {
        edits.removeAll()
        undone.removeAll()
    }
}

nonisolated extension ImageEdit {
    // MARK: - Flattening

    /// Draws the whole list onto `image` and hands back the result.
    ///
    /// The same function draws the preview the user is looking at and the bitmap
    /// that gets written, differing only in `cropping`. That is deliberate and
    /// it is the answer to the question this feature was rebuilt to answer —
    /// *what exactly did I just cover up?* A preview drawn by a different piece
    /// of code than the output is a promise, and this one is an identity.
    ///
    /// `cropping` is false only while a crop is being dragged, where the frame
    /// and its dimmed margin stand in for the result. The moment the drag ends
    /// the crop is written like anything else, and the picture on screen is the
    /// cropped one.
    ///
    /// Returns nil for an empty list rather than the original, for the reason
    /// `Redaction.pixelate` gives: the caller is about to overwrite a file, and
    /// "nothing to do" must not be spelled the same way as "done".
    static func render(
        _ image: CGImage, edits: [ImageEdit], pointSize: CGSize, cropping: Bool
    ) -> CGImage? {
        guard !edits.isEmpty, image.width > 0, image.height > 0 else { return nil }
        let pixels = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let scale = CGSize(
            width: pixels.width / max(pointSize.width, 1),
            height: pixels.height / max(pointSize.height, 1))
        // Marks are round and text is not stretched, so their size takes one
        // number out of a scale that is only ever anisotropic by a rounding
        // error's worth.
        let unit = (scale.width + scale.height) / 2

        // Fixed sRGB + premultipliedLast, the same choice and for the same
        // reason as `Redaction.pixelate`: a capture can arrive in Display P3 or
        // with no alpha at all, and drawing into whatever the source happened to
        // be makes the output depend on the display it was taken from.
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let full = CGRect(origin: .zero, size: pixels)
        context.draw(image, in: full)
        context.textMatrix = .identity

        var markerNumber = 0
        var index = edits.startIndex
        while index < edits.endIndex {
            switch edits[index] {
            case .redact:
                // Consecutive redactions go through `pixelate` in one pass. Not
                // only for the copy it saves: a rectangle drawn over a rectangle
                // must average the *original* pixels under both, and averaging
                // an average is how a redaction ends up lighter than its
                // neighbour and shows exactly where the second one was.
                var regions: [CGRect] = []
                while index < edits.endIndex, case .redact(let rect) = edits[index] {
                    regions.append(scaled(rect, by: scale))
                    index += 1
                }
                guard let snapshot = context.makeImage(),
                      let pixelated = Redaction.pixelate(snapshot, regions: regions)
                else { return nil }
                context.draw(pixelated, in: full)
            case .marker(let centre):
                markerNumber += 1
                draw(marker: markerNumber, at: scaled(centre, by: scale), unit: unit, in: context)
                index += 1
            case .text(let origin, let string):
                draw(text: string, at: scaled(origin, by: scale), unit: unit, in: context)
                index += 1
            case .crop:
                // Last, and outside the loop: a crop half way through the list
                // would shift the coordinates of everything after it, and the
                // list is the user's history rather than a rendering order.
                index += 1
            }
        }

        guard let flattened = context.makeImage() else { return nil }
        guard cropping, let crop = edits.compactMap(\.cropRect).last else { return flattened }
        let box = scaled(crop, by: scale).integral.intersection(full)
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return flattened }
        // `cropping(to:)` is in the bitmap's own space, whose origin is the TOP
        // left — the one place in this file where the flip has to be written out.
        return flattened.cropping(to: CGRect(
            x: box.minX, y: pixels.height - box.maxY,
            width: box.width, height: box.height)) ?? flattened
    }

    /// Scales rectangles drawn over a picture at its point size into the
    /// bitmap's own pixels.
    ///
    /// Internal, and a pure function, because it is the piece a 2× capture can
    /// silently get wrong and the only shape of it a self-test can hold still:
    /// at 144 dpi a rectangle over the left half of the picture is over the left
    /// half of twice as many pixels, and applying the drawn numbers unchanged
    /// would redact a quarter of the area in the wrong corner.
    ///
    /// Both spaces have their origin at the bottom left, so this is a scale and
    /// never a flip.
    static func regions(
        _ rects: [CGRect], atPointSize points: CGSize, inPixels pixels: CGSize
    ) -> [CGRect] {
        let scale = CGSize(
            width: pixels.width / max(points.width, 1),
            height: pixels.height / max(points.height, 1))
        return rects.map { scaled($0, by: scale) }
    }

    private static func scaled(_ rect: CGRect, by scale: CGSize) -> CGRect {
        CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height,
               width: rect.width * scale.width, height: rect.height * scale.height)
    }

    private static func scaled(_ point: CGPoint, by scale: CGSize) -> CGPoint {
        CGPoint(x: point.x * scale.width, y: point.y * scale.height)
    }

    private static func draw(
        marker number: Int, at centre: CGPoint, unit: CGFloat, in context: CGContext
    ) {
        let radius = markerRadius * unit
        let circle = CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2)
        // No ring at all. It went from a tenth of the radius to a hairline to
        // this: white around a red disc reads as a sticker cut out and pasted on
        // rather than as a mark made on the picture, and the shadow already does
        // the one job the ring was for — keeping the disc off a background of the
        // same colour.
        context.saveGState()
        setShadow(unit: unit, in: context)
        context.setFillColor(inkColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        let line = typeset("\(number)", size: radius * 1.15, fill: haloColor, halo: false)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: centre.x - bounds.width / 2 - bounds.minX,
            y: centre.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private static func draw(
        text string: String, at origin: CGPoint, unit: CGFloat, in context: CGContext
    ) {
        guard !string.isEmpty else { return }
        let size = textSize * unit
        // No outline. A white stroke around red letters was the first answer to
        // "it has to be legible on any screenshot", and two rounds of looking at
        // it said the same thing both times: at any width wide enough to help it
        // makes the text look doubled, and it is worst on the scripts with the
        // most strokes. The shadow does the separating.
        let line = typeset(string, size: size, fill: inkColor, halo: false)
        context.saveGState()
        setShadow(unit: unit, in: context)
        // Straight onto the point. `EditCanvas` places the field so that its own
        // baseline lands here too, which is the whole of what keeps the words
        // from jumping when ⏎ turns them into pixels.
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// What separates a mark from the screenshot under it, now that the outline
    /// no longer can.
    ///
    /// A wide white outline was the first answer and it was the wrong one: the
    /// stroke is centred on the glyph, so it eats inward, and on a script whose
    /// counters are a stroke wide — 撒 has four in the space of one Latin o — it
    /// fills them in and the character turns into a blob. A shadow is outside the
    /// glyph by construction and cannot do that to any writing system.
    private static func setShadow(unit: CGFloat, in context: CGContext) {
        context.setShadow(
            offset: CGSize(width: 0, height: -unit),
            blur: 3 * unit,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
    }

    private static func uiFont(size: CGFloat) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(
            system, size, nil, .traitBold, .traitBold) ?? system
    }

    /// The outline is a stroke *and* a fill in one pass — a negative stroke width
    /// is CoreText's way of asking for both, and drawing the string twice at
    /// different widths would double every antialiased edge.
    private static func typeset(
        _ string: String, size: CGFloat, fill: CGColor, halo: Bool
    ) -> CTLine {
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: uiFont(size: size),
            kCTForegroundColorAttributeName: fill,
        ]
        if halo {
            attributes[kCTStrokeColorAttributeName] = haloColor
            // Per cent of the font size, negative to ask for both. A hairline:
            // half of any stroke is spent eating into the fill, so this is the
            // most that can be asked for before red text starts turning white
            // from the inside out. The separation is the shadow's job.
            attributes[kCTStrokeWidthAttributeName] = -2.0
        }
        return CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
    }

    // MARK: - The file

    enum Failure: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Could not read \(name) to edit it."
            case .unwritable(let name): "Could not write the edited \(name)."
            }
        }
    }

    /// Flattens the list into a **new file beside the original**, which is left
    /// exactly as it was.
    ///
    /// This is the second answer to the same question, and the first one is worth
    /// writing down because it was not wrong: overwriting the capture in place
    /// makes every consumer agree, since share, copy, drag-out and Copy Text all
    /// read that one URL. The cost is that a redaction becomes unrecoverable the
    /// moment it is made, and an accidental one takes the pixels with it.
    ///
    /// Exporting inverts both. The capture is never modified — undo has nothing
    /// to repair, and a mistake costs a file nobody has to keep. What it buys in
    /// safety it gives back in danger: **the original, with the pixels still in
    /// it, stays on disk**, and it is the file the preview card, the share
    /// button and the drag-out still point at. The edited copy is the one on the
    /// clipboard; the un-edited one is the one a mis-click sends. Anyone reading
    /// this in six months and wondering why redaction does not protect the
    /// capture itself: that is why, and it was a decision rather than an
    /// oversight.
    ///
    /// `original` is the capture's own bytes, held in the open viewer's memory,
    /// so every export starts from the same source no matter how many have been
    /// made.
    ///
    /// Same format and same DPI as it found. The DPI is the load-bearing half:
    /// it is what stands between a 2× capture and being displayed at double size
    /// everywhere afterwards.
    @concurrent
    static func export(
        _ edits: [ImageEdit], of original: Data, pointSize: CGSize,
        to url: URL, quality: Double = 0.95
    ) async throws -> sending CGImage {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadable(name) }

        // An empty list still exports: "copy this capture" is a reasonable thing
        // to ask for, and the file that comes out is the one that went in.
        let edited = edits.isEmpty
            ? image
            : render(image, edits: edits, pointSize: pointSize, cropping: true)
        guard let edited else { throw Failure.unwritable(name) }

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

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type, 1, nil) else { throw Failure.unwritable(name) }
        CGImageDestinationAddImage(destination, edited, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.unwritable(name)
        }
        return edited
    }

    /// "name (edited).png" beside the original, and "(edited 2)" if that is
    /// taken.
    ///
    /// Counted rather than stamped with a time: two exports a second apart
    /// should read as the first and the second attempt, which is what they are,
    /// and a filename nobody can say out loud is a filename nobody can find.
    nonisolated static func exportURL(besides url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension
        for attempt in 1...999 {
            let name = attempt == 1 ? "\(stem) (edited)" : "\(stem) (edited \(attempt))"
            let candidate = directory.appendingPathComponent(name)
                .appendingPathExtension(suffix)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem) (edited \(UUID().uuidString.prefix(4)))")
            .appendingPathExtension(suffix)
    }
}
