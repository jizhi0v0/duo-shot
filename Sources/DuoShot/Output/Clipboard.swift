import AppKit
import Linkdrop

enum Clipboard {
    /// Puts both the image and its file URL on the pasteboard.
    ///
    /// The image is written at its **point** size. A 2× capture produces a
    /// CGImage with twice the point dimensions; handing that over without
    /// setting the logical size makes every paste target render it at 2×, which
    /// is the single most-reported bug in home-grown screenshot tools.
    ///
    /// **This materialises a full TIFF, and it stays that way on purpose.**
    /// Measured 2026-08-01 on a 3456×2234 capture: `writeObjects([NSImage])`
    /// costs 20 ms and leaves exactly one flavour on the pasteboard,
    /// `public.tiff`. The staged file's bytes are already on disk by the time
    /// this runs and writing those instead costs 0.5 ms — but it changes the
    /// advertised flavour to `public.png` / `public.jpeg` / `public.heic`
    /// depending on the format preference, and a HEIC-only pasteboard is one
    /// most applications cannot paste at all. Promising the TIFF lazily through
    /// an `NSPasteboardItemDataProvider` avoids the encode too, but Apple's
    /// pasteboard guide is explicit that a promise's writer "may not even exist
    /// anymore" — so a capture copied and then followed by a quit would paste
    /// as nothing, which is worse than 20 ms.
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
        if let fileURL { writeFileURL(fileURL, to: pasteboard, clearingFirst: false) }
    }

    /// A share link.
    ///
    /// The plain string is written first and is what almost every target reads:
    /// a chat window, a commit message, a text field. `public.url` goes on as
    /// well so a browser's tab bar and Finder still recognise it as a link —
    /// writing only the URL object leaves apps that ask for text with nothing.
    static func write(link url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        pasteboard.setString(url.absoluteString, forType: .URL)
    }

    /// The same link as Markdown.
    ///
    /// A still points at `fileURL`, because `![]()` only renders if the address
    /// resolves to bytes; anything else points at `pageURL`, which is where the
    /// player and the title live — an `.mp4` behind a bare `[]()` would download
    /// rather than play.
    ///
    /// **Unlike `write(link:)` this sets `public.string` and nothing else.**
    /// There the URL was the whole payload, so advertising `public.url` as well
    /// let Finder and browser tab bars take it. Here the payload is a sentence
    /// that contains a URL and is not one: a target reading `public.url` would
    /// be handed `![shot.png](https://…)` as an address and fail to open it.
    static func write(markdown link: LinkdropLink, name: String, isImage: Bool) {
        let target = isImage ? link.fileURL : link.pageURL
        let text = "\(isImage ? "!" : "")[\(markdownLabel(name))](\(target.absoluteString))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Filenames are free to contain the two characters that delimit a Markdown
    /// label, and an unescaped `]` ends the label early — turning the rest of the
    /// name into stray text and the link into nothing. Escaped rather than
    /// stripped so the label still reads as the file's actual name; the leading
    /// backslash pass has to come first or it would escape the backslashes this
    /// adds.
    private static func markdownLabel(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// The same thing, from the staged file rather than from memory.
    ///
    /// What a preview card's Copy button uses. A card can sit on screen for
    /// minutes and there can be twelve of them, so holding the full-resolution
    /// `CaptureResult` alive for a button that is usually never pressed is the
    /// wrong trade — the file is the copy of record, and `ImageDragSource`
    /// already re-reads it for exactly this reason.
    ///
    /// `pointSize` is applied explicitly rather than left to whatever the file's
    /// DPI tags imply: it is the one thing standing between a 2× capture and
    /// pasting at double size, and it must not depend on the format preference.
    static func write(fileAt url: URL, pointSize: CGSize) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = NSImage(contentsOf: url) {
            image.size = pointSize
            pasteboard.writeObjects([image])
        } else {
            // The file has been moved or deleted from under us. The URL is still
            // worth offering — it is what Finder and Mail take — but there is no
            // image, and silence would read as a working copy.
            Log.app.error("copy: no image at \(url.lastPathComponent, privacy: .public)")
            NSSound.beep()
        }
        writeFileURL(url, to: pasteboard, clearingFirst: false)
    }

    /// Text recognised from a capture.
    ///
    /// `public.string` and nothing else, deliberately: the file this came out of
    /// is not what was asked for. Adding its URL the way `write(fileAt:)` does
    /// would mean a paste into Finder or Mail attached the screenshot instead of
    /// inserting the words, which is the opposite of the request.
    static func write(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A recording goes on the pasteboard as a file reference and nothing else.
    ///
    /// There is no in-memory representation to offer the way a screenshot offers
    /// its NSImage, and every app that accepts a dropped or pasted movie accepts
    /// it by URL.
    static func write(_ result: RecordingResult) {
        writeFileURL(result.url, to: NSPasteboard.general, clearingFirst: true)
    }

    private static func writeFileURL(
        _ url: URL, to pasteboard: NSPasteboard, clearingFirst: Bool
    ) {
        if clearingFirst { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
    }
}
