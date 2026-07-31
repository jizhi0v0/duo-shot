import AppKit
import UniformTypeIdentifiers

/// The single owner of a capture's file.
///
/// Capture → encode once → write to staging → every later action operates on
/// that one file. "Save" is a move, "copy" reuses the in-memory image, "reveal"
/// and "drag out" both use the URL.
@MainActor
final class OutputPipeline {
    struct Output {
        let result: CaptureResult
        /// Where the file lives right now: staging, or the save directory once
        /// it has been moved there.
        let url: URL
        let wasSaved: Bool
    }

    static let shared = OutputPipeline()

    private let staging = StagingStore.shared

    private init() {}

    /// `saveDirectoryOverride` exists for `--selftest-output`, which must not
    /// litter the user's real save folder or mutate their preferences.
    @discardableResult
    func process(_ result: CaptureResult, saveDirectoryOverride: URL? = nil) -> Output? {
        let preferences = Preferences.shared
        let contentType = preferences.imageFormat

        let stagedURL: URL
        do {
            stagedURL = try staging.stage(
                result, as: contentType, quality: preferences.jpegQuality)
        } catch {
            Log.app.error("staging failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }

        var finalURL = stagedURL
        var wasSaved = false
        if preferences.saveToDisk {
            do {
                finalURL = try staging.move(
                    stagedURL, to: saveDirectoryOverride ?? preferences.saveDirectory)
                wasSaved = true
            } catch {
                Log.app.error("save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if preferences.copyToClipboard {
            Clipboard.write(result, fileURL: finalURL)
        }
        if preferences.playsSound {
            NSSound(named: "Grab")?.play()
        }

        Log.app.notice("output \(finalURL.lastPathComponent, privacy: .public) saved=\(wasSaved, privacy: .public)")
        staging.prune()
        return Output(result: result, url: finalURL, wasSaved: wasSaved)
    }

    /// The recording equivalent. Same contract, one fewer step.
    ///
    /// A screenshot is encoded into staging by us; a recording is written into
    /// staging by ScreenCaptureKit while it runs. By the time this is called the
    /// file already exists, so there is nothing to stage — only the same "save
    /// is a move" and the same clipboard/sound/prune tail.
    @discardableResult
    func process(
        _ result: RecordingResult, saveDirectoryOverride: URL? = nil
    ) -> RecordingOutput? {
        let preferences = Preferences.shared

        var finalURL = result.url
        var wasSaved = false
        if preferences.saveToDisk {
            do {
                finalURL = try staging.move(
                    result.url, to: saveDirectoryOverride ?? preferences.saveDirectory)
                wasSaved = true
            } catch {
                Log.record.error("save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // The moved file is the one every later action must point at.
        var moved = result
        moved.url = finalURL

        if preferences.copyToClipboard {
            Clipboard.write(moved)
        }
        if preferences.playsSound {
            NSSound(named: "Grab")?.play()
        }

        Log.record.notice("""
            recording output \(finalURL.lastPathComponent, privacy: .public) \
            saved=\(wasSaved, privacy: .public) \
            \(moved.durationDescription, privacy: .public)
            """)
        staging.prune()
        return RecordingOutput(result: moved, url: finalURL, wasSaved: wasSaved)
    }

    struct RecordingOutput {
        let result: RecordingResult
        let url: URL
        let wasSaved: Bool
        /// The take ended badly and this file is what survived. Set by
        /// `RecordingCoordinator`, which is the only place that knows.
        var isIncomplete = false
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
