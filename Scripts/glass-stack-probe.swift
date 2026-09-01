// Can a window capture keep what is stacked on the window, and can it keep the
// window's glass? Builds its own subject so neither answer depends on what the
// machine happens to have open.
//
// The subject is DuoUpdater's shape, because that is where both questions came
// from: MenuBarExtra + .menuBarExtraStyle(.window), with a SwiftUI .popover
// opened inside it — the Qt runtime tag. It clicks its own status item to open
// the panel, because MenuBarExtra exposes no way to open it and its status
// button has no target/action.
//
// Three coloured surfaces, so every question is a pixel count and not an
// impression:
//
//   magenta  the popover's content        — did the stacking survive
//   red      an opaque window parked directly behind the panel
//                                         — did the glass sample its backdrop
//   the panel itself is left transparent so the material is the real one
//
// **The red window is the point.** Without something loud behind the panel, an
// isolated capture and a display-bounded one are two rectangles of dark grey and
// read as identical; that is how a wrong "no difference here" got reported once.
//
// Prints, for the same window at the same instant: the AppKit window tree (so
// the popover's parent is named rather than guessed at), what DuoShot's picker
// would offer, every filter, and macOS's own screencapture -l as the reference
// point.
//
//   swiftc -parse-as-library Scripts/glass-stack-probe.swift -o /tmp/glass-stack-probe
//   /tmp/glass-stack-probe
//
// Results as of 2026-09-01 (macOS 27.0) are in CLAUDE.md, "Window capture".

import SwiftUI
import AppKit
import ScreenCaptureKit

let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("glass-stack-probe")

// The popover's content: one flat magenta block, so "did it survive" is a pixel count.
struct Detail: View {
    var body: some View {
        Color(red: 1, green: 0, blue: 1)
            .frame(width: 220, height: 120)
    }
}

struct Panel: View {
    @State private var showingDetail = false
    var body: some View {
        VStack(spacing: 0) {
            // Stand-in for the app list: a dark body the popover will sit over.
            Color.clear.frame(width: 420, height: 300)
        }
        .overlay(alignment: .topLeading) {
            Button("Qt") { showingDetail = true }
                .padding(20)
                .popover(isPresented: $showingDetail, arrowEdge: .bottom) { Detail() }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(900))
            showingDetail = true
        }
    }
}

func countMagenta(_ image: CGImage) -> Int {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var m = 0
    for i in stride(from: 0, to: px.count, by: 4) where Int(px[i + 3]) > 200 {
        if Int(px[i]) > 200, Int(px[i + 1]) < 60, Int(px[i + 2]) > 200 { m += 1 }
    }
    return m
}

/// Anything reddish — the backdrop showing through the glass, however dimmed
/// and blurred the material leaves it.
func countReddish(_ image: CGImage) -> Int {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0
    for i in stride(from: 0, to: px.count, by: 4) where Int(px[i + 3]) > 200 {
        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
        if r > 60, r > g * 2, r > b * 2 { n += 1 }
    }
    return n
}

