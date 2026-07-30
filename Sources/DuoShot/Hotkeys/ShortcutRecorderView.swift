import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click to record, press a combination, Esc or click away to cancel.
///
/// Uses a **local** event monitor, not a global one, so it needs no
/// Accessibility permission — the same reason the app uses Carbon hotkeys
/// instead of a CGEventTap.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }
    var onRecord: ((KeyCombo?) -> Void)?
    /// Called when recording starts and stops. The delegate must release every
    /// global binding while recording — see `beginRecording`.
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        isRecording ? cancelRecording() : beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)

        // Critical: a combo we have already registered globally is consumed by
        // Carbon and never reaches a local monitor, so without releasing the
        // bindings the user cannot re-record their own existing shortcut.
        onRecordingChanged?(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChanged?(false)
    }

    private func cancelRecording() {
        endRecording()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return nil }

        if Int(event.keyCode) == kVK_Escape {
            endRecording()
            return nil
        }
        if Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            combo = nil
            onRecord?(nil)
            endRecording()
            return nil
        }

        let candidate = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard candidate.isAcceptable else {
            NSSound.beep()
            return nil
        }

        combo = candidate
        onRecord?(candidate)
        endRecording()
        return nil
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                     : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        rounded.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()

        let text: String
        let colour: NSColor
        switch (isRecording, combo) {
        case (true, _):
            text = "Press keys…"
            colour = .controlAccentColor
        case (false, let combo?):
            text = combo.displayString
            colour = .labelColor
        case (false, nil):
            text = "Record shortcut"
            colour = .secondaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: colour,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

/// SwiftUI bridge. The recorder is the one control in Preferences that has to be
/// AppKit: it needs raw `keyDown`/`flagsChanged` before SwiftUI's own key
/// handling gets a look at them.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let onRecord: (KeyCombo?) -> Void
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.combo = combo
        view.onRecord = onRecord
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.combo = combo
        view.onRecord = onRecord
        view.onRecordingChanged = onRecordingChanged
    }
}
