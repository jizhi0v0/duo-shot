#!/usr/bin/env swift

import AppKit

// Answers one yes/no question: when `CGWindowListCreateImage` is slow, are the
// pixels it hands back from when the call *started* or from when it *returned*?
//
// `LegacyDisplayCapture` reads every window's position in the same turn the
// call returns, and verified that on the fast path -- 7-18 ms, where the
// outlines land 0.6 pt from their windows on average. But the capture log for
// 2026-09-18 has five calls between 41 and 192 ms, all while a desktop was
// being swiped, and the bug report puts the picked window's outline offset on
// those ("滑动的时候掉帧，最终选择的框 window 会偏移"). If the frame is the one
// composited before the stall, positions read on return are up to 192 ms newer
// than the pixels -- about 260 pt at the 1.36 pt/ms the 448 ms capture of
// 2026-09-12 00:23:48 worked out to.
//
// The instrument is a magenta panel sliding at a known speed as a clock. For
// every call it records three x values, all of them in the window server's own
// top-left display space so they compare directly:
//
//     b0    `kCGWindowBounds` read immediately before the call
//     b1    `kCGWindowBounds` read immediately after it returns
//     img   where the panel actually is in the returned picture
//
// `img` matching `b0` means the picture is as old as the call is long, and the
// fix is to read positions *before* the call, not after. `img` matching `b1`
// kills that -- a slow call returns a fresh frame, and the offset is something
// else. `img` matching neither, with `b0 == b1`, is the third answer: the
// window server does not move a window's reported bounds during a swipe at all,
// and no read order can help.
//
// Two things the harness has to get right, both of them load-bearing:
//
// - **The capture runs off the main thread.** `CGWindowListCreateImage` blocks,
//   and a 192 ms block on the main thread would stop the panel too -- the clock
//   would freeze exactly when it is being read, and every sample would agree
//   with every other for the wrong reason.
// - **The panel moves; its colour does not.** Setting `NSWindow.backgroundColor`
//   does not repaint an already-composited borderless panel (see
//   `screen-drifter.swift`), so the fill lives on a layer-backed view. Nothing
//   here changes it after that.
// - **The panel lives in a space of its own**, by the calls `OverlaySpace` uses.
//   The first version had it `.canJoinAllSpaces`, so that it stayed visible
//   whichever desktop arrived -- which is exactly the window that rides the
//   desktop being left. Run on 2026-09-18 during real swipes, its reported
//   bounds went to -3000 while it was still drawn at x = 800: a two-thousand
//   point disagreement, three orders above the effect being measured, in the
//   only samples that mattered. A clock that slides with the thing it is timing
//   is not a clock. Samples where the bounds leave the panel's own travel are
//   counted as slipped and kept out of the means.
//
// A second panel answers the question the first one raised by breaking. Green,
// static, and left on the ordinary desktop, so a swipe carries it away exactly
// as it carries every real window. Its `kCGWindowBounds` against its drawn
// position is the picker's own situation: the outline is drawn from those
// bounds, over a photograph that shows the window where it really was. While
// nothing moves the two must agree to the pixel -- that bucket is the negative
// control, and a non-zero mean there means the green measurement is broken and
// the moving bucket proves nothing.
//
// Slow calls are not synthesised: they happen while the window server is busy
// animating a space change, which is why the run asks for real swipes. A run
// with no slow samples has not answered the question -- swipe more, or longer.
//
// Usage:  swift Scripts/freeze-staleness-probe.swift [seconds]   (default 20)
//
// `env swift` compiles before the panel appears -- a couple of seconds on a
// warm cache. Wait for "sliding" on stderr before swiping.

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 20

// MARK: - The retired call, looked up rather than linked

private typealias WindowListCreateImage =
    @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

// RTLD_DEFAULT, which Swift does not import: every loaded image.
guard let createImage = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
    .map({ unsafeBitCast($0, to: WindowListCreateImage.self) })
else {
    FileHandle.standardError.write(Data("CGWindowListCreateImage is gone.\n".utf8))
    exit(1)
}

