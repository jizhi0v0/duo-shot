#!/usr/bin/env swift
// Why does the padding around a window capture sometimes show the whole desktop?
//
// `ShareableContentCache.wallpaperFilter` leaves the wallpaper by excluding
// every running application from a display filter. Reported 2026-08-05: the
// padding ring came back as a shrunken screenshot of the desktop — windows,
// menu bar and all — but only sometimes. Two captures 19 seconds apart, same
// build, one wallpaper and one desktop.
//
// If the exclusion silently does nothing, the "wallpaper" is just a display
// capture. So: build the same filter, capture it, and capture the plain display
// beside it. Identical images mean the exclusion did not happen.
//
//   swift Scripts/wallpaper-filter-probe.swift [rounds]
//
// Intermittent, so it repeats. One clean round proves nothing.

import AppKit
import ScreenCaptureKit

let rounds = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 10

/// Mean absolute per-channel difference, 0-255. Near zero means the two
/// captures are the same picture — i.e. excluding every application changed
/// nothing.
func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double? {
    guard lhs.width == rhs.width, lhs.height == rhs.height else { return nil }
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
    guard let a = raster(lhs), let b = raster(rhs) else { return nil }
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

@MainActor
func run() async throws {
    var identical = 0
    for round in 1...rounds {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            print("round \(round): no display")
            continue
        }

        let wallpaperFilter = SCContentFilter(
            display: display, excludingApplications: content.applications, exceptingWindows: [])
        wallpaperFilter.includeMenuBar = false
        let plainFilter = SCContentFilter(display: display, excludingWindows: [])

        guard let wallpaper = try await shoot(wallpaperFilter),
              let plain = try await shoot(plainFilter),
              let difference = meanAbsoluteDifference(wallpaper, plain)
        else {
            print("round \(round): capture failed")
            continue
        }

        // Below this the two are the same picture: excluding every application
        // removed nothing, so the "wallpaper" is the desktop.
        let leaked = difference < 1.0
        if leaked { identical += 1 }
        print(String(
            format: "round %2d: apps=%-3d windows=%-3d  wallpaper vs display mean diff %6.2f  %@",
            round, content.applications.count, content.windows.count, difference,
            leaked ? "LEAKED — exclusion did nothing" : "ok"))

        if round == 1 {
            // Numbers said "not identical to the display"; they cannot say
            // "this is the wallpaper". Look at it.
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("wallpaper-filter-probe")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, image) in [("wallpaper", wallpaper), ("display", plain)] {
                let url = dir.appendingPathComponent("\(name).png")
                if let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
            print("        wrote \(dir.path)")
        }
        try await Task.sleep(for: .milliseconds(400))
    }
    print("\n\(identical)/\(rounds) rounds leaked the desktop into the wallpaper")
}

Task {
    do { try await run() } catch { print("failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
