#!/usr/bin/env swift
// The picker draws a highlight over something the user cannot see.
//
// Reported after the overlay stopped taking key status: menus that used to be
// dismissed by the overlay appearing now survive it — and at least some of them
// survive as windows with nothing drawn in them. The frame is offered, the
// outline lands on empty screen, and there is nothing to capture.
//
// "Cannot see it" has two shapes and they need different fixes:
//
//   ghost   — the window is on screen and its surface is empty. The picker has
//             to stop offering it, the way it already refuses alpha-0 windows.
//   covered — the window is drawn but something is over it, or it is stale.
//             Then the picker is right and the problem is elsewhere.
//
// So this reports, for every on-screen window above the ordinary app range,
// what the window server says about it *and* how much of it is actually drawn.
//
//   swift Scripts/ghost-window-probe.swift [delay] [minLayer]
//
// Start it, put the screen into the state that produces the phantom outline
// (expand the menu, dismiss the overlay), and let it run.

import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments.dropFirst()
let delay = Double(args.first ?? "") ?? 10
let minLayer = Int(args.dropFirst().first ?? "") ?? 9

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// Where the drawn pixels start and end, in image pixels.
///
/// Also answers a second question this run has to settle: a `MenuBarExtra`
/// popup shows up as two windows, one wrapping the other with a uniform margin,
/// and both are offered. If their ink boxes are the same size, then
/// `CaptureEngine.trimmed` already makes the two produce the same picture and
/// only the outline differs — a much smaller problem than two different shots.
func inkBox(_ image: CGImage) -> String {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return "?" }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return "empty" }
    return "\(maxX - minX + 1)x\(maxY - minY + 1) px"
}

/// Fraction of pixels with any alpha at all, and mean luminance.
func score(_ image: CGImage) -> (drawn: Double, luma: Double) {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return (-1, -1) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var drawn = 0
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        if pixels[index + 3] > 0 { drawn += 1 }
        total += 0.2126 * Double(pixels[index])
            + 0.7152 * Double(pixels[index + 1])
            + 0.0722 * Double(pixels[index + 2])
    }
    let count = Double(width * height)
    return (Double(drawn) / count, total / count)
}

struct Server {
    let layer: Int
    let alpha: Double
    let depth: Int
}

func serverView() -> [CGWindowID: Server] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return [:] }
    var result: [CGWindowID: Server] = [:]
    for (depth, entry) in list.enumerated() {
        guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
        result[CGWindowID(number.uint32Value)] = Server(
            layer: entry[kCGWindowLayer as String] as? Int ?? 0,
            alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            depth: depth)
    }
    return result
}

/// One snapshot is the wrong instrument for a window that only exists while the
/// overlay is up.
///
/// The first version of this probe took a single reading at the end of a
/// countdown, and read back exactly the idle baseline — the phantom was gone by
/// then, most likely with the overlay that summoned it. "Nothing was found" and
/// "nothing was there" are not the same answer, so this polls instead and scores
/// every window the moment it *appears*.
@MainActor
func run() async throws {
    print("""
        watching for \(Int(delay))s — reproduce the phantom outline now.
        Windows already on screen are the baseline and are not reported; \
        anything that appears during the run is.
        """)

    var seen = Set<CGWindowID>(serverView().keys)
    let deadline = Date().addingTimeInterval(delay)
    var reported = 0

    while Date() < deadline {
        let server = serverView()
        let fresh = Set(server.keys).subtracting(seen)
        seen.formUnion(server.keys)
        guard !fresh.isEmpty else {
            try await Task.sleep(for: .milliseconds(250))
            continue
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            guard fresh.contains(window.windowID),
                  let info = server[window.windowID], info.layer >= minLayer
            else { return false }
            // The same floor the picker uses, so nothing is listed here that it
            // would have thrown away on size alone.
            let frame = window.frame
            return (frame.width >= 40 && frame.height >= 40)
                || frame.width * frame.height >= 20_000
        }

        for window in candidates {
            guard let info = server[window.windowID] else { continue }
            reported += 1
            let frame = window.frame
            let owner = window.owningApplication?.applicationName ?? "?"

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCScreenshotConfiguration()
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            // Children included: without them an ordinary popup reads as empty
            // for a reason that has nothing to do with this question.
            configuration.includeChildWindows = true

            // Wall clock, so these line up against DuoShot's own `hover ... ->`
            // stream: the question is which window was under the pointer at the
            // moment the outline was on screen, and neither half answers it
            // alone.
            var line = String(
                format: "%@  id=%-6u L%-4d a=%.2f  %4.0fx%-4.0f at %5.0f,%-5.0f  x:%.0f-%.0f y:%.0f-%.0f  %-22@ %@",
                clock.string(from: Date()) as NSString,
                window.windowID,
                info.layer, info.alpha, frame.width, frame.height, frame.minX, frame.minY,
                frame.minX, frame.maxX, frame.minY, frame.maxY,
                owner as NSString, (window.title ?? "") as NSString)
            do {
                let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
                    SCScreenshotManager.captureScreenshot(
                        contentFilter: filter, configuration: configuration
                    ) { output, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: output?.sdrImage) }
                    }
                }
                if let image {
                    let s = score(image)
                    line += String(format: "\n        drawn %5.1f%%  luma %5.1f  ink %@  -> %@",
                                   s.drawn * 100, s.luma, inkBox(image) as NSString,
                                   s.drawn < 0.01 ? "GHOST" : "real")
                } else {
                    line += "\n        no image -> GHOST"
                }
            } catch {
                line += "\n        capture failed: \(error.localizedDescription)"
            }
            print(line)
        }
    }

    if reported == 0 {
        print("""

            no new window at layer >= \(minLayer) appeared during the run.
            That is NOT the same as "there was no phantom": re-run and make sure \
            the outline is on screen while this is still counting down, or lower \
            the layer floor (second argument) if it is an ordinary app window.
            """)
    }
}

Task {
    do { try await run() } catch { print("failed: \(error)") }
    exit(0)
}
RunLoop.main.run()
