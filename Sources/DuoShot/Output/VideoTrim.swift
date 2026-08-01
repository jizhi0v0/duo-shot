import AVFoundation
import Foundation
import Linkdrop

/// Cutting a recording down to the part that was worth keeping.
///
/// The stills have `Redaction`; this is the recordings' equivalent, and it makes
/// the same bargain for the same reason. A take is started before the thing
/// being demonstrated happens and stopped after it, so the first and last
/// seconds are somebody reaching for a hotkey — and a link is the one place
/// those seconds cannot be skipped, because whoever opens it watches from zero.
///
/// **Passthrough, never a transcode.** `AVAssetExportPresetPassthrough` copies
/// the sample data through untouched, for the reason `MP4Layout.makeFastStartCopy`
/// gives: it runs at roughly disk speed and cannot change quality. The price is
/// stated below and is not a bug to be fixed later.
///
/// `@concurrent` for the reason `Redaction.apply` is: this reads and writes the
/// whole file, and none of that belongs on the main thread.
nonisolated enum VideoTrim {
    enum Failure: LocalizedError {
        case notExportable(String)
        case exportFailed(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .notExportable(let name): "\(name) cannot be trimmed."
            case .exportFailed(let name): "The trimmed \(name) could not be written."
            case .unwritable(let name): "The trimmed \(name) could not replace the original."
            }
        }
    }

    /// What the trim did, in seconds, so the caller can say it out loud. `to` is
    /// measured off the file that was written rather than off the range that was
    /// asked for, because those two are allowed to differ — see below.
    struct Outcome: Sendable {
        var from: TimeInterval
        var to: TimeInterval
    }

    /// Trims the staged file **in place**, and deliberately so.
    ///
    /// Same decision as `Redaction.apply(regions:toFileAt:)` and for the same
    /// reason: share, copy, drag and the preview card all read this one URL, so
    /// writing "name (trimmed).mp4" beside it would leave the long take a
    /// mis-click away from every one of them. The file that was cut is the file
    /// everything means. It is not undoable, and the caller is expected to have
    /// said so.
    ///
    /// **The cut is not frame-accurate, and cannot be.** A passthrough export
    /// copies compressed samples, and a frame that is not a sync frame cannot be
    /// decoded without the ones before it, so the writer starts at the last sync
    /// frame at or before the requested in-point. A screen recording's keyframes
    /// are seconds apart, so the result can begin visibly earlier than the
    /// handle was dragged to. The alternative is decoding and re-encoding the
    /// whole clip — minutes of CPU, a generation of quality loss, and a
    /// different colour pipeline than the one `RecordingEngine` was careful to
    /// choose. Not in v1.
    ///
    /// Written to a sibling and swapped with `replaceItemAt` rather than
    /// exported over the original: the export reads the file it is replacing, so
    /// writing in place would be reading a file that is being truncated, and a
    /// crash halfway through would leave neither take.
    @concurrent
    static func apply(range: CMTimeRange, toFileAt url: URL) async throws -> Outcome {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let before = try? await asset.load(.duration)

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw Failure.notExportable(name) }
        session.timeRange = range
        // The same knob `makeFastStartCopy` turns, asked for on the one pass this
        // export already costs rather than by remuxing afterwards. Whether it was
        // honoured is not assumed — see below.
        session.shouldOptimizeForNetworkUse = true

        let isQuickTime = url.pathExtension.lowercased() == "mov"
        var written = try await export(session, beside: url, as: isQuickTime ? .mov : .mp4)
        do {
            written = await makeFastStart(written, beside: url)
            let after = try? await AVURLAsset(url: written).load(.duration)
            try replace(url, with: written)
            return Outcome(
                from: before.map(CMTimeGetSeconds) ?? 0,
                to: after.map(CMTimeGetSeconds) ?? 0)
        } catch {
            try? FileManager.default.removeItem(at: written)
            throw error is Failure ? error : Failure.unwritable(name)
        }
    }

    private static func export(
        _ session: AVAssetExportSession, beside url: URL, as type: AVFileType
    ) async throws -> URL {
        let destination = sibling(of: url)
        do {
            try await session.export(to: destination, as: type)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.exportFailed(url.lastPathComponent)
        }
    }

    /// Asks rather than assumes, and repairs with the pipeline that already
    /// exists.
    ///
    /// `shouldOptimizeForNetworkUse` is a request; the export honours it for the
    /// formats it can and says nothing when it cannot. Everything that leaves
    /// this Mac goes through `LinkdropGate`, which checks the same property, so a
    /// trimmed file that lost its front `moov` would cost a second full remux at
    /// upload time — or, on a player that will not seek, the whole file before
    /// the first frame. Cheaper to find out here, where the file is already warm.
    ///
    /// Returns the original on any failure, exactly as `makeFastStartCopy`'s
    /// callers do: a trimmed recording that starts a beat slowly beats an
    /// untrimmed one.
    private static func makeFastStart(_ written: URL, beside url: URL) async -> URL {
        guard MP4Layout.isFastStart(written) == false,
              let remuxed = await MP4Layout.makeFastStartCopy(of: written)
        else { return written }

        // `makeFastStartCopy` writes into the system temporary directory, which
        // is not necessarily the volume staging lives on, and `replaceItemAt`
        // wants a sibling of what it is replacing.
        let destination = sibling(of: url)
        guard (try? FileManager.default.moveItem(at: remuxed, to: destination)) != nil else {
            try? FileManager.default.removeItem(at: remuxed)
            return written
        }
        try? FileManager.default.removeItem(at: written)
        return destination
    }

    private static func replace(_ url: URL, with replacement: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        } catch {
            throw Failure.unwritable(url.lastPathComponent)
        }
    }

    /// A dot-prefixed name in the same directory: invisible in Finder, on the
    /// same volume as the file it will replace, and unique so two trims of two
    /// recordings cannot collide.
    private static func sibling(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".duoshot-trim-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
    }
}
