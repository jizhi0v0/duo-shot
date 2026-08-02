#!/usr/bin/env swift

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Minimal reproduction for the editor's click hand-off. Both samples use the
// same CoreText line at the same pixel coordinates. The second sample merely
// composites it twice, as happens while the old preview bitmap and the newly
// opened text view overlap during an asynchronous re-render.

let text = "啊酒酒水酒酒水 SAAS"
let width = 920
let height = 130
let fontSize: CGFloat = 80 // 40 pt in a 2× capture
let background = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.11, alpha: 1)
let red = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)

func line() -> CTLine {
    let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
        ?? CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: red,
        kCTKernAttributeName: 0,
        kCTTrackingAttributeName: 0,
    ]
    return CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
}

func render(copies: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setShadow(
        offset: CGSize(width: 0, height: -2), blur: 6,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
    for _ in 0..<copies {
        context.textPosition = CGPoint(x: 20, y: 32)
        CTLineDraw(line(), context)
    }
    return context.makeImage()!
}

struct Ink {
    var bounds = CGRect.null
    var coverage: Double = 0
}

func ink(of image: CGImage) -> Ink {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var result = Ink()
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset])
            let g = Int(bytes[offset + 1])
            let b = Int(bytes[offset + 2])
            let strength = max(0, r - max(g, b))
            guard strength > 12 else { continue }
            result.bounds = result.bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            result.coverage += Double(strength) / 255
        }
    }
    return result
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "/tmp/duoshot-text-handoff-probe")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let once = render(copies: 1)
let twice = render(copies: 2)
write(once, to: output.appendingPathComponent("single.png"))
write(twice, to: output.appendingPathComponent("double.png"))

let singleInk = ink(of: once)
let doubleInk = ink(of: twice)
print("single bounds=\(singleInk.bounds) coverage=\(String(format: "%.1f", singleInk.coverage))")
print("double bounds=\(doubleInk.bounds) coverage=\(String(format: "%.1f", doubleInk.coverage))")
print(String(format: "same bounds=%@, coverage change=%+.2f%%",
             singleInk.bounds == doubleInk.bounds ? "yes" : "no",
             (doubleInk.coverage / singleInk.coverage - 1) * 100))
print("wrote \(output.path)/single.png and double.png")
