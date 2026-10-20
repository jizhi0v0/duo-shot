import AppKit
import Darwin
import DuoShotCLIWire

/// The client half of the command line — the `duoshot` tool an agent runs.
///
/// Its own executable, signed with its own identifier and kept outside
/// DuoShot.app, so that nothing run through it runs as DuoShot (see
/// `CLIWire`). Never creates `NSApplication`, never touches the window
/// server's pixels and never calls a capture API:
/// `windows` and `shot` are asked of the running app, which holds the Screen
/// Recording grant, and `frames` reads a file. Data goes to stdout as JSON,
/// errors to stderr, and the exit status says which kind of failure it was
/// (`CLIExit`).
@MainActor
package enum CLIClient {
    static let usage = """
        usage: duoshot <command> …

          windows [--app NAME | --pid N]
              On-screen windows, front to back, as JSON.
          shot --out PATH.png (--window ID | --app NAME [--panel] | --rect x,y,w,h) [--isolated]
              Capture through the running DuoShot. A window is taken as it looks
              on screen unless --isolated asks for it rendered alone.
          frames VIDEO --out DIR (--at t1,t2,… | --every SECONDS | --scene [THRESHOLD])
                 [--crop x,y,w,h] [--tile COLSxROWS]
              Stills from a video file. Runs here; needs no running DuoShot.
              With a DuoShot recording, the JSON also lists its clicks, each --scene
              change says how long after a click it came (after_click_ms), and
              frames near a click get a ring drawn on them (said in the JSON).
          record --out F.mp4 (--window ID | --app NAME [--panel] | --rect x,y,w,h)
                 --seconds N [--isolated]
              Record through the running DuoShot, at most 120 s; the menu bar shows
              the clock while it runs. --isolated records the window on its own,
              covered or not, without raising it. Exit 4 with the movie still
              written when the take ended early (the window went away).
              The JSON lists every frame written; --tile adds contact sheets
              (each at most 2000 px on its long edge).

        Window frames and --rect are global points, origin top-left of the main
        display (kCGWindowBounds, screencapture -R). --crop is video pixels,
        origin top-left.

        exit status: 0 ok, 2 usage, 3 DuoShot unreachable,
                     4 capture failed (no such window or panel, or it went away),
                     5 frames failed,
                     6 window still fading or changed while captured (retry)

        """

    /// Runs the command and exits. The run loop is `dispatchMain`, not AppKit's.
    package static func main(_ arguments: [String]) -> Never {
        Task {
            exit(await run(arguments))
        }
        dispatchMain()
    }

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else { return usageError("no command") }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "windows": return windows(rest)
        case "shot": return shot(rest)
        case "frames": return await frames(rest)
        case "record": return record(rest)
        case "-h", "--help", "help":
            FileHandle.standardOutput.write(Data(usage.utf8))
            return CLIExit.ok
        default: return usageError("unknown command '\(command)'")
        }
    }

    // MARK: - windows

    private static func windows(_ arguments: [String]) -> Int32 {
        var options = Options(arguments)
        let app = options.value("--app")
        let pidText = options.value("--pid")
        guard options.isEmpty else { return usageError(options.leftover) }
        if app != nil, pidText != nil { return usageError("--app and --pid are exclusive") }
        var pid: Int32?
        if let pidText {
            guard let parsed = Int32(pidText) else { return usageError("--pid needs a number") }
            pid = parsed
        }
        let request = CLIRequest(command: .windows, app: app, pid: pid)
        switch exchange(request) {
        case .failure(let code): return code
        case .success(let (reply, _)):
            printJSON(reply.windows ?? [CLIWindow]())
            return CLIExit.ok
        }
    }

    // MARK: - record

    private static func record(_ arguments: [String]) -> Int32 {
        var options = Options(arguments)
        let out = options.value("--out")
        let window = options.value("--window")
        let app = options.value("--app")
        let rect = options.value("--rect")
        let secondsText = options.value("--seconds")
        let panel = options.flag("--panel")
        let isolated = options.flag("--isolated")
        guard options.isEmpty else { return usageError(options.leftover) }
        guard let out else { return usageError("record needs --out PATH.mp4") }
        guard [window, app, rect].compactMap({ $0 }).count == 1 else {
            return usageError("record needs exactly one of --window, --app, --rect")
        }
        guard let secondsText, let seconds = Double(secondsText), seconds > 0,
              seconds <= CLIWire.maximumRecordSeconds
        else { return usageError("record needs --seconds above 0 and at most \(Int(CLIWire.maximumRecordSeconds))") }
        if panel, app == nil { return usageError("--panel goes with --app") }
        if isolated, rect != nil { return usageError("--isolated is for a window, not --rect") }

        var request = CLIRequest(command: .record)
        if let window {
            guard let id = UInt32(window) else { return usageError("--window needs a window id") }
            request.window = id
        }
        request.app = app
        request.panel = panel ? true : nil
        request.isolated = isolated ? true : nil
        request.seconds = seconds
        if let rect {
            guard let parsed = CLIRect(argument: rect) else {
                return usageError("--rect needs x,y,w,h with a positive size")
            }
            request.rect = parsed
        }

        let url = URL(fileURLWithPath: out).standardizedFileURL
        switch exchangeToFile(request, waiting: seconds + 60, file: url) {
        case .failure(let code): return code
        case .success(let (reply, _)):
            guard var recording = reply.recording else {
                return fail("DuoShot sent no movie", CLIExit.captureFailed)
            }
            recording.path = url.path
            printJSON(recording)
            if let early = recording.endedEarly {
                return fail("the take ended early: \(early); what was recorded is in \(url.path)",
                            CLIExit.captureFailed)
            }
            return CLIExit.ok
        }
    }

    // MARK: - shot

    private static func shot(_ arguments: [String]) -> Int32 {
        var options = Options(arguments)
        let out = options.value("--out")
        let window = options.value("--window")
        let app = options.value("--app")
        let rect = options.value("--rect")
        let panel = options.flag("--panel")
        let isolated = options.flag("--isolated")
        guard options.isEmpty else { return usageError(options.leftover) }
        guard let out else { return usageError("shot needs --out PATH.png") }
        guard [window, app, rect].compactMap({ $0 }).count == 1 else {
            return usageError("shot needs exactly one of --window, --app, --rect")
        }
        if panel, app == nil { return usageError("--panel goes with --app") }
        if isolated, rect != nil { return usageError("--isolated is for a window, not --rect") }

        var request = CLIRequest(command: .shot)
        if let window {
            guard let id = UInt32(window) else { return usageError("--window needs a window id") }
            request.window = id
        }
        request.app = app
        request.panel = panel ? true : nil
        request.isolated = isolated ? true : nil
        if let rect {
            guard let parsed = CLIRect(argument: rect) else {
                return usageError("--rect needs x,y,w,h with a positive size")
            }
            request.rect = parsed
        }

        switch exchange(request) {
        case .failure(let code): return code
        case .success(let (reply, png)):
            guard var shot = reply.shot, let png else {
                return fail("DuoShot sent no image", CLIExit.captureFailed)
            }
            // The app returned bytes; where they go is decided here and only here.
            let url = URL(fileURLWithPath: out).standardizedFileURL
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                return fail("cannot write \(url.path): \(error.localizedDescription)",
                            CLIExit.captureFailed)
            }
            shot.path = url.path
            printJSON(shot)
            return CLIExit.ok
        }
    }

    // MARK: - frames

    private static func frames(_ arguments: [String]) async -> Int32 {
        var options = Options(arguments)
        let out = options.value("--out")
        let at = options.value("--at")
        let every = options.value("--every")
        let scene = options.flag("--scene")
        // An optional number right after --scene.
        var threshold = CLIFrames.defaultSceneThreshold
        if scene, let value = options.leadingNumber() { threshold = value }
        let crop = options.value("--crop")
        let tile = options.value("--tile")
        guard let video = options.positional() else { return usageError("frames needs a VIDEO") }
        guard options.isEmpty else { return usageError(options.leftover) }
        guard let out else { return usageError("frames needs --out DIR") }
        guard [at != nil, every != nil, scene].filter({ $0 }).count == 1 else {
            return usageError("frames needs exactly one of --at, --every, --scene")
        }

        let selection: CLIFrames.Selection
        if let at {
            let times = at.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !times.isEmpty, times.allSatisfy({ $0 != nil }) else {
                return usageError("--at needs seconds, comma-separated")
            }
            selection = .at(times.compactMap { $0 })
        } else if let every {
            guard let step = Double(every), step > 0 else {
                return usageError("--every needs a positive number of seconds")
            }
            selection = .every(step)
        } else {
            guard threshold >= 0 else { return usageError("--scene threshold must be ≥ 0") }
            selection = .scene(threshold: threshold)
        }

        var job = CLIFrames.Job(
            video: URL(fileURLWithPath: video).standardizedFileURL,
            directory: URL(fileURLWithPath: out).standardizedFileURL,
            selection: selection)
        if let crop {
            guard let parsed = CLIRect(argument: crop) else {
                return usageError("--crop needs x,y,w,h with a positive size")
            }
            job.crop = parsed
        }
        if let tile {
            let parts = tile.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                return usageError("--tile needs COLSxROWS, e.g. 4x3")
            }
            job.tile = (parts[0], parts[1])
        }

        do {
            printJSON(try await CLIFrames.run(job))
            return CLIExit.ok
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return fail(message, CLIExit.framesFailed)
        }
    }

    // MARK: - Talking to the app

    private static var socketPath: String {
        ProcessInfo.processInfo.environment[CLIWire.socketEnvironmentKey]
            ?? CLIWire.defaultSocketPath
    }

    /// One request, one reply, and the image after it when there is one.
    private enum Exchange {
        case success((CLIReply, Data?))
        case failure(Int32)
    }

    private static func exchange(_ request: CLIRequest, waiting: Double = 60) -> Exchange {
        let fd: Int32
        switch CLIWire.connect(to: socketPath) {
        case .success(let connected): fd = connected
        case .failure(let error): return .failure(unreachable(error.code))
        }
        defer { close(fd) }
        CLIWire.setTimeout(fd, seconds: 30)

        guard var line = try? CLIWire.encoder.encode(request) else {
            return .failure(fail("cannot encode the request", CLIExit.usage))
        }
        line.append(0x0A)
        guard CLIWire.writeAll(fd, line), let header = CLIWire.readLine(fd, limit: 1 << 20, within: waiting),
              let reply = try? JSONDecoder().decode(CLIReply.self, from: header)
        else { return .failure(fail("DuoShot did not answer", CLIExit.unreachable)) }

        guard reply.ok else {
            return .failure(fail(reply.error ?? "DuoShot refused the request",
                                 reply.exitCode ?? CLIExit.captureFailed))
        }
        guard let count = reply.bytes, count > 0 else { return .success((reply, nil)) }
        // Before allocating: the length is the peer's say-so.
        guard count <= CLIWire.maximumPayload else {
            return .failure(fail("reply claims \(count) bytes, more than any screenshot; refused",
                                 CLIExit.captureFailed))
        }
        guard let payload = CLIWire.readExactly(fd, count) else {
            return .failure(fail("the image was cut short", CLIExit.captureFailed))
        }
        return .success((reply, payload))
    }

    /// Like `exchange`, for a reply that carries a movie: the bytes go straight
    /// to a hidden file beside `file` and are moved into place once complete,
    /// never held whole in memory.
    private static func exchangeToFile(_ request: CLIRequest, waiting: Double, file: URL) -> Exchange {
        let fd: Int32
        switch CLIWire.connect(to: socketPath) {
        case .success(let connected): fd = connected
        case .failure(let error): return .failure(unreachable(error.code))
        }
        defer { close(fd) }
        CLIWire.setTimeout(fd, seconds: 30)
        guard var line = try? CLIWire.encoder.encode(request) else {
            return .failure(fail("cannot encode the request", CLIExit.usage))
        }
        line.append(0x0A)
        guard CLIWire.writeAll(fd, line), let header = CLIWire.readLine(fd, limit: 1 << 20, within: waiting),
              let reply = try? JSONDecoder().decode(CLIReply.self, from: header)
        else { return .failure(fail("DuoShot did not answer", CLIExit.unreachable)) }
        guard reply.ok else {
            return .failure(fail(reply.error ?? "DuoShot refused the request",
                                 reply.exitCode ?? CLIExit.captureFailed))
        }
        guard let count = reply.bytes, count > 0 else {
            return .failure(fail("DuoShot sent no movie", CLIExit.captureFailed))
        }
        guard count <= CLIWire.maximumMoviePayload else {
            return .failure(fail("reply claims \(count) bytes, more than any recording; refused",
                                 CLIExit.captureFailed))
        }
        let partial = file.deletingLastPathComponent()
            .appendingPathComponent(".duoshot-partial-\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial)
        else { return .failure(fail("cannot write beside \(file.path)", CLIExit.captureFailed)) }
        var received = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while received < count {
            let n = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, min($0.count, count - received))
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            handle.write(Data(buffer[0..<n]))
            received += n
        }
        try? handle.close()
        guard received == count else {
            try? FileManager.default.removeItem(at: partial)
            return .failure(fail("the movie was cut short (\(received) of \(count) bytes)", CLIExit.captureFailed))
        }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .failure(fail("cannot write \(file.path): \(error.localizedDescription)", CLIExit.captureFailed))
        }
        return .success((reply, nil))
    }

    /// Not reachable. Which of three things is true decides what to do about
    /// it, so it is worked out rather than left to the reader of an errno:
    /// DuoShot is not running; it is, but too old to have a command line; or
    /// it has one and the user has not turned it on. A socket left behind by
    /// an instance that is gone (connection refused) is the same answer as no
    /// socket at all, so the errno is only shown when it is something else.
    private static func unreachable(_ code: POSIXErrorCode) -> Int32 {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.executableURL?.lastPathComponent == "DuoShot" }
            .map { app in
                app.bundleURL.flatMap(Bundle.init(url:))?
                    .object(forInfoDictionaryKey: CLIWire.capabilityKey) != nil
            }
        let message = CLIWire.diagnosis(runningCapable: running)
        switch code {
        case .ENOENT, .ECONNREFUSED:
            return fail(message, CLIExit.unreachable)
        default:
            return fail("\(message) (\(String(cString: strerror(code.rawValue))))", CLIExit.unreachable)
        }
    }

    // MARK: - Output

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = CLIWire.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func fail(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("duoshot: \(message)\n".utf8))
        return code
    }

    private static func usageError(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("duoshot: \(message)\n\n\(usage)".utf8))
        return CLIExit.usage
    }

    /// Takes options out of an argument list; whatever is left over is wrong.
    private struct Options {
        private var arguments: [String]

        init(_ arguments: [String]) { self.arguments = arguments }

        var isEmpty: Bool { arguments.isEmpty }
        var leftover: String { "unexpected '\(arguments.joined(separator: " "))'" }

        mutating func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name),
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--")
            else { return nil }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return value
        }

        mutating func flag(_ name: String) -> Bool {
            guard let index = arguments.firstIndex(of: name) else { return false }
            lastFlagIndex = index
            arguments.remove(at: index)
            return true
        }

        private var lastFlagIndex: Int?

        /// A number sitting where the last flag taken was.
        mutating func leadingNumber() -> Double? {
            guard let index = lastFlagIndex, index < arguments.count,
                  let number = Double(arguments[index])
            else { return nil }
            arguments.remove(at: index)
            return number
        }

        mutating func positional() -> String? {
            guard let index = arguments.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
            return arguments.remove(at: index)
        }
    }
}
