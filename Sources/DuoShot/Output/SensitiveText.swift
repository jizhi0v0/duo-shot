import CoreGraphics
import Foundation
import Vision

/// Finding the things in a capture that should not have been in it.
///
/// A screenshot is whatever happened to be on screen, and the reason redaction
/// exists is that "whatever happened to be on screen" regularly includes an
/// address, a key, or somebody's card. Remembering to cover those is a
/// discipline, and a discipline is a thing people are good at until the one time
/// they are in a hurry. This turns it into a default.
///
/// **Nothing here opens a socket**, for the reason `TextRecognition` gives at
/// more length: the whole point of doing this on the machine is that the pixels
/// being searched for secrets are exactly the pixels nobody should be sending
/// anywhere. The recognised strings are not logged either — a log line reading
/// `found card 4111...` would put the thing back in a file, which is the failure
/// this feature exists to prevent.
///
/// Two layers, deliberately separable. `matches(in:)` is pure: a string in,
/// ranges out, no Vision, no image, no I/O — so every pattern and every
/// *non*-match can be asserted exactly. `findings(inFileAt:pointSize:)` is the
/// half that needs a camera pointed at the world, and it can only ever be
/// tested as well as OCR happens to read that day.
nonisolated enum SensitiveText {
    enum Kind: String, Sendable, CaseIterable {
        case email
        case ipAddress
        case phone
        case card
        case secret
    }

    struct Finding: Sendable, Equatable {
        let kind: Kind
        /// Image points, origin bottom left — the space `ImageEdit` works in, so
        /// this can go straight into `.redact` with no conversion at the call
        /// site to get wrong.
        let rect: CGRect
    }

    // MARK: - The patterns
    //
    // Tuned for precision over recall, because the two errors are not
    // symmetrical. A miss leaves the user exactly where they were: looking at
    // their own screenshot with the redact tool one key away. A false positive
    // silently destroys pixels they wanted, in a feature whose whole promise is
    // that the destruction is real. So anything that needs a "probably" is left
    // out, and the one pattern here that is otherwise all false positives --
    // sixteen digits in a row -- carries a checksum.

    private static let patterns: [(kind: Kind, expression: NSRegularExpression)] = {
        let sources: [(Kind, String)] = [
            (.email, #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
            // Each octet bounded, so 999.1.1.1 is not an address and a version
            // number with four parts mostly is not either.
            (.ipAddress,
             #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#),
            // Named shapes only. A generic "long string of letters and digits"
            // matches a commit hash, a filename and a UUID far more often than
            // it matches a key.
            (.secret, #"\bsk-[A-Za-z0-9_-]{16,}\b"#),
            (.secret, #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
            (.secret, #"\bAKIA[0-9A-Z]{16}\b"#),
            (.secret, #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#),
            // A JWT is three base64url segments, and the first one is always the
            // encoding of `{"alg":`, so it always begins eyJ.
            (.secret, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
            (.secret, #"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}={0,2}"#),
            // Mainland mobile numbers, which is what a capture taken on this
            // machine is most likely to contain, plus anything written in E.164.
            (.phone, #"(?<![0-9])1[3-9]\d{9}(?![0-9])"#),
            (.phone, #"(?<![0-9+])\+\d{1,3}[ -]?(?:\d[ -]?){7,13}\d(?![0-9])"#),
            // Every 13-to-19-digit run; `isCard` throws out the ones that are not
            // card numbers, which is nearly all of them.
            (.card, #"(?<![0-9])(?:\d[ -]?){12,18}\d(?![0-9])"#),
        ]
        return sources.compactMap { kind, source in
            (try? NSRegularExpression(pattern: source)).map { (kind, $0) }
        }
    }()

    /// Every match in one line of text, overlaps resolved, in the order they
    /// appear.
    ///
    /// Pure and synchronous on purpose: this is the half of the feature that can
    /// be held to an exact answer, and holding it to one is what stops the
    /// patterns above from quietly rotting behind a Vision call that is hard to
    /// pin down.
    static func matches(in line: String) -> [(kind: Kind, range: Range<String.Index>)] {
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        var found: [(kind: Kind, range: Range<String.Index>, length: Int)] = []
        for (kind, expression) in patterns {
            for result in expression.matches(in: line, range: whole) {
                guard let range = Range(result.range, in: line) else { continue }
                let text = String(line[range])
                if kind == .card, !isCard(text) { continue }
                found.append((kind, range, result.range.length))
            }
        }
        // Longest first, so a card number is not reported as the phone number
        // hiding inside it, and an email is not reported as the address in its
        // domain. Then anything overlapping something already taken is dropped.
        found.sort { $0.length > $1.length }
        var kept: [(kind: Kind, range: Range<String.Index>)] = []
        for candidate in found
        where !kept.contains(where: { $0.range.overlaps(candidate.range) }) {
            kept.append((candidate.kind, candidate.range))
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Luhn, over a run of digits of a plausible length.
    ///
    /// This is the only thing standing between "redact card numbers" and
    /// "redact order numbers, timestamps and phone numbers as well". Every card
    /// scheme in use checksums this way, and an arbitrary 16-digit number passes
    /// one time in ten.
    static func isCard(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Against a real capture

    /// What Vision can see in the file, turned into rectangles in image points.
    ///
    /// `@concurrent` for the reason `TextRecognition.text` gives: `.accurate`
    /// recognition of a 5K capture takes long enough to drop frames, and every
    /// caller is on main.
    @concurrent
    static func findings(inFileAt url: URL, pointSize: CGSize) async -> [Finding] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // **Off**, unlike the transcript path, and this is the difference that
        // decides whether the feature works at all. Language correction exists
        // to turn what the camera saw into what a person would have written,
        // and none of these are words: it rewrites a key's characters into
        // something pronounceable and helpfully repairs a mistyped domain. The
        // string this needs is the one on the screen, wrong characters and all.
        request.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            Log.app.error("redact scan: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var findings: [Finding] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            for match in matches(in: line) {
                // Vision reports the box for a sub-range by re-deriving it from
                // the recognised glyphs, so ask it rather than interpolating
                // across the line's own box -- proportional text makes that
                // guess wrong by a character or more, and a redaction one
                // character short is not a redaction.
                guard let box = try? candidate.boundingBox(for: match.range) else { continue }
                let normalised = box.boundingBox
                let rect = CGRect(
                    x: normalised.minX * pointSize.width,
                    y: normalised.minY * pointSize.height,
                    width: normalised.width * pointSize.width,
                    height: normalised.height * pointSize.height)
                // Outwards a little. The box hugs the ink, and the pixels that
                // let a reader recover a glyph are the antialiased ones just
                // outside it.
                findings.append(Finding(
                    kind: match.kind, rect: rect.insetBy(dx: -2, dy: -2)))
            }
        }
        return findings
    }
}
