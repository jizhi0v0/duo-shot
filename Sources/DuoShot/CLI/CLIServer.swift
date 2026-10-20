import AppKit
import Darwin
import DuoShotCLIWire
import Observation

/// Where "Allow command-line capture" is kept between launches.
///
/// **Read from the persistent domain only.** `UserDefaults.bool(forKey:)`
/// answers from the argument domain first, so a stored setting read that way
/// is switched on by any same-user process that launches the app with
/// `--args -allowsCommandLineCapture YES` — confirmed by probe against the
/// first version. `persistentDomain(forName:)` is what is on disk and nothing
/// else; the argument and registration domains never reach it.
///
/// **Accepted risk:** a same-user process can still `defaults write` the key
/// and relaunch DuoShot, and it will come up listening. That is the price of
/// the setting surviving a restart, and the maintainer chose it; the "CLI"
/// mark in the menu bar, shown in every state and keeping the item up even
/// when the icon is hidden, is what makes it visible. Only the Settings toggle
/// writes the key, and a fresh install has none: off.
struct CommandLineAccessStore {
    static let key = "allowsCommandLineCapture"

    let defaults: UserDefaults
    /// The domain `defaults` writes to: the app's bundle identifier for the
    /// real store, the suite's name for the self-test's.
    let domain: String

    static var standard: CommandLineAccessStore {
        CommandLineAccessStore(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "")
    }

    var isOn: Bool {
        (defaults.persistentDomain(forName: domain)?[Self.key] as? Bool) ?? false
    }

    func save(_ on: Bool) {
        defaults.set(on, forKey: Self.key)
    }
}

/// Whether the command line is being served.
///
/// Persistent: once the user turns it on in Settings it stays on across
/// launches until they turn it off (`CommandLineAccessStore` says how it is
/// read, and what that still leaves open). Changed from outside while the app
/// runs, it applies at the next launch.
///
/// `isListening` is the server's own answer, not the stored wish: when the
/// socket cannot be taken (another DuoShot holds it), Settings shows it off and
/// says why.
@Observable
final class CommandLineAccess {
    static let shared = CommandLineAccess(store: .standard)

    @ObservationIgnored let store: CommandLineAccessStore
    private(set) var isListening = false
    /// Why the last request to listen did not end up listening.
    private(set) var problem: String?
    /// When the command-line take that is running started; nil when none is.
    /// The menu bar shows its clock, so a recording an agent started is never
    /// running unseen.
    private(set) var recordingSince: Date?

    /// Set by the server it controls (`CLIServer.follow`).
    @ObservationIgnored var onRequest: ((Bool) -> Void)?
    /// For the menu-bar indicator.
    @ObservationIgnored var onListeningChanged: (() -> Void)?

    init(store: CommandLineAccessStore) {
        self.store = store
    }

    /// What the Settings toggle calls. The only writer of the stored value.
    func request(_ on: Bool) {
        store.save(on)
        onRequest?(on)
    }

    fileprivate func noteRecording(_ since: Date?) {
        recordingSince = since
        onListeningChanged?()
    }

    fileprivate func report(listening: Bool, problem: String?) {
        let changed = listening != isListening
        isListening = listening
        self.problem = problem
        if changed { onListeningChanged?() }
    }
}

/// The app's half of the command line — see `CLIWire` for the protocol.
///
/// **Off unless the user turned it on.** While it listens, any
/// program running as this user can photograph the screen through DuoShot's
/// grant, which is exactly what Screen Recording's per-app consent exists to
/// prevent. So the socket does not exist until the user asks for it, and going
/// off removes it *and* cuts every connection already accepted — a request
/// that was opened while it was on is not served after it went off.
///
/// What still stands between the socket and anybody else: a 0700 directory, a
/// 0600 socket, and a `getpeereid` check on every connection. Every peer's pid
/// is logged; what it asked to see is not — a window title or an app name
/// supplied by the caller is the same leak `WindowInfo.logName` exists to stop.
///
/// Main-actor, like the engine it drives. The listening socket is non-blocking
/// and its readiness is delivered on the main queue, so `accept` never waits;
/// the reads and writes that could wait on a slow peer run `@concurrent`.
final class CLIServer {
    enum StartError: Error, CustomStringConvertible {
        /// Another instance answers at the path. Not taken over: two copies of
        /// the app with one bundle identifier both bind it otherwise — the
        /// second unlinks the first's socket and every client lands on whichever
        /// started last (seen in the spike).
        case inUse
        case failed(String)