// MARK: - The sliding clock

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else { exit(1) }
let displayID = CGMainDisplayID()
let displayBounds = CGDisplayBounds(displayID)

let panelSize = CGSize(width: 60, height: 220)
// A fixed y, so one row of pixels is enough to find it in a 5K picture.
let panelY = screen.frame.midY - panelSize.height / 2
let travel = (left: screen.frame.minX + 40, right: screen.frame.maxX - 40 - panelSize.width)
let speed: CGFloat = 1200  // pt/s -- 10 ms of staleness reads as 12 pt

let panel = NSPanel(
    contentRect: CGRect(x: travel.left, y: panelY, width: panelSize.width, height: panelSize.height),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = true
panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.level = .screenSaver
panel.collectionBehavior = [.ignoresCycle, .stationary]
let fill = NSView(frame: CGRect(origin: .zero, size: panelSize))
fill.wantsLayer = true
// `CGColor(srgbRed:…)`, never `CGColor(red:…)`: the latter is generic RGB and
// lands in an sRGB picture as (255, 64, 255), which the match below would miss.
fill.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
panel.contentView = fill
panel.orderFrontRegardless()

// MARK: - A space of its own, so a swipe cannot carry the clock away

typealias MainConnection = @convention(c) () -> Int32
typealias SpaceCreate = @convention(c) (Int32, UnsafeMutableRawPointer?, CFDictionary?) -> Int
typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int, Int32) -> Void
typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

func symbol<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}

// The same recipe as `OverlaySpace`, down to the flag: it must be 1, or Finder
// draws the desktop icons into the new space.
if let main = symbol("CGSMainConnectionID", as: MainConnection.self),
   let create = symbol("CGSSpaceCreate", as: SpaceCreate.self),
   let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
   let show = symbol("CGSShowSpaces", as: ShowSpaces.self),
   let add = symbol("CGSAddWindowsToSpaces", as: AddWindowsToSpaces.self) {
    let connection = main()
    let space = create(connection, UnsafeMutableRawPointer(bitPattern: 1), nil)
    if space != 0 {
        setLevel(connection, space, Int32.max)
        show(connection, [space] as CFArray)
        add(connection, [panel.windowNumber] as CFArray, [space] as CFArray)
    } else {
        FileHandle.standardError.write(Data("CGSSpaceCreate gave nothing; clock will ride swipes\n".utf8))
    }
} else {
    FileHandle.standardError.write(Data("private space calls missing; clock will ride swipes\n".utf8))
}

let startedAt = CACurrentMediaTime()
let span = travel.right - travel.left
// A triangle wave: one bounce every 2 * span / speed, which at 1200 pt/s over a
// wide screen is seconds -- far longer than the 200 ms of staleness in
// question, so no sample can be confused with one a period away.
func clockX(at now: CFTimeInterval) -> CGFloat {
    let period = 2 * span / speed
    let phase = (now - startedAt).truncatingRemainder(dividingBy: Double(period))
    let offset = CGFloat(phase) * speed
    return offset <= span ? travel.left + offset : travel.right - (offset - span)
}

let animation = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
    panel.setFrameOrigin(CGPoint(x: clockX(at: CACurrentMediaTime()), y: panelY))
}
RunLoop.main.add(animation, forMode: .common)

// MARK: - The window that rides the swipe

