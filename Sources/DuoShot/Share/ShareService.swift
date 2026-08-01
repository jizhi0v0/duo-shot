import AVFoundation
import AppKit
import Linkdrop

/// The app's side of sharing: policy, lifetime and everything that touches UI.
///
/// `Linkdrop` knows how to upload a file. It deliberately does not know that a
/// capture has a preview card, that the card times out, or that the link should
/// land on the clipboard. All of that is here.
///
/// **An upload does not belong to the card that started it.** A card times out
/// after six seconds; a recording can take a minute. So this object owns the
/// task, the card merely subscribes, and a finished upload still copies its link
/// and reaches the menu bar even if nothing is on screen any more.
@Observable
@MainActor
final class ShareService {
    static let shared = ShareService()

    enum State: Equatable {
        case uploading(Double)
        case done(LinkdropLink)
        case failed(String, retryable: Bool)
    }

    /// Keyed by the capture's file URL, which `StagingStore` already guarantees
    /// is unique per capture.
    private(set) var states: [URL: State] = [:]

    private let uploader = LinkdropUploader()
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var observers: [URL: [(State) -> Void]] = [:]

    /// Captures that were asked to go up as one-time links.
    ///
    /// Kept here rather than passed along because `retry` only has the entry: a
    /// retry that quietly produced an ordinary permanent link would be the worst
    /// possible outcome of a button whose whole point is that the file is not
    /// meant to survive being looked at.
    private var oneTime: Set<URL> = []

    /// Where the reason a dropped file could not be shared is shown, and nil to
    /// take the last one back down.
    ///
    /// A capture reports itself on its preview card. A file dragged onto the
    /// menu bar has no card, so without this the only evidence of a refusal
    /// would be a beep and a line in Console. The menu bar item is what took the
    /// drop, so its menu is where the sentence belongs; `StatusItemController`
    /// owns the wording of the row.
    var onDropNotice: ((String?) -> Void)?

    /// The Keychain item. Service string rather than the app's bundle id so the
    /// token survives a bundle rename, and so two builds of the same app share it.
    static let credentials = LinkdropCredentials(service: "com.boli.duoshot.share")

    private init() {}

    var isConfigured: Bool { ShareSettings.shared.endpoint != nil }

    func state(for url: URL) -> State? { states[url] }

    /// Lets a card follow an upload that may have started before it existed.
    func observe(_ url: URL, _ onChange: @escaping (State) -> Void) {
        observers[url, default: []].append(onChange)
        if let state = states[url] { onChange(state) }
    }

    func stopObserving(_ url: URL) {
        observers[url] = nil
    }

    var isUploading: Bool {
        states.values.contains { if case .uploading = $0 { true } else { false } }
    }

    var inFlightCount: Int {
        states.values.count { if case .uploading = $0 { true } else { false } }
    }

    func isUploading(_ url: URL) -> Bool {
        if case .uploading = states[url] { true } else { false }
    }

    /// Whether this capture's card must stay on screen.
    ///
    /// Uploading, obviously. But **also failed**: the card is the only place the
    /// reason is shown, and a six-second timer would take the sentence away
    /// before it had been read — leaving a capture the user believes was shared
    /// and a link that does not exist. A failed card waits to be dismissed or
    /// retried by hand.
    func isPinned(_ url: URL) -> Bool {
        switch states[url] {
        case .uploading, .failed: true
        case .done, .none: false
        }
    }

    // MARK: - Starting

    /// Idempotent: asking twice for the same capture does not upload it twice,
    /// which matters because the card's button and the auto-upload preference can
    /// both fire for one capture.
    ///
    /// - Parameter burnAfterReading: The service deletes the file after the
    ///   first complete read. Only honoured for a still — a video is fetched in
    ///   ranges, so there is no first complete read — and the service refuses it
    ///   for anything else regardless of what is asked here.
    func share(_ entry: PreviewEntry, burnAfterReading: Bool = false) {
        guard tasks[entry.url] == nil else { return }
        if case .done = states[entry.url] { return }

        guard let endpoint = ShareSettings.shared.endpoint else {
            publish(.failed("Set a share endpoint and token in Settings.", retryable: false),
                    for: entry.url)
            return
        }

        if burnAfterReading && !entry.isVideo {
            oneTime.insert(entry.url)
        } else {
            oneTime.remove(entry.url)
        }

        publish(.uploading(0), for: entry.url)
        let url = entry.url
        tasks[url] = Task { [weak self] in
            await self?.run(entry, endpoint: endpoint)
            self?.tasks[url] = nil
        }
    }

    func retry(_ entry: PreviewEntry) {
        states[entry.url] = nil
        share(entry, burnAfterReading: oneTime.contains(entry.url))
    }

    // MARK: - Files that were never captured

