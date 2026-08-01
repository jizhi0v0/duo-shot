import AVFoundation
import Foundation

/// Where an MP4 keeps its index.
///
/// `moov` is the table of contents: sample positions, durations, codec
/// descriptions. A player can decode nothing until it has read it. Writers that
/// stream to disk cannot know the final table until the last frame is in, so
/// they append it — leaving `ftyp → mdat → moov`, with the index at the very end
/// of a file that may be hundreds of megabytes.
///
/// Over HTTP with range support this still works: the player fetches the tail,
/// finds `moov`, and seeks back. It costs a round trip before the first frame.
/// **Without** range support, or with a player that will not go looking, it
/// costs the entire file — or fails outright.
///
/// None of this is visible to whoever made the recording. Locally the file is
/// just a file and every atom is a seek away.
public enum MP4Layout {
    /// nil when the file is not a parseable MP4 (which is not an error here —
    /// the caller simply does not remux it).
    public static func isFastStart(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var sawMdat = false

        // Top-level atoms only, and no more than a few: `moov` and `mdat` are
        // both top level, and a file that has neither in its first dozen boxes
        // is not something to guess about.
        for _ in 0..<16 {
            guard let header = readExactly(8, from: handle, at: offset), header.count == 8
            else { return nil }

            var size = UInt64(be32(header, 0))
            let name = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var headerSize: UInt64 = 8

            switch size {
            case 1:
                // 64-bit size follows the name.
                guard let extended = readExactly(8, from: handle, at: offset + 8),
                      extended.count == 8
                else { return nil }
                size = be64(extended)
                headerSize = 16
            case 0:
                // Runs to the end of the file, so nothing can follow it.
                return name == "moov" ? true : (sawMdat ? false : nil)
            default:
                break
            }
            guard size >= headerSize else { return nil }

            if name == "moov" { return !sawMdat }
            if name == "mdat" { sawMdat = true }

            offset += size
        }
        return nil
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, at offset: UInt64) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    private static func be32(_ data: Data, _ index: Int) -> UInt32 {
        let base = data.startIndex + index
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func be64(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Rewrites the container with the index in front. **Not a transcode** —
    /// `AVAssetExportPresetPassthrough` copies the sample data through
    /// untouched, so this runs at roughly disk speed and cannot change quality.
    ///
    /// Returns nil on any failure, and the caller uploads the original. A link
    /// that starts a beat slowly beats no link at all.
    public static func makeFastStartCopy(of url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkdrop-faststart-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)

        // The whole point.
        session.shouldOptimizeForNetworkUse = true

        do {
            try await session.export(
                to: destination, as: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
            return destination
        } catch {
            LinkdropLog.gate.notice(
                "faststart remux failed; uploading the original as recorded")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }
}
