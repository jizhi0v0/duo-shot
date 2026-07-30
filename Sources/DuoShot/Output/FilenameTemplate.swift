import Foundation

/// The filename template as a list of parts instead of one opaque string.
///
/// The string form (`DuoShot %Y-%m-%d at %H.%M.%S`) is still what gets stored and
/// what `FilenameFormatter` renders — this is a lossless view of it, so the UI can
/// show one chip per part. That matters for more than looks: a single text field
/// holding the whole template can be wiped by one keystroke while its text is
/// selected, which is exactly how a template became "么".
enum FilenameTemplate {
    /// The tokens `FilenameFormatter.strftimeToUnicode` understands. Adding one
    /// here without adding it there produces a chip that renders as literal text.
    enum Variable: String, CaseIterable, Identifiable, Sendable {
        case year = "Y"
        case month = "m"
        case day = "d"
        case hour = "H"
        case minute = "M"
        case second = "S"

        var id: String { rawValue }
        var token: String { "%\(rawValue)" }

        var label: String {
            switch self {
            case .year: "Year"
            case .month: "Month"
            case .day: "Day"
            case .hour: "Hour"
            case .minute: "Minute"
            case .second: "Second"
            }
        }

        /// What this variable looks like right now — "2026", "07", …
        func sample(at date: Date = .now) -> String {
            FilenameFormatter.render(template: token, date: date)
        }
    }

    enum Segment: Equatable, Identifiable, Sendable {
        case variable(Variable)
        case text(String)

        var id: String {
            switch self {
            case .variable(let variable): "v\(variable.rawValue)"
            case .text(let text): "t\(text)"
            }
        }

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    /// Splits a stored template into chips.
    ///
    /// Unknown escapes follow the renderer: `%%` is a literal percent and any
    /// other `%x` renders as a bare `x`, so both come back as text.
    static func parse(_ template: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var characters = Substring(template)

        func flush() {
            guard !literal.isEmpty else { return }
            segments.append(.text(literal))
            literal = ""
        }

        while let character = characters.first {
            characters = characters.dropFirst()
            guard character == "%", let next = characters.first else {
                literal.append(character)
                continue
            }
            characters = characters.dropFirst()
            if let variable = Variable(rawValue: String(next)) {
                flush()
                segments.append(.variable(variable))
            } else {
                literal.append(next)
            }
        }
        flush()
        return segments
    }

    /// The inverse of `parse`. A literal `%` is re-escaped so a round trip
    /// through the chip editor cannot turn text into a token.
    static func string(from segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .variable(let variable): variable.token
            case .text(let text): text.replacingOccurrences(of: "%", with: "%%")
            }
        }.joined()
    }
}
