import AVFoundation
import CoreGraphics
import Foundation

/// The clicks made during a recording, as a timed metadata track in the movie.
///
/// One timed metadata group per mouse event, at the event's time on the
/// movie's own timeline, holding one UTF-8 JSON item (`ClickMark`). The time is
/// deliberately *not* in the JSON: it is the group's, so anything that moves
/// the track — a trim, which shifts every sample — moves the clicks with it,
/// and nothing can be left holding a stale absolute time. Gaps between clicks
/// are explicit empty groups, or a passthrough export stretches each click's
/// sample to the next one and a trim that starts after a click drags it in at
/// time zero (measured while choosing this layout).
package enum ClickTimeline {
    package static let key = "com.duoshot.click"
    package static var identifier: AVMetadataIdentifier {
        AVMetadataItem.identifier(forKey: key as NSString, keySpace: .quickTimeMetadata)!
    }
    /// Each click's group lasts this long, so two events never share a sample.
    package static let markDuration = CMTime(value: 1, timescale: 1000)

    /// Every click in the movie at `url`, mouse-down and mouse-up, in time
    /// order; empty when the movie has no timeline.
    package static func read(from url: URL) async throws -> [CLIClick] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        var clicks: [CLIClick] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            guard reader.startReading() else { continue }
            let decoder = JSONDecoder()
            while let group = adaptor.nextTimedMetadataGroup() {
                for item in group.items where item.identifier == identifier {
                    guard let text = try? await item.load(.stringValue),
                          let mark = try? decoder.decode(ClickMark.self, from: Data(text.utf8))
                    else { continue }
                    clicks.append(CLIClick(t: group.timeRange.start.seconds, mark: mark))
                }
            }
        }
        return clicks.sorted { $0.t < $1.t }
    }
}

/// One mouse event as stored in the movie — everything but its time.
package struct ClickMark: Codable, Sendable, Equatable {
    /// "down" or "up".
    package var phase: String
    /// "left", "right" or "other".
    package var button: String
    package var clickCount: Int
    /// Global points, origin top-left of the main display (`kCGWindowBounds`'s
    /// space).
    package var x: Double
    package var y: Double
    /// Video pixels, origin top-left of the frame.
    package var px: Double
    package var py: Double
    /// Outside the recorded area: the click happened, but not in the picture.
    package var outside: Bool

    package init(phase: String, button: String, clickCount: Int, x: Double, y: Double,
                 px: Double, py: Double, outside: Bool) {
        self.phase = phase; self.button = button; self.clickCount = clickCount
        self.x = x; self.y = y; self.px = px; self.py = py; self.outside = outside
    }

    enum CodingKeys: String, CodingKey {
        case phase, button, outside
        case clickCount = "click_count"
        case x = "global_x_points_top_left", y = "global_y_points_top_left"
        case px = "video_x_pixels", py = "video_y_pixels"
    }
}

/// A click with its time on the movie's timeline, as `frames` prints it.
package struct CLIClick: Codable, Sendable {
    /// Seconds on the movie's timeline.
    package var t: Double
    package var phase: String
    package var button: String
    package var clickCount: Int
    package var x: Double
    package var y: Double
    package var px: Double
    package var py: Double
    package var outside: Bool

    package init(t: Double, mark: ClickMark) {
        self.t = t; phase = mark.phase; button = mark.button; clickCount = mark.clickCount
        x = mark.x; y = mark.y; px = mark.px; py = mark.py; outside = mark.outside
    }

    enum CodingKeys: String, CodingKey {
        case t, phase, button, outside
        case clickCount = "click_count"
        case x = "global_x_points_top_left", y = "global_y_points_top_left"
        case px = "video_x_pixels", py = "video_y_pixels"
    }
}
