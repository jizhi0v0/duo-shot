import CoreGraphics
import Darwin
import Foundation

// The agent-facing command line: `duoshot …`, a standalone tool.
//
// Two halves, and two executables. The *client* is its own signed binary with
// its own identifier, and it lives *outside* DuoShot.app — `build/duoshot`,
// installed to ~/.local/bin. Not in the bundle: measured in acceptance, TCC
// judged a helper inside Contents/ as the enclosing app for folder access
// (tccd logged `AUTHREQ_SUBJECT subject=<the app's identifier>` for a binary
// signed with an identifier of its own), so anything an agent ran through it
// read files with DuoShot's grants. Outside, it borrows none. It never calls a
// capture API.
//
// The *server* lives in the LaunchServices-launched app, which holds the
// Screen Recording grant, and answers over a Unix socket. Measured with the
// feasibility spike: a client started from a launchd job whose own
// `screencapture` was denied got pixels identical to `screencapture -l` this
// way.
//
// One request per connection:
//
//   client -> app : one JSON line (`CLIRequest`)
//   app -> client : one JSON line (`CLIReply`), then exactly `bytes` bytes of
//                   PNG when the reply carries an image
//
// The app returns bytes and nothing else. It never learns where the client is
// going to put them, so it can never be talked into writing to a path somebody
// else chose.

