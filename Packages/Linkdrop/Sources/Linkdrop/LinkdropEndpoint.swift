import Foundation

/// Where uploads go and what authorises them.
///
/// A value, not a session: the token can change while an upload is in flight,
/// and every request should be signed by whatever was configured when it
/// started rather than by whatever is configured now.
public struct LinkdropEndpoint: Sendable, Equatable, Hashable {
    /// Never has a trailing slash. Enforced here rather than at each use site,
    /// because a double slash produces a 404 that reads exactly like a wrong key.
    public let base: URL
    public let token: String

    /// Returns nil for anything that could not work, so callers have one check
    /// rather than a scattering of them.
    ///
    /// - Parameter base: With or without a scheme. `https` is assumed, because a
    ///   settings field where "s.example.com" silently does nothing is worse
    ///   than one that guesses the only scheme this can use.
    public init?(base: String, token: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !token.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        if components.scheme == nil {
            guard let withScheme = URLComponents(string: "https://\(trimmed)") else { return nil }
            components = withScheme
        }
        // Plain http is allowed only for loopback, which is what a local
        // `wrangler dev` is. Anywhere else it would put the bearer token on the
        // wire in clear.
        let host = components.host ?? ""
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard components.scheme == "https" || (components.scheme == "http" && isLoopback) else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return nil }

        self.base = url
        self.token = token
    }

    public var isLoopback: Bool {
        let host = base.host ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path += path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// What is being uploaded, as the service needs to hear it.
public struct LinkdropDescriptor: Sendable {
    /// Lowercase, no dot.
    public var ext: String
    /// Display only. The service never builds a path from it.
    public var name: String
    public var kind: Kind
    public var width: Int?
    public var height: Int?
    /// Seconds.
    public var duration: Double?
    /// Lands under the service's expiring prefix.
    public var ephemeral: Bool
    /// The service deletes the bytes after the first complete read.
    ///
    /// Images only, and the service refuses it for anything else: a video is
    /// fetched in ranges, so there is no first complete read to trigger on. The
    /// service also caps how large one may be, because it has to hold the whole
    /// file in memory to answer and delete in the same breath.
    public var burnAfterReading: Bool

    public enum Kind: String, Sendable {
        case image
        case video
        case file
    }

    public init(
        ext: String, name: String, kind: Kind, width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, ephemeral: Bool = false, burnAfterReading: Bool = false
    ) {
        self.ext = ext
        self.name = name
        self.kind = kind
        self.width = width
        self.height = height
        self.duration = duration
        self.ephemeral = ephemeral
        self.burnAfterReading = burnAfterReading
    }
}

/// A finished upload.
public struct LinkdropLink: Sendable, Codable, Equatable, Hashable {
    /// The one to put on a clipboard: a page a person can open, and the one that
    /// unfurls with a thumbnail in chat apps.
    public let pageURL: URL
    /// The bytes themselves, for embedding.
    public let fileURL: URL
    public let key: String

    public init(key: String, pageURL: URL, fileURL: URL) {
        self.key = key
        self.pageURL = pageURL
        self.fileURL = fileURL
    }
}

/// One link the service is still holding.
///
/// Not a `LinkdropLink`: that type is the receipt for an upload this process
/// just made, and every field of it is known to be present. This one is
/// assembled from a sidecar written by some earlier run — possibly by an older
/// build — so `fileURL` is optional and the rest are whatever the sidecar says.
public struct LinkdropItem: Sendable, Identifiable, Equatable, Hashable {
    public let key: String
    /// The filename the upload was made under. Display only.
    public let name: String
    /// Lowercase, no dot. Empty if the sidecar never recorded one.
    public let ext: String
    public let kind: LinkdropDescriptor.Kind
    public let createdAt: Date
    public let pageURL: URL
    /// nil when the service could not name the bytes, which is what an empty
    /// `ext` leaves it with.
    public let fileURL: URL?

    public var id: String { key }

    public init(
        key: String, name: String, ext: String, kind: LinkdropDescriptor.Kind,
        createdAt: Date, pageURL: URL, fileURL: URL?
    ) {
        self.key = key
        self.name = name
        self.ext = ext
        self.kind = kind
        self.createdAt = createdAt
        self.pageURL = pageURL
        self.fileURL = fileURL
    }
}

/// A page of `/api/list`.
public struct LinkdropListing: Sendable, Equatable {
    public let items: [LinkdropItem]
    /// The service stopped walking the bucket before it had seen all of it, so
    /// these are the newest of what it did see. A caller that shows a list has
    /// to say so; silently presenting a partial answer as the whole one is how
    /// a link someone is looking for appears to have been deleted.
    public let truncated: Bool

    public init(items: [LinkdropItem], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }

    /// What the service actually sends. Dates arrive as strings and stay strings
    /// until `date(from:)` has had its say, because a `JSONDecoder` date
    /// strategy would fail the whole page over one malformed row.
    struct Wire: Decodable {
        struct Row: Decodable {
            let key: String
            let name: String
            let ext: String
            let kind: String
            let createdAt: String
            let pageURL: URL
            let fileURL: URL?
        }
        let items: [Row]
        let truncated: Bool
    }

    /// The service stamps `Date.toISOString()`, which carries milliseconds, but
    /// a sidecar could have been written by hand or by an older build. Both
    /// spellings are tried, and anything else becomes `distantPast` rather than
    /// costing the row its place in the list: a link with a wrong-looking date
    /// is still a link the user can copy or revoke, and dropping it would make
    /// an item that exists on the server look as though it does not.
    static func date(from text: String) -> Date {
        if let withFraction = try? Date(
            text, strategy: .iso8601.time(includingFractionalSeconds: true)) {
            return withFraction
        }
        return (try? Date(text, strategy: .iso8601)) ?? .distantPast
    }
}