let riderSize = CGSize(width: 200, height: 120)
let riderY = panelY - 320
let rider = NSPanel(
    contentRect: CGRect(
        x: screen.frame.midX - riderSize.width / 2, y: riderY,
        width: riderSize.width, height: riderSize.height),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
rider.isOpaque = true
rider.hasShadow = false
rider.ignoresMouseEvents = true
// `.floating` and the default collection behaviour: an ordinary member of the
// desktop it was opened on, which is the point -- it has to slide when the
// desktop slides. Nothing moves it afterwards, so every disagreement between
// its bounds and its pixels is the window server's doing.
rider.level = .floating
rider.collectionBehavior = [.ignoresCycle]
let riderFill = NSView(frame: CGRect(origin: .zero, size: riderSize))
riderFill.wantsLayer = true
riderFill.layer?.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
rider.contentView = riderFill
rider.orderFrontRegardless()

// MARK: - Reading the window server and the picture

let windowID = CGWindowID(panel.windowNumber)
let riderID = CGWindowID(rider.windowNumber)

/// The window server's own frame for `id`, in the top-left display space the
/// picture is also in -- so its `minX` compares directly with a column found in
/// the image. Nil once the window is not listed.
func serverBounds(of id: CGWindowID) -> CGRect? {
    guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
          let raw = info.first?[kCGWindowBounds as String]
    else { return nil }
    return CGRect(dictionaryRepresentation: raw as! CFDictionary)
}

/// The leftmost and rightmost columns of a run matching `match` on the row that
/// `screenY` (AppKit, bottom-left) falls on, in display points -- or nil when
/// nothing on that row matches.
///
/// Scans a single row rather than the whole bitmap: a 5K frame is tens of
/// megabytes and this runs in the capture loop, between two calls whose timing
/// is the measurement.
func runInRow(
    of image: CGImage, screenY: CGFloat, scale: CGFloat,
    match: (UInt8, UInt8, UInt8) -> Bool
) -> (left: CGFloat, right: CGFloat)? {
    // Converted from AppKit's bottom-left screen space to the picture's
    // top-left one.
    let row = Int(((screen.frame.height - screenY) * scale).rounded())
    guard row >= 0, row < image.height,
          let strip = image.cropping(
            to: CGRect(x: 0, y: CGFloat(row), width: CGFloat(image.width), height: 1))
    else { return nil }

    let width = strip.width
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * 4)
    defer { bytes.deallocate() }
    bytes.initialize(repeating: 0, count: width * 4)
    guard let context = CGContext(
        data: bytes, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: 1))

    var left = -1, right = -1
    for x in 0..<width where match(bytes[x * 4], bytes[x * 4 + 1], bytes[x * 4 + 2]) {
        if left < 0 { left = x }
        right = x
    }
    guard left >= 0 else { return nil }
    return (displayBounds.minX + CGFloat(left) / scale,
            displayBounds.minX + CGFloat(right) / scale)
}

// Generous on the bright channels, strict on the dark one: nothing on a desktop
// sits at full red and full blue with no green, or at full green alone.
let isMagenta: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 200 && b > 200 && g < 60 }
let isGreen: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in g > 200 && r < 60 && b < 60 }

/// Where the rider's left edge is in the picture, in display points.
///
/// Its left edge is the answer whenever it is on screen; once the swipe has
/// carried that edge off, the right edge and the width it is known to have give
/// the same number. Clipped at both ends it cannot be placed, and says so.
func riderLeftEdge(in image: CGImage, scale: CGFloat) -> CGFloat? {
    guard let run = runInRow(
        of: image, screenY: riderY + riderSize.height / 2, scale: scale, match: isGreen)
    else { return nil }
    if run.left > displayBounds.minX + 0.5 { return run.left }
    if run.right < displayBounds.maxX - 0.5 { return run.right - riderSize.width }
    return nil
}

// MARK: - The samples

struct Sample {
    let at: CFTimeInterval
    let duration: Double  // ms
    let before: CGFloat   // b0
    let after: CGFloat    // b1
    let inPicture: CGFloat  // img
    /// The rider, when it was on screen and placeable: the same three numbers
    /// for the window that slides with the desktop.
    let riderBefore: CGFloat?
    let riderAfter: CGFloat?
    let riderInPicture: CGFloat?
}

let lock = NSLock()
var samples: [Sample] = []
var missed = 0
var slipped = 0

/// The panel's own travel, with a point of slack for the window server's
/// rounding. Bounds outside it mean the clock has been carried off by something
/// other than its timer -- the failure the first version died of.
let travelInPicture = (
    low: displayBounds.minX + travel.left - 2, high: displayBounds.minX + travel.right + 2)

