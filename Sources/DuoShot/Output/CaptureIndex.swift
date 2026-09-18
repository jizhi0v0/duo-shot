import Foundation

/// What was written in each capture, so it can be found again by what it said.
///
/// The problem this solves is the one a screenshot folder always has: the
/// filenames are timestamps, the thumbnails are 200 pixels wide, and the only
/// thing anybody remembers about the one they want is a word that was in it.
/// Vision already reads these captures for "Copy Text"; keeping what it read
/// turns a folder of dated rectangles into something answerable.
///
/// **Nothing leaves the machine**, for the reason `TextRecognition` gives —
/// and it matters more here than there, because this is the one place in
/// DuoShot that keeps the words after the window has closed.
///
/// What that does *not* mean: the index is a file in Application Support,
/// alongside the staging directory, and the only thing keeping another user off
/// it is that `~/Library` is `0700`. That is the wrong threat. This file is a
/// plaintext transcript of every screenshot the user has taken — which is to say
/// of every password manager, token, private message and bank page that was on
/// screen when they pressed the shortcut — and the processes that can read it are
/// every process running as **this** user: any app they install, any script, any
/// npm postinstall. Sandboxed apps cannot reach it; nothing else is stopped by
/// the directory alone. So the file itself is `0600` and the directory `0700`
/// (see `save()`), which removes group and other. It is not encrypted, and
/// `0600` does not pretend to stop code already running as this user that goes
/// looking for it.
///
/// An `actor` for the reason `ScrollStitcher` is one: it carries state across
/// calls, indexing happens off the main thread behind every capture, and the
/// alternative was another `@unchecked Sendable`.
actor CaptureIndex {
    static let shared = CaptureIndex()

    struct Entry: Codable, Sendable, Equatable {
        /// Stored as a path rather than a URL: a `URL` encodes with its scheme
        /// and its relative-base, and one written by an earlier build has to
        /// stay decodable.
        var path: String
        var name: String
        var capturedAt: Date
        var text: String
    }

    struct Hit: Sendable, Equatable {
        var url: URL
        var name: String
        var capturedAt: Date
        /// The line the query was found in. A capture's transcript is the whole
        /// screen, so showing it whole would be a wall of text per row; the line
        /// that matched is the part that answers "is this the one".
        var snippet: String
    }

    /// Captures whose text is kept. Well past what `StagingStore` retains, since
    /// an entry is a few kilobytes of text rather than a file — but not
    /// unbounded, because this is a convenience and not an archive.
    private static let capacity = 5000

    private var entries: [Entry] = []
    private var loaded = false
    private let location: URL

    /// - Parameter location: for the self-test, which must not write into the
    ///   user's real history. **One instance per file.** Each holds its own copy
    ///   of the entries in memory and writes the whole lot on every change, so
    ///   two over one path will silently overwrite each other. The app has
    ///   `shared` and nothing else.
    init(location: URL? = nil) {
        self.location = location ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DuoShot", isDirectory: true)
            .appendingPathComponent("capture-index.json")
    }

    // MARK: - The part that needs no camera

    /// Files it back under `url`, replacing any earlier record of the same file.
    ///
    /// Separate from `index(_:)` so the whole of search can be tested against
    /// text that is known exactly, rather than against whatever OCR made of a
    /// fixture that day.
    func record(_ url: URL, text: String, capturedAt: Date) {
        load()
        entries.removeAll { $0.path == url.path }
        entries.append(Entry(
            path: url.path, name: url.lastPathComponent,
            capturedAt: capturedAt, text: text))
        entries.sort { $0.capturedAt > $1.capturedAt }
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        save()
    }

    /// Newest first.
    ///
    /// Every whitespace-separated token has to appear somewhere in the capture,
    /// in its text or its filename — an AND rather than an OR, because the
    /// second word someone types is there to narrow the answer, not to widen it.
    ///
    /// Matching is by substring, not by word. Chinese does not put spaces
    /// between words, so a word-boundary match would find nothing at all in
    /// exactly the captures this user takes most.
    func search(_ query: String, limit: Int = 200) -> [Hit] {
        load()
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { folded(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return entries.prefix(limit).map {
                Hit(url: URL(fileURLWithPath: $0.path), name: $0.name,
                    capturedAt: $0.capturedAt, snippet: firstLine(of: $0.text))
            }
        }

        var hits: [Hit] = []
        for entry in entries {
            let haystack = folded(entry.text + "\n" + entry.name)
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            hits.append(Hit(
                url: URL(fileURLWithPath: entry.path), name: entry.name,
                capturedAt: entry.capturedAt,
                snippet: line(of: entry.text, containing: tokens[0])
                    ?? firstLine(of: entry.text)))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Drops entries whose files are gone. Captures are pruned from staging and
    /// deleted from the save folder by hand, and a search result that opens
    /// nothing is worse than one row fewer.
    @discardableResult
    func forgetMissingFiles() -> Int {
        load()
        let before = entries.count
        entries.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if entries.count != before { save() }
        return before - entries.count
    }

    func forget(_ url: URL) {
        load()
        entries.removeAll { $0.path == url.path }
        save()
    }

    var count: Int {
        load()
        return entries.count
    }

    // MARK: - The part that does

    /// Reads `url` and files what it finds. No-op for a file already indexed,
    /// so re-running over a folder is cheap.
    func index(_ url: URL, capturedAt: Date = .now) async {
        load()
        guard !entries.contains(where: { $0.path == url.path }) else { return }
        // Recorded even when nothing is recognised. The alternative is retrying
        // Vision on every screenshot of a photograph, for ever, at a second a
        // go -- and "this one has no words in it" is a real answer.
        let text = await TextRecognition.text(inFileAt: url) ?? ""
        record(url, text: text, capturedAt: capturedAt)
    }

    // MARK: - On disk

    private func load() {
        guard !loaded else { return }
        loaded = true
        // An index written by a build before the mode was closed is 0644 on disk,
        // and `save()` only reaches it at the next capture. Tightening it on the
        // way in means an install that is never captured into again still stops
        // being readable by everything running as this user.
        try? FileManager.default.setAttributes(
            [.posixPermissions: Self.fileMode], ofItemAtPath: location.path)
        guard let data = try? Data(contentsOf: location),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Mode of the index file. Owner read/write, nothing for group or other.
    private static let fileMode: Int = 0o600
    /// Mode of the `DuoShot` directory in Application Support. `Staging` lives in
    /// it, so closing it costs nothing and covers more than this one file.
    private static let directoryMode: Int = 0o700

    /// Written by hand rather than by `Data.write(options: .atomic)`.
    ///
    /// The trade-off, because it is not obvious and the obvious version is wrong
    /// twice over. `.atomic` writes a temp file and renames it, and the temp file
    /// is created at `0644` — so permissions set on the *old* file do not survive
    /// a rewrite, and a `chmod` after the rename leaves a window in which the
    /// whole transcript is world-readable. `createFile(attributes:)` gets the mode
    /// right and is not atomic, which would trade a privacy bug for losing the
    /// index on a crash — and this is rewritten after every capture, so a crash
    /// mid-write is not hypothetical.
    ///
    /// So: create the temp file with the mode already on it, then `rename(2)` it
    /// into place. `rename` is atomic within a directory and carries the mode
    /// across, which is what makes this hold on the thousandth rewrite and not
    /// only on first creation. The cost is the one thing `.atomic` did for free —
    /// if the process dies between the two, a `.capture-index.json.new` is left
    /// behind; it is overwritten by the next save and never read.
    private func save() {
        do {
            let directory = location.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryMode])
            // `attributes:` above applies only when the directory is created, and
            // every install from before this change has it at 0755.
            try? FileManager.default.setAttributes(
                [.posixPermissions: Self.directoryMode], ofItemAtPath: directory.path)

            let temp = directory
                .appendingPathComponent(".\(location.lastPathComponent).new")
            try? FileManager.default.removeItem(at: temp)
            guard FileManager.default.createFile(
                atPath: temp.path, contents: try JSONEncoder().encode(entries),
                attributes: [.posixPermissions: Self.fileMode])
            else { throw CocoaError(.fileWriteUnknown) }
            guard rename(temp.path, location.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Log.app.error("capture index: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Matching

    /// Case- and diacritic-insensitive, and width-insensitive: a full-width
    /// ＡＢＣ pasted out of a Chinese input method has to match `abc`.
    private func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil)
    }

    private func line(of text: String, containing token: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first { folded(String($0)).contains(token) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func firstLine(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
