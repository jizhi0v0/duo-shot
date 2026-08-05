#!/usr/bin/env swift
// Which same-process ScreenCaptureKit state turns a menu-bar popup translucent?
//
// Round one ruled out the obvious answer. The saved files are 100% black, but
// the same window captured through `SCStreamConfiguration` came back with all
// its text and icons, and captured as a region of the display came back at
// 100% non-black. So it is not the glass-with-no-backdrop failure the Dock hit
// (`CaptureEngine.captureRegion`) — that one cannot blacken text anyway.
//
// First, one variable at a time: window-only versus a full-display capture
// immediately followed by that same window request. Then test two in-process
// alternatives after the same display precursor: the pre-26 captureImage API,
// and a display-bounded filter that includes only the selected parent window.
//
//   swift Scripts/popup-capture-probe.swift DuoUpdater [delay] [rounds]
//
// Start it, then open the popup and leave it open.

import AppKit
import ScreenCaptureKit

// CoreGraphics aborts with CGS_REQUIRE_INIT if the window-server connection has
// not been established on the main thread before the first SCContentFilter is
// built — and these filters are built from a nonisolated async context, i.e.
// off the main thread. Establishing it here costs nothing and fixes it.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let args = CommandLine.arguments.dropFirst()
let needle = args.first ?? "DuoUpdater"
let delay = Double(args.dropFirst().first ?? "") ?? 8
let rounds = Int(args.dropFirst(2).first ?? "") ?? 5
let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("popup-capture-probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// The box containing every pixel whose alpha is above `threshold`, in image
/// pixels. Nil when nothing clears the bar.
func inkBounds(_ image: CGImage, above threshold: UInt8) -> CGRect? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > threshold {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func shoot(
    _ window: SCWindow, children: Bool, shadows: Bool
) async throws -> CGImage? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = SCScreenshotConfiguration()
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.includeChildWindows = children
    configuration.ignoreShadows = shadows
    return try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration
        ) { output, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: output?.sdrImage) }
        }
    }
}

/// A full-display capture through the exact new screenshot API used by freeze
/// mode. Its returned image is intentionally discarded: the variable under
/// test is whether this request happened in the same process immediately before
/// the desktop-independent window request.
func shootDisplay(_ display: SCDisplay) async throws {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = SCScreenshotConfiguration()
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.ignoreShadows = true
    _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<CGImage?, any Error>) in
        SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: configuration
        ) { output, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: output?.sdrImage) }
        }
    }
}

func shootLegacy(_ window: SCWindow) async throws -> CGImage? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let configuration = SCStreamConfiguration()
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.includeChildWindows = true
    configuration.ignoreShadowsSingleWindow = true
    return try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) { image, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: image) }
        }
    }
}

/// Display-bounded sharing with an inclusion list does not photograph the
/// z-order above the selected window: only the listed window, plus children
/// requested by the configuration, enters the frame. `sourceRect` merely crops
/// that isolated composition down from display coordinates to the window.
func shootDisplayBounded(
    _ window: SCWindow, on display: SCDisplay
) async throws -> CGImage? {
    let filter = SCContentFilter(display: display, including: [window])
    let scale = CGFloat(filter.pointPixelScale)
    let sourceRect = CGRect(
        x: window.frame.minX - display.frame.minX,
        y: window.frame.minY - display.frame.minY,
        width: window.frame.width,
        height: window.frame.height)
    let configuration = SCScreenshotConfiguration()
    configuration.width = Int((sourceRect.width * scale).rounded())
    configuration.height = Int((sourceRect.height * scale).rounded())
    configuration.sourceRect = sourceRect
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

@MainActor
func run() async throws {
    print("waiting \(Int(delay))s — open the popup now")
    try await Task.sleep(for: .seconds(delay))

    let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
    let windows = content.windows.filter {
        ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(needle)
    }
    guard !windows.isEmpty else {
        print("no on-screen window owned by an app matching '\(needle)'")
        return
    }

    // The app makes a full-display freeze photograph just before the isolated
    // window shot; the old probe process did not. Alternate the two sequences
    // against one held SCWindow. Within each pair the only changed variable is
    // the preceding display request.
    func opacity(_ image: CGImage) -> (Int, Int) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w*h*4)
        px.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w*4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0, sum = 0
        for i in stride(from: 0, to: px.count, by: 4) where Int(px[i+3]) > 128 {
            n += 1; sum += Int(px[i+3])
        }
        return (n, n > 0 ? sum/n : 0)
    }

    print("\n\(windows.count) window(s), \(rounds) paired round(s):\n")
    for window in windows {
        print("  id=\(window.windowID) \(Int(window.frame.width))x\(Int(window.frame.height))")

        let display = content.displays.min { lhs, rhs in
            abs(lhs.frame.midX - window.frame.midX) < abs(rhs.frame.midX - window.frame.midX)
        }
        guard let display else { continue }

        for round in 1...rounds {
            for precededByDisplay in [false, true] {
                if precededByDisplay { try await shootDisplay(display) }
                let image = try await shoot(window, children: true, shadows: true)
                let label = precededByDisplay ? "display -> window" : "window only      "
                guard let image else {
                    print("        round \(round) \(label): no image")
                    continue
                }
                write(image, "\(window.windowID)-r\(round)-\(precededByDisplay ? "after-display" : "control").png")
                let o = opacity(image)
                print("        round \(round) \(label): body \(o.0) px, meanBodyAlpha \(o.1)/255"
                    + (o.1 >= 250 ? "  opaque" : "  DEGRADED"))
            }
        }

        print("        alternatives after display precursor:")
        for round in 1...rounds {
            try await shootDisplay(display)
            let legacy = try await shootLegacy(window)
            try await shootDisplay(display)
            let bounded = try await shootDisplayBounded(window, on: display)
            for (label, image) in [("legacy captureImage ", legacy),
                                   ("display including  ", bounded)] {
                guard let image else {
                    print("          round \(round) \(label): no image")
                    continue
                }
                write(image, "\(window.windowID)-alt-r\(round)-\(label.hasPrefix("legacy") ? "legacy" : "bounded").png")
                let o = opacity(image)
                print("          round \(round) \(label): body \(o.0) px, meanBodyAlpha \(o.1)/255"
                    + (o.1 >= 250 ? "  opaque" : "  DEGRADED"))
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