let capture = Thread {
    // Let the panel land and the window server settle before the first read.
    Thread.sleep(forTimeInterval: 0.4)
    FileHandle.standardError.write(Data("sliding — swipe between desktops now\n".utf8))
    while CACurrentMediaTime() - startedAt < seconds {
        guard let before = serverBounds(of: windowID) else { continue }
        let riderBefore = serverBounds(of: riderID)
        let began = CACurrentMediaTime()
        let picture = createImage(
            displayBounds, CGWindowListOption.optionOnScreenOnly.rawValue,
            kCGNullWindowID, CGWindowImageOption().rawValue)?.takeRetainedValue()
        let ended = CACurrentMediaTime()
        // Exactly where `LegacyDisplayCapture` reads it: first thing after the
        // call, before anything else can run.
        let after = serverBounds(of: windowID)
        let riderAfter = serverBounds(of: riderID)

        guard let picture, let after else { continue }
        guard (travelInPicture.low...travelInPicture.high).contains(before.minX),
              (travelInPicture.low...travelInPicture.high).contains(after.minX)
        else {
            lock.lock(); slipped += 1; lock.unlock()
            continue
        }
        let scale = CGFloat(picture.width) / displayBounds.width
        guard let run = runInRow(
            of: picture, screenY: panelY + panelSize.height / 2, scale: scale, match: isMagenta)
        else {
            lock.lock(); missed += 1; lock.unlock()
            continue
        }
        let found = run.left
        let sample = Sample(
            at: began - startedAt, duration: (ended - began) * 1000,
            before: before.minX, after: after.minX, inPicture: found,
            riderBefore: riderBefore?.minX, riderAfter: riderAfter?.minX,
            riderInPicture: riderLeftEdge(in: picture, scale: scale))
        lock.lock(); samples.append(sample); lock.unlock()
    }
}

// The verdict is printed from the main run loop rather than from the capture
// thread, half a second after it has stopped sampling, so the last call in
// flight still lands in the table.
let finish = Timer(timeInterval: seconds + 0.5, repeats: false) { _ in report() }
RunLoop.main.add(finish, forMode: .common)

// MARK: - The verdict