        var description: String {
            switch self {
            case .inUse: "another DuoShot is already serving the command line"
            case .failed(let why): why
            }
        }
    }

    let socketPath: String
    private let engine: CaptureEngine
    /// Its own, like the capture engine: a command-line take shares nothing
    /// with one the user started.
    private let recorder = RecordingEngine()
    private var recordInFlight = false
    private var recordEndedEarly: String?
    private var source: (any DispatchSourceRead)?
    /// The socket file this instance created, so `stop` cannot remove one that
    /// another instance has since put at the same path.
    private var bound: (device: dev_t, inode: ino_t)?
    /// Requests are answered one at a time. The engine is shared with the
    /// interactive capture and was never written to be re-entered by two
    /// requests at once.
    private var tail: Task<Void, Never>?
    /// Bumped by every `stop`. A connection is served only while the epoch it
    /// was accepted in is still the current one and the server is listening.
    private var epoch = 0
    /// Accepted and not yet closed, so `stop` can cut them.
    private var connections: Set<Int32> = []
    private weak var access: CommandLineAccess?

    /// The whole request line has to arrive within this. One deadline, not a
    /// timeout per read: a peer trickling a byte at a time would reset that.
    nonisolated private static let requestDeadline = 5.0
    /// And the whole reply has to leave within this, for the same reason.
    nonisolated static let replyDeadline = 10.0
    /// Connections open at once. More are closed as soon as they are accepted:
    /// each one holds a descriptor and a task, and nothing an agent does needs
    /// more than a few at a time.
    static let maximumConnections = 8
    private var terminationObserver: (any NSObjectProtocol)?

    /// For the self-test: called at each point where the gate is checked again,
    /// so a test can turn it off at exactly that moment.
    enum Stage { case afterRead, beforeCapture, beforeEncode }
    var stageHookForTest: ((Stage) async -> Void)?
    /// For the self-test: how many captures and encodes were started, so a test
    /// can tell "refused" from "did the work and failed to deliver it".
    private(set) var capturesStartedForTest = 0
    private(set) var encodesStartedForTest = 0
    var openConnectionsForTest: Int { connections.count }
    /// For the self-test: whether a command-line take is still running.
    var isRecordingForTest: Bool { recorder.isRecording }

    init(socketPath: String = CLIWire.defaultSocketPath, engine: CaptureEngine) {
        self.socketPath = socketPath
        self.engine = engine
    }

    var isListening: Bool { source != nil }

    // MARK: - The gate

