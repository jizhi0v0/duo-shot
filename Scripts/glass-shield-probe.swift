#!/usr/bin/env swift
// Does covering a glass panel with a full-screen window degrade its capture?
//
// This was "tested" once already and the test was blind: the shield went over
// an ordinary Telegram window, and an ordinary window has no material that
// samples its backdrop, so the experiment could not have shown anything. The
// window that degrades is a `MenuBarExtra` popup — liquid glass — and the only
// process that ever reproduces the degradation is the one that puts a
// full-screen panel over it.
//
// Everything else has been ruled out by measurement: the capture flags, the
// API version, two captures in a row, a full-display capture immediately
// before, a stale SCWindow, the pixel-size arithmetic, the window's own alpha
// (read 1.000 while the capture came back empty), and the post-capture crop.
// Thirty probe captures in a row came back at 253-254 with none of those
// varying. The shield is what the probe never had.
//
//   swift Scripts/glass-shield-probe.swift DuoUpdater [delay] [rounds]
//
// Open the popup and leave it open. The probe raises and drops the shield
// itself; nothing here clicks, and the shield never takes key, so the popup is
// not dismissed by the experiment.

import AppKit
import ScreenCaptureKit

// CoreGraphics aborts with CGS_REQUIRE_INIT unless the window-server connection
// exists before the first SCContentFilter, which is built off the main thread.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let args = CommandLine.arguments.dropFirst()
let needle = args.first ?? "DuoUpdater"
let delay = Double(args.dropFirst().first ?? "") ?? 8
let rounds = Int(args.dropFirst(2).first ?? "") ?? 4
let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("glass-shield-probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// The overlay's recipe, minus everything that is not the variable under test.
/// `canBecomeKey` stays false: a shield that dismissed the popup would end the
/// experiment instead of running it.
final class Shield: NSPanel {
    override var canBecomeKey: Bool { false }
    init(screen: NSScreen, frozen: CGImage?) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        hasShadow = false
        sharingType = .none
        if let frozen {
            // Freeze mode: the overlay is not a tint, it is a full-screen
            // photograph. If what matters is that the glass has an opaque
            // surface over it, this is the case that has it.
            isOpaque = true
            let view = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.image = NSImage(cgImage: frozen, size: screen.frame.size)
            view.imageScaling = .scaleAxesIndependently
            contentView = view
        } else {
            isOpaque = false
            backgroundColor = NSColor.black.withAlphaComponent(0.35)
        }
    }
}

func shootWindow(_ window: SCWindow) async throws -> CGImage? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = SCScreenshotConfiguration()
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.includeChildWindows = true
    configuration.ignoreShadows = true
    return try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration
        ) { output, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: output?.sdrImage) }
        }
    }
}

func shootDisplay(_ display: SCDisplay) async throws -> CGImage? {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = SCScreenshotConfiguration()
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    return try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration
        ) { output, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: output?.sdrImage) }
        }
    }
}

func opacity(_ image: CGImage) -> (pixels: Int, mean: Int) {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
        let c = CGContext(data: raw.baseAddress, width: w, height: h,
                          bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var n = 0, sum = 0
    for i in stride(from: 0, to: px.count, by: 4) where Int(px[i + 3]) > 128 {
        n += 1; sum += Int(px[i + 3])
    }
    return (n, n > 0 ? sum / n : 0)
}

func write(_ image: CGImage, _ name: String) {
    guard let d = CGImageDestinationCreateWithURL(
        outDir.appendingPathComponent("\(name).png") as CFURL,
        "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, image, nil)
    CGImageDestinationFinalize(d)
}

@MainActor
func run() async throws {
    print("waiting \(Int(delay))s — open the popup and leave it open")
    try await Task.sleep(for: .seconds(delay))

    let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
    guard let screen = NSScreen.main, let display = content.displays.first else {
        print("no screen"); return
    }
    let windows = content.windows.filter {
        ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(needle)
            && $0.frame.width * $0.frame.height > 20_000
    }
    guard !windows.isEmpty else { print("no popup window found"); return }

    // The freeze photograph the real overlay would be displaying.
    let frozen = try await shootDisplay(display)

    for window in windows {
        print("\n  id=\(window.windowID) \(Int(window.frame.width))x\(Int(window.frame.height))")
        for round in 1...rounds {
            for (label, shield) in [
                ("no shield          ", nil as Shield?),
                ("translucent shield ", Shield(screen: screen, frozen: nil)),
                ("frozen-photo shield", Shield(screen: screen, frozen: frozen)),
            ] {
                shield?.orderFrontRegardless()
                // Long enough for a material to notice it has been covered.
                try await Task.sleep(for: .milliseconds(350))
                let image = try await shootWindow(window)
                shield?.orderOut(nil)
                try await Task.sleep(for: .milliseconds(150))
                guard let image else { print("    round \(round) \(label): no image"); continue }
                let o = opacity(image)
                write(image, "\(window.windowID)-r\(round)-\(label.prefix(3))")
                print("    round \(round) \(label): body \(o.pixels) px, "
                    + "meanBodyAlpha \(o.mean)/255"
                    + (o.mean >= 250 ? "  opaque" : "  DEGRADED"))
            }
        }
    }
    print("\nPNGs: \(outDir.path)")
}

Task {
    do { try await run() } catch { print("failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
