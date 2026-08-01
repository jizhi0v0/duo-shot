import Foundation

/// Reports bytes-sent for one upload.
///
/// A per-task delegate rather than a session-wide one: it is the only way to
/// observe progress without making the session stateful, and it is why the
/// uploader can stay a plain actor with no delegate queue of its own.
private final class ProgressReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// The smallest advance worth telling anyone about.
    ///
    /// URLSession calls the delegate per body write, which for a
    /// multi-hundred-megabyte upload is thousands of calls describing motion no
    /// progress ring can render. Half a percent is finer than a pixel on any ring
    /// this drives.
    private static let step = 0.005

    private let onProgress: @Sendable (Double) -> Void

    /// Guards `lastReported`. The delegate runs on URLSession's own queue, which
    /// makes no serialisation promise to anything here, so the class is
    /// `@unchecked Sendable` and this is what earns that.
    private let lock = NSLock()
    private var lastReported = -1.0

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)

        lock.lock()
        // 1.0 always gets through, whatever the step would say: "finished" is the
        // one value a caller cannot infer from the ones before it.
        let forward = fraction >= lastReported + Self.step || (fraction >= 1 && lastReported < 1)
        if forward { lastReported = fraction }
        lock.unlock()

        guard forward else { return }
        onProgress(fraction)
    }
}

