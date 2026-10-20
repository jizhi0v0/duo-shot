import AVFoundation
import AppKit
import DuoShotCLIWire
import ImageIO

/// `--selftest-cli <dir> -allowsCommandLineCapture YES`: the command line end
/// to end.
///
/// The real server (`CLIServer`, behind the real gate `CommandLineAccess`) runs in this process on a private socket, and every
/// command goes through the real client: the standalone `duoshot` built next to
/// this bundle (`build/duoshot`), launched as a subprocess. What is checked is the
/// exit status, the JSON on stdout and the pixels in the files the client wrote.
///
/// The launch argument is part of the test, not a convenience: it is exactly
/// how the gate could once be switched on from outside, and the run asserts
/// that it is visible to `UserDefaults` *and* that the gate is off anyway.
/// The stored setting lives in a throwaway suite of this run's own; DuoShot's
/// real domain is never written.
enum CLISelfTest {
    private static var failures: [String] = []
    private static let gateKey = "allowsCommandLineCapture"

    private static func check(_ condition: Bool, _ label: String, _ detail: String = "") {
        print("  \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
        if !condition { failures.append(label) }
    }

    static func run(into directory: URL) async throws -> Int32 {
        guard ScreenPermission.isGranted else {
            print("result:        FAIL — no Screen Recording grant; nothing can be captured")
            return 1
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("duoshot-cli-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: socketDirectory)
        let socket = socketDirectory.appendingPathComponent("capture.sock").path
        defer { try? FileManager.default.removeItem(at: socketDirectory) }

        print("(s1) persistent, but only from what Settings stored")
        let argument = UserDefaults.standard.volatileDomain(
            forName: UserDefaults.argumentDomain)[gateKey]
        check(argument != nil, "the launch argument -\(gateKey) YES reached UserDefaults",
              argument.map { "\($0)" } ?? "run with -\(gateKey) YES, or this proves nothing")
        // A registered default is another domain the stored value must ignore.
        UserDefaults.standard.register(defaults: [gateKey: true])

        // Stores of the test's own, so the real domain is never written. Fixed
        // names, emptied at both ends: an emptied suite keeps an empty plist
        // that the preferences daemon writes back if it is deleted, so a name
        // per run would leave one behind per run.
        let suite = "duoshot.selftest.cli"
        let storedSuite = suite + ".stored"
        guard let defaults = UserDefaults(suiteName: suite),
              let storedDefaults = UserDefaults(suiteName: storedSuite)
        else {
            print("result:        FAIL — no test suite")
            return 1
        }
        defaults.removePersistentDomain(forName: suite)
        storedDefaults.removePersistentDomain(forName: storedSuite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            storedDefaults.removePersistentDomain(forName: storedSuite)
        }
        let store = CommandLineAccessStore(defaults: defaults, domain: suite)
        check(defaults.bool(forKey: gateKey),
              "the suite's own lookup sees the launch argument (so ignoring it is a choice)")
        check(!store.isOn, "a fresh store says off, launch argument and all")

        // Stored on by an earlier session: on from the start.
        storedDefaults.setPersistentDomain([gateKey: true], forName: storedSuite)
        let earlier = CommandLineAccess(
            store: CommandLineAccessStore(defaults: storedDefaults, domain: storedSuite))
        let earlierSocket = socketDirectory.appendingPathComponent("stored.sock").path
        let earlierServer = CLIServer(socketPath: earlierSocket, engine: CaptureEngine())
        earlierServer.follow(earlier)
        check(earlier.isListening && FileManager.default.fileExists(atPath: earlierSocket),
              "stored on: listening from the start")
        earlier.request(false)
        let storedAfter = storedDefaults.persistentDomain(forName: storedSuite)?[gateKey] as? Bool
        check(storedAfter == false && !FileManager.default.fileExists(atPath: earlierSocket)
                && !earlier.isListening,
              "toggled off: stored off, socket gone", "stored=\(storedAfter.map { "\($0)" } ?? "nil")")
        earlier.onRequest = nil

        let access = CommandLineAccess(store: store)
        let engine = CaptureEngine()
        let server = CLIServer(socketPath: socket, engine: engine)
        server.follow(access)
        defer {
            access.request(false)
            access.onRequest = nil
        }
        check(!access.isListening && !FileManager.default.fileExists(atPath: socket),
              "fresh store, launch argument -\(gateKey) YES: off, no socket")

        print("(a) gate")
        var run = await client(["windows"], socket: socket)
        check(run.status == CLIExit.unreachable && run.stderr.contains("command-line capture is off"),
              "off: client exits 3 saying capture is off", run.summary)

        access.request(true)
        var info = stat()
        let socketExists = lstat(socket, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        check(socketExists && access.isListening, "on: socket exists, Settings says listening")
        check(info.st_mode & 0o777 == 0o600, "on: socket is 0600", String(info.st_mode & 0o777, radix: 8))
        var folder = stat()
        lstat(socketDirectory.path, &folder)
        check(folder.st_mode & 0o777 == 0o700, "on: its directory is 0700",
              String(folder.st_mode & 0o777, radix: 8))
        run = await client(["windows"], socket: socket)
        check(run.status == 0, "on: client exits 0", run.summary)

        let intruder = CLIServer(socketPath: socket, engine: CaptureEngine())
        var refused = false
        do { try intruder.start() } catch .inUse { refused = true } catch {}
        var after = stat()
        lstat(socket, &after)
        check(refused && after.st_ino == info.st_ino,
              "a second instance does not take over a live socket")
        intruder.stop()
        run = await client(["windows"], socket: socket)
        check(run.status == 0, "the first instance still answers", run.summary)

        print("(s3) a socket held by somebody else reads as off")
        access.request(false)
        let holder = CLIServer(socketPath: socket, engine: CaptureEngine())
        try? holder.start()
        access.request(true)
        check(!access.isListening && (access.problem ?? "").contains("another DuoShot"),
              "Settings shows not listening, and why",
              "listening=\(access.isListening) problem=\(access.problem ?? "nil")")
        holder.stop()
        access.request(true)
        check(access.isListening, "once it is free, it listens")

        print("(s3) the client does not allocate what a reply claims")
        let fake = socketDirectory.appendingPathComponent("fake.sock").path
        if let listener = fakeListener(at: fake) {
            let served = Task { await serveHugeClaim(listener) }
            let capPNG = directory.appendingPathComponent("cli-cap.png")
            run = await client(["shot", "--window", "1", "--out", capPNG.path], socket: fake)
            await served.value
            check(run.status == CLIExit.captureFailed && run.stderr.contains("more than any screenshot")
                    && !FileManager.default.fileExists(atPath: capPNG.path),
                  "a 600 MB claim is refused before reading", run.summary)
        } else {
            check(false, "fake server listening")
        }

        print("(s4) the client is the standalone tool, not DuoShot")
        run = await client(["windows"], socket: socket, executable: Bundle.main.executableURL)
        check(run.status == CLIExit.usage && run.stderr.contains("standalone `duoshot`"),
              "DuoShot's own binary refuses `cli`", run.summary)
        check(!FileManager.default.fileExists(
                  atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path)
                && FileManager.default.isExecutableFile(atPath: clientURL.path),
              "nothing of the client is inside the bundle; it is beside it", clientURL.path)

        print("(a2) connections past the cap are closed at once")
        let cut = await openIdle(Self.idleConnections, to: socket)
        check(cut == Self.idleConnections - CLIServer.maximumConnections,
              "\(Self.idleConnections) idle connections: the \(Self.idleConnections - CLIServer.maximumConnections) past the cap of \(CLIServer.maximumConnections) closed within 1.5 s",
              "\(cut) closed")
        try await Task.sleep(for: .milliseconds(300))
        run = await client(["windows"], socket: socket)
        check(run.status == 0, "and the next client is served", run.summary)

        let screen = NSScreen.screens[0].visibleFrame
        let owner = NSRunningApplication.current.localizedName ?? "DuoShot"

        // --- (a1) the menu-bar mark ---------------------------------------------
        print("(a1) the menu-bar mark, in every state")
        try await statusItemMark(access)

        // --- (b) windows, (c) shot, (d) fade --------------------------------
        let quadrants = window(
            frame: CGRect(x: screen.minX + 80, y: screen.minY + 80, width: 400, height: 300),
            colours: [Colour.red, Colour.green, Colour.blue, Colour.yellow], level: .floating)
        try await Task.sleep(for: .milliseconds(500))
        let quadrantID = UInt32(quadrants.windowNumber)
        let expected = DisplayGeometry.flipped(quadrants.frame)

        print("(b) windows")
        run = await client(["windows", "--pid", "\(getpid())"], socket: socket)
        let listed = (try? JSONDecoder().decode([CLIWindow].self, from: run.stdoutData)) ?? []
        let entry = listed.first { $0.id == quadrantID }
        check(entry != nil, "fixture window \(quadrantID) is listed", run.summary)
        if let entry {
            check(same(entry.frame.cgRect, expected),
                  "its frame is the NSWindow frame in global top-left points",
                  "listed \(entry.frame.cgRect), expected \(expected)")
            check(entry.pid == getpid() && entry.owner == owner, "pid and owner are this process")
        }

        print("(c) shot --window")
        let scale = quadrants.backingScaleFactor
        let quadrantPNG = directory.appendingPathComponent("cli-quadrants.png")
        try? FileManager.default.removeItem(at: quadrantPNG)
        run = await client(["shot", "--window", "\(quadrantID)", "--out", quadrantPNG.path],
                           socket: socket)
        check(run.status == 0, "exits 0", run.summary)
        let shot = try? JSONDecoder().decode(CLIShot.self, from: run.stdoutData)
        check(shot?.mode == "as_seen", "default mode is as_seen", shot?.mode ?? "no JSON")
        check(shot?.path == quadrantPNG.path, "reports the path it wrote")
        check(shot.map { same($0.frame.cgRect, expected) } ?? false,
              "reports the window's frame", "\(shot?.frame.cgRect ?? .null)")
        if let bitmap = Bitmap(quadrantPNG) {
            check(bitmap.width == Int(400 * scale) && bitmap.height == Int(300 * scale),
                  "PNG is frame x scale", "\(bitmap.width)x\(bitmap.height) at \(scale)x")
            assertQuadrants(bitmap, "PNG")
        } else {
            check(false, "PNG was written and decodes")
        }

        print("(c2) shot --rect")
        let rectPNG = directory.appendingPathComponent("cli-rect.png")
        try? FileManager.default.removeItem(at: rectPNG)
        run = await client([
            "shot", "--rect",
            "\(Int(expected.minX)),\(Int(expected.minY)),\(Int(expected.width)),\(Int(expected.height))",
            "--out", rectPNG.path], socket: socket)
        check(run.status == 0, "exits 0", run.summary)
        if let bitmap = Bitmap(rectPNG) {
            check(bitmap.width == Int(400 * scale) && bitmap.height == Int(300 * scale),
                  "PNG is rect x scale", "\(bitmap.width)x\(bitmap.height)")
            assertQuadrants(bitmap, "rect PNG")
        } else {
            check(false, "rect PNG was written and decodes")
        }

        print("(d) fade guard")
        quadrants.alphaValue = 0.5
        try await Task.sleep(for: .milliseconds(300))
        let fadedPNG = directory.appendingPathComponent("cli-faded.png")
        try? FileManager.default.removeItem(at: fadedPNG)
        run = await client(["shot", "--window", "\(quadrantID)", "--out", fadedPNG.path],
                           socket: socket)
        check(run.status == CLIExit.retry && run.stderr.contains("still fading"),
              "alpha 0.5: exits 6 (retry), still fading", run.summary)
        check(!FileManager.default.fileExists(atPath: fadedPNG.path), "alpha 0.5: no file written")
        quadrants.alphaValue = 1
        try await Task.sleep(for: .milliseconds(300))
        run = await client(["shot", "--window", "\(quadrantID)", "--out", fadedPNG.path],
                           socket: socket)
        check(run.status == 0, "alpha 1.0: exits 0", run.summary)

        print("(c1) changed between the shape and the region")
        let racePNG = directory.appendingPathComponent("cli-race.png")
        for (label, change) in [
            ("closed", { @MainActor in quadrants.orderOut(nil) }),
            ("faded", { @MainActor in quadrants.alphaValue = 0.4 }),
        ] as [(String, @MainActor () -> Void)] {
            try? FileManager.default.removeItem(at: racePNG)
            engine.betweenAsSeenCapturesForTest = {
                change()
                try? await Task.sleep(for: .milliseconds(200))
            }
            run = await client(["shot", "--window", "\(quadrantID)", "--out", racePNG.path],
                               socket: socket)
            engine.betweenAsSeenCapturesForTest = nil
            check(run.status == CLIExit.retry && run.stderr.contains("while it was being captured")
                    && !FileManager.default.fileExists(atPath: racePNG.path),
                  "\(label) mid-capture: exits 6, no file", run.summary)
            quadrants.alphaValue = 1
            quadrants.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(400))
        }

        print("(s2) turning off cuts a connection already open")
        let held: Int32? = if case .success(let fd) = CLIWire.connect(to: socket) { fd } else { nil }
        if let held {
            // Long enough for the server to accept it and start reading.
            try await Task.sleep(for: .milliseconds(400))
            access.request(false)
            let answer = await lateRequest(on: held, window: quadrantID)
            check(!answer.ok && answer.bytes == 0,
                  "a request finished after off gets no reply and no pixels",
                  "reply ok=\(answer.ok), \(answer.bytes) bytes after the header")
            access.request(true)
        } else {
            check(false, "connected while on")
        }

        print("(a5) turned off at each re-check, nothing is captured or encoded")
        for stage in [CLIServer.Stage.afterRead, .beforeCapture, .beforeEncode] {
            let captures = server.capturesStartedForTest
            let encodes = server.encodesStartedForTest
            server.stageHookForTest = { reached in
                if reached == stage { access.request(false) }
            }
            var answer = (ok: true, bytes: -1)
            if case .success(let fd) = CLIWire.connect(to: socket) {
                answer = await lateRequest(on: fd, window: quadrantID)
            }
            // The client hears nothing the moment the gate goes off; the server
            // may still be working. Count only once it has let go.
            let waitStart = Date()
            while server.openConnectionsForTest > 0, Date().timeIntervalSince(waitStart) < 15 {
                try await Task.sleep(for: .milliseconds(100))
            }
            server.stageHookForTest = nil
            let started = stage == .beforeEncode
                ? server.encodesStartedForTest - encodes
                : server.capturesStartedForTest - captures
            check(!answer.ok && answer.bytes == 0 && started == 0,
                  "off at \(stage): no reply, no pixels, nothing started after it",
                  "ok=\(answer.ok) bytes=\(answer.bytes) \(stage == .beforeEncode ? "encodes" : "captures") started=\(started)")
            access.request(true)
        }

        print("(a3) a command-line shot leaves an interactive capture's snapshot alone")
        let interactive = CaptureEngine()
        let marker = window(
            frame: CGRect(x: screen.minX + 600, y: screen.minY + 80, width: 120, height: 90),
            colours: Array(repeating: Colour.green, count: 4), level: .floating)
        try await Task.sleep(for: .milliseconds(400))
        try await interactive.refreshContent()
        let markerID = CGWindowID(marker.windowNumber)
        let listedBefore = interactive.shareableContent.windows.contains { $0.id == markerID }
        marker.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
        let interactivePNG = directory.appendingPathComponent("cli-interactive.png")
        try? FileManager.default.removeItem(at: interactivePNG)
        run = await client(["shot", "--window", "\(quadrantID)", "--out", interactivePNG.path],
                           socket: socket)
        let listedAfter = interactive.shareableContent.windows.contains { $0.id == markerID }
        check(run.status == 0 && listedBefore && listedAfter,
              "the snapshot taken before still lists a window that has since closed",
              "before=\(listedBefore) after=\(listedAfter), \(run.summary)")
        quadrants.orderOut(nil)

        print("(a2) a reply nobody reads is cut at the deadline")
        let noise = noiseWindow(
            frame: CGRect(x: screen.minX + 80, y: screen.minY + 80, width: 600, height: 400))
        try await Task.sleep(for: .milliseconds(500))
        let trickle = Task { await trickleRead(socket: socket, window: UInt32(noise.windowNumber), seconds: 30) }
        let start = Date()
        try await Task.sleep(for: .milliseconds(500))
        while server.openConnectionsForTest > 0, Date().timeIntervalSince(start) < 32 {
            try await Task.sleep(for: .milliseconds(200))
        }
        let heldFor = Date().timeIntervalSince(start)
        let received = await trickle.value
        noise.orderOut(nil)
        check(heldFor < CLIServer.replyDeadline + 8 && received > 0,
              "a peer reading a byte a second is let go within the \(Int(CLIServer.replyDeadline)) s reply deadline",
              String(format: "connection held %.1f s, %d bytes read", heldFor, received))

        // --- (e) --panel ------------------------------------------------------
        print("(e) --app / --panel")
        let plain = window(
            frame: CGRect(x: screen.minX + 80, y: screen.minY + 80, width: 420, height: 320),
            colours: Array(repeating: Colour.blue, count: 4), level: .normal)
        let panel = window(
            frame: CGRect(x: screen.minX + 140, y: screen.minY + 140, width: 200, height: 150),
            colours: Array(repeating: Colour.green, count: 4),
            level: NSWindow.Level(rawValue: 101))
        try await Task.sleep(for: .milliseconds(500))
        let panelPNG = directory.appendingPathComponent("cli-panel.png")
        try? FileManager.default.removeItem(at: panelPNG)
        run = await client(["shot", "--app", owner, "--panel", "--out", panelPNG.path],
                           socket: socket)
        let panelShot = try? JSONDecoder().decode(CLIShot.self, from: run.stdoutData)
        check(run.status == 0 && panelShot?.window?.id == UInt32(panel.windowNumber),
              "--panel picks the panel above layer 0",
              "got \(panelShot?.window?.id ?? 0), panel \(panel.windowNumber), \(run.summary)")
        run = await client(["shot", "--app", owner, "--out", panelPNG.path], socket: socket)
        let plainShot = try? JSONDecoder().decode(CLIShot.self, from: run.stdoutData)
        check(run.status == 0 && plainShot?.window?.id == UInt32(plain.windowNumber),
              "--app alone picks the layer-0 window",
              "got \(plainShot?.window?.id ?? 0), window \(plain.windowNumber)")
        panel.orderOut(nil)
        run = await client(["shot", "--app", owner, "--panel", "--out", panelPNG.path],
                           socket: socket)
        check(run.status == CLIExit.captureFailed, "--panel with no panel exits 4", run.summary)
        plain.orderOut(nil)

        // --- (g) as seen vs isolated -------------------------------------------
        print("(g) as seen vs --isolated")
        try await asSeen(socket: socket, screen: screen, into: directory)

        // --- (r) record ------------------------------------------------------
        try await recordChecks(socket: socket, server: server, access: access, screen: screen, into: directory)

        // --- (f) frames -------------------------------------------------------
        print("(f) frames")
        try await frames(socket: socket, into: directory)

        print("(c4) what an unreachable app is told")
        check(CLIWire.diagnosis(runningCapable: []).contains("not running"),
              "nothing running: not running")
        check(CLIWire.diagnosis(runningCapable: [false]).contains("too old"),
              "only a DuoShot without the command line: too old")
        check(CLIWire.diagnosis(runningCapable: [false, true]).contains("is off"),
              "one that has it: turned off")

        print("(d2) quitting removes the socket; a stale one reads as off")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        check(!FileManager.default.fileExists(atPath: socket) && !access.isListening,
              "willTerminate: socket removed, not listening")
        let stale = socketDirectory.appendingPathComponent("stale.sock").path
        if makeStaleSocket(at: stale) {
            run = await client(["windows"], socket: stale)
            check(run.status == CLIExit.unreachable && run.stderr.contains("is off")
                    && !run.stderr.contains("refused"),
                  "a refused stale socket: exit 3, says off, no errno", run.summary)
        } else {
            check(false, "stale socket made")
        }
        access.request(true)

        print("(a) gate, off again")
        access.request(false)
        check(!FileManager.default.fileExists(atPath: socket) && !access.isListening,
              "off: socket removed")
        run = await client(["windows"], socket: socket)
        check(run.status == CLIExit.unreachable && run.stderr.contains("command-line capture is off"),
              "off: client exits 3 again", run.summary)

        if failures.isEmpty {
            print("result:        PASS")
            return 0
        }
        print("result:        FAIL — \(failures.count): \(failures.joined(separator: "; "))")
        return 1
    }

    /// `build/duoshot`, beside `build/DuoShot.app`.
    nonisolated private static var clientURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("duoshot")
    }

    private static let idleConnections = 12

    // MARK: - Record

    private static func recordChecks(
        socket: String, server: CLIServer, access: CommandLineAccess, screen: CGRect, into directory: URL
    ) async throws {
        let scale = NSScreen.screens[0].backingScaleFactor

        print("(r1) record --rect, and the menu bar says so while it runs")
        StatusItemController.buildsMenu = false
        let coordinator = CaptureCoordinator()
        let status = StatusItemController(
            coordinator: coordinator,
            recorder: RecordingCoordinator(overlay: coordinator.overlay),
            scroller: ScrollCaptureCoordinator(engine: coordinator.engine, overlay: coordinator.overlay))
        status.setUserShowsIcon(false)
        status.follow(access)
        defer {
            status.remove()
            access.onListeningChanged = nil
        }
        let target = window(
            frame: CGRect(x: screen.minX + 80, y: screen.minY + 80, width: 320, height: 240),
            colours: [Colour.red, Colour.green, Colour.blue, Colour.yellow], level: .floating)
        try await Task.sleep(for: .milliseconds(400))
        let rect = DisplayGeometry.flipped(target.frame)
        let rectArgument = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        let rectMovie = directory.appendingPathComponent("cli-record-rect.mp4")
        try? FileManager.default.removeItem(at: rectMovie)
        let rectTake = Task { await client(["record", "--rect", rectArgument, "--seconds", "2",
                                            "--out", rectMovie.path], socket: socket) }
        try await Task.sleep(for: .milliseconds(1200))
        let during = status.buttonForTest?.title ?? "<no item>"
        var run = await rectTake.value
        let after = status.buttonForTest?.title ?? "<no item>"
        let recorded = try? JSONDecoder().decode(CLIRecording.self, from: run.stdoutData)
        check(during.contains(":") && during.contains("CLI"),
              "while it records: the clock and the CLI mark in the menu bar", during)
        check(!after.contains(":"), "after it: no clock", after)
        let movieDuration = (try? await AVURLAsset(url: rectMovie).load(.duration).seconds) ?? 0
        check(run.status == 0 && recorded?.mode == "rect"
                && recorded?.pixelWidth == Int(rect.width * scale)
                && abs(movieDuration - 2) < 0.6 && abs((recorded?.duration ?? 0) - movieDuration) < 0.05,
              "the movie comes back, about 2 s, frame x scale",
              "\(run.summary) mode=\(recorded?.mode ?? "?") \(recorded?.pixelWidth ?? 0) px, \(String(format: "%.2f", movieDuration)) s")
        target.orderOut(nil)

        print("(r2) the cap")
        run = await client(["record", "--rect", rectArgument, "--seconds", "500",
                            "--out", rectMovie.path], socket: socket)
        check(run.status == CLIExit.usage, "--seconds 500: the client refuses, exit 2", run.summary)
        var capped = CLIRequest(command: .record)
        capped.rect = CLIRect(rect)
        capped.seconds = 500
        let reply = await rawReply(capped, socket: socket)
        check(reply?.ok == false && reply?.exitCode == CLIExit.usage,
              "--seconds 500 sent past the client: the app refuses too",
              reply.map { "exit \($0.exitCode ?? -1): \($0.error ?? "")" } ?? "no reply within 5 s")

        print("(r3) turned off mid-take")
        let offMovie = directory.appendingPathComponent("cli-record-off.mp4")
        try? FileManager.default.removeItem(at: offMovie)
        let offTake = Task { await client(["record", "--rect", rectArgument, "--seconds", "4",
                                           "--out", offMovie.path], socket: socket) }
        try await Task.sleep(for: .milliseconds(1200))
        let wasRecording = server.isRecordingForTest
        access.request(false)
        // The client is cut off at once either way; what matters is that the
        // app stops recording too, not when the take would have ended.
        let offAt = Date()
        while server.isRecordingForTest, Date().timeIntervalSince(offAt) < 3 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stoppedAfter = Date().timeIntervalSince(offAt)
        run = await offTake.value
        access.request(true)
        check(wasRecording && stoppedAfter < 1.5, "the app stops recording within 1.5 s of being turned off",
              String(format: "recording before: %@, stopped after %.2f s", wasRecording ? "yes" : "no", stoppedAfter))
        check(run.status == CLIExit.unreachable && !FileManager.default.fileExists(atPath: offMovie.path),
              "exit 3, no movie", run.summary)

        print("(r4) --isolated: a covered window, recorded on its own")
        let fixture = ClickTimelineSelfTest.FlipWindow(
            frame: CGRect(x: screen.minX + 140, y: screen.minY + 140, width: 360, height: 240))
        let cover = window(frame: fixture.frame.insetBy(dx: -30, dy: -30),
                           colours: Array(repeating: Colour.green, count: 4),
                           level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        let outsider = window(
            frame: CGRect(x: fixture.frame.maxX + 80, y: fixture.frame.minY, width: 120, height: 90),
            colours: Array(repeating: Colour.red, count: 4), level: .floating)
        defer {
            fixture.orderOut(nil)
            cover.orderOut(nil)
            outsider.orderOut(nil)
        }
        try await Task.sleep(for: .milliseconds(500))
        let fixtureRect = DisplayGeometry.flipped(fixture.frame)
        for isolated in [true, false] {
            let label = isolated ? "isolated" : "as_seen"
            let movie = directory.appendingPathComponent("cli-record-\(label).mp4")
            try? FileManager.default.removeItem(at: movie)
            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let aboveBefore = windowsAbove(fixture)
            let barShot = directory.appendingPathComponent("cli-menubar-before-\(label).png")
            let barRect = menuBarRect()
            _ = await client(["shot", "--rect", barRect, "--out", barShot.path], socket: socket)
            let windowsBefore = Set(onScreenWindowNames())
            var arguments = ["record", "--window", "\(fixture.windowNumber)", "--seconds", "4",
                             "--out", movie.path]
            if isolated { arguments.append("--isolated") }
            let take = Task { await client(arguments, socket: socket) }
            // The fixture changes on its own once a second; a click lands on
            // the cover over it, and one outside it entirely.
            var newWindows: [String] = []
            for step in 0..<6 {
                try await Task.sleep(for: .milliseconds(500))
                if step % 2 == 1 { fixture.flip() }
                if step == 2 {
                    _ = try await ClickTimelineSelfTest.postClick(
                        at: CGPoint(x: fixtureRect.minX + 60, y: fixtureRect.minY + 50), button: .left)
                    newWindows = onScreenWindowNames().filter { !windowsBefore.contains($0) }
                }
                if step == 3 {
                    _ = try await ClickTimelineSelfTest.postClick(
                        at: DisplayGeometry.flipped(CGPoint(x: outsider.frame.midX, y: outsider.frame.midY)),
                        button: .left)
                }
                if step == 4 {
                    // After the clicks: a shot takes a moment, and must not push
                    // one of them past the end of the take.
                    let during = directory.appendingPathComponent("cli-menubar-during-\(label).png")
                    _ = await client(["shot", "--rect", barRect, "--out", during.path], socket: socket)
                }
            }
            run = await take.value
            let info = try? JSONDecoder().decode(CLIRecording.self, from: run.stdoutData)
            let fractions = try await colourFractions(of: movie)
            let greenest = fractions.map(\.green).max() ?? -1
            let fixtureColours = Set(fractions.compactMap { $0.blue > 0.9 ? "blue" : $0.yellow > 0.9 ? "yellow" : nil })
            print("  \(label): \(fractions.count) frames, green per frame \(fractions.map { String(format: "%.0f%%", $0.green * 100) })")
            if isolated {
                check(run.status == 0 && info?.mode == "isolated", "--isolated: exit 0, says isolated", run.summary)
                check(greenest == 0 && fixtureColours == ["blue", "yellow"],
                      "--isolated: the window's own changing content, 0% of the cover in every frame",
                      String(format: "max green %.2f%%, fixture colours %@", greenest * 100, fixtureColours.sorted().joined(separator: ",")))
                _ = (frontBefore, aboveBefore)
                let differing = menuBarDifference(
                    directory.appendingPathComponent("cli-menubar-before-\(label).png"),
                    directory.appendingPathComponent("cli-menubar-during-\(label).png"))
                print("  menu bar right side, before vs during the take: \(differing) (photographs kept in the output directory)")
                print("  windows that appeared during the take (any system recording indicator would be here): \(newWindows.isEmpty ? "none" : newWindows.joined(separator: "; "))")
                let clicks = ((try? await ClickTimeline.read(from: movie)) ?? []).filter { $0.phase == "down" }
                let inside = clicks.first { !$0.outside }
                let outsideClick = clicks.first { $0.outside }
                check(clicks.count == 2 && inside.map {
                        abs($0.px - 60 * scale) <= 1 && abs($0.py - 50 * scale) <= 1 } == true
                        && outsideClick != nil,
                      "--isolated: clicks mapped into the window's pixels, the one outside it flagged",
                      clicks.map { String(format: "(%.0f,%.0f) px outside=%@", $0.px, $0.py, $0.outside ? "yes" : "no") }.joined(separator: "; "))
            } else {
                check(run.status == 0 && info?.mode == "as_seen" && greenest > 0.9,
                      "as seen: the cover is what the screen shows, so the movie shows it",
                      String(format: "%@ max green %.1f%%", run.summary, greenest * 100))
            }
        }

        print("(r4b) --isolated raises nothing: a take with no clicks posted during it")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let aboveBefore = windowsAbove(fixture)
        let quiet = directory.appendingPathComponent("cli-record-quiet.mp4")
        try? FileManager.default.removeItem(at: quiet)
        run = await client(["record", "--window", "\(fixture.windowNumber)", "--isolated", "--seconds", "1.5",
                            "--out", quiet.path], socket: socket)
        // Every window that was above the fixture and is still on screen is
        // still above it, and the frontmost application has not changed.
        let stillOnScreen = Set(CLIServer.onScreenWindows().map(\.window.id))
        let aboveAfter = Set(windowsAbove(fixture))
        let lost = aboveBefore.filter { stillOnScreen.contains($0) && !aboveAfter.contains($0) }
        let lostNames = CLIServer.onScreenWindows().filter { lost.contains($0.window.id) }
            .map { "\($0.window.owner)#\($0.window.id)" }
        check(run.status == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore
                && aboveBefore.contains(UInt32(cover.windowNumber)) && lost.isEmpty,
              "--isolated: nothing activated or raised (frontmost app; everything above it still above it)",
              "\(run.summary); front \(frontBefore ?? 0) -> \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), \(aboveBefore.count) above before, now below it: \(lostNames)")

        print("(r5) the window goes away mid-take")
        for minimize in [false, true] {
            let label = minimize ? "minimized" : "closed"
            let leaving = NSWindow(contentRect: CGRect(x: screen.minX + 160, y: screen.minY + 160, width: 300, height: 200),
                                   styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
            leaving.isReleasedWhenClosed = false
            leaving.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            let movie = directory.appendingPathComponent("cli-record-\(label).mp4")
            try? FileManager.default.removeItem(at: movie)
            let take = Task { await client(["record", "--window", "\(leaving.windowNumber)", "--isolated",
                                            "--seconds", "4", "--out", movie.path], socket: socket) }
            try await Task.sleep(for: .milliseconds(1500))
            if minimize { leaving.miniaturize(nil) } else { leaving.orderOut(nil) }
            run = await take.value
            let info = try? JSONDecoder().decode(CLIRecording.self, from: run.stdoutData)
            let kept = (try? await AVURLAsset(url: movie).load(.duration).seconds) ?? 0
            check(run.status == CLIExit.captureFailed && info?.endedEarly != nil && kept > 0.5 && kept < 3.5,
                  "\(label) mid-take: exit 4, says it ended early, keeps what was recorded",
                  String(format: "%@; movie %.2f s; ended_early: %@", run.summary, kept, info?.endedEarly ?? "nil"))
            leaving.orderOut(nil)
        }
    }

    /// The windows in front of this one, by the window server's own list and
    /// layers (the same rule `occluded_by` uses).
    private static func windowsAbove(_ window: NSWindow) -> [UInt32] {
        let list = CLIServer.onScreenWindows()
        guard let me = list.first(where: { $0.window.id == UInt32(window.windowNumber) }) else { return [] }
        return list.filter {
            $0.window.layer > me.window.layer || ($0.window.layer == me.window.layer && $0.depth < me.depth)
        }.map(\.window.id)
    }

    /// The right-hand 500 points of the menu bar, as `--rect` wants it.
    private static func menuBarRect() -> String {
        let main = NSScreen.screens[0].frame
        return "\(Int(main.width) - 500),0,500,24"
    }

    private static func menuBarDifference(_ a: URL, _ b: URL) -> String {
        guard let first = Bitmap(a), let second = Bitmap(b),
              first.width == second.width, first.height == second.height
        else { return "could not compare" }
        var differing = 0, total = 0
        for y in 0..<first.height {
            for x in 0..<first.width {
                total += 1
                let p = first.pixel(x, y), q = second.pixel(x, y)
                if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 30 { differing += 1 }
            }
        }
        return "\(differing) of \(total) pixels differ"
    }

    private static func onScreenWindowNames() -> [String] {
        CLIServer.onScreenWindows().map { "\($0.window.owner)#\($0.window.id) layer \($0.window.layer) \($0.window.title)" }
    }

    /// Per frame of the movie: the share of sampled pixels that are the
    /// cover's green, and the fixture's blue and yellow.
    private static func colourFractions(of url: URL) async throws -> [(t: Double, green: Double, blue: Double, yellow: Double)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var result: [(Double, Double, Double, Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            var green = 0, blue = 0, yellow = 0, total = 0
            for y in stride(from: 2, to: height - 2, by: 6) {
                for x in stride(from: 2, to: width - 2, by: 6) {
                    let p = base + y * row + x * 4
                    let (b, g, r) = (Int(p[0]), Int(p[1]), Int(p[2]))
                    total += 1
                    if g > 150, r < 100, b < 100 { green += 1 }
                    if b > 150, r < 100, g < 100 { blue += 1 }
                    if r > 150, g > 150, b < 100 { yellow += 1 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let n = Double(max(total, 1))
            result.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                           Double(green) / n, Double(blue) / n, Double(yellow) / n))
        }
        return result
    }

    /// Sends a request and reads the reply header, giving up after 5 s.
    @concurrent private static func rawReply(_ request: CLIRequest, socket: String) async -> CLIReply? {
        guard case .success(let fd) = CLIWire.connect(to: socket) else { return nil }
        defer { close(fd) }
        guard var line = try? CLIWire.encoder.encode(request) else { return nil }
        line.append(0x0A)
        guard CLIWire.writeAll(fd, line),
              let header = CLIWire.readLine(fd, limit: 1 << 20, within: 5)
        else { return nil }
        return try? JSONDecoder().decode(CLIReply.self, from: header)
    }

    // MARK: - Raw sockets

    /// Opens `count` connections that never send anything, and counts how many
    /// the server closes within 1.5 s. Closes them all before returning.
    @concurrent private static func openIdle(_ count: Int, to socket: String) async -> Int {
        var fds: [Int32] = []
        for _ in 0..<count {
            if case .success(let fd) = CLIWire.connect(to: socket) { fds.append(fd) }
            usleep(20_000)
        }
        defer { fds.forEach { close($0) } }
        let deadline = Date().addingTimeInterval(1.5)
        var closed = Set<Int32>()
        while Date() < deadline, closed.count < fds.count {
            for fd in fds where !closed.contains(fd) {
                var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&poll, 1, 0) > 0 {
                    var byte: UInt8 = 0
                    if read(fd, &byte, 1) <= 0 { closed.insert(fd) }
                }
            }
            usleep(50_000)
        }
        return closed.count + (count - fds.count)
    }

    /// Asks for a big image and then takes it a byte a second, for at most
    /// `seconds`. Returns how many bytes it got.
    @concurrent private static func trickleRead(socket: String, window: UInt32, seconds: Double) async -> Int {
        guard case .success(let fd) = CLIWire.connect(to: socket) else { return 0 }
        defer { close(fd) }
        var request = CLIRequest(command: .shot)
        request.window = window
        guard var line = try? CLIWire.encoder.encode(request) else { return 0 }
        line.append(0x0A)
        guard CLIWire.writeAll(fd, line) else { return 0 }
        let end = Date().addingTimeInterval(seconds)
        var total = 0
        var byte: UInt8 = 0
        while Date() < end {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 1000) > 0 else { continue }
            guard read(fd, &byte, 1) == 1 else { break }
            total += 1
            usleep(1_000_000)
        }
        return total
    }

    /// A socket file nobody listens on: what a crashed or killed DuoShot left.
    private static func makeStaleSocket(at path: String) -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = CLIWire.address(path) else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// Completes a shot request on a connection opened earlier, and reads what
    /// comes back.
    @concurrent private static func lateRequest(on fd: Int32, window: UInt32) async -> (ok: Bool, bytes: Int) {
        defer { close(fd) }
        var request = CLIRequest(command: .shot)
        request.window = window
        guard var line = try? CLIWire.encoder.encode(request) else { return (false, 0) }
        line.append(0x0A)
        _ = CLIWire.writeAll(fd, line)
        guard let header = CLIWire.readLine(fd, limit: 1 << 20, within: 15),
              let reply = try? JSONDecoder().decode(CLIReply.self, from: header)
        else { return (false, 0) }
        var rest = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            rest += n
        }
        return (reply.ok, rest)
    }

    private static func fakeListener(at path: String) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = CLIWire.address(path) else { return nil }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// One connection: a reply that claims 600 MB of image, and then nothing.
    @concurrent private static func serveHugeClaim(_ listener: Int32) async {
        defer { close(listener) }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        CLIWire.noSigPipe(client)
        _ = CLIWire.readLine(client, limit: 1 << 16, within: 10)
        let claim = CLIReply(ok: true, shot: CLIShot(
            mode: "as_seen", frame: CLIRect(.zero), scale: 1, pixelWidth: 1, pixelHeight: 1,
            alpha: 1, timestamp: ""), bytes: 600 * 1024 * 1024)
        guard var header = try? CLIWire.encoder.encode(claim) else { return }
        header.append(0x0A)
        _ = CLIWire.writeAll(client, header)
        // Stay open briefly, so a client that does try to read finds EOF only
        // after it has committed to the allocation.
        usleep(300_000)
    }

    // MARK: - The menu-bar mark

    /// The real status item, with the menu left out (it reads the Keychain).
    /// The icon is hidden throughout, so the item is up only because of the
    /// command line.
    private static func statusItemMark(_ access: CommandLineAccess) async throws {
        StatusItemController.buildsMenu = false
        let coordinator = CaptureCoordinator()
        let controller = StatusItemController(
            coordinator: coordinator,
            recorder: RecordingCoordinator(overlay: coordinator.overlay),
            scroller: ScrollCaptureCoordinator(engine: coordinator.engine, overlay: coordinator.overlay))
        access.request(false)
        controller.setUserShowsIcon(false)
        controller.follow(access)
        check(controller.buttonForTest == nil, "off, icon hidden: no item")
        access.request(true)
        let idle = controller.buttonForTest?.title ?? "<no item>"
        check(idle.contains("CLI"), "on, icon hidden: the item is up and marked", idle)
        controller.noteCaptureFailure(.other)
        let failed = controller.buttonForTest?.title ?? "<no item>"
        check(failed.contains("CLI"), "after a failure notice: still marked", failed)
        controller.recordingOverrideForTest = true
        controller.refreshRecordingState()
        let recording = controller.buttonForTest?.title ?? "<no item>"
        check(recording.contains("CLI") && recording.contains(":"),
              "while recording: the clock and the mark", recording)
        controller.recordingOverrideForTest = nil
        controller.refreshRecordingState()
        access.request(false)
        check(controller.buttonForTest == nil, "off again, icon hidden: no item")
        controller.remove()
        access.onListeningChanged = nil
        access.request(true)
    }

    // MARK: - As seen

    /// The glass check from CLAUDE.md, made a fixture: something loud parked
    /// directly behind a translucent window, and its pixels counted.
    private static func asSeen(socket: String, screen: CGRect, into directory: URL) async throws {
        let frame = CGRect(x: screen.minX + 120, y: screen.minY + 120, width: 400, height: 300)
        // Overlaps the fixture from a lower layer: behind it, whatever the
        // window list's order.
        let lower = window(frame: frame.offsetBy(dx: 200, dy: -60),
                           colours: Array(repeating: Colour.yellow, count: 4), level: .normal)
        let backdrop = window(frame: frame.insetBy(dx: -40, dy: -40),
                              colours: Array(repeating: Colour.red, count: 4), level: .floating)
        // TL opaque blue, TR translucent white, BL nothing at all, BR opaque yellow.
        let fixture = window(
            frame: frame,
            colours: [Colour.blue, NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35),
                      nil, Colour.yellow],
            level: .floating)
        // Over the fixture's top-left corner and nothing else of interest.
        let occluder = window(
            frame: CGRect(x: frame.minX - 20, y: frame.maxY - 60, width: 80, height: 80),
            colours: Array(repeating: Colour.green, count: 4), level: .floating)
        // In front of all of it, the size of the fixture, and draws nothing.
        let glassPane = window(frame: frame, colours: [nil, nil, nil, nil],
                               level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        defer {
            glassPane.orderOut(nil)
            occluder.orderOut(nil)
            fixture.orderOut(nil)
            backdrop.orderOut(nil)
            lower.orderOut(nil)
        }
        try await Task.sleep(for: .milliseconds(500))
        let id = "\(fixture.windowNumber)"

        let seenPNG = directory.appendingPathComponent("cli-as-seen.png")
        try? FileManager.default.removeItem(at: seenPNG)
        var run = await client(["shot", "--window", id, "--out", seenPNG.path], socket: socket)
        let seen = try? JSONDecoder().decode(CLIShot.self, from: run.stdoutData)
        check(run.status == 0 && seen?.mode == "as_seen", "as seen: exits 0, says as_seen", run.summary)
        let listed = seen?.occludedBy?.map(\.id) ?? []
        let expectedOverlap = DisplayGeometry.flipped(occluder.frame)
            .intersection(DisplayGeometry.flipped(frame))
        let reported = seen?.occludedBy?.first { $0.id == UInt32(occluder.windowNumber) }
        check(reported.map { same($0.overlap.cgRect, expectedOverlap) } ?? false,
              "as seen: the opaque window over it is in occluded_by, with the overlap",
              "\(reported?.overlap.cgRect ?? .null) vs \(expectedOverlap)")
        check(!listed.contains(UInt32(glassPane.windowNumber)),
              "as seen: a window over it that draws nothing there is not", "listed \(listed)")
        check(!listed.contains(UInt32(backdrop.windowNumber)) && !listed.contains(UInt32(lower.windowNumber)),
              "as seen: windows behind it, same layer or lower, are not", "listed \(listed)")

        let isolatedPNG = directory.appendingPathComponent("cli-isolated.png")
        try? FileManager.default.removeItem(at: isolatedPNG)
        run = await client(["shot", "--window", id, "--isolated", "--out", isolatedPNG.path],
                           socket: socket)
        let isolated = try? JSONDecoder().decode(CLIShot.self, from: run.stdoutData)
        check(run.status == 0 && isolated?.mode == "isolated",
              "--isolated: exits 0, says isolated", run.summary)

        guard let seenBitmap = Bitmap(seenPNG), let isolatedBitmap = Bitmap(isolatedPNG) else {
            check(false, "both PNGs decode")
            return
        }
        // Interiors, clear of edges and of the occluder in the top-left corner.
        let translucent = CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3)
        let empty = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.3)
        let seenRed = seenBitmap.fraction(in: translucent) { $0.isRed && $0.a > 0 }
        let isolatedRed = isolatedBitmap.fraction(in: translucent) { $0.isRed && $0.a > 0 }
        check(seenRed > 0.9, "as seen: the red behind shows through the translucent part",
              String(format: "%.1f%% red", seenRed * 100))
        check(isolatedRed < 0.01, "--isolated: it does not",
              String(format: "%.1f%% red", isolatedRed * 100))
        let seenVisible = seenBitmap.fraction(in: empty) { $0.a > 8 }
        check(seenVisible < 0.01, "as seen: cut to the window's alpha, nothing where it drew nothing",
              String(format: "%.1f%% visible", seenVisible * 100))
        check(seenBitmap.colour(atFraction: CGPoint(x: 0.25, y: 0.3)) == "blue"
                && seenBitmap.colour(atFraction: CGPoint(x: 0.75, y: 0.75)) == "yellow",
              "as seen: the opaque parts are where they belong")
    }

    // MARK: - Frames

    private static func frames(socket: String, into directory: URL) async throws {
        let video = directory.appendingPathComponent("cli-fixture.mp4")
        guard await writeFixtureVideo(to: video) else {
            check(false, "fixture video written")
            return
        }
        let fps = 30.0

        let atDirectory = directory.appendingPathComponent("cli-frames-at")
        try? FileManager.default.removeItem(at: atDirectory)
        var run = await client(["frames", video.path, "--out", atDirectory.path,
                                "--at", "0.5,1.5,2.5", "--crop", "0,0,320,120"], socket: socket)
        var report = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        check(run.status == 0 && report?.frames.count == 3, "--at: three frames", run.summary)
        let wanted = ["red", "green", "blue"]
        for (index, frame) in (report?.frames ?? []).enumerated() {
            let bitmap = Bitmap(URL(fileURLWithPath: frame.path))
            let colour = bitmap?.colour(atFraction: CGPoint(x: 0.5, y: 0.5))
            check(bitmap?.width == 320 && bitmap?.height == 120 && colour == wanted[index],
                  "--at \(frame.time) s, cropped to the top band, is \(wanted[index])",
                  "\(bitmap?.width ?? 0)x\(bitmap?.height ?? 0) \(colour ?? "?")")
        }

        // Adjacent frames in one request: the batch that used to fail its
        // second time with "Cannot Decode".
        let adjacentDirectory = directory.appendingPathComponent("cli-frames-adjacent")
        try? FileManager.default.removeItem(at: adjacentDirectory)
        run = await client(["frames", video.path, "--out", adjacentDirectory.path,
                            "--at", "0.95,0.9833,1.0,1.0333", "--crop", "0,0,320,120"], socket: socket)
        report = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        let adjacentTimes = report?.frames.map { ($0.time * 1000).rounded() / 1000 } ?? []
        let adjacentColours = report?.frames.map {
            Bitmap(URL(fileURLWithPath: $0.path))?.colour(atFraction: CGPoint(x: 0.5, y: 0.5)) ?? "?"
        } ?? []
        check(run.status == 0 && adjacentTimes == [0.933, 0.967, 1.0, 1.033]
                && adjacentColours == ["red", "red", "green", "green"],
              "--at four adjacent frames: each the frame on screen at that time",
              "\(adjacentTimes) \(adjacentColours) \(run.summary)")

        let sceneDirectory = directory.appendingPathComponent("cli-frames-scene")
        try? FileManager.default.removeItem(at: sceneDirectory)
        run = await client(["frames", video.path, "--out", sceneDirectory.path, "--scene"],
                           socket: socket)
        report = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        let changes = report?.changes?.map(\.time) ?? []
        let detail = report?.changes.map { "\($0.map { ($0.time, $0.score) })" } ?? run.summary
        func near(_ t: Double) -> Bool { changes.contains { abs($0 - t) < 0.5 / fps } }
        check(run.status == 0 && near(1) && near(2),
              "--scene: the colour changes at 1 s and 2 s, to the frame", detail)
        check(near(2.5), "--scene: a text-sized mark appearing at 2.5 s, to the frame", detail)
        check(changes.contains { $0 > 3 && $0 <= 4 }, "--scene: a one-second fade from 3 s", detail)
        check(changes.count == 4, "--scene: four changes and nothing else", detail)
        check(report?.frames.count == changes.count + 1,
              "--scene: a frame for the start and for each change")

        let tileDirectory = directory.appendingPathComponent("cli-frames-tile")
        try? FileManager.default.removeItem(at: tileDirectory)
        run = await client(["frames", video.path, "--out", tileDirectory.path,
                            "--at", "0.5,1.5,2.5", "--tile", "3x1"], socket: socket)
        report = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        check(report?.frames.count == 3
                && report?.frames.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) == true,
              "--tile: the frames are written and listed too")
        if let sheet = report?.sheets?.first, let bitmap = Bitmap(URL(fileURLWithPath: sheet.path)) {
            // Each cell is the frame above a label strip; its top band is the
            // changing colour.
            let cells = (0..<3).map { index in
                bitmap.colour(atFraction: CGPoint(x: (Double(index) + 0.5) / 3, y: 0.2))
            }
            check(report?.sheets?.count == 1 && cells == wanted,
                  "--tile 3x1: one sheet, cells in time order", "\(cells)")
        } else {
            check(false, "--tile wrote a sheet", run.summary)
        }

        let capDirectory = directory.appendingPathComponent("cli-frames-cap")
        try? FileManager.default.removeItem(at: capDirectory)
        run = await client(["frames", video.path, "--out", capDirectory.path,
                            "--every", "0.1", "--tile", "10x1"], socket: socket)
        report = try? JSONDecoder().decode(CLIFramesReport.self, from: run.stdoutData)
        let sheets = report?.sheets ?? []
        let sizes = sheets.compactMap { Bitmap(URL(fileURLWithPath: $0.path)) }
        check(run.status == 0 && sheets.count == 5 && sizes.count == 5
                && sizes.allSatisfy { max($0.width, $0.height) <= 2000 }
                && sheets.allSatisfy { abs($0.cellScale - 0.625) < 0.002 },
              "--tile 10x1 of 320 px frames: capped at 2000 px, cell_scale 0.625",
              "\(sizes.map { "\($0.width)x\($0.height)" }) \(sheets.map(\.cellScale))")
    }

