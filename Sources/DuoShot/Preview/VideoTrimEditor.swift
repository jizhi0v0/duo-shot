import AVKit
import AppKit

/// The recording viewer's contents: the player, and the one thing you are
/// allowed to do to the take before it leaves.
///
/// The still's `ImageEditor` is the shape this follows — a bar over the
/// content, an explicit confirmation, and a destructive write to the staged
/// file — but almost none of the machinery, because `AVPlayerView` already has
/// the hard part. `beginTrimming(completionHandler:)` puts the system's own
/// trimming UI into the transport controls: two handles on the filmstrip, a
/// live preview while dragging, and Cancel and Trim buttons. Building a scrubber
/// beside it would be a worse one that behaved differently from every other
/// video on this Mac.
///
/// So this class is only the two ends AVKit does not have an opinion about:
/// where the Trim button lives before the mode starts, and what happens to the
/// file after the user presses Trim.
@MainActor
final class VideoTrimEditor: NSView {
    /// The staged file, which is both what is being played and what will be
    /// overwritten. Every consumer of this recording reads this URL.
    private let url: URL
    /// Exposed so the window can make it first responder: Space plays and pauses
    /// and the arrow keys step, but only while the player view itself holds the
    /// keyboard, and a container in front of it would swallow both.
    let playerView = AVPlayerView()

    private let bar: TrimBar
    private let notice: ViewerNotice

    /// True from Trim until the file has been rewritten. A second press in that
    /// window would export the range out of a file that is being replaced.
    private var isExporting = false

    /// Handed a fresh poster frame after a successful trim, so a preview card
    /// still on screen stops showing a frame the file may no longer contain.
    /// Injected rather than reached for, for the reason
    /// `ViewerWindowController.onVideoTrimmed` gives.
    var onTrimmed: ((NSImage) -> Void)?

    init(url: URL, frame: CGRect) {
        self.url = url
        bar = TrimBar()
        notice = ViewerNotice()
        super.init(frame: frame)

        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        // `.inline` rather than `.floating`: floating controls are the
        // full-screen player chrome, which fades out and takes the scrubber with
        // it. In a window this size the scrubber is the whole point — and the
        // trimming UI is drawn into these controls, so a style that hides them
        // hides the handles too.
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)

        bar.onTrim = { [weak self] in self?.beginTrimming() }
        bar.onGIF = { [weak self] in self?.exportGIF() }
        addSubview(bar)
        addSubview(notice)
        notice.isHidden = true
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func play() { playerView.player?.play() }

    // MARK: - Geometry

    private static let barInset: CGFloat = 14
    private static let noticeGap: CGFloat = 8

    /// The bar sits at the **top**, where the still viewer's sits at the bottom.
    /// Not a stylistic difference: the bottom of a recording is the transport
    /// controls, and a pill parked over the scrubber would be over the one part
    /// of the window that has to stay clickable.
    override func layout() {
        super.layout()
        playerView.frame = bounds
        let barSize = bar.fittingSize
        bar.frame = CGRect(
            x: ((bounds.width - barSize.width) / 2).rounded(),
            y: bounds.height - barSize.height - Self.barInset,
            width: barSize.width, height: barSize.height)
        guard !notice.isHidden else { return }
        let noticeSize = notice.fittingSize(inWidth: bounds.width - Self.barInset * 2)
        notice.frame = CGRect(
            x: ((bounds.width - noticeSize.width) / 2).rounded(),
            y: bar.frame.minY - Self.noticeGap - noticeSize.height,
            width: noticeSize.width, height: noticeSize.height)
    }

    // MARK: - The mode

