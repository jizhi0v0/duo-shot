import AppKit
import Vision

/// Reading the words out of a capture, with Vision.
///
/// **Everything happens on this machine.** That is the point of using Vision
/// rather than any of the OCR services that would recognise more scripts more
/// accurately: a screenshot is whatever happened to be on screen — a password
/// manager, a medical record, somebody else's message — and an app that
/// silently posted those pixels to a server in exchange for a nicer transcript
/// would be trading something that is not ours to trade. Nothing here opens a
/// socket.
enum TextRecognition {
    /// The recognised lines of the image at `url`, joined top to bottom, or nil
    /// if the file cannot be read, Vision fails, or there was nothing to read.
    ///
    /// `@concurrent` rather than plain `nonisolated`, for the reason
    /// `StagingStore.encode` gives: under NonisolatedNonsendingByDefault an
    /// async function runs on its caller's executor, and every caller of this is
    /// on main. `.accurate` on a 5K capture is comfortably long enough to drop
    /// frames — measured at 0.4–1.2 s — so it has to leave.
    ///
    /// The **file** is the input, not the bitmap the card or the viewer is
    /// drawing. Both of those are downsampled to something that fits a 208 pt
    /// tile or a window, and recognition accuracy is a direct function of how
    /// many pixels a glyph has: OCR of the thumbnail would read a headline and
    /// miss every line of body text under it.
    @concurrent
    static func text(inFileAt url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Log.app.error("ocr: cannot read \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Vision otherwise recognises the languages of the user's locale and
        // nothing else, which silently mangles a screenshot of a page in a
        // language they merely read. Detection costs one pass over the image and
        // this request is already the expensive part of the operation.
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            Log.app.error("ocr: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let lines = (request.results ?? [])
            // Sorted here rather than trusted to arrive that way. Vision's order
            // is documented as confidence-related, not geometric, and a
            // transcript whose paragraphs are shuffled is worse than no
            // transcript — the reader cannot tell it happened.
            .sorted {
                let (a, b) = ($0.boundingBox, $1.boundingBox)
                // Normalised coordinates with the origin at the bottom left, so
                // "higher on screen" is a larger midY. Rows within half a line
                // height of each other are one row and go left to right.
                if abs(a.midY - b.midY) > max(a.height, b.height) / 2 {
                    return a.midY > b.midY
                }
                return a.minX < b.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// The "Copy Text" action, shared by the preview card and the viewer window.
///
/// Owns the two things that are policy rather than recognition: that success is
/// **silent** — every other clipboard write in DuoShot is, and a sound after
/// copying is a notification nobody asked for — and that failure beeps, because
/// the clipboard still holds whatever it held before and the user is about to
/// paste it believing otherwise.
enum CopyText {
    /// Files with recognition in flight. A second click while Vision is working
    /// would run the whole thing again and race the first one to the pasteboard;
    /// there is no busy indicator on the card to make the wait obvious, so the
    /// double click is likely rather than hypothetical.
    private static var inFlight: Set<URL> = []

    static func run(fileAt url: URL) {
        guard inFlight.insert(url).inserted else { return }
        Task {
            defer { inFlight.remove(url) }
            guard let text = await TextRecognition.text(inFileAt: url) else {
                // Nothing recognised and Vision failing are one outcome here on
                // purpose: from the user's side both are "I asked for the text
                // and there is no text", and the log already distinguishes them
                // for anyone who cares which.
                Log.app.error("""
                    copy text: nothing recognised in \
                    \(url.lastPathComponent, privacy: .public)
                    """)
                NSSound.beep()
                return
            }
            Clipboard.write(text: text)
        }
    }
}