    /// Serves while `access` asks for it, starting from what the user last
    /// chose in Settings (`CommandLineAccessStore`).
    func follow(_ access: CommandLineAccess) {
        self.access = access
        access.onRequest = { [weak self] on in self?.apply(on) }
        // Quitting with it on used to leave the socket behind, and the next
        // launch's client met a refused connection instead of no socket.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(false) }
        }
        apply(access.store.isOn)
    }

    private func apply(_ on: Bool) {
        guard on else {
            stop()
            access?.report(listening: false, problem: nil)
            return
        }
        guard !isListening else { return }
        do {
            try start()
            access?.report(listening: true, problem: nil)
        } catch {
            // Private: the reasons quote the socket path, which is under the
            // user's home directory and so names them.
            Log.app.error("command line: not listening: \(error.description, privacy: .private)")
            access?.report(listening: false, problem: error.description)
        }
    }

    // MARK: - Lifecycle

    func start() throws(StartError) {
        guard source == nil else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        try Self.prepareDirectory(directory)

        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else {
                throw .failed("\(socketPath) exists and is not a socket")
            }
            // Live means somebody accepted the connection: leave it alone. Only
            // a socket nobody answers is stale, and only that one is removed.
            switch CLIWire.connect(to: socketPath) {
            case .success(let fd):
                close(fd)
                throw .inUse
            case .failure:
                unlink(socketPath)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .failed("socket: \(String(cString: strerror(errno)))") }
        guard var address = CLIWire.address(socketPath) else {
            close(fd)
            throw .failed("socket path too long: \(socketPath)")
        }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw .failed("bind: \(why)")
        }
        // Before listen, so there is no moment at which it is both reachable
        // and more open than this. The directory is 0700 throughout anyway.
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
        else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(socketPath)
            throw .failed("listen: \(why)")
        }
        var created = stat()
        if lstat(socketPath, &created) == 0 {
            bound = (created.st_dev, created.st_ino)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending(on: fd) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        Log.app.notice("command line: listening (pid \(getpid(), privacy: .public))")
    }

    func stop() {
        guard let source else { return }
        epoch += 1
        source.cancel()
        self.source = nil
        // Wakes any read or write in flight with an error. The descriptor is
        // closed by whoever owns it, when it notices.
        for connection in connections { shutdown(connection, SHUT_RDWR) }
        var current = stat()
        if let bound, lstat(socketPath, &current) == 0,
           current.st_dev == bound.device, current.st_ino == bound.inode {
            unlink(socketPath)
        }
        bound = nil
        Log.app.notice("""
            command line: stopped listening, cut \(self.connections.count, privacy: .public) \
            connection(s)
            """)
    }

    /// Creates the directory 0700 and refuses one that is anybody else's, or
    /// a symlink, or open to anybody else.
    private static func prepareDirectory(_ path: String) throws(StartError) {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw .failed("cannot create \(path): \(error.localizedDescription)")
        }
        chmod(path, 0o700)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw .failed("\(path) is not a private directory owned by this user") }
    }

    // MARK: - Connections

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }  // EAGAIN: nothing more queued
            guard connections.count < Self.maximumConnections else {
                close(client)
                Log.app.notice("command line: connection refused, \(Self.maximumConnections, privacy: .public) already open")
                continue
            }
            // Inherited from the listener on Darwin; the per-connection I/O is
            // written as blocking reads and writes with deadlines.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            CLIWire.noSigPipe(client)
            connections.insert(client)
            let accepted = epoch
            Task { [weak self] in
                await self?.serve(client, epoch: accepted)
                self?.connections.remove(client)
                close(client)
            }
        }
    }

    /// One request's work at a time. Only the work: reading a request and
    /// sending a reply happen per connection, so a peer that is slow to send or
    /// slow to read holds up nobody else.
    private func serialized(
        _ work: @escaping @MainActor @Sendable () async -> (CLIReply, Data)
    ) async -> (CLIReply, Data) {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Still the session the connection was accepted in, and still listening.
    private func isLive(_ accepted: Int) -> Bool {
        accepted == epoch && isListening
    }

    private func serve(_ client: Int32, epoch accepted: Int) async {
        // Queued behind a request that was still running when it went off.
        guard isLive(accepted) else { return }

        var uid: uid_t = 0
        var gid: gid_t = 0
        var peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length)
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            Log.app.error("""
                command line: refused peer pid \(peerPID, privacy: .public) \
                uid \(uid, privacy: .public)
                """)
            return
        }

        guard let line = await Self.receive(client) else { return }
        await stageHookForTest?(.afterRead)
        // Turned off while the request was arriving: nothing more is said to it.
        guard isLive(accepted) else {
            Log.app.notice("command line: request from pid \(peerPID, privacy: .public) arrived after it was turned off; refused")
            return
        }

        let reply: CLIReply
        var payload = Data()
        var movie: URL?
        var ownsTake = false
        if let request = try? JSONDecoder().decode(CLIRequest.self, from: line) {
            Log.capture.notice("""
                command line: \(request.command.rawValue, privacy: .public) \
                for peer pid \(peerPID, privacy: .public)
                """)
            if request.command == .record {
                // Not on the serial queue: a two-minute take would hold every
                // other request behind it, and it shares no engine with them.
                (reply, movie, ownsTake) = await record(request, epoch: accepted)
            } else {
                (reply, payload) = await serialized { [weak self] in
                    guard let self else { return (.failure("DuoShot is quitting", exitCode: CLIExit.unreachable), Data()) }
                    return await self.respond(to: request, epoch: accepted)
                }
            }
            Log.capture.notice("""
                command line: \(request.command.rawValue, privacy: .public) \
                -> \(reply.ok ? "ok" : "exit \(reply.exitCode ?? 1)", privacy: .public)\
                \(reply.shot.map { " window \($0.window?.id ?? 0) \($0.pixelWidth)x\($0.pixelHeight) px" } ?? "", privacy: .public)
                """)
        } else {
            reply = .failure("malformed request", exitCode: CLIExit.usage)
        }

        var data = (try? CLIWire.encoder.encode(reply)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(0x0A)
        data.append(payload)
        await Self.send(data, to: client)
        // A movie follows its header straight from disk, never held whole in
        // memory, and the take counts as running until it has gone.
        if let movie {
            await Self.sendFile(movie, to: client)
            try? FileManager.default.removeItem(at: movie)
        }
        if ownsTake { recordInFlight = false }
    }

    @concurrent private static func sendFile(_ url: URL, to client: Int32) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let end = Date().addingTimeInterval(replyDeadline + Double(size) / 20_000_000)
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0, CLIWire.writeAll(client, chunk, within: remaining) else { return }
        }
    }

    @concurrent private static func receive(_ client: Int32) async -> Data? {
        CLIWire.readLine(client, limit: 64 * 1024, within: requestDeadline)
    }

    @concurrent private static func send(_ data: Data, to client: Int32) async {
        // A movie can be a few hundred megabytes; allow it 20 MB/s on top.
        _ = CLIWire.writeAll(client, data, within: replyDeadline + Double(data.count) / 20_000_000)
    }

    // MARK: - Commands

    private struct Failure: Error {
        let message: String
        var exitCode: Int32 = CLIExit.captureFailed
    }

    private func respond(to request: CLIRequest, epoch accepted: Int) async -> (CLIReply, Data) {
        switch request.command {
        case .windows:
            var windows = Self.onScreenWindows().map(\.window)
            if let app = request.app {
                windows = windows.filter { Self.owner($0.owner, is: app) }
            }
            if let pid = request.pid {
                windows = windows.filter { $0.pid == pid }
            }
            return (CLIReply(ok: true, windows: windows), Data())
        case .record:
            return (.failure("record is not served here", exitCode: CLIExit.usage), Data())
        case .shot:
            do {
                return try await shoot(request, epoch: accepted)
            } catch let failure as Failure {
                return (.failure(failure.message, exitCode: failure.exitCode), Data())
            } catch let changed as CaptureEngine.ChangedDuringCapture {
                return (.failure(changed.reason, exitCode: CLIExit.retry), Data())
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return (.failure("capture failed: \(message)", exitCode: CLIExit.captureFailed),
                        Data())
            }
        }
    }

    // MARK: - Recording

    /// The reply, the movie to send after it, and whether this request now
    /// owns the one command-line take (and must release it once sent).
    private func record(
        _ request: CLIRequest, epoch accepted: Int
    ) async -> (CLIReply, URL?, Bool) {
        guard let seconds = request.seconds, seconds > 0, seconds <= CLIWire.maximumRecordSeconds else {
            return (.failure("record needs --seconds above 0 and at most \(Int(CLIWire.maximumRecordSeconds))",
                             exitCode: CLIExit.usage), nil, false)
        }
        guard !recordInFlight else {
            return (.failure("a command-line recording is already running", exitCode: CLIExit.captureFailed), nil, false)
        }
        recordInFlight = true
        do {
            let (reply, movie) = try await recordTake(request, seconds: seconds, epoch: accepted)
            return (reply, movie, true)
        } catch let failure as Failure {
            return (.failure(failure.message, exitCode: failure.exitCode), nil, true)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return (.failure("recording failed: \(message)", exitCode: CLIExit.captureFailed), nil, true)
        }
    }

    /// A command-line take is running or its movie is still being sent.
    var hasTakeInFlight: Bool { recordInFlight }

    /// For quitting: ends a running command-line take early — finalised, with
    /// its timeline if one can still be added, and sent to its client — and
    /// returns once it has gone.
    func settle() async {
        guard recordInFlight else { return }
        if recordEndedEarly == nil { recordEndedEarly = "DuoShot is quitting" }
        let deadline = ContinuousClock.now + .seconds(30)
        while recordInFlight, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static var takeDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoShotCommandLine", isDirectory: true)
    }

    /// Removes whatever a quit, a crash or a kill left in the private take
    /// directory: every file there is one of ours and belongs to no client
    /// any more.
    @discardableResult
    static func sweepTakes() -> Int {
        let directory = takeDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
            removed += 1
        }
        if removed > 0 {
            Log.app.notice("removed \(removed, privacy: .public) command-line take(s) left from an earlier run")
        }
        return removed
    }

    /// Where a take is written before its bytes go back: a 0700 directory of
    /// the app's own, never a path the client named.
    private static func privateTakeURL() throws -> URL {
        let directory = takeDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    private func recordTake(
        _ request: CLIRequest, seconds: Double, epoch accepted: Int
    ) async throws -> (CLIReply, URL) {
        var mode = "rect"
        var windowRef: CLIShot.Window?
        let recordingRequest: RecordingRequest
        var watchedWindow: CGWindowID?
        if let rect = request.rect {
            let inAppKit = DisplayGeometry.flipped(rect.cgRect)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(inAppKit) }),
                  let displayID = ScreenIndex.displayID(of: screen)
            else { throw Failure(message: "rect \(Self.describe(rect)) is not inside one display") }
            recordingRequest = .area(displayID: displayID, rectInAppKitGlobal: inAppKit)
        } else {
            let target = try Self.target(of: request)
            windowRef = .init(id: target.id, owner: target.owner, title: target.title)
            let frame = DisplayGeometry.flipped(target.frame.cgRect)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                    ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
                  let displayID = ScreenIndex.displayID(of: screen)
            else { throw Failure(message: "window \(target.id) is not on a display") }
            if request.isolated == true {
                mode = "isolated"
                recordingRequest = .window(target.id, displayID: displayID)
                watchedWindow = target.id
            } else {
                mode = "as_seen"
                let visible = frame.intersection(screen.frame)
                guard !visible.isNull, visible.width >= 2, visible.height >= 2 else {
                    throw Failure(message: "window \(target.id) is not on screen")
                }
                recordingRequest = .area(displayID: displayID, rectInAppKitGlobal: visible)
            }
        }

        try await beginCapture(accepted)
        let url = try Self.privateTakeURL()
        // Removed here on every way out but success; on success the movie is
        // the caller's to send and then remove.
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: url) } }
        var options = RecordingOptions.default
        options.capturesMicrophone = false
        recordEndedEarly = nil
        let recording = try await recorder.start(recordingRequest, options: options, to: url)
        let region = recording.regionInCGGlobal
        recording.onUnexpectedStop { [weak self] error in
            let reason = error.localizedDescription
            Task { @MainActor in self?.recordEndedEarly = "the recording stopped: \(reason)" }
        }
        access?.noteRecording(.now)
        defer { access?.noteRecording(nil) }
        Log.capture.notice("command line: recording \(mode, privacy: .public) for \(seconds, privacy: .public) s")

        let started = ContinuousClock.now
        while started.duration(to: .now) < .seconds(seconds), recordEndedEarly == nil, isLive(accepted) {
            // An isolated take of a window that has gone — closed, minimized,
            // moved to another Space — has nothing left to show.
            if let watchedWindow, Self.alpha(of: watchedWindow) == nil {
                recordEndedEarly = "the window left the screen (closed, minimized or moved to another Space)"
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isLive(accepted) else {
            await recorder.cancel()
            throw Failure(message: "command-line capture was turned off", exitCode: CLIExit.unreachable)
        }

        switch await recorder.finish() {
        case .finished(let result), .salvaged(let result, _):
            // Before replying: the agent asked for the movie with its clicks.
            var clicks = 0
            if let pending = result.clickTimeline,
               case .success(let report) = await ClickTimelineJobs.shared.run(pending, into: result.url) {
                clicks = report.clicks
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
            let info = CLIRecording(
                mode: mode, window: windowRef, rect: request.rect, frame: CLIRect(region),
                scale: Double(result.scale), pixelWidth: Int(result.pixelSize.width),
                pixelHeight: Int(result.pixelSize.height), duration: result.duration,
                clicks: clicks, endedEarly: recordEndedEarly)
            delivered = true
            return (CLIReply(ok: true, recording: info, bytes: size), result.url)
        case .lost(_, let failure):
            throw Failure(message: "nothing was recorded\(failure.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    /// Just before any capture: the gate, once more.
    private func beginCapture(_ accepted: Int) async throws {
        await stageHookForTest?(.beforeCapture)
        try ensureLive(accepted)
        capturesStartedForTest += 1
    }

    private func ensureLive(_ accepted: Int) throws {
        guard isLive(accepted) else {
            throw Failure(message: "command-line capture was turned off", exitCode: CLIExit.unreachable)
        }
    }

    /// Fixed, deliberately not the user's preferences: an agent comparing two
    /// shots must not find that somebody changed the padding in between.
    ///
    /// `includeChildWindows` stays off, which is *not* "leave attached panels
    /// out": with it off the engine asks for the window's group whenever its
    /// app has something stacked on it, and frames the file to that group
    /// (`CaptureEngine.captureGroup`). On, it would skip that path and squeeze
    /// the group into the window's own size — see `CaptureOptions`.
    private static var options: CaptureOptions {
        var options = CaptureOptions()
        options.showsCursor = false
        options.windowPadding = 0
        options.includeChildWindows = false
        return options
    }

    private func shoot(_ request: CLIRequest, epoch accepted: Int) async throws -> (CLIReply, Data) {
        if let rect = request.rect {
            return try await shoot(rect: rect, epoch: accepted)
        }
        let target = try Self.target(of: request)
        try await engine.refreshContent()

        // Not after the capture: a window the compositor is fading comes back
        // carrying the fade, and a translucent picture handed back as if it were
        // the window is the one wrong answer worse than none.
        let alpha = try await Self.settledAlpha(of: target.id)

        if request.isolated == true {
            try await beginCapture(accepted)
            let result = try await engine.capture(.window(target.id), options: Self.options)
            let covers = result.coversInCGGlobal ?? target.frame.cgRect
            return try await reply(
                for: result, epoch: accepted,
                shot: CLIShot(
                    mode: "isolated",
                    window: .init(id: target.id, owner: target.owner, title: target.title),
                    frame: CLIRect(covers), scale: Double(result.scale),
                    pixelWidth: result.image.width, pixelHeight: result.image.height,
                    alpha: alpha, timestamp: Self.timestamp(result.capturedAt)))
        }

        try await beginCapture(accepted)
        let seen = try await engine.captureAsSeen(target.id, options: Self.options)
        let result = seen.result
        let covers = result.coversInCGGlobal ?? target.frame.cgRect
        let occluders = await occluders(of: target.id, within: covers, own: seen.ownWindowIDs)
        return try await reply(
            for: result, epoch: accepted,
            shot: CLIShot(
                mode: "as_seen",
                window: .init(id: target.id, owner: target.owner, title: target.title),
                frame: CLIRect(covers), scale: Double(result.scale),
                pixelWidth: result.image.width, pixelHeight: result.image.height,
                alpha: alpha, timestamp: Self.timestamp(result.capturedAt),
                occludedBy: occluders))
    }

    /// Windows that are in front of the target, overlap what the file covers,
    /// are not part of it, and draw something in that overlap — the ones whose
    /// pixels are in the file. Read after the capture.
    ///
    /// "In front" is decided by layer first and list position only within a
    /// layer: a window on a lower layer is behind, wherever the window list
    /// happens to put it. Measured in acceptance: a TCC alert at layer 8 was
    /// listed ahead of a layer-101 panel, while its pixels were behind the
    /// panel's glass. And "draws something" is asked of the window's own
    /// pixels, because a window's frame says nothing about what it paints: the
    /// Dock's layer-20 window covers the whole screen and draws one strip.
    private func occluders(
        of id: CGWindowID, within covers: CGRect, own: Set<CGWindowID>
    ) async -> [CLIShot.Occluder] {
        let windows = Self.onScreenWindows()
        guard let target = windows.first(where: { $0.window.id == id }) else { return [] }
        var found: [CLIShot.Occluder] = []
        for candidate in windows {
            let window = candidate.window
            guard window.id != id, !own.contains(window.id), window.alpha >= 0.05,
                  window.layer > target.window.layer
                      || (window.layer == target.window.layer && candidate.depth < target.depth)
            else { continue }
            let overlap = window.frame.cgRect.intersection(covers)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            // Unknown counts as drawing: better a window named that was not in
            // the picture than one left out that was.
            guard await engine.draws(window.id, within: overlap) ?? true else { continue }
            found.append(CLIShot.Occluder(id: window.id, owner: window.owner, overlap: CLIRect(overlap)))
        }
        return found
    }

    private func shoot(rect: CLIRect, epoch accepted: Int) async throws -> (CLIReply, Data) {
        let inAppKit = DisplayGeometry.flipped(rect.cgRect)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(inAppKit) }),
              let displayID = ScreenIndex.displayID(of: screen)
        else { throw Failure(message: "rect \(Self.describe(rect)) is not inside one display") }
        try await engine.refreshContent()
        try await beginCapture(accepted)
        let result = try await engine.capture(
            .area(displayID: displayID, rectInAppKitGlobal: inAppKit), options: Self.options)
        // The engine snaps to whole points before it captures; report what it
        // took, not what was asked for.
        let taken = DisplayGeometry.flipped(inAppKit.integral)
        return try await reply(
            for: result, epoch: accepted,
            shot: CLIShot(
                mode: "rect", rect: rect, frame: CLIRect(taken), scale: Double(result.scale),
                pixelWidth: result.image.width, pixelHeight: result.image.height,
                alpha: nil, timestamp: Self.timestamp(result.capturedAt)))
    }

    /// Pixels leave the capture only here, and only while the gate is still on.
    private func reply(
        for result: CaptureResult, epoch accepted: Int, shot: CLIShot
    ) async throws -> (CLIReply, Data) {
        await stageHookForTest?(.beforeEncode)
        try ensureLive(accepted)
        encodesStartedForTest += 1
        guard let png = await Self.encode(result) else {
            throw Failure(message: "could not encode the capture as PNG")
        }
        return (CLIReply(ok: true, shot: shot, bytes: png.count), png)
    }

    @concurrent private static func encode(_ result: CaptureResult) async -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * Double(result.scale),
            kCGImagePropertyDPIHeight: 72.0 * Double(result.scale),
        ]
        CGImageDestinationAddImage(destination, result.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Choosing a window

    private static func target(of request: CLIRequest) throws -> CLIWindow {
        let windows = onScreenWindows().map(\.window)
        if let id = request.window {
            guard let window = windows.first(where: { $0.id == id }) else {
                throw Failure(message: "no on-screen window with id \(id)")
            }
            return window
        }
        guard let app = request.app else { throw Failure(message: "nothing to capture") }
        let mine = windows.filter { owner($0.owner, is: app) }
        if request.panel == true {
            // A menu-bar panel or popover. Largest, because the same app can
            // have a tooltip up over its panel, and the tooltip is not what
            // anybody means by "the panel".
            guard let panel = mine.filter({ $0.layer > 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { throw Failure(message: "\(app) has no on-screen panel (no window above layer 0)") }
            return panel
        }
        // The window list is front to back within a layer, so the first is the
        // frontmost.
        guard let window = mine.first(where: { $0.layer == 0 }) else {
            throw Failure(message: "\(app) has no on-screen window at layer 0")
        }
        return window
    }

    private static func owner(_ owner: String, is name: String) -> Bool {
        owner.compare(name, options: [.caseInsensitive]) == .orderedSame
    }

    /// Every on-screen window, in the window server's list order, with its
    /// position in that list. `kCGWindowBounds` is already global points with a
    /// top-left origin, which is the space this command line speaks — nothing
    /// here converts.
    nonisolated static func onScreenWindows() -> [(window: CLIWindow, depth: Int)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.enumerated().compactMap { depth, entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return (CLIWindow(
                id: number.uint32Value,
                pid: (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String ?? "",
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                frame: CLIRect(bounds)), depth)
        }
    }

    // MARK: - Fade guard

    /// The window's `kCGWindowAlpha` once it has held at full opacity for two
    /// reads ~50 ms apart, polled for up to a second.
    ///
    /// ScreenCaptureKit returns what the compositor is drawing, and a window
    /// that is fading in or out is drawn translucent — a menu-bar popup does
    /// both within a few hundred milliseconds of a click. Two reads, because a
    /// single one can land on the last frame of a fade-in that has not quite
    /// finished and the first frame of a fade-out alike.
    private static func settledAlpha(of id: CGWindowID) async throws -> Double {
        let deadline = ContinuousClock.now + .seconds(1)
        var previousWasOpaque = false
        while true {
            guard let alpha = alpha(of: id) else {
                throw Failure(message: "window \(id) is no longer on screen")
            }
            if alpha >= 0.99 {
                if previousWasOpaque { return alpha }
                previousWasOpaque = true
            } else {
                previousWasOpaque = false
            }
            guard ContinuousClock.now < deadline else {
                throw Failure(
                    message: String(
                        format: "window %u is still fading (alpha=%.3f); not captured", id, alpha),
                    exitCode: CLIExit.retry)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    nonisolated static func alpha(of id: CGWindowID) -> Double? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
                  as? [[String: Any]],
              let entry = list.first,
              (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        else { return nil }
        return (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    }

    // MARK: - Formatting

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)
            .timeZone(separator: .omitted))
    }

    private static func describe(_ rect: CLIRect) -> String {
        "\(rect.x),\(rect.y),\(rect.width),\(rect.height)"
    }
}
