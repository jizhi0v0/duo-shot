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

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