    /// Whether a file is worth accepting from a drag at all.
    ///
    /// The gate's own answer, asked before the drop rather than after it, so a
    /// file nothing could do anything with shows no drop cursor instead of
    /// beeping once it has been let go of.
    nonisolated static func canShare(fileAt url: URL) -> Bool {
        LinkdropGate.medium(of: url) != nil
    }

    /// Shares a file that is not a capture: no `PreviewEntry`, no thumbnail and
    /// no card.
    ///
    /// Everything after the plan is deliberately identical to `share(_:)` — the
    /// ephemeral settings by kind, the history row, the clipboard format, the
    /// sound — because a file should not be treated differently for having
    /// arrived by hand. What differs is the reporting: the card is a capture's
    /// failure surface and there is none here, so a refusal goes to
    /// `onDropNotice` as well as to the beep.
    ///
    /// Idempotent through the same `tasks` and `states` maps as `share(_:)`, so
    /// dropping the same file again while it is still going up is one upload,
    /// and dropping one already shared this session is none.
    func share(fileAt url: URL) {
        guard tasks[url] == nil else { return }
        if case .done = states[url] { return }

        guard let endpoint = ShareSettings.shared.endpoint else {
            failDrop("Set a share endpoint and token in Settings.", for: url, retryable: false)
            return
        }
        guard let medium = LinkdropGate.medium(of: url) else {
            failDrop("\(url.lastPathComponent) is not a kind of file that can be shared.",
                     for: url, retryable: false)
            return
        }

        publish(.uploading(0), for: url)
        tasks[url] = Task { [weak self] in
            await self?.runDrop(url, medium: medium, endpoint: endpoint)
            self?.tasks[url] = nil
        }
    }

    private func runDrop(
        _ url: URL, medium: LinkdropGate.Medium, endpoint: LinkdropEndpoint
    ) async {
        let outcome: LinkdropGate.Outcome
        switch medium {
        case .image:
            // No point size, because nothing here has opened the file. That is
            // the honest answer: a made-up one would be what the page lays the
            // image out at.
            outcome = LinkdropGate.plan(
                image: url, ephemeral: ShareSettings.shared.ephemeralScreenshots)
        case .video:
            let duration = await Self.duration(of: url)
            outcome = await LinkdropGate.plan(
                video: url, duration: duration,
                ephemeral: ShareSettings.shared.ephemeralRecordings)
        }

        guard case .ok(let plan) = outcome else {
            if case .refused(let reason) = outcome {
                failDrop(reason, for: url, retryable: false)
            }
            return
        }

        do {
            let link = try await uploader.upload(plan, to: endpoint) { fraction in
                // Progress arrives on URLSession's queue.
                Task { @MainActor [weak self] in
                    self?.publishProgress(fraction, for: url)
                }
            }

            // Same reason a recording gets one: without a still the link is bare
            // text in every chat app. A card would already hold the frame; this
            // path has no card, so it is decoded here and only on success.
            if medium == .video, let poster = await VideoPoster.frame(for: url) {
                await attachPoster(poster, to: link, endpoint: endpoint)
            }

            publish(.done(link), for: url)
            onDropNotice?(nil)
            ShareHistory.shared.record(link, name: url.lastPathComponent)
            if ShareSettings.shared.linkToClipboard {
                Self.copy(link, name: url.lastPathComponent, isImage: medium == .image)
            }
            if Preferences.shared.playsSound { NSSound(named: "Morse")?.play() }
        } catch {
            let failure = LinkdropError.from(error)
            failDrop(failure.message, for: url, retryable: failure.isRetryable)
        }
    }

