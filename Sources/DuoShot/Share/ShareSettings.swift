import Foundation
import Linkdrop
import Observation

/// Share settings, kept out of `Preferences` on purpose.
///
/// Everything in `Preferences` is a local, offline choice. These are the only
/// settings that decide whether a capture *leaves this machine*, and keeping
/// that distinction visible in the type system is worth one more small store.
/// The token itself is not here -- see `ShareCredentials`.
@Observable
@MainActor
final class ShareSettings {
    static let shared = ShareSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let endpoint = "share.endpoint"
        static let autoUploadScreenshots = "share.autoUploadScreenshots"
        static let autoUploadRecordings = "share.autoUploadRecordings"
        static let linkToClipboard = "share.linkToClipboard"
        static let ephemeralRecordings = "share.ephemeralRecordings"
        static let ephemeralScreenshots = "share.ephemeralScreenshots"
    }

    /// e.g. "https://s.example.com".
    var endpointString: String {
        didSet { defaults.set(endpointString, forKey: Key.endpoint) }
    }

    /// **Both default to off, and that is not a placeholder.** Turning either on
    /// means every capture of that kind leaves this machine without being asked,
    /// and screenshots routinely contain things their author would not publish.
    /// The Settings copy has to say so.
    var autoUploadScreenshots: Bool {
        didSet { defaults.set(autoUploadScreenshots, forKey: Key.autoUploadScreenshots) }
    }
    var autoUploadRecordings: Bool {
        didSet { defaults.set(autoUploadRecordings, forKey: Key.autoUploadRecordings) }
    }

    /// After a successful upload, put the link on the clipboard rather than
    /// leaving the image there.
    ///
    /// Without this the two writes race in the user's head: `OutputPipeline`
    /// puts the image on the clipboard at capture time, the upload finishes
    /// seconds later, and "what did I just copy" has no good answer.
    var linkToClipboard: Bool {
        didSet { defaults.set(linkToClipboard, forKey: Key.linkToClipboard) }
    }

    /// Recordings land under the Worker's `e/` prefix, which an R2 lifecycle
    /// rule expires.
    ///
    /// On by default while screenshots are not: 10 GB of R2 free tier is
    /// thousands of screenshots but only a couple of dozen 5K recordings, so
    /// this is the setting that keeps storage bounded without anyone tidying up.
    var ephemeralRecordings: Bool {
        didSet { defaults.set(ephemeralRecordings, forKey: Key.ephemeralRecordings) }
    }

    /// Off, unlike recordings: a screenshot link is the kind people paste into a
    /// document and expect to still work next year, and stills are not what
    /// fills a bucket.
    var ephemeralScreenshots: Bool {
        didSet { defaults.set(ephemeralScreenshots, forKey: Key.ephemeralScreenshots) }
    }

    /// The upload token, mirrored in memory.
    ///
    /// The Keychain stays the source of truth and fills this at launch, but it
    /// cannot be read on every access: `endpoint` is asked from menu construction
    /// and from SwiftUI bodies, and each read is up to two `SecItemCopyMatching`
    /// round trips. `saveToken(_:)` is the only writer, which is what keeps the
    /// two in step.
    private var token: String?

    private init() {
        defaults.register(defaults: [
            Key.endpoint: "",
            Key.autoUploadScreenshots: false,
            Key.autoUploadRecordings: false,
            Key.linkToClipboard: true,
            Key.ephemeralRecordings: true,
            Key.ephemeralScreenshots: false,
        ])
        endpointString = defaults.string(forKey: Key.endpoint) ?? ""
        autoUploadScreenshots = defaults.bool(forKey: Key.autoUploadScreenshots)
        autoUploadRecordings = defaults.bool(forKey: Key.autoUploadRecordings)
        linkToClipboard = defaults.bool(forKey: Key.linkToClipboard)
        ephemeralRecordings = defaults.bool(forKey: Key.ephemeralRecordings)
        ephemeralScreenshots = defaults.bool(forKey: Key.ephemeralScreenshots)
        token = ShareService.credentials.load()
    }

    /// The only supported way to change the token: it writes through to the
    /// Keychain and updates the cached copy in one step, so nothing can be left
    /// reading a token the Keychain no longer holds. An empty string clears both.
    func saveToken(_ newToken: String) {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        ShareService.credentials.save(trimmed)
        token = trimmed.isEmpty ? nil : trimmed
    }

    /// nil whenever sharing is not usable, which is also the check the UI uses
    /// to decide whether to offer it at all.
    var endpoint: LinkdropEndpoint? {
        guard let token else { return nil }
        return LinkdropEndpoint(base: endpointString, token: token)
    }

    var isConfigured: Bool { endpoint != nil }
}
