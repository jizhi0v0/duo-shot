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
/// DuoShot that keeps the words after the window has closed. The index is a
/// file in Application Support, alongside the staging directory, readable by
/// this user and nobody else.
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
        guard let data = try? Data(contentsOf: location),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded.sorted { $0.capturedAt > $1.capturedAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic, because this is rewritten after every capture and a crash
            // half way through would lose the whole index rather than one entry.
            try JSONEncoder().encode(entries).write(to: location, options: .atomic)
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
