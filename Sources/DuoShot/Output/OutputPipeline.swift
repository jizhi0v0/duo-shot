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
        /// The move into the save directory was attempted and threw.
        ///
        /// Distinct from `!wasSaved`, which is also what "save to disk is off"
        /// looks like — a perfectly ordinary outcome that must not be reported as
        /// a problem. Only this one means the user believes the file is in their
        /// save folder and it is not.
        var saveFailed = false
    }

    static let shared = OutputPipeline()

    private let staging = StagingStore.shared

    private init() {}

    /// `saveDirectoryOverride` exists for `--selftest-output`, which must not
    /// litter the user's real save folder or mutate their preferences.
    ///
    /// `async` only because the encode leg is — see `StagingStore.stage`. The
    /// order of everything after it is unchanged: stage, optional move,
    /// clipboard, sound, prune.
    @discardableResult
    func process(_ result: CaptureResult, saveDirectoryOverride: URL? = nil) async -> Output? {
        let preferences = Preferences.shared
        let contentType = preferences.imageFormat

        let stagedURL: URL
        do {
            stagedURL = try await staging.stage(
                result, as: contentType, quality: preferences.jpegQuality)
        } catch {
            Log.app.error("staging failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }

        var finalURL = stagedURL
        var wasSaved = false
        var saveFailed = false
        if preferences.saveToDisk {
            do {
                finalURL = try staging.move(
                    stagedURL, to: saveDirectoryOverride ?? preferences.saveDirectory)
                wasSaved = true
            } catch {
                Log.app.error("save failed: \(error.localizedDescription, privacy: .public)")
                saveFailed = true
            }
        }

        if preferences.copyToClipboard {
            Clipboard.write(result, fileURL: finalURL)
        }
        // A failed save gets the error sound, not the shutter, and gets it
        // whatever `playsSound` says. The capture is still in staging and prune
        // will eventually take it, so the one thing that must not happen is the
        // usual success chime telling the user the file is in their save folder.
        if saveFailed {
            NSSound.beep()
        } else if preferences.playsSound {
            NSSound(named: "Grab")?.play()
        }

        Log.app.notice("output \(finalURL.lastPathComponent, privacy: .public) saved=\(wasSaved, privacy: .public)")
        staging.prune()
        return Output(
            result: result, url: finalURL, wasSaved: wasSaved, saveFailed: saveFailed)
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
        var saveFailed = false
        if preferences.saveToDisk {
            do {
                finalURL = try staging.move(
                    result.url, to: saveDirectoryOverride ?? preferences.saveDirectory)
                wasSaved = true
            } catch {
                Log.record.error("save failed: \(error.localizedDescription, privacy: .public)")
                saveFailed = true
            }
        }

        // The moved file is the one every later action must point at.
        var moved = result
        moved.url = finalURL

        if preferences.copyToClipboard {
            Clipboard.write(moved)
        }
        // Same rule as the screenshot path: a take that never reached the save
        // folder must not be announced with the success sound.
        if saveFailed {
            NSSound.beep()
        } else if preferences.playsSound {
            NSSound(named: "Grab")?.play()
        }

        Log.record.notice("""
            recording output \(finalURL.lastPathComponent, privacy: .public) \
            saved=\(wasSaved, privacy: .public) \
            \(moved.durationDescription, privacy: .public)
            """)
        staging.prune()
        return RecordingOutput(
            result: moved, url: finalURL, wasSaved: wasSaved, saveFailed: saveFailed)
    }

    struct RecordingOutput {
        let result: RecordingResult
        let url: URL
        let wasSaved: Bool
        /// See `Output.saveFailed`.
        var saveFailed = false
        /// The take ended badly and this file is what survived. Set by
        /// `RecordingCoordinator`, which is the only place that knows.
        var isIncomplete = false
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
