import CoreGraphics
import Foundation
import ScreenCaptureKit

// =============================================================================
// The ONLY file in this project permitted to use `@unchecked Sendable`.
//
// ScreenCaptureKit ships almost no Sendable annotations: `SCScreenshotConfiguration`
// is NS_SWIFT_SENDABLE, but `SCScreenshotOutput`, `SCContentFilter`, `SCWindow`,
// `SCDisplay`, `SCRunningApplication` and `SCShareableContent` are not (verified
// against the macOS 27.0 SDK headers; there are no .apinotes adding them).
//
// We deliberately wrap the *completion-handler* variants rather than calling the
// auto-generated `async` ones. That puts the isolation boundary somewhere we
// control, lets us snapshot into a Sendable type inside the callback, and keeps
// the compiler diagnostics comprehensible.
//
// Every function here is `nonisolated`. Combined with NonisolatedNonsendingByDefault
// (SE-0461) they run on the *caller's* executor, so a MainActor-isolated
// `SCContentFilter` passed in never leaves its isolation region.
// =============================================================================

nonisolated enum CaptureError: Error, LocalizedError {
    case emptyOutput
    case noDisplays
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    case noImageProduced
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            "ScreenCaptureKit returned neither an output nor an error."
        case .noDisplays:
            "No displays reported by ScreenCaptureKit."
        case .displayNotFound(let id):
            "No SCDisplay for display ID \(id)."
        case .windowNotFound(let id):
            "No SCWindow for window ID \(id)."
        case .noImageProduced:
            "Capture succeeded but produced no image."
        case .encodingFailed(let why):
            "Image encoding failed: \(why)."
        }
    }
}

/// Immutable snapshot of `SCScreenshotOutput`.
///
/// SCK fires its completion on an internal queue. We copy out the immutable
/// fields there and share nothing else, so `@unchecked` is honest rather than a
/// silencer. `CGImage` itself is an immutable CF type.
// `nonisolated` on the type opts the whole thing out of the module's default
// MainActor isolation (SE-0466). Required: these are built inside SCK completion
// handlers, which fire on an internal queue.
nonisolated struct SCKOutput: @unchecked Sendable {
    let sdrImage: CGImage?
    let hdrImage: CGImage?
    let fileURL: URL?

    /// The image we actually want to hand to the rest of the app.
    var image: CGImage? { sdrImage ?? hdrImage }
}

/// Carries a live, non-Sendable SCK object across the completion-handler boundary.
///
/// Honest because SCK constructs these fresh per call and the receiving side
/// immediately pins them to `@MainActor` (see `ShareableContentCache`). Nothing
/// else ever touches the boxed value.
nonisolated struct SCKBox<Value>: @unchecked Sendable {
    let value: Value
}

enum SCKBridge {
    // MARK: - Screenshots

    static func captureScreenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> SCKOutput {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            ) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let output else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                    return
                }
                continuation.resume(
                    returning: SCKOutput(
                        sdrImage: output.sdrImage,
                        hdrImage: output.hdrImage,
                        // Declared `assign` (not `strong`) in the SDK, so it
                        // imports as NSURL? rather than bridging to URL?. Read
                        // it here, inside the callback, while `output` is alive.
                        fileURL: output.fileURL as URL?
                    )
                )
            }
        }
    }

    // MARK: - Content enumeration

    /// Everything shareable on the system. Requires the Screen Recording grant.
    static func shareableContent(
        excludingDesktopWindows: Bool = true,
        onScreenWindowsOnly: Bool = true
    ) async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }

    /// The plain enumeration, kept alongside the filtered one for diagnostics:
    /// they can disagree, and when displays go missing it matters which.
    static func allShareableContent() async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }

    /// Only *our own* process's windows.
    ///
    /// macOS 14.4+. Dramatically cheaper than the full enumeration and — the
    /// reason we use it — it requires no TCC round-trip, so finding our overlay
    /// panels to exclude them can never be affected by the monthly re-prompt.
    static func currentProcessShareableContent() async throws -> SCKBox<SCShareableContent> {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: SCKBox(value: content))
                } else {
                    continuation.resume(throwing: CaptureError.emptyOutput)
                }
            }
        }
    }
}
