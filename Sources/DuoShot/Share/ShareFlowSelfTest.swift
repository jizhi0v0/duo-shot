import AppKit
import Linkdrop
import UniformTypeIdentifiers

/// The five paths that were written and never once executed.
///
/// Everything `--selftest-share` covers is the transport. This covers the parts
/// the *app* adds on top of it — the format gate reached through a real capture,
/// the auto-upload preference, the card's survival rules, retry after a genuine
/// failure, and the menu the links land in.
///
/// **This one uploads to the real bucket**, because every one of these paths ends
/// at a server and a fake would only test the fake. It deletes everything it
/// creates, and restores every preference it changes, including on the failing
/// paths.
@MainActor
enum ShareFlowSelfTest {
    static func run() async -> Int32 {
        guard ScreenPermission.isGranted else {
            print("result:        FAIL — no screen recording permission")
            return 1
        }
        guard let endpoint = ShareSettings.shared.endpoint else {
            print("result:        FAIL — sharing is not configured; fill in Settings › Share")
            return 1
        }
        print("endpoint:      \(endpoint.base.absoluteString)")

        var failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("  \(passed ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        // Everything this test touches, put back no matter how it exits.
        let settings = ShareSettings.shared
        let preferences = Preferences.shared
        let originalAuto = settings.autoUploadScreenshots
        let originalEndpoint = settings.endpointString
        let originalFormat = preferences.imageFormatIdentifier
        let originalClipboard = settings.linkToClipboard
        var created: [String] = []
        defer {
            settings.autoUploadScreenshots = originalAuto
            settings.endpointString = originalEndpoint
            preferences.imageFormatIdentifier = originalFormat
            settings.linkToClipboard = originalClipboard
        }

        // MARK: 1 — HEIC reaches the server as PNG

        preferences.imageFormatIdentifier = UTType.heic.identifier
        guard let heic = await capture(into: nil) else {
            print("result:        FAIL — could not capture")
            return 1
        }
        check("staged as .heic", heic.url.pathExtension.lowercased() == "heic",
              heic.url.lastPathComponent)

        let heicEntry = await PreviewEntry(heic)
        if let link = await upload(heicEntry, label: "heic") {
            created.append(link.key)
            check("HEIC uploaded as .png", link.fileURL.pathExtension == "png",
                  link.fileURL.lastPathComponent)
            let type = await contentType(of: link.fileURL)
            check("served as image/png", type == "image/png", type ?? "no response")
        } else {
            check("HEIC upload", false, "the gate or the upload refused it")
        }
        preferences.imageFormatIdentifier = originalFormat

        // MARK: 2 — the auto-upload preference

        settings.autoUploadScreenshots = true
        // Off, or the test would leave the machine's clipboard holding a link.
        settings.linkToClipboard = false

        let stack = PreviewStackController()
        stack.timeout = .seconds(120)
        guard let auto = await capture(into: nil) else {
            print("result:        FAIL — could not capture")
            return 1
        }
        await stack.present(auto)
        let started = await waitFor(seconds: 3) {
            ShareService.shared.state(for: auto.url) != nil
        }
        check("auto-upload started without being asked", started)

        // MARK: 3 — a card with an unfinished share does not time out

        check("card is pinned while uploading", ShareService.shared.isPinned(auto.url))

        let finished = await waitFor(seconds: 60) {
            if case .done = ShareService.shared.state(for: auto.url) { true } else { false }
        }
        check("auto-upload finished", finished)
        check("card is released once done", !ShareService.shared.isPinned(auto.url))
        if case .done(let link) = ShareService.shared.state(for: auto.url) {
            created.append(link.key)
        }
        settings.autoUploadScreenshots = originalAuto

        // MARK: 4 — a real failure, then retry

        // A closed port on loopback, not a bogus public hostname.
        //
        // The first version used `share.invalid.example` and the failure came
        // back as a **TLS error**, not a DNS one: something — a proxy, a
        // captive resolver, an ISP wildcard — answered for it. Which means the
        // test had opened a connection to a stranger and offered it the upload
        // token. TLS failed before anything was sent, this time. Port 9 is the
        // discard port and nothing listens on it, so the failure is a refused
        // connection and it never leaves the machine.
        settings.endpointString = "http://127.0.0.1:9"
        guard let doomed = await capture(into: nil) else {
            print("result:        FAIL — could not capture")
            return 1
        }
        let doomedEntry = await PreviewEntry(doomed)
        ShareService.shared.share(doomedEntry)
        let failed = await waitFor(seconds: 30) {
            if case .failed = ShareService.shared.state(for: doomed.url) { true } else { false }
        }
        check("upload to a dead host fails", failed)

        if case .failed(let message, let retryable) = ShareService.shared.state(for: doomed.url) {
            check("failure is offered as retryable", retryable, message)
            // Ours, not the system's. `LinkdropError` exists to turn
            // NSURLErrorDomain into something a person can act on, and a message
            // that still reads like a framework's is that work not happening.
            check("failure is our own sentence", message == LinkdropError.offline.message, message)
            check("a failed card stays on screen", ShareService.shared.isPinned(doomed.url))
        }

        settings.endpointString = originalEndpoint
        ShareService.shared.retry(doomedEntry)
        let recovered = await waitFor(seconds: 60) {
            if case .done = ShareService.shared.state(for: doomed.url) { true } else { false }
        }
        check("retry after fixing the endpoint succeeds", recovered)
        if case .done(let link) = ShareService.shared.state(for: doomed.url) {
            created.append(link.key)
        }

        // MARK: 5 — the links reach the menu

        let history = ShareHistory.shared.entries.map(\.link.key)
        check("history has every successful upload",
              created.allSatisfy(history.contains), "history=\(history.count) created=\(created.count)")

        let menu = StatusItemController(
            coordinator: CaptureCoordinator(),
            recorder: RecordingCoordinator(overlay: OverlayController())
        ).menuForTest()
        let recent = menu.items.first { $0.title == "Recent Links" }
        check("menu bar has a Recent Links submenu", recent != nil)
        if let submenu = recent?.submenu {
            let copyable = submenu.items.filter { !$0.isAlternate && $0.representedObject != nil }
            let deletable = submenu.items.filter { $0.isAlternate }
            check("submenu lists the uploads", copyable.count >= min(created.count, 10),
                  "\(copyable.count) rows")
            check("each row has an ⌥ delete alternate", deletable.count == copyable.count,
                  "\(deletable.count) alternates for \(copyable.count) rows")
        }

        // MARK: - Put the bucket back

        var deleted = 0
        for key in Set(created) {
            do {
                try await ShareUploaderBridge.delete(key: key, from: endpoint)
                ShareHistory.shared.forget(key)
                deleted += 1
            } catch {
                print("  note: could not delete \(key) — \(LinkdropError.from(error).message)")
            }
        }
        check("every upload this test made was deleted", deleted == Set(created).count,
              "\(deleted)/\(Set(created).count)")

        print("result:        \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Helpers

    private static func capture(into directory: URL?) async -> OutputPipeline.Output? {
        let coordinator = CaptureCoordinator()
        guard (try? await coordinator.engine.refreshContent()) != nil else { return nil }
        let displayID = ScreenIndex.screenUnderMouse().flatMap(ScreenIndex.displayID(of:))
            ?? CGMainDisplayID()
        guard let result = try? await coordinator.engine.capture(
            .area(displayID: displayID,
                  rectInAppKitGlobal: CGRect(x: 200, y: 200, width: 320, height: 240)))
        else { return nil }
        return await OutputPipeline.shared.process(result, saveDirectoryOverride: directory)
    }

    private static func upload(_ entry: PreviewEntry, label: String) async -> LinkdropLink? {
        ShareService.shared.share(entry)
        _ = await waitFor(seconds: 60) {
            switch ShareService.shared.state(for: entry.url) {
            case .done, .failed: true
            default: false
            }
        }
        if case .done(let link) = ShareService.shared.state(for: entry.url) { return link }
        return nil
    }

    /// Polls rather than sleeps a fixed amount: these steps cross a network and
    /// a fixed sleep is either flaky or slow.
    private static func waitFor(
        seconds: Double, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return condition()
    }

    private static func contentType(of url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    }
}

/// `ShareService` owns its uploader privately, and this test has to clean up
/// after itself even for the uploads it made through paths that do not hand a
/// link back.
private enum ShareUploaderBridge {
    static func delete(key: String, from endpoint: LinkdropEndpoint) async throws {
        try await LinkdropUploader().delete(key: key, from: endpoint)
    }
}