package struct CLIRect: Codable, Sendable, Equatable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double

    package init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    package var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// "x,y,w,h", the form every rect on this command line is written in.
    package init?(argument: String) {
        let parts = argument.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4, let x = parts[0], let y = parts[1],
              let w = parts[2], let h = parts[3], w > 0, h > 0
        else { return nil }
        self.init(CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Every frame is printed under `frame_global_points_top_left`. The name carries
/// the space, because a bare "frame" next to AppKit's bottom-left convention is
/// a coin toss: this is `kCGWindowBounds`'s space, the one `screencapture -R`
/// takes — global points, origin top-left of the menu-bar display, +y down.
package struct CLIWindow: Codable, Sendable {
    package var id: UInt32
    package var pid: Int32
    package var owner: String
    package var title: String
    package var layer: Int
    package var alpha: Double
    package var frame: CLIRect

    package init(id: UInt32, pid: Int32, owner: String, title: String, layer: Int,
                 alpha: Double, frame: CLIRect) {
        self.id = id; self.pid = pid; self.owner = owner; self.title = title
        self.layer = layer; self.alpha = alpha; self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case id, pid, owner, title, layer, alpha
        case frame = "frame_global_points_top_left"
    }
}

package struct CLIShot: Codable, Sendable {
    /// Filled in by the client, which is the only side that knows it.
    package var path: String?
    /// "as_seen" (the default: the window's region of the screen cut to its
    /// own outline, so glass shows what is behind it), "isolated" (the window
    /// rendered alone, as `screencapture -l` does) or "rect".
    package var mode: String
    package var window: Window?
    /// The rect that was asked for, when it was `--rect`.
    package var rect: CLIRect?
    /// What the file covers. For a window this is the engine's own framing —
    /// the window, trimmed of a border it never drew, or grown to the group of
    /// panels attached to it — so it is not always the window's bounds.
    package var frame: CLIRect
    package var scale: Double
    package var pixelWidth: Int
    package var pixelHeight: Int
    /// The window server's `kCGWindowAlpha` at the moment of the capture.
    package var alpha: Double?
    package var timestamp: String
    /// As-seen only: windows that are not the target's own, are in front of it,
    /// and draw something inside `frame` — so their pixels are in the file.
    /// Said out loud rather than left for somebody to find in the picture.
    package var occludedBy: [Occluder]?

    package init(path: String? = nil, mode: String, window: Window? = nil, rect: CLIRect? = nil,
                 frame: CLIRect, scale: Double, pixelWidth: Int, pixelHeight: Int,
                 alpha: Double?, timestamp: String, occludedBy: [Occluder]? = nil) {
        self.path = path; self.mode = mode; self.window = window; self.rect = rect
        self.frame = frame; self.scale = scale; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.alpha = alpha; self.timestamp = timestamp
        self.occludedBy = occludedBy
    }

    package struct Window: Codable, Sendable {
        package var id: UInt32
        package var owner: String
        package var title: String

        package init(id: UInt32, owner: String, title: String) {
            self.id = id; self.owner = owner; self.title = title
        }
    }

    package struct Occluder: Codable, Sendable {
        package var id: UInt32
        package var owner: String
        package var overlap: CLIRect

        package init(id: UInt32, owner: String, overlap: CLIRect) {
            self.id = id; self.owner = owner; self.overlap = overlap
        }

        enum CodingKeys: String, CodingKey {
            case id, owner
            case overlap = "overlap_global_points_top_left"
        }
    }

    enum CodingKeys: String, CodingKey {
        case path, mode, window, rect, scale, alpha, timestamp
        case occludedBy = "occluded_by"
        case frame = "frame_global_points_top_left"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

/// What `duoshot record` prints.
package struct CLIRecording: Codable, Sendable {
    /// Filled in by the client, which is the only side that knows it.
    package var path: String?
    /// "as_seen" (the screen region the window or rect covers, whatever is in
    /// front of it), "isolated" (the window on its own, covered or not) or
    /// "rect".
    package var mode: String
    package var window: CLIShot.Window?
    package var rect: CLIRect?
    /// What the movie shows, global points, origin top-left; for a window the
    /// frame it had when the take started.
    package var frame: CLIRect
    package var scale: Double
    package var pixelWidth: Int
    package var pixelHeight: Int
    package var duration: Double
    /// Mouse events in the movie's click timeline.
    package var clicks: Int
    /// Set when the take ended before the time asked for — the window closed,
    /// the stream stopped. The movie holds what was recorded up to then.
    package var endedEarly: String?

    package init(mode: String, window: CLIShot.Window? = nil, rect: CLIRect? = nil,
                 frame: CLIRect, scale: Double, pixelWidth: Int, pixelHeight: Int,
                 duration: Double, clicks: Int, endedEarly: String? = nil) {
        self.mode = mode; self.window = window; self.rect = rect; self.frame = frame
        self.scale = scale; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.duration = duration; self.clicks = clicks; self.endedEarly = endedEarly
    }

    enum CodingKeys: String, CodingKey {
        case path, mode, window, rect, scale, duration, clicks
        case frame = "frame_global_points_top_left"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case endedEarly = "ended_early"
    }
}

package struct CLIRequest: Codable, Sendable {
    package enum Command: String, Codable, Sendable { case windows, shot, record }
    package var command: Command
    package var app: String?
    package var pid: Int32?
    package var window: UInt32?
    package var panel: Bool?
    package var isolated: Bool?
    package var rect: CLIRect?
    /// `record` only: how long, at most `CLIWire.maximumRecordSeconds`.
    package var seconds: Double?

    package init(command: Command, app: String? = nil, pid: Int32? = nil) {
        self.command = command; self.app = app; self.pid = pid
    }
}

package struct CLIReply: Codable, Sendable {
    package var ok: Bool
    package var error: String?
    /// The exit status the client should end with when `ok` is false.
    package var exitCode: Int32?
    package var windows: [CLIWindow]?
    package var shot: CLIShot?
    package var recording: CLIRecording?
    /// Length of the PNG or movie that follows the header line.
    package var bytes: Int?

    package init(ok: Bool, error: String? = nil, exitCode: Int32? = nil,
                 windows: [CLIWindow]? = nil, shot: CLIShot? = nil,
                 recording: CLIRecording? = nil, bytes: Int? = nil) {
        self.ok = ok; self.error = error; self.exitCode = exitCode
        self.windows = windows; self.shot = shot; self.recording = recording; self.bytes = bytes
    }

    package static func failure(_ message: String, exitCode: Int32) -> CLIReply {
        CLIReply(ok: false, error: message, exitCode: exitCode)
    }
}

/// What `duoshot frames` prints. `frames` is always there, one entry per
/// sampled time, whatever else was asked for; `--tile` adds `sheets` beside it.
package struct CLIFramesReport: Codable, Sendable {
    package var video: String
    package var duration: Double
    package var frames: [Frame] = []
    package var sheets: [Sheet]?
    package var changes: [Change]?
    package var threshold: Double?
    /// Mouse-downs from the movie's click timeline; absent when it has none.
    package var clicks: [CLIClick]?
    /// Present when any frame has a click ring drawn on it.
    package var clickRingsNote: String?

    package init(video: String, duration: Double) {
        self.video = video; self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case video, duration, frames, sheets, changes, threshold, clicks
        case clickRingsNote = "click_rings_note"
    }

    package struct Frame: Codable, Sendable {
        package var path: String
        package var time: Double
        /// Clicks within 100 ms of this frame, drawn on it as rings (and on its
        /// contact-sheet cell) at these positions in the written image.
        package var clickRings: [Ring]?

        package init(path: String, time: Double, clickRings: [Ring]? = nil) {
            self.path = path; self.time = time; self.clickRings = clickRings
        }

        enum CodingKeys: String, CodingKey {
            case path, time
            case clickRings = "click_rings"
        }
    }

    package struct Ring: Codable, Sendable {
        /// The click's time on the movie's timeline.
        package var t: Double
        /// In the written image's pixels, origin top-left (after any crop).
        package var x: Double
        package var y: Double

        package init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    package struct Sheet: Codable, Sendable {
        package var path: String
        package var times: [Double]
        /// Each cell's size over the frame's own, ≤ 1.
        package var cellScale: Double

        package init(path: String, times: [Double], cellScale: Double) {
            self.path = path; self.times = times; self.cellScale = cellScale
        }

        enum CodingKeys: String, CodingKey {
            case path, times
            case cellScale = "cell_scale"
        }
    }

    package struct Change: Codable, Sendable {
        package var time: Double
        package var score: Double
        /// Milliseconds since the latest mouse-down at or before the change,
        /// when there was one within the last second; null otherwise — and
        /// absent when the movie has no click timeline.
        package var afterClickMs: Double?
        package var click: CLIClick?

        package init(time: Double, score: Double) { self.time = time; self.score = score }

        enum CodingKeys: String, CodingKey {
            case time, score, click
            case afterClickMs = "after_click_ms"
        }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .time)
            try container.encode(score, forKey: .score)
            try container.encodeIfPresent(click, forKey: .click)
            // Present-and-null is the answer "no click explains this"; only a
            // movie with no timeline leaves the key out.
            if hasTimeline { try container.encode(afterClickMs, forKey: .afterClickMs) }
        }

        /// Set once clicks have been looked for.
        package var hasTimeline = false

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decode(Double.self, forKey: .time)
            score = try container.decode(Double.self, forKey: .score)
            click = try container.decodeIfPresent(CLIClick.self, forKey: .click)
            hasTimeline = container.contains(.afterClickMs)
            afterClickMs = try container.decodeIfPresent(Double.self, forKey: .afterClickMs)
        }
    }
}

package enum CLIExit {
    package static let ok: Int32 = 0
    package static let usage: Int32 = 2
    package static let unreachable: Int32 = 3
    /// No such window or panel, or it went away: asking again will not help.
    package static let captureFailed: Int32 = 4
    package static let framesFailed: Int32 = 5
    /// Still fading, or changed while it was being captured: worth retrying.
    package static let retry: Int32 = 6
}

/// Socket plumbing shared by both halves. Blocking calls only; whoever calls
/// these from the app does so off the main thread.
package enum CLIWire {
    /// `~/Library/Application Support/DuoShot/CommandLine/capture.sock`.
    ///
    /// A directory of its own so that it can be 0700 without touching the
    /// permissions of anything else DuoShot keeps there.
    package static var defaultSocketPath: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("DuoShot", isDirectory: true)
            .appendingPathComponent("CommandLine", isDirectory: true)
            .appendingPathComponent("capture.sock").path
    }

    /// Lets the self-test point its client subprocess at the socket its
    /// in-process server is listening on. The client only — the app's own
    /// socket path is never read from the environment.
    package static let socketEnvironmentKey = "DUOSHOT_CLI_SOCKET"

    /// Present in the Info.plist of every DuoShot that can serve the command
    /// line, so the client can tell "off" from "too old to have it".
    package static let capabilityKey = "DuoShotCommandLineProtocol"

    /// The most a reply may claim to carry. A 6K display at 2x as a 32-bit PNG
    /// is well under 200 MB; a claim past this is not a screenshot, and the
    /// client must not allocate for it.
    package static let maximumPayload = 512 * 1024 * 1024

    /// The longest `duoshot record` take.
    package static let maximumRecordSeconds = 120.0

    package static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// A connected stream socket, or the errno that stopped it.
    package static func connect(to path: String) -> Result<Int32, POSIXError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        guard var addr = address(path) else {
            close(fd)
            return .failure(POSIXError(.ENAMETOOLONG))
        }
        noSigPipe(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            return .failure(POSIXError(code))
        }
        return .success(fd)
    }

    /// A peer that hangs up mid-reply must cost an EPIPE, not the app.
    package static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    package static func setTimeout(_ fd: Int32, seconds: Double) {
        var tv = interval(seconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<Darwin.timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<Darwin.timeval>.size))
    }

    private static func interval(_ seconds: Double) -> Darwin.timeval {
        let clamped = max(0.001, seconds)
        return Darwin.timeval(tv_sec: Int(clamped),
                              tv_usec: Int32((clamped - floor(clamped)) * 1_000_000))
    }

    /// All of `data`, within `deadline` seconds overall when one is given.
    ///
    /// Overall, and enforced here rather than by `SO_SNDTIMEO`: that timeout
    /// applies to each sleep *inside* one `write`, and every byte the peer
    /// takes wakes the writer and starts it again — measured, a peer
    /// reading one byte a second held a reply for the full 30 s it kept reading,
    /// with a 10 s deadline set that way. So with a deadline the socket is
    /// written non-blocking, and only `poll` waits, for what is left of it.
    package static func writeAll(_ fd: Int32, _ data: Data, within deadline: Double? = nil) -> Bool {
        let end = deadline.map { Date().addingTimeInterval($0) }
        let flags = fcntl(fd, F_GETFL)
        if end != nil { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        defer { if end != nil { _ = fcntl(fd, F_SETFL, flags) } }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                if let end {
                    let remaining = end.timeIntervalSinceNow
                    guard remaining > 0 else { return false }
                    var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let polled = poll(&ready, 1, Int32(min(remaining * 1000, 60_000)) + 1)
                    if polled < 0, errno == EINTR { continue }
                    guard polled > 0 else { continue }  // timed out: the guard decides
                }
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// One newline-terminated line, without the newline — read whole within
    /// `deadline` or not at all. One overall deadline rather than a timeout per
    /// read, which a peer could keep resetting by trickling a byte at a time.
    ///
    /// A byte at a time, deliberately: whatever follows the newline belongs to
    /// the caller — on the client it is the first bytes of the image — and a
    /// buffered read would swallow it.
    package static func readLine(_ fd: Int32, limit: Int, within deadline: Double) -> Data? {
        let end = Date().addingTimeInterval(deadline)
        var line = Data()
        var byte: UInt8 = 0
        while line.count <= limit {
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var tv = interval(remaining)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<Darwin.timeval>.size))
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            guard n == 1 else { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    package static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var off = 0
            while off < count {
                let n = Darwin.read(fd, base + off, count - off)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        return ok ? data : nil
    }

    /// What the client says when there is no socket to talk to. One entry per
    /// running DuoShot: whether its bundle declares the command line
    /// (`capabilityKey`).
    package static func diagnosis(runningCapable: [Bool]) -> String {
        if runningCapable.contains(true) {
            return """
                DuoShot is running, but command-line capture is off. Turn on \
                Settings → General → Allow command-line capture.
                """
        }
        if !runningCapable.isEmpty {
            return """
                The DuoShot that is running is too old to serve the command line. \
                Quit it and open a current DuoShot.
                """
        }
        return "DuoShot is not running. Open DuoShot and try again."
    }

    package static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