    /// The duration a video's descriptor carries, or nil.
    ///
    /// Worth asking for because the page uses it, and cheap enough to ask on
    /// this path because the gate is about to parse the same header anyway to
    /// find out what the codecs are. Anything it cannot answer from that header
    /// is nil rather than waited for.
    private static func duration(of url: URL) async -> Double? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 0
        else { return nil }
        return seconds
    }

    private func failDrop(_ message: String, for url: URL, retryable: Bool) {
        Log.share.error("drop share failed: \(message, privacy: .public)")
        publish(.failed(message, retryable: retryable), for: url)
        onDropNotice?("Could not share \"\(url.lastPathComponent)\": \(message)")
        NSSound.beep()
    }

    private func run(_ entry: PreviewEntry, endpoint: LinkdropEndpoint) async {
        let outcome: LinkdropGate.Outcome
        switch entry.kind {
        case .image(let pointSize):
            outcome = LinkdropGate.plan(
                image: entry.url, pointSize: pointSize,
                ephemeral: ShareSettings.shared.ephemeralScreenshots,
                burnAfterReading: oneTime.contains(entry.url))
        case .video(let result):
            outcome = await LinkdropGate.plan(
                video: entry.url, pointSize: result.pointSize, duration: result.duration,
                ephemeral: ShareSettings.shared.ephemeralRecordings)
        }

        guard case .ok(let plan) = outcome else {
            if case .refused(let reason) = outcome {
                Log.share.notice("refused: \(reason, privacy: .public)")
                publish(.failed(reason, retryable: false), for: entry.url)
            }
            return
        }

        do {
            let url = entry.url
            let link = try await uploader.upload(plan, to: endpoint) { fraction in
                // Progress arrives on URLSession's queue.
                Task { @MainActor [weak self] in
                    self?.publishProgress(fraction, for: url)
                }
            }

            // A video's link is a bare URL in every chat app until the service
            // has a still to unfurl with. The card already holds one.
            if entry.isVideo { await attachPoster(entry.thumbnail, to: link, endpoint: endpoint) }

            publish(.done(link), for: entry.url)
            ShareHistory.shared.record(link, name: entry.url.lastPathComponent)
            if ShareSettings.shared.linkToClipboard {
                Self.copy(link, name: entry.url.lastPathComponent, isImage: !entry.isVideo)
            }
            if Preferences.shared.playsSound { NSSound(named: "Morse")?.play() }
        } catch {
            let failure = LinkdropError.from(error)
            Log.share.error("upload failed: \(failure.message, privacy: .public)")
            publish(.failed(failure.message, retryable: failure.isRetryable), for: entry.url)
            NSSound.beep()
        }
    }

    /// Best effort by design: a link that works but unfurls as plain text is a
    /// far better outcome than an upload reported as failed.
    private func attachPoster(
        _ thumbnail: NSImage, to link: LinkdropLink, endpoint: LinkdropEndpoint
    ) async {
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("duoshot-poster-\(link.key).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try jpeg.write(to: file)
            try await uploader.attachPoster(file, toKey: link.key, at: endpoint)
        } catch {
            Log.share.notice("poster upload skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The only way a link reaches the pasteboard.
    ///
    /// Two places copy links — the upload that has just finished, and a row of
    /// the Recent Links menu — and the format preference has to reach both. They
    /// go through here so that the preference cannot end up honoured in one and
    /// not the other, which is the failure mode a second call site invites.
    ///
    /// `isImage` is asked for rather than derived from `name`: the caller that
    /// has the capture knows, and only the caller that has nothing but a history
    /// row has to guess.
    static func copy(_ link: LinkdropLink, name: String, isImage: Bool) {
        switch ShareSettings.shared.linkFormat {
        case .plain: Clipboard.write(link: link.pageURL)
        case .markdown: Clipboard.write(markdown: link, name: name, isImage: isImage)
        }
    }

    // MARK: - Listing

    /// Everything the server is still holding, newest first.
    ///
    /// Deliberately not merged with `ShareHistory`: that list is what *this Mac*
    /// uploaded lately and survives the server going away, while this one is the
    /// server's own answer and includes links made from another machine or by a
    /// build that predates the history file.
    func allLinks(limit: Int) async throws -> LinkdropListing {
        guard let endpoint = ShareSettings.shared.endpoint else {
            throw LinkdropError.unsupported("Set a share endpoint and token in Settings.")
        }
        do {
            return try await uploader.list(limit: limit, from: endpoint)
        } catch {
            throw LinkdropError.from(error)
        }
    }

    // MARK: - Deleting

    /// Makes the link stop working for everyone, then forgets it locally.
    ///
    /// Answers whether it happened, because a list showing server state cannot
    /// drop a row on optimism: the row is the only evidence the link still
    /// exists, so it goes away when the server says the object did and stays put
    /// when it does not. The failure is audible either way — the menu's
    /// ⌥-delete has nothing to show and so has only the beep.
    @discardableResult
    func revoke(_ key: String) async -> Bool {
        guard let endpoint = ShareSettings.shared.endpoint else { return false }
        do {
            try await uploader.delete(key: key, from: endpoint)
            ShareHistory.shared.forget(key)
            states = states.filter {
                if case .done(let link) = $0.value { link.key != key } else { true }
            }
            return true
        } catch {
            Log.share.error("""
                delete failed: \(LinkdropError.from(error).message, privacy: .public)
                """)
            NSSound.beep()
            return false
        }
    }

    func probe(_ endpoint: LinkdropEndpoint) async -> String? {
        do {
            try await uploader.probe(endpoint)
            return nil
        } catch {
            return LinkdropError.from(error).message
        }
    }

    // MARK: -

    /// Drops a fraction lower than the one already on screen.
    ///
    /// Each callback is hopped onto the main actor as its own task and nothing
    /// orders them against each other, so an out-of-order pair reads as the
    /// transfer having gone backwards. It did not; the ring should not say so.
    private func publishProgress(_ fraction: Double, for url: URL) {
        if case .uploading(let shown) = states[url], fraction < shown { return }
        publish(.uploading(fraction), for: url)
    }

    private func publish(_ state: State, for url: URL) {
        states[url] = state
        observers[url]?.forEach { $0(state) }
    }
}