/// Uploads one file and returns its links.
///
/// An `actor`: it owns no UI, and the bookkeeping for a multi-hundred-megabyte
/// transfer has no business on a main thread.
public actor LinkdropUploader {
    /// Anything at or below this goes through the service in one request;
    /// anything above gets a presigned URL and goes straight to object storage.
    ///
    /// Must not exceed the server's own limit. A Cloudflare Worker's request
    /// body is capped well below the size of a few minutes of screen recording,
    /// which is the entire reason the two-request path exists.
    public static let directUploadLimit: Int64 = 90 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // Not the seven-day default, and not sixty seconds either: a large
        // recording on a domestic uplink is a genuinely long transfer, while the
        // per-request timeout above already catches a stalled connection.
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// - Parameter onProgress: 0...1. Called on URLSession's queue, many times
    ///   for a large file over a real network -- and possibly exactly once over
    ///   loopback, where the kernel accepts the whole body in one write.
    @discardableResult
    public func upload(
        _ plan: LinkdropGate.Plan, to endpoint: LinkdropEndpoint,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LinkdropLink {
        defer {
            // A re-encode exists only for this transfer. Deleting in `defer`
            // covers the throwing paths, which is exactly where a temp file
            // otherwise leaks forever.
            if plan.isTemporary { try? FileManager.default.removeItem(at: plan.fileURL) }
        }

        let size = try fileSize(of: plan.fileURL)
        let link = size <= Self.directUploadLimit
            ? try await direct(plan, to: endpoint, onProgress: onProgress)
            : try await presigned(plan, size: size, to: endpoint, onProgress: onProgress)

        LinkdropLog.upload.notice("""
            \(plan.descriptor.ext, privacy: .public) \(size, privacy: .public) bytes \
            -> \(link.key, privacy: .public)
            """)
        return link
    }

    /// One request. What every screenshot takes.
    private func direct(
        _ plan: LinkdropGate.Plan, to endpoint: LinkdropEndpoint,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> LinkdropLink {
        let d = plan.descriptor
        var query = [
            URLQueryItem(name: "ext", value: d.ext),
            URLQueryItem(name: "name", value: d.name),
        ]
        if d.ephemeral { query.append(URLQueryItem(name: "ephemeral", value: "1")) }
        if d.burnAfterReading { query.append(URLQueryItem(name: "burn", value: "1")) }
        if let width = d.width { query.append(URLQueryItem(name: "w", value: "\(width)")) }
        if let height = d.height { query.append(URLQueryItem(name: "h", value: "\(height)")) }
        if let duration = d.duration {
            query.append(URLQueryItem(name: "d", value: String(format: "%.2f", duration)))
        }

        var request = URLRequest(url: endpoint.url(path: "/api/put", query: query))
        request.httpMethod = "PUT"
        let link: LinkdropLink = try decode(
            await send(endpoint.authorized(request), fromFile: plan.fileURL,
                       onProgress: onProgress))
        try Self.validate(key: link.key)
        return link
    }

    /// Two requests, and the bytes never touch the service.
    private func presigned(
        _ plan: LinkdropGate.Plan, size: Int64, to endpoint: LinkdropEndpoint,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> LinkdropLink {
        struct Body: Encodable {
            let ext: String, name: String
            let size: Int64, ephemeral: Bool, burn: Bool
            let width: Int?, height: Int?, duration: Double?
        }
        struct Reply: Decodable {
            let key: String
            let pageURL: URL, fileURL: URL, uploadURL: URL
        }

        let d = plan.descriptor
        var request = URLRequest(url: endpoint.url(path: "/api/new"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            ext: d.ext, name: d.name, size: size, ephemeral: d.ephemeral,
            burn: d.burnAfterReading,
            width: d.width, height: d.height, duration: d.duration))

        let reply: Reply = try decode(await send(endpoint.authorized(request)))
        try Self.validate(key: reply.key)

        // No Authorization header on this one. The signature is in the URL, and
        // sending the service's bearer token to the storage host would hand a
        // third party a credential it has no need for.
        var put = URLRequest(url: reply.uploadURL)
        put.httpMethod = "PUT"
        do {
            _ = try await send(put, fromFile: plan.fileURL, onProgress: onProgress)
        } catch LinkdropError.unauthorized {
            // This request never carried the token, so a 401/403 here is not the
            // token being wrong. It is the storage host refusing the signature the
            // service just minted, and "the server rejected the token" would send
            // the user off to rotate a credential that is fine.
            throw LinkdropError.server(
                status: 403,
                message: "The storage host rejected the presigned upload. That is a "
                    + "signature or clock problem on the server, not your token.")
        }

        return LinkdropLink(key: reply.key, pageURL: reply.pageURL, fileURL: reply.fileURL)
    }

    // MARK: - Other operations

    /// What a "test connection" button calls. Throws `.unauthorized` for a bad
    /// token and `.offline` for a bad host, which is the distinction the user
    /// needs.
    public func probe(_ endpoint: LinkdropEndpoint) async throws {
        var request = URLRequest(
            url: endpoint.url(path: "/api/list", query: [.init(name: "limit", value: "1")]))
        request.httpMethod = "GET"
        _ = try await send(endpoint.authorized(request))
    }

    /// Makes the link stop working, everywhere, for everyone.
    public func delete(key: String, from endpoint: LinkdropEndpoint) async throws {
        try Self.validate(key: key)
        var request = URLRequest(url: endpoint.url(path: "/api/o/\(key)"))
        request.httpMethod = "DELETE"
        _ = try await send(endpoint.authorized(request))
    }

    /// A poster still for a video, so its link unfurls with a thumbnail instead
    /// of a bare URL. No unfurler decodes a frame for you.
    public func attachPoster(
        _ imageURL: URL, toKey key: String, at endpoint: LinkdropEndpoint
    ) async throws {
        try Self.validate(key: key)
        var request = URLRequest(url: endpoint.url(path: "/api/poster/\(key)"))
        request.httpMethod = "PUT"
        _ = try await send(endpoint.authorized(request), fromFile: imageURL)
    }

    // MARK: - Keys

    /// Longest key this client will carry. Deliberately far above the length the
    /// server happens to mint today: the client has no business owning that
    /// constant, and only has to know that a key is a short opaque word.
    static let maximumKeyLength = 64

    /// Checked at every boundary a key crosses, because the key is a server-supplied
    /// string that then gets interpolated into request paths and into a temp
    /// filename. One containing `/` or `..` — from an endpoint that is hostile,
    /// compromised, or merely typo'd into the settings field — would let whoever
    /// answers those requests steer paths on this machine and on the service.
    /// ASCII alphanumerics leave nothing to interpret.
    static func validate(key: String) throws {
        guard (1...maximumKeyLength).contains(key.count),
              key.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
                      || (0x61...0x7A).contains($0)
              })
        else {
            throw LinkdropError.server(
                status: 0,
                message: "The server returned an object key that is not a plain "
                    + "alphanumeric name, so this upload was not trusted.")
        }
    }

    // MARK: - Transport

    private func send(
        _ request: URLRequest, fromFile file: URL? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        let reporter = onProgress.map(ProgressReporter.init)
        do {
            let (data, response): (Data, URLResponse)
            if let file {
                // `fromFile`, never `Data(contentsOf:)`. This is the difference
                // between streaming a recording off disk and holding all of it
                // resident, and it is invisible until the file is large.
                (data, response) = try await session.upload(
                    for: request, fromFile: file, delegate: reporter)
            } else {
                (data, response) = try await session.data(for: request, delegate: reporter)
            }
            try check(response, data)
            return data
        } catch {
            throw LinkdropError.from(error)
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode)
        else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw LinkdropError.unauthorized }

        struct Failure: Decodable { let error: String }
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? ""
        throw LinkdropError.server(status: http.statusCode, message: message)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LinkdropError.server(
                status: 0, message: "The server sent a reply this build cannot read.")
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64
        else { throw LinkdropError.fileUnreadable("The file is no longer on disk.") }
        return size
    }
}
