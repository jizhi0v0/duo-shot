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
    /// A second cap, in bytes, because the count alone does not bound this
    /// directory: recordings are written here too, and 200 of those is hundreds
    /// of gigabytes. Applied oldest-first on top of the count.
    private let retainedByteBudget = 2 * 1024 * 1024 * 1024

    private(set) lazy var directory: URL = {
        let base = root ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DuoShot", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Where a capture goes when the move into the save directory failed.
    ///
    /// A subdirectory rather than a flag on the file, because the directory *is*
    /// the ledger: `prune()` only ever sees a directory listing, so the exemption
    /// has to be something a listing can express. It also survives the relaunch
    /// `ScreenPermission.relaunch()` performs after a re-grant — which is one of
    /// the situations in which saves start failing, so an in-memory set would
    /// evaporate exactly when it is load-bearing. And unlike an extended
    /// attribute it is legible: a folder called `Unsaved` answers "which of these
    /// two hundred identical timestamps is the one that never made it" without
    /// any code at all.
    ///
    /// Deliberately **not** pruned. Being pruned is the thing this exists to
    /// prevent, so it is bounded by visibility instead — the menu-bar notice says
    /// how many are in here, and `prune()` logs its size every time it runs.
    private(set) lazy var unsavedDirectory: URL = {
        let base = directory.appendingPathComponent("Unsaved", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Non-nil only under test.
    private let root: URL?

    /// - Parameter directory: for the self-test, which must not prune the user's
    ///   real staging folder. **One instance per directory**, for the reason
    ///   `CaptureIndex.init(location:)` gives: two stores over one path would
    ///   prune each other's files. The app has `shared` and nothing else.
    init(directory: URL? = nil) { self.root = directory }

    /// Encodes the capture into staging and returns where it landed.
    ///
    /// `async` because the encode is the expensive half: a 5K screenshot is a
    /// ~59 MB bitmap to PNG- or HEIC-compress, and doing that on the main thread
    /// froze the app for the length of every capture. The name and the unique
    /// path are still decided here, on the main actor — but that alone is not
    /// enough: see `pendingPaths`.
    func stage(_ result: CaptureResult, as contentType: UTType, quality: Double) async throws -> URL {
        let name = FilenameFormatter.filename(
            for: result, template: Preferences.shared.filenameTemplate, contentType: contentType)
        let url = uniqueURL(for: name)
        pendingPaths.insert(url.path)
        // On success the file is on disk before this runs, so the existence
        // check takes over; on failure the name goes back into circulation.
        defer { pendingPaths.remove(url.path) }
        try await Self.encode(result, to: url, as: contentType, quality: quality)
        return url
    }

    /// Paths handed out whose files do not exist on disk yet: a screenshot
    /// whose encode is still in flight off-main, a recording whose writer has
    /// not opened the file. `uniqueURL`'s existence check cannot see either, so
    /// without this two captures in the same second — the filename template
    /// resolves to seconds — are offered the *same* path and the second encode
    /// overwrites the first.
    private var pendingPaths: Set<String> = []

    /// `@concurrent` rather than plain `nonisolated`: under
    /// NonisolatedNonsendingByDefault a nonisolated async function runs on the
    /// caller's executor, which here is the main actor — the one place this must
    /// not run. `CaptureResult` is already Sendable (its `CGImage` is immutable),
    /// so the whole result crosses rather than the bare image.
    @concurrent
    private nonisolated static func encode(
        _ result: CaptureResult, to url: URL, as contentType: UTType, quality: Double
    ) async throws {
        try ImageEncoder.write(
            result.image, to: url, as: contentType, scale: result.scale, quality: quality)
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
        let url = uniqueURL(for: name)
        // No matching remove: the entry retires itself the next time
        // `uniqueURL` runs after the writer has opened the file. If the start
        // fails and the file is deleted instead, the entry lingers and the
        // worst case is a cosmetic " 2" suffix on a later same-second name.
        pendingPaths.insert(url.path)
        return url
    }

    /// Moves a capture whose save failed out of prune's reach.
    ///
    /// The user believes this file is in their save folder and it is not. Left in
    /// staging it would be deleted the moment 200 newer captures landed on top of
    /// it — about three days at a heavy user's rate — with the beep at the time
    /// being the only thing that ever said so.
    /// Does not throw: its only caller has already failed once and has nowhere
    /// better to go. If even this move fails the file stays in staging — where
    /// prune can still take it — and both errors are in the log.
    func quarantine(_ url: URL) -> URL {
        let destination = uniqueURL(for: url.lastPathComponent, in: unsavedDirectory)
        do {
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            Log.app.error(
                "quarantine failed: \(error.localizedDescription, privacy: .public)")
            return url
        }
    }

    /// How many captures are sitting in `unsavedDirectory`, for the notice that
    /// makes them visible. Zero is the ordinary answer.
    func unsavedCount() -> Int {
        (try? fileManager.contentsOfDirectory(
            at: unsavedDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.count ?? 0
    }

    /// "Save" is a move, not a re-encode: atomic and instant.
    func move(_ url: URL, to directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueURL(
            for: url.lastPathComponent, in: directory)
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Keeps staging under both caps: newest `retainedFileCount` files, and no
    /// more than `retainedByteBudget` of them.
    ///
    /// Resource values are read once per file, up front. The comparator used to
    /// do the `resourceValues` call itself, so a sort at the 200-file cap made
    /// ~3000 of them — on the main thread, after every capture.
    func prune() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
        ]
        // Directories are skipped, and `unsavedDirectory` is why this matters:
        // a subdirectory is an ordinary entry in the listing with a nil file
        // size, and `removeItem` on a directory is recursive — so without this
        // the first prune past the cap would take the whole quarantine with it.
        let stat = entries.compactMap { url -> (url: URL, date: Date, size: Int)? in
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true { return nil }
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        // Newest first, so "keep" is a prefix under both caps.
        let sorted = stat.sorted { $0.date > $1.date }

        var kept = 0
        var keptBytes = 0
        var removed = 0
        // Latched rather than re-tested per file, so the cut is a clean age
        // boundary: without it a small old file would slip in behind a large
        // newer one that had just been deleted.
        var full = false
        for file in sorted {
            // The newest file is kept whatever its size. A take larger than the
            // whole budget must not delete itself the moment it lands.
            if !full, kept > 0,
               kept >= retainedFileCount || keptBytes + file.size > retainedByteBudget {
                full = true
            }
            guard full else {
                kept += 1
                keptBytes += file.size
                continue
            }
            try? fileManager.removeItem(at: file.url)
            removed += 1
        }
        // Said every time there is anything in quarantine, not only when
        // something was pruned: the folder is deliberately unbounded, so the log
        // is half of what keeps its growth from being silent. The notice in the
        // menu bar is the other half.
        let unsaved = unsavedCount()
        if unsaved > 0 {
            Log.app.notice("\(unsaved, privacy: .public) captures held in Unsaved")
        }
        guard removed > 0 else { return }
        Log.app.notice("pruned \(removed, privacy: .public) staged files")
    }

    private func uniqueURL(for name: String, in directory: URL? = nil) -> URL {
        // Entries whose file has since landed are the disk check's job now.
        pendingPaths = pendingPaths.filter { !fileManager.fileExists(atPath: $0) }
        func isTaken(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.path) || pendingPaths.contains(url.path)
        }

        let base = directory ?? self.directory
        var candidate = base.appendingPathComponent(name)
        guard isTaken(candidate) else { return candidate }

        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        repeat {
            candidate = base
                .appendingPathComponent("\(stem) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        } while isTaken(candidate)
        return candidate
    }
}

enum FilenameFormatter {
    static let defaultTemplate = "DuoShot %Y-%m-%d at %H.%M.%S"

    /// One formatter, reused. Two reasons, and the second is the load-bearing
    /// one: constructing a `DateFormatter` costs milliseconds and this runs per
    /// capture plus per SwiftUI render of the template chips — and an unpinned
    /// formatter renders `yyyy` in the user's numbering system, so an `ar`
    /// locale would put Eastern Arabic digits into filenames. `en_US_POSIX` is
    /// the standard fixed-digits, fixed-calendar pin.
    ///
    /// Shared safely because everything here is MainActor (module default) and
    /// nothing suspends between setting `dateFormat` and reading the string.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func filename(
        for result: CaptureResult, template: String, contentType: UTType
    ) -> String {
        format(template: template, date: result.capturedAt, contentType: contentType)
    }

    /// A name for an output that is not a screenshot, so has no `UTType` in the
    /// project's image-format sense.
    static func filename(date: Date, template: String, fileExtension: String) -> String {
        let formatter = Self.formatter
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
        let formatter = Self.formatter
        formatter.dateFormat = strftimeToUnicode(template)
        return formatter.string(from: date)
    }

    private static func format(template: String, date: Date, contentType: UTType) -> String {
        let formatter = Self.formatter
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