    /// 320x240 at 30 fps for 5 s.
    ///
    /// Top half: red, then green from 1 s, then blue from 2 s. Bottom half grey,
    /// with a dark 24x8 mark — about a word of text — appearing at 2.5 s, and a
    /// 60x40 block fading from grey to white between 3 s and 4 s, never more
    /// than ~4 grey levels from one frame to the next.
    @concurrent private static func writeFixtureVideo(to url: URL) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let width = 320, height = 240
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        // BGRA.
        let phases: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255]]
        for index in 0..<150 {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let top = phases[min(2, index / 30)]
            let fade = UInt8(128 + 127 * min(1, max(0, Double(index - 90) / 30)))
            for y in 0..<height {
                for x in 0..<width {
                    var colour: [UInt8] = y < height / 2 ? top : [128, 128, 128, 255]
                    if index >= 75, (20..<44).contains(x), (180..<188).contains(y) {
                        colour = [30, 30, 30, 255]
                    }
                    if (240..<300).contains(x), (180..<220).contains(y) {
                        colour = [fade, fade, fade, 255]
                    }
                    let p = base + y * stride + x * 4
                    p[0] = colour[0]; p[1] = colour[1]; p[2] = colour[2]; p[3] = colour[3]
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30))
            else { return false }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    // MARK: - The client, for real

    struct ClientRun: Sendable {
        let status: Int32
        let stdoutData: Data
        let stderr: String

        var summary: String {
            "exit \(status)\(stderr.isEmpty ? "" : ": " + stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// The helper in this bundle — or, for (s4), another executable given `cli`
    /// in front — pointed at the test's socket. Output goes to files rather
    /// than pipes so a chatty stderr cannot stall it, and a run that has not
    /// finished in a minute is killed and reported as such.
    @concurrent static func client(
        _ arguments: [String], socket: String, executable: URL? = nil
    ) async -> ClientRun {
        let process = Process()
        if let executable {
            process.executableURL = executable
            process.arguments = ["cli"] + arguments
        } else {
            process.executableURL = clientURL
            process.arguments = arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment[CLIWire.socketEnvironmentKey] = socket
        process.environment = environment
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("duoshot-cli-run-\(UUID().uuidString)")
        let outURL = scratch.appendingPathExtension("out")
        let errURL = scratch.appendingPathExtension("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let out = try? FileHandle(forWritingTo: outURL),
              let err = try? FileHandle(forWritingTo: errURL)
        else { return ClientRun(status: -1, stdoutData: Data(), stderr: "no scratch files") }
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ClientRun(status: -1, stdoutData: Data(), stderr: "\(error)")
        }
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            process.waitUntilExit()
        }
        try? out.close()
        try? err.close()
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ClientRun(
            status: timedOut ? -2 : process.terminationStatus,
            stdoutData: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: timedOut ? "TIMED OUT after 60 s. " + stderr : stderr)
    }

    // MARK: - Fixtures

    private enum Colour {
        static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        static let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        static let yellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    }

    /// A borderless window in four quadrants: top-left, top-right, bottom-left,
    /// bottom-right. Nil leaves that quadrant undrawn.
    private static func window(frame: CGRect, colours: [NSColor?], level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let opaque = colours.allSatisfy { ($0?.alphaComponent ?? 0) == 1 }
        window.isOpaque = opaque
        window.backgroundColor = opaque ? .black : .clear
        window.hasShadow = false
        window.level = level
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = QuadrantView(colours: colours)
        window.orderFrontRegardless()
        return window
    }

    /// Random pixels, so its PNG is megabytes and cannot sit in a socket buffer.
    private static func noiseWindow(frame: CGRect) -> NSWindow {
        let width = Int(frame.width * 2), height = Int(frame.height * 2)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
            bytes[i + 1] = UInt8(truncatingIfNeeded: seed >> 32)
            bytes[i + 2] = UInt8(truncatingIfNeeded: seed >> 40)
        }
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        view.imageScaling = .scaleAxesIndependently
        view.image = image.map { NSImage(cgImage: $0, size: frame.size) }
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private final class QuadrantView: NSView {
        let colours: [NSColor?]

        init(colours: [NSColor?]) {
            self.colours = colours
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
            let w = bounds.width / 2, h = bounds.height / 2
            // AppKit is bottom-left: "top" is the upper half.
            let rects = [CGRect(x: 0, y: h, width: w, height: h), CGRect(x: w, y: h, width: w, height: h),
                         CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w, y: 0, width: w, height: h)]
            for (rect, colour) in zip(rects, colours) {
                guard let colour else { continue }
                colour.setFill()
                rect.fill(using: .copy)
            }
        }
    }

    private static func assertQuadrants(_ bitmap: Bitmap, _ label: String) {
        let found = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                     CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
            .map { bitmap.colour(atFraction: $0) ?? "?" }
        check(found == ["red", "green", "blue", "yellow"],
              "\(label): each colour in its own quadrant (TL, TR, BL, BR)", "\(found)")
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
            && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    // MARK: - Pixels

    /// A PNG decoded into sRGB, unpremultiplied, rows from the top.
    private struct Bitmap {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        struct Pixel {
            let r: Int, g: Int, b: Int, a: Int
            var isRed: Bool { r > 150 && g < 130 && b < 130 }
        }

        init?(_ url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
        }

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let i = (y * width + x) * 4
            let a = Int(bytes[i + 3])
            func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int(v) * 255 / a) }
            return Pixel(r: un(bytes[i]), g: un(bytes[i + 1]), b: un(bytes[i + 2]), a: a)
        }

        /// The share of pixels in a region, given as fractions of the image,
        /// for which `test` holds.
        func fraction(in region: CGRect, _ test: (Pixel) -> Bool) -> Double {
            var hits = 0, total = 0
            let x0 = Int(region.minX * Double(width)), x1 = Int(region.maxX * Double(width))
            let y0 = Int(region.minY * Double(height)), y1 = Int(region.maxY * Double(height))
            for y in Swift.stride(from: y0, to: y1, by: 2) {
                for x in Swift.stride(from: x0, to: x1, by: 2) {
                    total += 1
                    if test(pixel(x, y)) { hits += 1 }
                }
            }
            return total == 0 ? 0 : Double(hits) / Double(total)
        }

        func colour(atFraction point: CGPoint) -> String? {
            let x = min(width - 1, Int(point.x * Double(width)))
            let y = min(height - 1, Int(point.y * Double(height)))
            let p = pixel(x, y)
            guard p.a > 200 else { return "clear" }
            if p.r > p.g + 80, p.r > p.b + 80 { return "red" }
            if p.g > p.r + 80, p.g > p.b + 80 { return "green" }
            if p.b > p.r + 80, p.b > p.g + 80 { return "blue" }
            if p.r > 170, p.g > 170, p.b < 100 { return "yellow" }
            if abs(p.r - p.g) < 30, abs(p.g - p.b) < 30 { return "grey" }
            return "other(\(p.r),\(p.g),\(p.b))"
        }
    }
}