/// `WindowPickerModel.isUniformInflation`, copied verbatim so the replica judges
/// the window set the way the picker actually would.
func isUniformInflation(of inner: CGRect, to outer: CGRect) -> Bool {
    let margins = [inner.minX - outer.minX, outer.maxX - inner.maxX,
                   inner.minY - outer.minY, outer.maxY - inner.maxY]
    guard let smallest = margins.min(), let largest = margins.max() else { return false }
    return smallest > 1 && largest - smallest <= 2
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task.detached {
            try? await Task.sleep(for: .seconds(40))
            print("watchdog: giving up")
            exit(3)
        }
        Task { @MainActor in await self.run() }
    }

    /// MenuBarExtra exposes no way to open its panel; its status button has no
    /// target/action (`performClick` is a no-op) and reports a window number of
    /// 2^32, so nothing can be posted to it in-process either. The status item is
    /// hosted outside this process.
    ///
    /// So the click is a real one, posted to the window server at the button's
    /// screen position. The pointer is put back where it was.
    func openPanel() -> Bool {
        let screens = NSScreen.screens.map(\.frame)
        guard let primary = NSScreen.screens.first?.frame else { return false }
        for window in NSApp.windows
        where NSStringFromClass(type(of: window)).contains("StatusBar")
            && screens.contains(where: { $0.intersects(window.frame) }) {
            let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
            // AppKit global (origin bottom-left) -> CG global (origin top-left).
            let point = CGPoint(x: centre.x, y: primary.maxY - centre.y)
            let restore = CGEvent(source: nil)?.location
            print("  clicking the status item at CG \(NSStringFromPoint(point))")
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                usleep(60_000)
            }
            if let restore {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: restore, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            return true
        }
        return false
    }

    /// True once a window that is not a status-bar tile is on screen.
    var panelIsOpen: Bool {
        NSApp.windows.contains {
            $0.isVisible && !NSStringFromClass(type(of: $0)).contains("StatusBar")
                && $0.frame.width > 100
        }
    }

    /// Parked under where the MenuBarExtra panel opens, in a colour nothing else
    /// on screen has. Any of it in a capture of the panel is the glass sampling
    /// its backdrop; none of it is the glass falling back to its base tint.
    let backdrop: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 1064, y: 782, width: 420, height: 300),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        w.isOpaque = true
        w.hasShadow = false
        w.level = .normal
        return w
    }()

    func run() async {
        backdrop.orderFrontRegardless()
        // The status item is not installed the instant the app finishes launching.
        try? await Task.sleep(for: .milliseconds(1500))
        var opened = false
        for attempt in 1...5 {
            _ = openPanel()
            try? await Task.sleep(for: .milliseconds(800))
            if panelIsOpen { opened = true; print("  panel open after attempt \(attempt)"); break }
        }
        guard opened else { print("could not open the panel"); exit(2) }
        // 900 ms for the popover's own .task, plus slack for it to be composited.
        try? await Task.sleep(for: .milliseconds(1800))

        print("=== AppKit windows in this process ===")
        for w in NSApp.windows where w.isVisible {
            print(String(format: "  #%-6d level %-5d parent %-6d %-26s %@",
                         w.windowNumber, w.level.rawValue, w.parent?.windowNumber ?? -1,
                         (String(describing: type(of: w)) as NSString).utf8String!,
                         NSStringFromRect(w.frame)))
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { print("no shareable content"); exit(2) }

        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        // The panel and the popover; the status item's own tile is far too small
        // to be pickable and is not part of this.
        let candidates = mine.filter { $0.frame.width >= 40 && $0.frame.height >= 40 }
        print("=== SCWindows the picker would consider ===")
        for w in candidates {
            print(String(format: "  #%-6d layer %-5d %@", w.windowID, w.windowLayer,
                         NSStringFromRect(w.frame)))
        }

        var hosts: Set<CGWindowID> = []
        for outer in candidates {
            for inner in candidates where inner.windowID != outer.windowID {
                guard inner.windowLayer == outer.windowLayer,
                      isUniformInflation(of: inner.frame, to: outer.frame) else { continue }
                hosts.insert(outer.windowID)
                print("  picker would drop #\(outer.windowID) as a shadow host around #\(inner.windowID)")
                break
            }
        }
        let offered = candidates.filter { !hosts.contains($0.windowID) }
        print("  picker would offer: \(offered.map { "#\($0.windowID)" }.joined(separator: ", "))")

        // The popover's window, named by AppKit so there is no guessing.
        let popoverNumbers = Set(NSApp.windows
            .filter { NSStringFromClass(type(of: $0)).contains("Popover") }
            .map { CGWindowID($0.windowNumber) })
        print("  popover window(s): \(popoverNumbers.map { "#\($0)" }.joined(separator: ", "))")

        // The panel, named by AppKit rather than picked out by size: the backdrop
        // window behind it is deliberately the same size, so "the biggest one"
        // was a coin toss and it landed wrong once.
        let panelNumbers = Set(NSApp.windows
            .filter { NSStringFromClass(type(of: $0)).contains("MenuBarExtra") }
            .map { CGWindowID($0.windowNumber) })
        guard let target = offered.first(where: { panelNumbers.contains($0.windowID) })
        else { print("no MenuBarExtra panel among \(offered.count) offered windows"); exit(2) }
        print("  target (what the pick resolves to): #\(target.windowID) \(NSStringFromRect(target.frame))")

        func config(_ child: Bool, _ source: CGRect?) -> SCScreenshotConfiguration {
            let c = SCScreenshotConfiguration()
            c.width = Int(target.frame.width * 2)
            c.height = Int(target.frame.height * 2)
            c.includeChildWindows = child
            c.showsCursor = false
            if let source { c.sourceRect = source }
            return c
        }
        func shoot(_ filter: SCContentFilter, _ c: SCScreenshotConfiguration, _ label: String) async {
            do {
                let out = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter, configuration: c)
                guard let img = out.sdrImage else { print("\(label): no image"); return }
                print(String(format: "  %-44s %4dx%-4d  magenta %6d  reddish %6d",
                             (label as NSString).utf8String!, img.width, img.height,
                             countMagenta(img), countReddish(img)))
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])!.write(
                    to: outDir.appendingPathComponent(
                        label.replacingOccurrences(of: " ", with: "-") + ".png"))
            } catch { print("\(label): \(error)") }
        }

        print("=== captures of #\(target.windowID) ===")
        await shoot(SCContentFilter(desktopIndependentWindow: target),
                    config(false, nil), "A desktopIndependent child=false")
        await shoot(SCContentFilter(desktopIndependentWindow: target),
                    config(true, nil), "B desktopIndependent child=true")
        let group = candidates   // the panel and the popover
        await shoot(SCContentFilter(display: display, including: group),
                    config(false, target.frame), "C display:including child=false")

        // Both filters above are measured against the picked window's frame, and
        // the popover overhangs it. So the same two again, sized to the union of
        // the group instead — the shape a fix would actually have to use.
        let union = group.reduce(target.frame) { $0.union($1.frame) }
        print("  union of the group: \(NSStringFromRect(union)) "
            + "(picked window \(NSStringFromRect(target.frame)))")
        func unionConfig(_ child: Bool, _ source: CGRect?) -> SCScreenshotConfiguration {
            let c = SCScreenshotConfiguration()
            c.width = Int(union.width * 2); c.height = Int(union.height * 2)
            c.includeChildWindows = child
            c.showsCursor = false
            if let source { c.sourceRect = source }
            return c
        }
        await shoot(SCContentFilter(desktopIndependentWindow: target),
                    unionConfig(true, nil), "D desktopIndependent child=true union-sized")
        await shoot(SCContentFilter(display: display, including: group),
                    unionConfig(false, union), "E display:including union-sized")

        // Does SCK hand back the group's true rect if the size is left alone?
        // The header says width/height default to "the width/height of the
        // content being captured", and with includeChildWindows that content is
        // the whole group — which would give the union without having to know
        // which windows are in it.
        let bare = SCScreenshotConfiguration()
        bare.includeChildWindows = true
        bare.showsCursor = false
        if let out = try? await SCScreenshotManager.captureScreenshot(
            contentFilter: SCContentFilter(desktopIndependentWindow: target),
            configuration: bare), let img = out.sdrImage {
            print("  F child=true, size unset -> \(img.width)x\(img.height) px "
                + "(picked window \(Int(target.frame.width * 2))x\(Int(target.frame.height * 2)), "
                + "union \(Int(union.width * 2))x\(Int(union.height * 2)))")
        }

        // Anything in the window server's own dictionary that names the group?
        if let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let n = entry[kCGWindowNumber as String] as? NSNumber,
                      [target.windowID, CGWindowID(popoverNumbers.first ?? 0)]
                        .contains(CGWindowID(n.uint32Value)) else { continue }
                print("  CGWindowList #\(n): \(entry.keys.sorted().joined(separator: ", "))")
            }
        }

        let regionFilter = SCContentFilter(display: display, excludingWindows: [])
        let regionConfig = SCScreenshotConfiguration()
        regionConfig.showsCursor = false
        let local = CGRect(x: target.frame.minX, y: target.frame.minY,
                           width: target.frame.width, height: target.frame.height)
        regionConfig.sourceRect = local
        regionConfig.width = Int(local.width * 2); regionConfig.height = Int(local.height * 2)
        await shoot(regionFilter, regionConfig, "G region of the display")

        // What does macOS's own window capture do with the same window? It is the
        // only reference point that settles whether the flat glass is a limit of
        // the platform or a limit of how we ask.
        for (label, args) in [
            ("H screencapture -l", ["-x", "-o", "-l\(target.windowID)"]),
            ("I screencapture -l (with shadow)", ["-x", "-l\(target.windowID)"]),
        ] {
            let url = outDir.appendingPathComponent(
                label.replacingOccurrences(of: " ", with: "-") + ".png")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = args + [url.path]
            try? task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("  \(label): exit \(task.terminationStatus), no image"); continue
            }
            print(String(format: "  %-44s %4dx%-4d  magenta %6d  reddish %6d",
                         (label as NSString).utf8String!, img.width, img.height,
                         countMagenta(img), countReddish(img)))
        }

        print("out: \(outDir.path)")
        exit(0)
    }
}

@main
struct ReplicaApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        MenuBarExtra("Probe") { Panel() }
            .menuBarExtraStyle(.window)
    }
}
