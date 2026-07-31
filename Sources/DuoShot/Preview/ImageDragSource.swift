import AppKit
import UniformTypeIdentifiers

/// Drags a finished capture out to another app.
///
/// Deliberately a plain pasteboard file URL rather than `NSFilePromiseProvider`.
/// File promises exist to defer producing an expensive file until a destination
/// accepts the drop — not our situation: `OutputPipeline` has already written the
/// file by the time the preview appears (we need it for the thumbnail, for
/// "reveal", and for Quick Look anyway). The file exists, so a promise is pure
/// overhead, and its delegate is split across `NS_SWIFT_UI_ACTOR` and
/// `NS_SWIFT_NONISOLATED`, which is awkward under Swift 6.
@MainActor
final class ImageDragSource: NSObject, NSDraggingSource, NSPasteboardItemDataProvider {
    private let onCompleted: (Bool) -> Void

    /// Off for a recording. The image flavours below re-read the file and hand
    /// it to `NSBitmapImageRep`, which an .mp4 is not — offering `.png` for one
    /// advertises a flavour that resolves to nothing, and a destination that
    /// prefers image data over a file URL (rich-text fields do) would take the
    /// advertised one and receive an empty drop.
    private let providesImageData: Bool

    /// The provider callback below is `nonisolated` and runs on whichever thread
    /// asks for the data, so everything it needs must be Sendable and reachable
    /// without hopping to the main actor. A `URL` is; `NSPasteboardItem` is not,
    /// which is why the bytes are re-read from disk rather than taken from the
    /// MainActor-bound NSImage.
    private nonisolated let fileURL: URL

    /// Below this the gesture is a click, not a drag. Without it, ordinary
    /// clicks on the panel register as failed drags.
    static let threshold: CGFloat = 3

    init(entry: PreviewEntry, onCompleted: @escaping (Bool) -> Void) {
        self.onCompleted = onCompleted
        self.fileURL = entry.url
        self.providesImageData = !entry.isVideo
        super.init()
    }

    func beginDrag(from view: NSView, event: NSEvent, thumbnail: NSImage) {
        let item = NSPasteboardItem()
        // The file URL is what makes Finder, Mail, Slack, Figma and browser file
        // inputs all do the right thing.
        item.setString(fileURL.absoluteString, forType: .fileURL)
        // Image bytes as well, for rich-text fields that only accept image data.
        // Supplied lazily so dragging into Finder never materialises a redundant
        // multi-megabyte TIFF.
        if providesImageData {
            item.setDataProvider(self, forTypes: [.png, .tiff])
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let frame = CGRect(origin: .zero, size: view.bounds.size)
        draggingItem.setDraggingFrame(frame, contents: thumbnail)

        let session = view.beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Dragging a capture out is a completion gesture: if something accepted
        // it, the preview has done its job.
        onCompleted(operation != [])
    }

    // MARK: - NSPasteboardItemDataProvider

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard
            let data = try? Data(contentsOf: fileURL),
            let representation = NSBitmapImageRep(data: data)
        else { return }

        switch type {
        case .png:
            // Re-encoded rather than passed through: the staged file may be JPEG
            // or HEIC depending on the format preference.
            item.setData(representation.representation(using: .png, properties: [:]) ?? data,
                         forType: .png)
        case .tiff:
            item.setData(representation.tiffRepresentation ?? data, forType: .tiff)
        default:
            break
        }
    }
}
