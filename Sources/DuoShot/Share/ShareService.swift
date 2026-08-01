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
    func share(_ entry: PreviewEntry) {
        guard tasks[entry.url] == nil else { return }
        if case .done = states[entry.url] { return }

        guard let endpoint = ShareSettings.shared.endpoint else {
            publish(.failed("Set a share endpoint and token in Settings.", retryable: false),
                    for: entry.url)
            return
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
        share(entry)
    }

    private func run(_ entry: PreviewEntry, endpoint: LinkdropEndpoint) async {
        let outcome: LinkdropGate.Outcome
        switch entry.kind {
        case .image(let pointSize):
            outcome = LinkdropGate.plan(
                image: entry.url, pointSize: pointSize,
                ephemeral: ShareSettings.shared.ephemeralScreenshots)
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
                Clipboard.write(link: link.pageURL)
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

    // MARK: - Deleting

    /// Makes the link stop working for everyone, then forgets it locally.
    func revoke(_ key: String) {
        guard let endpoint = ShareSettings.shared.endpoint else { return }
        Task {
            do {
                try await uploader.delete(key: key, from: endpoint)
                ShareHistory.shared.forget(key)
                states = states.filter {
                    if case .done(let link) = $0.value { link.key != key } else { true }
                }
            } catch {
                Log.share.error("""
                    delete failed: \(LinkdropError.from(error).message, privacy: .public)
                    """)
                NSSound.beep()
            }
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