func report() {
    // The run loop's timer fired this, so main it is -- stated rather than
    // hopped, because a hop would let another sample land mid-report.
    MainActor.assumeIsolated {
        animation.invalidate()
        panel.orderOut(nil)
    }
    lock.lock()
    let all = samples
    let lost = missed
    let carried = slipped
    lock.unlock()

    print("t_s,dur_ms,b0_x,b1_x,img_x,img-b1,g_b0,g_b1,g_img,g_img-g_b1,g_b1-g_b0")
    for s in all {
        let clock = String(
            format: "%.3f,%.1f,%.1f,%.1f,%.1f,%.1f",
            s.at, s.duration, s.before, s.after, s.inPicture, s.inPicture - s.after)
        guard let g0 = s.riderBefore, let g1 = s.riderAfter, let gi = s.riderInPicture else {
            print(clock + ",,,,,")
            continue
        }
        print(clock + String(format: ",%.1f,%.1f,%.1f,%.1f,%.1f", g0, g1, gi, gi - g1, g1 - g0))
    }

    func summarise(_ name: String, _ group: [Sample]) {
        guard !group.isEmpty else {
            print("\n\(name): no samples — the question is unanswered for this bucket")
            return
        }
        let toBefore = group.map { abs($0.inPicture - $0.before) }
        let toAfter = group.map { abs($0.inPicture - $0.after) }
        let still = group.filter { abs($0.after - $0.before) < 1 }.count
        func mean(_ xs: [CGFloat]) -> CGFloat { xs.reduce(0, +) / CGFloat(xs.count) }
        print("""

            \(name): \(group.count) samples, \
            call \(String(format: "%.1f", group.map(\.duration).min()!))–\
            \(String(format: "%.1f", group.map(\.duration).max()!)) ms
              |img − b0|  mean \(String(format: "%6.1f", mean(toBefore))) pt, \
            worst \(String(format: "%.1f", toBefore.max()!))
              |img − b1|  mean \(String(format: "%6.1f", mean(toAfter))) pt, \
            worst \(String(format: "%.1f", toAfter.max()!))
              bounds did not move across the call in \(still)/\(group.count)
            """)
    }

    // Three bands, because the log has three populations: the ordinary capture
    // (7–18 ms), the ones reported as offset (41–192 ms), and what a real swipe
    // did to it on 2026-09-18 (532–544 ms).
    summarise("fast   (< 25 ms)", all.filter { $0.duration < 25 })
    summarise("slow   (25–100 ms)", all.filter { (25..<100).contains($0.duration) })
    summarise("stalled (≥ 100 ms)", all.filter { $0.duration >= 100 })
    // The rider, split by whether the desktop was moving during the call. The
    // still bucket is the control: bounds and pixels describe the same window
    // at rest, so anything but ~0 there means this measurement cannot be
    // trusted and the moving bucket says nothing.
    let placed = all.filter {
        $0.riderBefore != nil && $0.riderAfter != nil && $0.riderInPicture != nil
    }
    func riderGap(_ s: Sample) -> CGFloat { abs(s.riderInPicture! - s.riderAfter!) }
    func riderSummary(_ name: String, _ group: [Sample]) {
        guard !group.isEmpty else {
            print("\n  \(name): no samples")
            return
        }
        let gaps = group.map(riderGap)
        print("""
              \(name): \(group.count) samples, \
            |g_img − g_b1| mean \(String(format: "%.1f", gaps.reduce(0, +) / CGFloat(gaps.count))) pt, \
            worst \(String(format: "%.1f", gaps.max()!))
            """)
    }
    print("\nthe rider (green, riding the desktop):")
    riderSummary("still   (bounds unchanged across the call)", placed.filter {
        abs($0.riderAfter! - $0.riderBefore!) < 2
    })
    riderSummary("moving  (bounds changed — mid-swipe)", placed.filter {
        abs($0.riderAfter! - $0.riderBefore!) >= 2
    })
    print("  not placeable in the picture: \(all.count - placed.count) of \(all.count)")

    // The same gap in milliseconds. A swipe moves the desktop 10 to 60 times
    // faster than the clock panel moves itself, so a gap in points says more
    // about how fast the desktop was going than about the pipeline. Dividing by
    // the speed the rider was actually travelling at over that call is what
    // makes the swipe samples comparable with the still ones -- and with the
    // clock's own 9-19 pt.
    let travelling = placed.filter { abs($0.riderAfter! - $0.riderBefore!) >= 50 }
    if travelling.isEmpty {
        print("  in milliseconds: no sample moved far enough to divide by")
    } else {
        let ms = travelling.map { s -> Double in
            let speed = (s.riderAfter! - s.riderBefore!) / s.duration  // pt/ms, signed
            return Double((s.riderAfter! - s.riderInPicture!) / speed)
        }.sorted()
        let speeds = travelling.map { abs($0.riderAfter! - $0.riderBefore!) / $0.duration }
        print("""
              in milliseconds, over \(travelling.count) samples that were really moving:
                stale  median \(String(format: "%.1f", ms[ms.count / 2])) ms, \
            mean \(String(format: "%.1f", ms.reduce(0, +) / Double(ms.count))) ms, \
            range \(String(format: "%.1f", ms.first!)) to \(String(format: "%.1f", ms.last!))
                desktop speed \(String(format: "%.1f", speeds.min()!))\
            –\(String(format: "%.1f", speeds.max()!)) pt/ms \
            (the clock panel moves at 1.2)
            """)
    }

    print("\npanel not in the picture: \(lost) calls")
    print("clock carried off its own travel: \(carried) calls (kept out of the means)")
    print("""

        Reading it: the clock settles how old the picture is -- |img − b1| small
        at every duration means the frame is fresh however long the call took.
        The rider settles the other question, and only the millisecond line
        answers it: a gap in points grows with the desktop's speed and says
        little. If the stale figure there is of the same order as the clock's,
        the two agree in time and the offset is that one latency multiplied by a
        swipe's speed; if it is far larger, a window riding a desktop is drawn
        somewhere its own bounds never report, and no read order can help.
        """)
    exit(0)
}

capture.start()
app.run()
