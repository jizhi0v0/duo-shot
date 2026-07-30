import AppKit

enum Clipboard {
    /// Puts both the image and its file URL on the pasteboard.
    ///
    /// The image is written at its **point** size. A 2× capture produces a
    /// CGImage with twice the point dimensions; handing that over without
    /// setting the logical size makes every paste target render it at 2×, which
    /// is the single most-reported bug in home-grown screenshot tools.
    static func write(_ result: CaptureResult, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Written as two separate calls, image first. Passing both to a single
        // writeObjects([image, url]) put the image on the pasteboard but left
        // the URL unreadable — measured: readObjects(forClasses: [NSURL.self])
        // came back empty.
        //
        // The NSImage (not raw TIFF data) carries the *point* size, which is what
        // keeps a 2x capture from pasting at double size.
        pasteboard.writeObjects([result.nsImage])
        if let fileURL {
            let item = NSPasteboardItem()
            item.setString(fileURL.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        }
    }
}
