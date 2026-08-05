#!/usr/bin/env swift
// Where has the wallpaper actually gone?
//
// `DesktopWallpaper` gets it by excluding every running application from a
// display filter, on the stated premise that "what is left is exactly the
// wallpaper". Measured 2026-08-05 on this machine: what is left is a completely
// black 3456x2234 image. The wallpaper is drawn by an application too, so
// excluding them all excludes it as well — and the padding around every window
// capture has been a flat fill ever since, which is what "the wallpaper has
// never worked" meant.
//
// So find the windows that *do* draw it. They are desktop-level windows, which
// the app's enumeration throws away (`excludingDesktopWindows: true`), and a
// filter built to include only those should be the wallpaper and nothing else.
//
//   swift Scripts/wallpaper-source-probe.swift
//
// Prints every candidate and scores each attempt: black means the wallpaper is
// still missing, and near-identical to the plain display means everything else
// leaked in.

import AppKit
import ScreenCaptureKit

let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("wallpaper-source-probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func raster(_ image: CGImage) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return ok ? pixels : nil
}

func meanLuma(_ image: CGImage) -> Double {
    guard let pixels = raster(image) else { return -1 }
    var sum = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        sum += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
            + 0.0722 * Double(pixels[index + 2])
    }
    return sum / Double(pixels.count / 4)
}

func difference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
    guard lhs.width == rhs.width, lhs.height == rhs.height,
          let a = raster(lhs), let b = raster(rhs) else { return -1 }
    var sum = 0
    for index in 0..<a.count { sum += abs(Int(a[index]) - Int(b[index])) }
    return Double(sum) / Double(a.count)
}

func shoot(_ filter: SCContentFilter) async throws -> CGImage? {
    let configuration = SCScreenshotConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
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

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

@MainActor
func run() async throws {
    // Desktop windows kept, unlike the app's own enumeration: they are the whole
    // point here.
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
        print("no display")
        return
    }

    let plain = try await shoot(SCContentFilter(display: display, excludingWindows: []))
    guard let plain else {
        print("could not capture the plain display")
        return
    }
    write(plain, "display")
    print(String(format: "plain display: mean luma %.1f\n", meanLuma(plain)))

    let layers = { () -> [CGWindowID: Int] in
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var result: [CGWindowID: Int] = [:]
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            result[CGWindowID(number.uint32Value)] = entry[kCGWindowLayer as String] as? Int ?? 0
        }
        return result
    }()

    // At or below the desktop level, covering the display.
    //
    // The bound is the interesting part. Everything below zero is "desktop", but
    // that range holds two different things and only one of them is wanted:
    //
    //     Finder            -2147483603   the desktop *icons*
    //     kCGDesktopWindow  -2147483623   <- the line
    //     WindowManager     -2147483624   "Wallpaper"
    //     (none)            -2147483626   "Display 1 Backstop"
    //
    // A padding backdrop full of the user's desktop clutter is not what anyone
    // means by "the wallpaper", so the icon window has to stay out — and it does,
    // by a documented constant rather than by an application name.
    let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
    let desktopWindows = content.windows.filter { window in
        let layer = layers[window.windowID] ?? 0
        return layer <= desktopLevel && window.frame.width >= display.frame.width * 0.9
    }
    print("desktop level = \(desktopLevel)")

    print("desktop-level windows covering the display: \(desktopWindows.count)")
    for window in desktopWindows {
        print(String(format: "  id=%-6u L%-12d %4.0fx%-4.0f  %-22@ %@",
                     window.windowID, layers[window.windowID] ?? 0,
                     window.frame.width, window.frame.height,
                     (window.owningApplication?.applicationName ?? "—") as NSString,
                     (window.title ?? "") as NSString))
    }

    guard !desktopWindows.isEmpty else {
        print("\nnone found — the wallpaper is not a desktop-level window here")
        return
    }

    let filter = SCContentFilter(display: display, including: desktopWindows)
    guard let image = try await shoot(filter) else {
        print("\ncapture failed")
        return
    }
    write(image, "wallpaper-from-desktop-windows")
    print(String(
        format: "\nincluding only those: mean luma %.1f, diff vs display %.2f -> %@",
        meanLuma(image), difference(image, plain),
        meanLuma(image) < 1 ? "STILL BLACK" : "has content"))
    print("\nPNGs: \(outDir.path)")
}

Task {
    do { try await run() } catch { print("failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
