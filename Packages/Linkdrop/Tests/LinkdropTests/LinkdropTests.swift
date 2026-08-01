import Foundation
import Testing

@testable import Linkdrop

@Suite("Endpoint")
struct EndpointTests {
    @Test("assumes https for a bare host")
    func bareHost() throws {
        let endpoint = try #require(LinkdropEndpoint(base: "s.example.com", token: "t"))
        #expect(endpoint.base.absoluteString == "https://s.example.com")
    }

    @Test("strips trailing slashes")
    func trailingSlash() throws {
        let endpoint = try #require(LinkdropEndpoint(base: "https://s.example.com//", token: "t"))
        #expect(endpoint.base.absoluteString == "https://s.example.com")
        #expect(endpoint.url(path: "/api/put").absoluteString == "https://s.example.com/api/put")
    }

    // Plain http anywhere but loopback would put the bearer token on the wire in
    // clear. This is the assertion that keeps that from being a one-line
    // regression.
    @Test("refuses plain http off-loopback")
    func rejectsInsecure() {
        #expect(LinkdropEndpoint(base: "http://s.example.com", token: "t") == nil)
    }

    @Test("allows http on loopback, which is what a local dev server is")
    func allowsLoopback() throws {
        let endpoint = try #require(LinkdropEndpoint(base: "http://127.0.0.1:8787", token: "t"))
        #expect(endpoint.isLoopback)
    }

    @Test("refuses an empty token")
    func rejectsEmptyToken() {
        #expect(LinkdropEndpoint(base: "https://s.example.com", token: "") == nil)
        #expect(LinkdropEndpoint(base: "", token: "t") == nil)
    }

    @Test("percent-encodes a filename with spaces and quotes")
    func encodesQuery() throws {
        let endpoint = try #require(LinkdropEndpoint(base: "https://s.example.com", token: "t"))
        let url = endpoint.url(path: "/api/put", query: [
            URLQueryItem(name: "name", value: #"a "b" c.png"#)
        ])
        #expect(!url.absoluteString.contains(" "))
        #expect(url.absoluteString.contains("/api/put?name="))
    }
}

@Suite("Gate")
struct GateTests {
    // Not a style preference. Serving an uploaded SVG inline from a share domain
    // runs its script on that origin, which is stored XSS against every other
    // link ever shared from it.
    @Test("refuses SVG")
    func refusesSVG() {
        #expect(isRefused(LinkdropGate.plan(image: URL(fileURLWithPath: "/tmp/x.svg"))))
    }

    @Test("accepts the web image formats", arguments: ["png", "jpg", "jpeg", "gif", "webp"])
    func acceptsWebImages(ext: String) {
        // The file need not exist: nothing is read for a format already fit to
        // send, which is what makes this check free at capture time.
        guard case .ok(let plan) = LinkdropGate.plan(
            image: URL(fileURLWithPath: "/tmp/x.\(ext)"))
        else { Issue.record("refused .\(ext)"); return }
        #expect(plan.descriptor.ext == ext)
        #expect(!plan.isTemporary)
    }

    @Test("refuses an unknown extension")
    func refusesUnknown() {
        #expect(isRefused(LinkdropGate.plan(image: URL(fileURLWithPath: "/tmp/x.xcf"))))
        #expect(isRefused(LinkdropGate.plan(image: URL(fileURLWithPath: "/tmp/x"))))
    }

    @Test("refuses a container browsers cannot play")
    func refusesContainer() async {
        #expect(isRefused(await LinkdropGate.plan(video: URL(fileURLWithPath: "/tmp/x.mkv"))))
        #expect(isRefused(await LinkdropGate.plan(video: URL(fileURLWithPath: "/tmp/x.avi"))))
    }

    @Test("reads four-character codes back as text")
    func fourCC() {
        #expect(LinkdropGate.fourCharString(0x6176_6331) == "avc1")
        #expect(LinkdropGate.fourCharString(0x6870_6134) == "hpa4")
    }

    private func isRefused(_ outcome: LinkdropGate.Outcome) -> Bool {
        if case .refused = outcome { true } else { false }
    }
}

@Suite("Object keys")
struct KeyTests {
    // The key comes back from the server and is then interpolated into request
    // paths and a temp filename. These are the strings that would turn a bad
    // endpoint into path influence.
    @Test("refuses anything that could steer a path", arguments: [
        "../../etc/passwd", "a/b", "a..b", "..", "a b", "a%2fb", "a?b", "a.jpg", "a-b", "ä",
    ])
    func refusesPathy(key: String) {
        #expect(throws: LinkdropError.self) { try LinkdropUploader.validate(key: key) }
    }

    @Test("refuses an empty key and one longer than the bound")
    func refusesLengths() {
        #expect(throws: LinkdropError.self) { try LinkdropUploader.validate(key: "") }
        #expect(throws: LinkdropError.self) {
            try LinkdropUploader.validate(
                key: String(repeating: "a", count: LinkdropUploader.maximumKeyLength + 1))
        }
    }

    // The bound is the client's, not the server's: a service that lengthens its
    // keys must keep working without a new build.
    @Test("accepts what the service actually mints", arguments: [
        "aB3xY9kL2mQ7", "a", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12",
    ])
    func acceptsPlainKeys(key: String) throws {
        try LinkdropUploader.validate(key: key)
    }
}

@Suite("Errors")
struct ErrorTests {
    @Test("maps a lost connection to something a person can act on")
    func mapsOffline() {
        let underlying = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(LinkdropError.from(underlying) == .offline)
    }

    @Test("passes its own errors through unchanged")
    func passesThrough() {
        #expect(LinkdropError.from(LinkdropError.unauthorized) == .unauthorized)
    }

    // Offering "retry" for a rejected token or a format that will never be
    // accepted trains people to press a button that cannot work.
    @Test("only offers retry where retrying could work")
    func retryable() {
        #expect(LinkdropError.offline.isRetryable)
        #expect(LinkdropError.timedOut.isRetryable)
        #expect(LinkdropError.server(status: 503, message: "").isRetryable)
        #expect(!LinkdropError.unauthorized.isRetryable)
        #expect(!LinkdropError.unsupported("nope").isRetryable)
        #expect(!LinkdropError.server(status: 400, message: "").isRetryable)
    }

    @Test("never shows a bare status code when the server explained itself")
    func prefersServerMessage() {
        let error = LinkdropError.server(status: 413, message: "larger than 90 MB")
        #expect(error.message == "larger than 90 MB")
    }
}