    /// `canBeginTrimming` is false until the asset's tracks are loaded, which is
    /// a beat after the window opens, and stays false for a file AVKit cannot
    /// trim at all. Both deserve the beep rather than a button that looks live
    /// and does nothing.
    private func beginTrimming() {
        guard !isExporting, playerView.canBeginTrimming else {
            NSSound.beep()
            return
        }
        // The trimming UI replaces the transport controls, so the bar has nothing
        // to offer while it is up — and a Trim button beside the system's own
        // Trim button is two different promises.
        playerView.player?.pause()
        bar.isHidden = true
        notice.isHidden = true
        needsLayout = true

        // AVKit calls this back on the main thread and says so in prose rather
        // than in the type, so the isolation has to be asserted rather than
        // hopped to — the same move `ViewerWindowController`'s close observer
        // makes. Hopping would let the window close between the two.
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.leaveTrimmingUI(applying: result == .okButton ? self.selectedRange() : nil)
            }
        }
    }

    /// Coming back out of the system's trimming UI, whichever button ended it.
    ///
    /// One function rather than two lines at the call site because `trimForTest`
    /// has to arrive at the export by exactly this road: the bar is left with a
    /// layout pending *and* then put into its busy state, and that ordering is
    /// what the width bug was made of.
    private func leaveTrimmingUI(applying range: CMTimeRange?) {
        bar.isHidden = false
        needsLayout = true
        guard let range else { return }
        apply(range)
    }

    /// Writes an animated GIF beside the recording.
    ///
    /// Beside, not over, and that is the difference from Trim: this is a lossy
    /// copy made for somewhere that will not play an MP4, and the take itself is
    /// still the real thing. So there is no confirmation to give -- nothing can
    /// be lost -- and the notice says where the file went rather than what it
    /// cost.
    ///
    /// Shares `isExporting` with the trim. Two writers of this recording at once
    /// is the state neither of them is written to survive, and the GIF reading
    /// frames out of a file the trim is replacing is precisely that.
    private func exportGIF() {
        guard !isExporting else { return }
        isExporting = true
        bar.setBusy(true, saying: "Making a GIF…")
        let destination = GIFExport.url(besides: url)
        Task { [weak self, url] in
            defer {
                self?.isExporting = false
                self?.bar.setBusy(false)
            }
            do {
                let outcome = try await GIFExport.write(url, to: destination)
                guard let self else { return }
                self.notice.show(
                    message: "\(outcome.frames) frames as "
                        + "\(outcome.url.lastPathComponent) — "
                        + String(format: "%.0f×%.0f, %.1fs",
                                 outcome.pixelSize.width, outcome.pixelSize.height,
                                 outcome.seconds)
                        + ". The recording itself is untouched.",
                    action: ("Show in Finder", {
                        NSWorkspace.shared.activateFileViewerSelecting([outcome.url])
                    }),
                    symbol: "folder")
                self.showNotice()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The GIF could not be written."
                Log.app.error("gif export: \(reason, privacy: .public)")
                NSSound.beep()
                self?.notice.show(message: reason, action: nil)
                self?.showNotice()
            }
        }
    }

    /// Where the handles were left.
    ///
    /// AVKit reports the selection by setting the player item's playback
    /// boundaries rather than by handing anything to the completion handler:
    /// after Trim the item plays only the chosen span, which is also why the
    /// file has to be rewritten for the trim to mean anything outside this
    /// window.
    private func selectedRange() -> CMTimeRange? {
        guard let item = playerView.player?.currentItem else { return nil }
        let start = item.reversePlaybackEndTime
        let end = item.forwardPlaybackEndTime
        guard start.isNumeric, end.isNumeric, end > start else { return nil }
        // Pressing Trim without having moved a handle is a legitimate thing to
        // do and must not rewrite the file: the export would produce a copy that
        // differs from the original only in which atoms moved, and the recording
        // would be replaced for nothing.
        let whole = item.duration
        if whole.isNumeric, start <= .zero, end >= whole { return nil }
        return CMTimeRange(start: start, end: end)
    }

    // MARK: - Applying

    private func apply(_ range: CMTimeRange?) {
        guard let range, !isExporting else { return }
        isExporting = true
        bar.setBusy(true)

        Task { [url, weak self] in
            defer {
                self?.isExporting = false
                self?.bar.setBusy(false)
            }
            do {
                let outcome = try await VideoTrim.apply(range: range, toFileAt: url)
                Log.record.notice("""
                    trim: \(url.lastPathComponent, privacy: .public) \
                    \(outcome.from, format: .fixed(precision: 2))s -> \
                    \(outcome.to, format: .fixed(precision: 2))s
                    """)
                await self?.adoptTrimmedFile()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The trim could not be written."
                Log.record.error("trim: \(reason, privacy: .public)")
                NSSound.beep()
                self?.notice.show(message: reason, action: nil)
                self?.showNotice()
            }
        }
    }

    /// Re-reads the file that was just written.
    ///
    /// A fresh `AVURLAsset` rather than a seek back to zero: the item on screen
    /// is describing bytes that have been replaced underneath it, and its own
    /// idea of where every sample lives is now wrong. Its playback boundaries go
    /// with it — the trimmed file *is* the selection now, and leaving the old
    /// in- and out-points in place would clip it a second time.
    private func adoptTrimmedFile() async {
        playerView.player?.replaceCurrentItem(
            with: AVPlayerItem(asset: AVURLAsset(url: url)))
        await playerView.player?.seek(to: .zero)

        if let poster = await VideoPoster.frame(for: url) { onTrimmed?(poster) }

        guard let link = ShareService.shared.existingLink(for: url) else { return }
        // The one thing a trim cannot do is reach a link that already exists.
        // Said here, in the window where it happened, rather than in a modal: the
        // user has just finished a deliberate action and an alert would be
        // dismissed as the acknowledgement of that rather than read.
        notice.show(
            message: "This recording was already shared — that link still serves the "
                + "whole take.",
            action: ("Revoke Link", { [weak self] in self?.revoke(link.key) }))
        showNotice()
    }

    private func revoke(_ key: String) {
        notice.setBusy(true)
        Task { [weak self] in
            let gone = await ShareService.shared.revoke(key)
            self?.notice.show(
                message: gone
                    ? "The link has been revoked. The untrimmed take is no longer served."
                    : "The link could not be revoked. Try again from Recent Links.",
                action: nil)
            self?.needsLayout = true
        }
    }

    private func showNotice() {
        notice.isHidden = false
        needsLayout = true
    }

    // MARK: - Test hooks

    /// What `--selftest-trim` drives, because the system's trimming UI cannot be
    /// dragged from a test: the export and the replace are everything this
    /// feature owns, and the handles are AVKit's.
    func trimForTest(_ range: CMTimeRange) { leaveTrimmingUI(applying: range) }

    var isExportingForTest: Bool { isExporting }

    /// The bar's frame, for the check that it is the same width after a trim as
    /// before one. Its width is state-dependent — the busy hint sits inside it —
    /// and only this view's `layout()` ever applies it.
    var barFrameForTest: CGRect { bar.frame }
}

