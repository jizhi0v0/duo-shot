import CoreGraphics
import Foundation

/// A finished recording, before any output action has been taken.
///
/// The screenshot analogue carries a `CGImage`; this carries a file, because a
/// recording never exists in memory. `StagingStore` owns the file's location in
/// exactly the same way.
nonisolated struct RecordingResult: Sendable, Identifiable {
    let id = UUID()
    /// Mutable for exactly one reason: "save" is a move, and after it the whole
    /// app must agree on where the file went. Same invariant the screenshot side
    /// gets by carrying the URL in `OutputPipeline.Output`.
    var url: URL
    let duration: TimeInterval
    let fileSize: Int
    /// Encoded frame size.
    let pixelSize: CGSize
    /// The logical size of the recorded region, for the preview card.
    let pointSize: CGSize
    let scale: CGFloat
    let sourceDisplayID: CGDirectDisplayID
    let sourceDescription: String
    let startedAt: Date

    var durationDescription: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
