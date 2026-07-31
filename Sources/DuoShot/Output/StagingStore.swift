import AppKit
import UniformTypeIdentifiers

/// Every capture is encoded once, written here, and every later action operates
/// on that one file.
///
/// **Not `/tmp`.** Several apps — Mail in particular — attach a dropped file *by
/// reference*, so `/tmp` reaping breaks the attachment days later. Application
/// Support is stable and ours to prune.
@MainActor
final class StagingStore {
    static let shared = StagingStore()

    private let fileManager = FileManager.default
    private let retainedFileCount = 200

    private(set) lazy var directory: URL = {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DuoShot", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {}

    func stage(_ result: CaptureResult, as contentType: UTType, quality: Double) throws -> URL {
        let name = FilenameFormatter.filename(
            for: result, template: Preferences.shared.filenameTemplate, contentType: contentType)
        let url = uniqueURL(for: name)
        try ImageEncoder.write(
            result.image, to: url, as: contentType, scale: result.scale, quality: quality)
        return url
    }

    /// Reserves a staging path for a file that does not exist yet.
    ///
    /// A recording is written *by ScreenCaptureKit*, straight into staging, so
    /// unlike a screenshot there is nothing to encode and hand over — the path
    /// has to exist before the take starts. Everything after that is identical:
    /// one file, and "save" is a move.
    func reserve(fileExtension: String, at date: Date = .now) -> URL {
        let name = FilenameFormatter.filename(
            date: date, template: Preferences.shared.filenameTemplate,
            fileExtension: fileExtension)
        return uniqueURL(for: name)
    }

    /// "Save" is a move, not a re-encode: atomic and instant.
    func move(_ url: URL, to directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueURL(
            for: url.lastPathComponent, in: directory)
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    func prune() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        guard entries.count > retainedFileCount else { return }

        let sorted = entries.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for stale in sorted.dropFirst(retainedFileCount) {
            try? fileManager.removeItem(at: stale)
        }
        Log.app.notice("pruned \(sorted.count - self.retainedFileCount, privacy: .public) staged files")
    }

    private func uniqueURL(for name: String, in directory: URL? = nil) -> URL {
        let base = directory ?? self.directory
        var candidate = base.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        repeat {
            candidate = base
                .appendingPathComponent("\(stem) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}

enum FilenameFormatter {
    static let defaultTemplate = "DuoShot %Y-%m-%d at %H.%M.%S"

    static func filename(
        for result: CaptureResult, template: String, contentType: UTType
    ) -> String {
        format(template: template, date: result.capturedAt, contentType: contentType)
    }

    /// A name for an output that is not a screenshot, so has no `UTType` in the
    /// project's image-format sense.
    static func filename(date: Date, template: String, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = strftimeToUnicode(template)
        var stem = formatter.string(from: date)
        if stem.trimmingCharacters(in: .whitespaces).isEmpty {
            formatter.dateFormat = strftimeToUnicode(defaultTemplate)
            stem = formatter.string(from: date)
        }
        return "\(stem).\(fileExtension)"
    }

    /// What the Settings window shows under the template field.
    static func preview(template: String, contentType: UTType) -> String {
        format(template: template, date: .now, contentType: contentType)
    }

    /// A template rendered with no extension and no empty-template fallback —
    /// for showing what a single variable stands for on its chip.
    static func render(template: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = strftimeToUnicode(template)
        return formatter.string(from: date)
    }

    private static func format(template: String, date: Date, contentType: UTType) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = strftimeToUnicode(template)
        var stem = formatter.string(from: date)
        // A template that renders to nothing would produce a file called ".png".
        if stem.trimmingCharacters(in: .whitespaces).isEmpty {
            formatter.dateFormat = strftimeToUnicode(defaultTemplate)
            stem = formatter.string(from: date)
        }
        let ext = contentType.preferredFilenameExtension ?? "png"
        return "\(stem).\(ext)"
    }

    /// The template is written in familiar strftime syntax; DateFormatter wants
    /// Unicode patterns.
    ///
    /// Literal runs must be quoted, not just passed through: every ASCII letter
    /// is a pattern character to DateFormatter, so the innocuous " at " in the
    /// default template would otherwise render as an AM/PM marker.
    private static func strftimeToUnicode(_ template: String) -> String {
        let mapping: [Character: String] = [
            "Y": "yyyy", "m": "MM", "d": "dd", "H": "HH", "M": "mm", "S": "ss",
        ]

        var pattern = ""
        var literal = ""
        var characters = Substring(template)

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            // A literal single quote is written as two of them inside a quoted run.
            pattern += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }

        while let character = characters.first {
            characters = characters.dropFirst()
            guard character == "%", let token = characters.first else {
                literal.append(character)
                continue
            }
            characters = characters.dropFirst()
            if let replacement = mapping[token] {
                flushLiteral()
                pattern += replacement
            } else {
                // "%%" and anything unrecognised stay literal.
                literal.append(token)
            }
        }
        flushLiteral()
        return pattern
    }
}
