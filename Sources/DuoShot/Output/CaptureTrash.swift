import AppKit

/// Throwing a capture away.
///
/// The loop a screenshot tool is actually used in is take → look → keep or bin,
/// and until this existed DuoShot had no third step: the card's ✕ and its swipe
/// both only dismissed the card, and the file stayed — so every retake stayed
/// in the save folder next to the one that was kept.
///
/// One owner rather than the same two calls written out at each of the three
/// places that delete — the card, the viewer and the search results — because
/// the second of those calls is the one that would get forgotten, and a stale
/// index row points at a file that is not there.
@MainActor
enum CaptureTrash {
    /// The Trash, never `removeItem`.
    ///
    /// This control sits in a bar the pointer passes over on the way to Copy,
    /// and it is one click with no confirmation — which is only defensible
    /// because the file is recoverable. `NSWorkspace.recycle` is what makes that
    /// true, so it is not an implementation detail to be swapped for something
    /// tidier later. `--selftest-delete` asserts the file lands in the Trash
    /// rather than merely that it stopped existing, for exactly that reason.
    ///
    /// The share link, if there is one, is deliberately left working. Deleting
    /// server-side is not recoverable, and `StatusItemController`'s Recent Links
    /// already put that behind a modifier and says so; a local bin button
    /// quietly revoking a published URL would contradict a rule this app has
    /// already reasoned out.
    ///
    /// - Returns: where it landed in the Trash, or nil if it could not be moved.
    @discardableResult
    static func delete(_ url: URL) async -> URL? {
        // A click timeline swapped in after this would put the take back
        // (`ClickTimelineJobs`).
        await ClickTimelineJobs.shared.stop(url)
        let landed: URL?
        do {
            landed = try await NSWorkspace.shared.recycle([url])[url]
        } catch {
            Log.app.error("""
                could not trash \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            NSSound.beep()
            return nil
        }
        // Only after the file is actually gone. Forgetting first would leave the
        // capture searchable-by-nothing if the move failed.
        await CaptureIndex.shared.forget(url)
        Log.app.notice("trashed \(url.lastPathComponent, privacy: .public)")
        return landed
    }
}