/// The strip along the top of the recording viewer.
///
/// One button and no modes, unlike `EditToolbar`: the confirmation this feature
/// needs is the system trimming UI's own Trim button, so there is nothing for
/// this to ask.
private final class TrimBar: NSView {
    var onTrim: () -> Void = {}
    var onGIF: () -> Void = {}

    private let content: NSView
    /// Not red, where `EditToolbar`'s Apply is: this button destroys nothing —
    /// it opens the handles. The press that cannot be taken back is the system
    /// trimming UI's own Trim, and colouring both as the dangerous one would
    /// spend the warning on the harmless half.
    private let trim = HUDPill(
        title: "Trim", mark: .symbol("scissors"), tint: NSColor(white: 1, alpha: 0.16))
    /// Beside Trim rather than in a menu the video viewer does not have. It
    /// writes a new file and touches nothing, so it is as untinted as Trim.
    private let gif = HUDPill(
        title: "GIF", mark: .symbol("square.stack.3d.down.right"),
        tint: NSColor(white: 1, alpha: 0.16))
    private let hint = NSTextField(labelWithString: "Rewriting the recording…")

    private var isBusy = false
    private var busyMessage = "Rewriting the recording…" 

    init() {
        let box = CGRect(x: 0, y: 0, width: 200, height: HUDMetrics.height)
        let chrome = HUDMetrics.chrome(in: box)
        content = chrome.content
        super.init(frame: box)
        addSubview(chrome.glass)

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.sizeToFit()
        hint.isHidden = true
        content.addSubview(hint)

        trim.onClick = { [weak self] in self?.onTrim() }
        content.addSubview(trim)
        gif.onClick = { [weak self] in self?.onGIF() }
        content.addSubview(gif)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setBusy(_ busy: Bool, saying message: String = "Rewriting the recording…") {
        isBusy = busy
        if busy, message != busyMessage {
            busyMessage = message
            hint.stringValue = message
            hint.sizeToFit()
        }
        hint.isHidden = !busy
        trim.setLive(!busy, animated: false)
        gif.setLive(!busy, animated: false)
        // The superview, not just this view: `fittingSize` is the one thing here
        // that depends on the state, and the only code that ever applies it is
        // `VideoTrimEditor.layout()`. Marking only this view laid the button out
        // inside whatever frame the bar was last given — which, because the trim
        // path enters this state with a layout already pending, was the wide one
        // the hint needed. The hint went away and the width stayed.
        superview?.needsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override var fittingSize: NSSize {
        var width = HUDMetrics.margin * 2 + trim.frame.width
            + HUDMetrics.groupGap + gif.frame.width
        if isBusy { width += hint.frame.width + HUDMetrics.groupGap }
        return CGSize(width: width.rounded(), height: HUDMetrics.height)
    }

    override func layout() {
        super.layout()
        var x = HUDMetrics.margin
        if isBusy {
            hint.setFrameOrigin(CGPoint(
                x: x, y: ((HUDMetrics.height - hint.frame.height) / 2).rounded()))
            x += hint.frame.width + HUDMetrics.groupGap
        }
        let y = ((HUDMetrics.height - HUDMetrics.controlHeight) / 2).rounded()
        trim.setFrameOrigin(CGPoint(x: x, y: y))
        x += trim.frame.width + HUDMetrics.groupGap
        gif.setFrameOrigin(CGPoint(x: x, y: y))
    }
}
