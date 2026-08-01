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

    public enum Kind: String, Sendable {
        case image
        case video
        case file
    }

    public init(
        ext: String, name: String, kind: Kind, width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, ephemeral: Bool = false
    ) {
        self.ext = ext
        self.name = name
        self.kind = kind
        self.width = width
        self.height = height
        self.duration = duration
        self.ephemeral = ephemeral
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
