import AppKit
import CoreGraphics
import Foundation

/// A finished capture, before any output action has been taken.
///
/// `@unchecked Sendable` solely because of `CGImage`, which is an immutable CF
/// type — this is the one place outside `SCKBridge.swift` where that is true,
/// and it is stated rather than assumed.
nonisolated struct CaptureResult: @unchecked Sendable, Identifiable {
    let id = UUID()
    let image: CGImage
    /// Points, in the source display's space. The logical size for pasteboard
    /// and preview purposes.
    let pointSize: CGSize
    let scale: CGFloat
    let sourceDisplayID: CGDirectDisplayID
    let sourceDescription: String
    let capturedAt: Date

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// An NSImage whose *logical* size is in points.
    ///
    /// This is the fix for the "screenshots paste at double size" bug: a 2×
    /// capture has twice the point dimensions in pixels, and handing that to the
    /// pasteboard naively makes every paste target render it at 2×.
    var nsImage: NSImage {
        NSImage(cgImage: image, size: pointSize)
    }
}
