import CoreGraphics
import Foundation

/// Assembles a long screenshot from repeated captures of one fixed region while
/// the user scrolls the content underneath — the app never scrolls anything
/// itself, so no synthesized events and no Accessibility grant.
///
/// An `actor` rather than a `nonisolated` enum: unlike the other pixel workers
/// this one carries state between calls (the growing canvas, the previous
/// frame's row signatures), and an actor is Sendable by construction — the
/// alternative was another `@unchecked Sendable`, which CLAUDE.md caps at
/// `SCKBridge`.
///
/// Rows are compared by *signature with tolerance*, never by exact bytes. The
/// window server does not render the same content byte-identically at two
/// screen positions — measured 2026-08-02 on the flow test's flat colour
/// fills: after a 120 pt scroll, 0 of 440 rows matched exactly, with every
/// channel wobbling ±1–2 from colour-management dithering. A row's signature
/// is the per-segment mean of each channel, which averages that noise away;
/// two rows match when every component agrees within `Config.tolerance`.
///
/// Signatures alone choose the *candidate* shift; pixels confirm it. Learned
/// from a real mis-stitched chat capture (2026-08-02): two different lines of
/// prose average to the same segment means — same ink density over a flat
/// background — and two-thirds of a chat's rows are background that matches
/// anything. Under a tolerant row comparison a wrong shift routinely cleared
/// the 90 % ratio, and the smallest-shift bias then guaranteed it was picked;
/// scrolling *up* produced spliced, reordered output instead of rejections.
/// So every candidate shift must also survive `pixelConfirmation`: sampled
/// rows of the implied overlap compared pixel-for-pixel (glyphs at a wrong
/// alignment cannot), and the overlap must contain at least
/// `Config.minInformativeRows` rows with real structure, because an overlap of
/// pure background confirms nothing.
///
/// Stitching is bidirectional: scrolling down appends past the frontier,
/// scrolling up prepends above the top, and moving through content already
/// stitched repositions without writing (`cursor`). The session can start
/// anywhere in a document and grow both ways.
///
/// Known v1 failure modes, deliberate and documented rather than half-fixed:
/// - A page that *changes while being captured* — a chat streaming its reply
///   in, with fade-in animation and reflow — cannot be stitched faithfully:
///   frames mid-animation get written as they looked, and content that moved
///   non-uniformly can leave a chimera line at a seam. Revisit-refresh is the
///   remedy after the fact: once the page settles, scrolling back across the
///   damage re-describes every changed row. Capturing after the page stops
///   changing avoids it entirely.
/// - A translucent/vibrancy header changes pixels with the content behind it,
///   so the sticky-prefix detector cannot see it; it repeats in the output.
///   Selecting below the header avoids it.
/// - Scrolling more than a band height between two frames (~0.2 s apart)
///   leaves no overlap to match — the frame is rejected and the HUD asks the
///   user to scroll slower.
/// - Sub-pixel offsets and horizontal jitter fail the row comparison and
///   reject the frame rather than mis-stitch it.
/// - Perfectly periodic content can under-measure the shift by whole periods.
///   Any alignment of a repeating pattern is indistinguishable from any other,
///   so the output is seamless — just conservatively short.
/// - Rows that genuinely differ by less than the tolerance — a very gentle
///   gradient — can align a row or two off. Where that happens the content is
///   by definition near-uniform, so the seam is invisible.
actor ScrollStitcher {
    nonisolated struct Config: Sendable {
        /// Rows of genuine overlap a candidate shift must explain before it is
        /// believed. Below this, a match is more likely two blank strips than
        /// the same content seen twice.
        var minOverlapRows = 24
        /// Fraction of overlap rows whose signatures must agree. Not 1.0: an
        /// animated speck inside the overlap (a caret, a spinner) is one
        /// mismatched row, not a different picture.
        var matchRatio = 0.90
        /// How far apart two rows' signature components may sit and still be
        /// "the same row". Sized for the ±1–2 per-channel dithering the window
        /// server applies when it re-renders content at a new position; the
        /// segment means wobble far less than the pixels do.
        var tolerance: Int16 = 3
        /// Rows with pixel-level structure the implied overlap must contain
        /// before a shift is believed. An overlap of pure background matches
        /// every shift and proves none of them.
        var minInformativeRows = 8
        /// The lenient ratio for moves that cannot write at the canvas ends —
        /// interior repositions and relocation. A page that finished changing
        /// after it was first captured (a streaming chat) diverges from the
        /// canvas by every settled line; the strict ratio would refuse ever to
        /// re-find it, and with it the revisit-refresh that heals those lines.
        var revisitMatchRatio = 0.75
        /// Canvas cap — roughly 40 000 rows at a 2400-pixel-wide region, taller
        /// for narrower ones. Past it `append` reports `.canvasFull` and the
        /// session finishes with what it has.
        var maxCanvasBytes = 384 << 20
        /// Negative control for the self-test: replaces the shift search with a
        /// wrong constant, so the stitched output must fail the pixel
        /// comparison. A green run with this set means the test proves nothing.
        var brokenOverlapSearchForTest = false
    }

    nonisolated enum RejectReason: Sendable, Equatable {
        /// No vertical shift explains the new frame — scrolled too far, scrolled
        /// up, or jittered horizontally.
        case cannotAlign
        /// The frame's pixel size or scale differs from the first frame's; the
        /// display configuration changed under the session.
        case mismatchedFrame
    }

    nonisolated enum Verdict: Sendable, Equatable {
        case seeded
        /// `newRows` is the net growth in canvas rows, at either end: appended
        /// past the frontier scrolling down, or prepended above the top
        /// scrolling up.
        case appended(newRows: Int, totalRows: Int)
        /// The frame aligned inside content already stitched — the user is
        /// moving through what the canvas has, and nothing is written. Not
        /// writing matters: every frame's bottom rows carry any sticky footer,
        /// and stamping those into the canvas interior put the footer mid-page.
        case repositioned(totalRows: Int)
        /// Nothing moved. Also reported when only a sliver smaller than the
        /// minimum overlap changed (a blinking caret on an otherwise still
        /// page): treating that as `cannotAlign` made the HUD nag a user who
        /// simply wasn't scrolling yet.
        case skippedIdentical
        case rejected(RejectReason)
        case canvasFull(totalRows: Int)
    }

    /// Horizontal segments per row. One mean over the whole row would call a
    /// row and its mirror image the same; four means make that vanishingly
    /// unlikely without costing anything.
    private static let segments = 4
    /// R, G and B of each segment; alpha is 255 everywhere and says nothing.
    private static let componentsPerRow = segments * 3

    private let config: Config
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var scale: CGFloat = 1
    /// Raw sRGB/premultipliedLast rows, top row first — the memory order of a
    /// `CGContext` bitmap, so appending downward content is appending bytes.
    private var canvas = Data()
    /// `componentsPerRow` values per row, flat.
    private var lastSignatures: [Int16] = []
    /// Signatures for every canvas row, maintained alongside it, so a frame
    /// that lost the frame-to-frame thread can be looked for in *everything*
    /// stitched so far — see `relocate`.
    private var canvasSignatures: [Int16] = []
    /// The previous frame's normalized bytes, kept for pixel confirmation of
    /// the next frame's shift. One frame (~15 MB at a 2400×1600 region), gone
    /// with the session.
    private var lastFrame = Data()
    /// Sticky-header height in rows, frozen at the first accepted pair's
    /// in-place prefix. Rows above it are never rewritten; the header from the
    /// first frame is the one the output keeps.
    private var headerRows: Int?
    /// Sticky-footer height, frozen the same way from the first accepted
    /// pair's in-place suffix. The guard for revisit-refresh: a frame's bottom
    /// rows carry any docked bar, and those belong at the bottom of the
    /// picture, never stamped into its middle.
    private var footerRows: Int?
    /// Where the viewport sits inside the canvas: the canvas *body* row (below
    /// the header) that the current frame's first below-header row shows.
    /// 0 when the viewport is at the canvas top; `bodyRows - frameBodyRows`
    /// when it is at the frontier. What makes scrolling back and forth safe:
    /// growth happens only when the viewport pushes past either end.
    private var cursor = 0

    init(config: Config = Config()) {
        self.config = config
    }

    var totalRows: Int {
        pixelWidth == 0 ? 0 : canvas.count / (pixelWidth * 4)
    }

    func append(_ frame: CaptureResult) -> Verdict {
        let image = frame.image
        if canvas.isEmpty {
            guard image.width > 0, image.height > 0,
                  let bytes = Self.normalized(image) else {
                return .rejected(.mismatchedFrame)
            }
            pixelWidth = image.width
            pixelHeight = image.height
            scale = frame.scale
            canvas = bytes
            lastSignatures = Self.rowSignatures(bytes, width: pixelWidth, height: pixelHeight)
            canvasSignatures = lastSignatures
            lastFrame = bytes
            return .seeded
        }

        guard image.width == pixelWidth, image.height == pixelHeight,
              frame.scale == scale,
              let bytes = Self.normalized(image) else {
            return .rejected(.mismatchedFrame)
        }

        let signatures = Self.rowSignatures(bytes, width: pixelWidth, height: pixelHeight)
        let h = pixelHeight
        // In-place prefix and suffix: rows that did not move at all. In scrolled
        // content a row matches its *shifted* counterpart, not its own position,
        // so these brackets are sticky chrome (and blank margins) only.
        var prefix = 0
        while prefix < h, rowsMatch(lastSignatures, prefix, signatures, prefix) { prefix += 1 }
        // Every row still where it was: nothing moved. This is also what a
        // still screen's dithering noise resolves to now that rows are compared
        // with tolerance — it used to read as `cannotAlign` and nag the user.
        if prefix == h { return .skippedIdentical }
        var suffix = 0
        while suffix < h - prefix,
              rowsMatch(lastSignatures, h - 1 - suffix, signatures, h - 1 - suffix) {
            suffix += 1
        }

        switch shift(
            from: lastSignatures, to: signatures, newBytes: bytes,
            prefix: prefix, suffix: suffix) {
        case .none:
            // The frame-to-frame thread is lost — a fling, or a return from
            // one. Before giving up, look for this frame in *everything*
            // stitched so far: the user scrolling back to reconnect lands
            // somewhere in the canvas, almost never within a band of the last
            // aligned frame.
            if let found = relocate(signatures: signatures, bytes: bytes) {
                cursor = found
                refreshRevisited(
                    signatures: signatures, bytes: bytes,
                    header: headerRows ?? 0, suffix: suffix)
                lastSignatures = signatures
                lastFrame = bytes
                return .repositioned(totalRows: totalRows)
            }
            return .rejected(.cannotAlign)
        case .stillness:
            return .skippedIdentical
        case .found(let d):
            let header = headerRows ?? prefix
            headerRows = header
            if footerRows == nil { footerRows = suffix }
            let bytesPerRow = pixelWidth * 4
            let frameBody = h - header
            let frontier = totalRows - header
            var growth = 0

            if d > 0 {
                // Scrolled down. Interior movement writes nothing; at or past
                // the frontier the canvas tail from the new position on is
                // re-described by the frame — including a sticky footer, which
                // is rewritten every round and so appears exactly once at the
                // bottom, and mid-frame animations, which settle to their
                // final state.
                let newCursor = cursor + d
                let viewBottom = newCursor + frameBody
                if viewBottom >= frontier {
                    let removal = frontier - newCursor
                    guard removal >= 0, removal <= frontier else {
                        return .rejected(.cannotAlign)
                    }
                    canvas.removeLast(removal * bytesPerRow)
                    canvas.append(bytes[(header * bytesPerRow)...])
                    canvasSignatures.removeLast(removal * Self.componentsPerRow)
                    canvasSignatures.append(
                        contentsOf: signatures[(header * Self.componentsPerRow)...])
                    growth = viewBottom - frontier
                }
                cursor = newCursor
            } else {
                // Scrolled up. Rows revealed above the canvas top slot in
                // right under the frozen header; the memmove this costs is one
                // frame's worth of canvas shuffle, a few ms off the main
                // thread.
                let newCursor = cursor + d
                if newCursor < 0 {
                    let prepend = -newCursor
                    let insertAt = header * bytesPerRow
                    canvas.replaceSubrange(
                        insertAt..<insertAt,
                        with: bytes[(header * bytesPerRow)..<((header + prepend) * bytesPerRow)])
                    let signaturesAt = header * Self.componentsPerRow
                    canvasSignatures.replaceSubrange(
                        signaturesAt..<signaturesAt,
                        with: signatures[
                            signaturesAt..<((header + prepend) * Self.componentsPerRow)])
                    growth = prepend
                    cursor = 0
                } else {
                    cursor = newCursor
                }
            }

            refreshRevisited(signatures: signatures, bytes: bytes, header: header, suffix: suffix)

            lastSignatures = signatures
            lastFrame = bytes
            let total = totalRows
            if canvas.count > config.maxCanvasBytes {
                return .canvasFull(totalRows: total)
            }
            return growth > 0
                ? .appended(newRows: growth, totalRows: total)
                : .repositioned(totalRows: total)
        }
    }

    /// Re-describes revisited rows that have genuinely changed since they were
    /// first captured — a line frozen mid-fade while a chat was streaming
    /// heals when the user scrolls back over it after the page settles. Only
    /// rows whose signatures moved beyond tolerance are written, and never the
    /// sticky-bottom zone: `footerRows` (frozen) or this frame's own in-place
    /// suffix, whichever is taller.
    private func refreshRevisited(
        signatures: [Int16], bytes: Data, header: Int, suffix: Int
    ) {
        let bytesPerRow = pixelWidth * 4
        let componentsPerRow = Self.componentsPerRow
        let guardRows = max(footerRows ?? 0, suffix)
        let upperBound = max(header, pixelHeight - guardRows)
        for row in header..<upperBound {
            let canvasRow = cursor + row
            guard canvasRow >= header, canvasRow < totalRows else { continue }
            if !rowsMatch(canvasSignatures, canvasRow, signatures, row) {
                canvas.replaceSubrange(
                    canvasRow * bytesPerRow..<(canvasRow + 1) * bytesPerRow,
                    with: bytes[row * bytesPerRow..<(row + 1) * bytesPerRow])
                for component in 0..<componentsPerRow {
                    canvasSignatures[canvasRow * componentsPerRow + component] =
                        signatures[row * componentsPerRow + component]
                }
            }
        }
    }

    /// Wraps the canvas in a `CaptureResult` — the one sanctioned Sendable image
    /// box — so the caller gets file naming, staging, preview and the editor
    /// unchanged. Consumes the canvas: the image's data provider holds the only
    /// reference, no second copy is made, and the stitcher is spent.
    func finalize(
        sourceDisplayID: CGDirectDisplayID, sourceDescription: String
    ) -> CaptureResult? {
        let rows = totalRows
        guard rows > 0, pixelWidth > 0 else { return nil }
        let data = canvas
        canvas = Data()
        lastSignatures = []
        canvasSignatures = []
        lastFrame = Data()
        footerRows = nil
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: pixelWidth,
                height: rows,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return CaptureResult(
            image: image,
            pointSize: CGSize(
                width: CGFloat(pixelWidth) / scale, height: CGFloat(rows) / scale),
            scale: scale,
            sourceDisplayID: sourceDisplayID,
            sourceDescription: sourceDescription,
            capturedAt: Date()
        )
    }

    // MARK: - Alignment

    private enum Shift {
        /// Positive: content moved up (the user scrolled down). Negative:
        /// content moved down (the user scrolled up).
        case found(Int)
        /// The band between the in-place prefix and suffix is too small to hold
        /// any believable shift — the page is still, give or take a speck.
        case stillness
        case none
    }

    /// Smallest shift whose implied overlap agrees row-for-row within the
    /// match budget — by signature first, and then, because signatures cannot
    /// tell two lines of prose apart, by pixels. Downward candidates first
    /// (scrolling down is the common direction), then upward. Smallest, not
    /// best-scoring: on a repeating pattern every period-multiple matches,
    /// and the small answer errs toward output that is short, never toward a
    /// hole bridged by a guess.
    ///
    /// Two passes with different budgets. Strict first, for every candidate:
    /// what it accepts can be *written* at the canvas ends. Then lenient, for
    /// candidates that grow nothing: a page revisited after it finished
    /// changing (a chat that was streaming while first captured) diverges
    /// from the canvas by every settled line, more than the strict budget
    /// allows — but re-finding it can only reposition and refresh, so the
    /// worst a false match could write is rows the pixel check already vouched
    /// were 75 % identical in place.
    private func shift(
        from last: [Int16], to new: [Int16], newBytes: Data, prefix: Int, suffix: Int
    ) -> Shift {
        let bandLength = pixelHeight - suffix - prefix
        let maxShift = bandLength - config.minOverlapRows
        guard maxShift >= 1 else { return .stillness }

        if config.brokenOverlapSearchForTest {
            return .found(min(config.minOverlapRows, maxShift))
        }

        if let found = search(
            from: last, to: new, newBytes: newBytes, prefix: prefix,
            bandLength: bandLength, maxShift: maxShift,
            matchRatio: config.matchRatio, interiorOnly: false) {
            return .found(found)
        }
        if let found = search(
            from: last, to: new, newBytes: newBytes, prefix: prefix,
            bandLength: bandLength, maxShift: maxShift,
            matchRatio: config.revisitMatchRatio, interiorOnly: true) {
            return .found(found)
        }
        return .none
    }

    private func search(
        from last: [Int16], to new: [Int16], newBytes: Data, prefix: Int,
        bandLength: Int, maxShift: Int, matchRatio: Double, interiorOnly: Bool
    ) -> Int? {
        for magnitude in 1...maxShift {
            for candidate in [magnitude, -magnitude] {
                if interiorOnly, !isInterior(candidate) { continue }
                let overlap = bandLength - magnitude
                // The side that scrolled off leads: comparing last[+d] against
                // new[] is the downward case, and the mirror is upward.
                let lastOffset = prefix + max(candidate, 0)
                let newOffset = prefix + max(-candidate, 0)
                let budget = Int((1 - matchRatio) * Double(overlap))
                var mismatches = 0
                var i = 0
                while i < overlap {
                    if !rowsMatch(last, lastOffset + i, new, newOffset + i) {
                        mismatches += 1
                        if mismatches > budget { break }
                    }
                    i += 1
                }
                if i == overlap,
                   pixelConfirmation(
                    reference: lastFrame, referenceOffset: lastOffset,
                    newOffset: newOffset, newBytes: newBytes, overlap: overlap,
                    allowedFailRatio: 1 - matchRatio) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Whether shifting the viewport by `d` keeps it entirely inside content
    /// the canvas already has — the moves that write nothing new.
    private func isInterior(_ d: Int) -> Bool {
        let header = headerRows ?? 0
        let newCursor = cursor + d
        return newCursor >= 0
            && newCursor + (pixelHeight - header) <= totalRows - header
    }

    /// Finds the frame's below-header body inside the whole canvas — the
    /// recovery path for a lost thread. Only whole-body containment: the
    /// partial overlaps at either end are exactly what the frame-to-frame
    /// search already covers. Same two-stage proof as `shift` — signatures
    /// nominate, pixels confirm against the canvas itself — so a frame of
    /// content the canvas never saw cannot "relocate" anywhere.
    private func relocate(signatures: [Int16], bytes: Data) -> Int? {
        let header = headerRows ?? 0
        let frameBody = pixelHeight - header
        let bodyRows = totalRows - header
        guard bodyRows >= frameBody, frameBody > 0 else { return nil }

        // Lenient budgets, like the interior pass of `shift` and for the same
        // reason: a page that settled after being captured mid-stream differs
        // from the canvas by every line that finished arriving, and relocation
        // can only reposition and refresh, never write at the ends.
        let budget = Int((1 - config.revisitMatchRatio) * Double(frameBody))
        for candidate in 0...(bodyRows - frameBody) {
            var mismatches = 0
            var i = 0
            while i < frameBody {
                if !rowsMatch(canvasSignatures, header + candidate + i, signatures, header + i) {
                    mismatches += 1
                    if mismatches > budget { break }
                }
                i += 1
            }
            if i == frameBody,
               pixelConfirmation(
                reference: canvas, referenceOffset: header + candidate,
                newOffset: header, newBytes: bytes, overlap: frameBody,
                allowedFailRatio: 1 - config.revisitMatchRatio) {
                return candidate
            }
        }
        return nil
    }

    /// Whether the overlap `d` implies really shows the same pixels twice.
    ///
    /// Samples up to 48 rows spread across the overlap and compares every 4th
    /// pixel of each against the previous frame. The per-sample threshold is
    /// 24: the window server's dithering is not the ±1–3 it first measured as
    /// — on some colours it re-renders a row at a new screen position with a
    /// 32-px-periodic pattern of ±9–13 deltas (measured 2026-08-02 on the
    /// flow test's flat fills), while a glyph out of register moves samples by
    /// the content's own contrast, ~190 on ordinary text. The same
    /// `matchRatio` budget of rows may fail outright — an animated speck is
    /// one bad row, not a wrong shift. Rows whose sampled pixels span less
    /// than a flat background's noise carry no information, and a shift whose
    /// overlap has fewer than `minInformativeRows` of them is refused rather
    /// than trusted: background matches everything.
    private func pixelConfirmation(
        reference: Data, referenceOffset: Int, newOffset: Int, newBytes: Data, overlap: Int,
        allowedFailRatio: Double
    ) -> Bool {
        let rowBytes = pixelWidth * 4
        let sampleRows = min(48, overlap)
        let rowBudget = max(1, Int(allowedFailRatio * Double(sampleRows)))
        var informative = 0
        var failedRows = 0

        reference.withUnsafeBytes { lastRaw in
            newBytes.withUnsafeBytes { newRaw in
                guard let lastBase = lastRaw.bindMemory(to: UInt8.self).baseAddress,
                      let newBase = newRaw.bindMemory(to: UInt8.self).baseAddress else {
                    failedRows = sampleRows
                    return
                }
                for sample in 0..<sampleRows {
                    let i = overlap * sample / sampleRows
                    let lastRow = (referenceOffset + i) * rowBytes
                    let newRow = (newOffset + i) * rowBytes
                    var minValue = 255
                    var maxValue = 0
                    var offSamples = 0
                    var samples = 0
                    var x = 0
                    while x < rowBytes {
                        for channel in 0..<3 {
                            let a = Int(lastBase[lastRow + x + channel])
                            let b = Int(newBase[newRow + x + channel])
                            if abs(a - b) > 24 { offSamples += 1 }
                            if a < minValue { minValue = a }
                            if a > maxValue { maxValue = a }
                        }
                        samples += 3
                        x += 16
                    }
                    if maxValue - minValue > 24 { informative += 1 }
                    // 2 % of samples wildly off is not dithering.
                    if offSamples * 50 > samples {
                        failedRows += 1
                        if failedRows > rowBudget { return }
                    }
                }
            }
        }
        return failedRows <= rowBudget && informative >= config.minInformativeRows
    }

    private func rowsMatch(_ a: [Int16], _ aRow: Int, _ b: [Int16], _ bRow: Int) -> Bool {
        let ia = aRow * Self.componentsPerRow
        let ib = bRow * Self.componentsPerRow
        for k in 0..<Self.componentsPerRow
        where abs(a[ia + k] - b[ib + k]) > config.tolerance {
            return false
        }
        return true
    }

    // MARK: - Pixels

    /// One drawing pass into the fixed known-good layout — sRGB,
    /// premultipliedLast, 8 bpc — for the same reason `ImagePadding` uses it:
    /// captures can arrive as Display P3, and concatenating rows across two
    /// colour spaces is how seams appear.
    private nonisolated static func normalized(_ image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        var data = Data(count: width * 4 * height)
        let drawn = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    /// Per-segment channel means over every 4th pixel of the row. Means rather
    /// than hashes because the pixels themselves are not reproducible: the
    /// window server's dithering wobbles each one ±1–2 between composites, and
    /// a hash amplifies one wobbled byte into a different row. The mean of a
    /// hundred samples wobbles by a fraction of a level.
    private nonisolated static func rowSignatures(
        _ bytes: Data, width: Int, height: Int
    ) -> [Int16] {
        bytes.withUnsafeBytes { raw -> [Int16] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return [Int16](repeating: 0, count: height * componentsPerRow)
            }
            let rowBytes = width * 4
            let segmentWidth = max(1, width / segments)
            var signatures = [Int16](repeating: 0, count: height * componentsPerRow)
            for row in 0..<height {
                let rowStart = row * rowBytes
                for segment in 0..<segments {
                    let from = segment * segmentWidth
                    let to = segment == segments - 1 ? width : from + segmentWidth
                    var sums: (Int, Int, Int) = (0, 0, 0)
                    var count = 0
                    var x = from
                    while x < to {
                        let p = rowStart + x * 4
                        sums.0 += Int(base[p])
                        sums.1 += Int(base[p + 1])
                        sums.2 += Int(base[p + 2])
                        count += 1
                        x += 4
                    }
                    guard count > 0 else { continue }
                    let out = row * componentsPerRow + segment * 3
                    signatures[out] = Int16(sums.0 / count)
                    signatures[out + 1] = Int16(sums.1 / count)
                    signatures[out + 2] = Int16(sums.2 / count)
                }
            }
            return signatures
        }
    }
}
