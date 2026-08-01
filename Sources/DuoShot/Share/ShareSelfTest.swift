import AppKit
import Foundation
import Linkdrop

/// The share pipeline, end to end, against a local `wrangler dev`.
///
/// Kept out of `SelfTest.swift` because it is the only check in the project that
/// needs a socket. It still costs nothing and touches nothing: `wrangler dev`
/// runs the real Worker in workerd against miniflare's local R2, so this is the
/// same code path production takes, with none of the account.
///
/// Endpoint and token come from the command line, never from Settings or the
/// Keychain. A test that reads the live configuration would upload real captures
/// to a real bucket the first time someone ran `make test` after configuring
/// sharing.
nonisolated enum ShareSelfTest {
    private static let uploader = LinkdropUploader()

    /// - Parameters:
    ///   - base/token: nil means "read the app's own configuration". Explicitly
    ///     opt-in (`--configured`) and never the default, because a test that
    ///     silently read live settings would upload to the real bucket the first
    ///     time anyone ran `make test` after setting sharing up.
    ///   - bigMegabytes: forces the file over `LinkdropUploader.directUploadLimit`
    ///     so the **presigned** path runs. Without it every run exercises only
    ///     the small-file route, which is how that path stayed unverified while
    ///     fourteen assertions passed.
    static func run(
        endpoint base: String?, token: String?, file: URL?, bigMegabytes: Int? = nil
    ) async -> Int32 {
        let configured = await MainActor.run {
            (ShareSettings.shared.endpointString, ShareService.credentials.load() ?? "")
        }
        let base = base ?? configured.0
        let token = token ?? configured.1
        guard let endpoint = LinkdropEndpoint(base: base, token: token) else {
            print("result:        FAIL — bad endpoint or empty token")
            return 1
        }
        print("endpoint:      \(endpoint.base.absoluteString)")

        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        // A fixed PNG rather than a screenshot: this test asserts on exact bytes
        // and must run on a machine with no screen-recording grant.
        let source: URL
        let temporary: Bool
        if let file {
            source = file
            temporary = false
        } else if let megabytes = bigMegabytes {
            guard let generated = makeLargeFile(megabytes: megabytes) else {
                print("result:        FAIL — could not write the \(megabytes) MB test file")
                return 1
            }
            source = generated
            temporary = true
        } else {
            guard let generated = makeTestPNG() else {
                print("result:        FAIL — could not write the test PNG")
                return 1
            }
            source = generated
            temporary = true
        }
        defer { if temporary { try? FileManager.default.removeItem(at: source) } }

        let original: Data
        do {
            original = try Data(contentsOf: source)
        } catch {
            print("result:        FAIL — \(error.localizedDescription)")
            return 1
        }
        let limit = LinkdropUploader.directUploadLimit
        let route = Int64(original.count) > limit ? "presigned (POST /api/new)" : "direct (PUT /api/put)"
        print("file:          \(source.lastPathComponent) (\(original.count) bytes)")
        print("route:         \(route)")

        // 1. The gate.
        guard case .ok(let upload) = LinkdropGate.plan(
            image: source, pointSize: CGSize(width: 64, height: 64), ephemeral: false)
        else {
            print("result:        FAIL — the gate refused a plain PNG")
            return 1
        }

        // 2. Upload, counting progress callbacks.
        //
        // The count is the assertion, not decoration: an implementation that
        // buffers the whole file and reports 0% then 100% also "has progress",
        // and looks identical from the outside until a 400 MB recording pins a
        // spinner at zero for a minute.
        let progress = ProgressCounter()
        let link: LinkdropLink
        do {
            link = try await uploader.upload(upload, to: endpoint) { fraction in
                progress.record(fraction)
            }
        } catch {
            let message = (error as? LinkdropError)?.message ?? error.localizedDescription
            print("result:        FAIL — upload: \(message)")
            return 1
        }
        print("key:           \(link.key)")
        print("page:          \(link.pageURL.absoluteString)")
        print("progress:      \(progress.count) callbacks, last=\(progress.last)")
        check("progress reported", progress.count >= 1)
        check("progress reached 1.0", progress.last > 0.99)

        // Granularity cannot be tested over loopback, and pretending otherwise
        // would be worse than not testing it. Measured 2026-08-01: a 3.4 MB body
        // to 127.0.0.1 produces exactly ONE `didSendBodyData` callback -- the
        // kernel takes the whole write at once -- so "1 callback" here says
        // nothing about whether a 400 MB recording over a real uplink would
        // animate a progress ring or sit at zero.
        //
        // Printed as SKIP rather than folded into the pass count: a check that
        // silently cannot fail is the thing this project keeps negative controls
        // around to prevent.
        if isLoopback(endpoint) {
            print("  SKIP progress granularity — loopback sends the body in one write")
        } else {
            check("progress arrived in steps", progress.count >= 2, "got \(progress.count)")
        }

        // 3. The bytes must survive the round trip.
        do {
            let (data, response) = try await URLSession.shared.data(from: link.fileURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? ""
            check("file 200", status == 200, "got \(status)")
            check("bytes identical", data == original,
                  "\(data.count) vs \(original.count) bytes")
            check("Content-Type", type == "image/png", type)
        } catch {
            check("download", false, error.localizedDescription)
        }

        // 4. Range, which is what video seeking is made of.
        do {
            var request = URLRequest(url: link.fileURL)
            request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            check("range 206", http?.statusCode == 206, "got \(http?.statusCode ?? 0)")
            check("range length", data.count == 10, "\(data.count) bytes")
        } catch {
            check("range", false, error.localizedDescription)
        }

        // 5. The viewer page, and the tag that makes a link unfurl.
        do {
            let (data, _) = try await URLSession.shared.data(from: link.pageURL)
            let html = String(decoding: data, as: UTF8.self)
            check("page has og:image", html.contains("og:image"))
            check("page embeds the file", html.contains(link.fileURL.absoluteString))
        } catch {
            check("page", false, error.localizedDescription)
        }

        // 6. A wrong token must fail. Without this the five checks above pass
        //    just as well against a Worker with its auth removed.
        if let wrong = LinkdropEndpoint(base: base, token: token + "x") {
            do {
                try await uploader.probe(wrong)
                check("wrong token rejected", false, "the server accepted it")
            } catch LinkdropError.unauthorized {
                check("wrong token rejected", true)
            } catch {
                check("wrong token rejected", false,
                      "failed for the wrong reason: \((error as? LinkdropError)?.message ?? "?")")
            }
        }

        // 7. Delete, then the link must stop working.
        do {
            try await uploader.delete(key: link.key, from: endpoint)
            let (_, response) = try await URLSession.shared.data(from: link.fileURL)
            check("deleted file 404", (response as? HTTPURLResponse)?.statusCode == 404)
        } catch {
            check("delete", false, (error as? LinkdropError)?.message ?? error.localizedDescription)
        }

        // 8. The gate's refusals, which need no network at all.
        check("gate refuses .svg", isRefused(LinkdropGate.plan(
            image: URL(fileURLWithPath: "/tmp/x.svg"), pointSize: .zero, ephemeral: false)))
        check("gate refuses .bmp", isRefused(LinkdropGate.plan(
            image: URL(fileURLWithPath: "/tmp/x.bmp"), pointSize: .zero, ephemeral: false)))

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// Whether the Keychain round-trips at all, and with what status codes.
    ///
    /// Uses a throwaway account name: a diagnostic that overwrites the real
    /// token to prove the Keychain works would be a fine way to lose it.
    static func credentials() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        let secret = "probe-\(UUID().uuidString.prefix(8))"
        for synchronizable in [true, false] {
            let store = LinkdropCredentials(
                service: "com.boli.duoshot.share", account: "selftest-probe",
                synchronizable: synchronizable)
            store.delete()
            let wrote = store.save(secret)
            let read = store.load()
            print("  synchronizable=\(synchronizable): save=\(wrote) read=\(read == secret ? "ok" : String(describing: read))")
            check("round trip (synchronizable=\(synchronizable))", wrote && read == secret)
            store.delete()
        }

        // And the real one, read-only.
        let (live, endpointString, configured) = await MainActor.run {
            (ShareService.credentials.load(), ShareSettings.shared.endpointString,
             ShareSettings.shared.endpoint != nil)
        }
        print("  live token present: \(live != nil)")
        check("configured endpoint", configured,
              "endpointString=\"\(endpointString)\" token=\(live != nil)")

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    /// Prints what is actually inside a recording. The whole point is that this
    /// cannot be answered by looking at the recording settings.
    static func compatibility(of url: URL) async -> Int32 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("result:        FAIL — no such file: \(url.path)")
            return 1
        }
        let codecs = await LinkdropGate.codecs(of: url)
        print("file:          \(url.lastPathComponent)")
        print("video:         \(describe(codecs.video))")
        print("audio:         \(describe(codecs.audio))")

        // Where the index sits. A recorder that streams to disk appends it, and
        // the cost is paid by whoever opens the link, never by whoever made it.
        let before = MP4Layout.isFastStart(url)
        print("faststart:     \(describe(before)) (as recorded)")

        let outcome = await LinkdropGate.plan(
            video: url, pointSize: .zero, duration: 0, ephemeral: false)
        switch outcome {
        case .ok(let plan):
            let after = MP4Layout.isFastStart(plan.fileURL)
            print("uploads as:    \(plan.isTemporary ? "a rewritten copy" : "the original file")")
            print("faststart:     \(describe(after)) (as uploaded)")
            if plan.isTemporary { try? FileManager.default.removeItem(at: plan.fileURL) }

            guard after == true else {
                print("result:        FAIL — the uploaded copy still has its index at the end")
                return 1
            }
            print("result:        PASS — playable for people not on Apple platforms")
            return 0
        case .refused(let reason):
            print("result:        FAIL — \(reason)")
            return 1
        }
    }

    private static func describe(_ fastStart: Bool?) -> String {
        switch fastStart {
        case true: "yes — the index is at the front"
        case false: "NO — index at the end, the player must fetch the tail first"
        case nil: "unknown (not a parseable MP4)"
        }
    }

    private static func describe(_ codec: LinkdropGate.Codec?) -> String {
        switch codec {
        case .none: "none"
        case .h264: "H.264 (avc1) — universally playable"
        case .hevc: "HEVC — NOT playable in most browsers"
        case .aac: "AAC (mp4a) — universally playable"
        case .other(let tag): "\(tag) — unknown, assume not playable"
        }
    }

    private static func isLoopback(_ endpoint: LinkdropEndpoint) -> Bool {
        let host = endpoint.base.host()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isRefused(_ outcome: LinkdropGate.Outcome) -> Bool {
        if case .refused = outcome { true } else { false }
    }

    /// Incompressible bytes, large enough to force the presigned route.
    ///
    /// Written as a `.png` because the gate's allowlist is by extension and this
    /// test is about the transport, not the format. It is not a valid image and
    /// nothing decodes it — the server stores bytes.
    private static func makeLargeFile(megabytes: Int) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duoshot-share-big.png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }

        // A megabyte at a time: building the whole thing in memory would be the
        // exact mistake this route exists to avoid.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<megabytes {
            var chunk = Data(count: 1 << 20)
            chunk.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for index in words.indices { words[index] = generator.next() }
            }
            do { try handle.write(contentsOf: chunk) } catch { return nil }
        }
        return url
    }

    /// 1024x1024 of noise, which is a few megabytes of PNG.
    ///
    /// Deliberately not a small solid-colour tile. The first version was 64x64
    /// and compressed to 363 bytes, which URLSession sends in **one** write --
    /// so the progress assertion below saw a single callback and there was no
    /// way to tell a streaming implementation from one that buffers the whole
    /// file and reports 0% then 100%. Incompressible bytes are the point.
    private static func makeTestPNG() -> URL? {
        let size = 1024
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let pixels = context.data {
            let count = context.bytesPerRow * size
            let bytes = pixels.bindMemory(to: UInt8.self, capacity: count)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<count { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        guard let image = context.makeImage() else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duoshot-share-selftest.png")
        do {
            try ImageEncoder.write(image, to: url, as: .png, scale: 1, quality: 1)
            return url
        } catch {
            return nil
        }
    }

    /// Progress arrives on URLSession's queue, so the counter has to be safe to
    /// touch from there.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _last: Double = 0

        func record(_ fraction: Double) {
            lock.lock()
            defer { lock.unlock() }
            _count += 1
            _last = fraction
        }

        var count: Int { lock.withLock { _count } }
        var last: Double { lock.withLock { _last } }
    }
}
