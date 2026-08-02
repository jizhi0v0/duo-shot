#!/usr/bin/env swift

import AppKit

// Makes the centre of the main screen refuse to hold still: a small panel
// above `.floating` cycling three colours every 40 ms, for the number of
// seconds given as the first argument (default 6).
//
// This is the instrument for exercising a stability sandwich's INCONCLUSIVE
// path on demand — run it alongside `--selftest-scroll-flow` (or any check
// that probes the screen twice and bails when the readings differ) and the
// probe must report drift. Two traps it already ate, so the next reader
// doesn't:
//
// - Setting `NSWindow.backgroundColor` does not repaint an already-composited
//   borderless panel. The window server keeps serving the original pixels;
//   captures see a perfectly static square while the process believes it is
//   flashing. The colour has to change on a layer-backed view.
// - Two colours on an 80 ms period is invisible to probes taken 150 ms apart —
//   the second reading lands a whole period later, on the same colour. Three
//   colours on 40 ms means no 150 ms gap can see a repeat.
// - `env swift` compiles before the panel appears — a couple of seconds on a
//   warm cache. Start this a good five seconds before the check under test, or
//   the panel lands between the probes and trips a *later* assertion instead.

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6

final class Runner: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { exit(1) }
        let size: CGFloat = 120
        let frame = CGRect(
            x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2,
            width: size, height: size)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        let colors: [NSColor] = [.red, .blue, .green]
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            DispatchQueue.main.async {
                tick += 1
                view.layer?.backgroundColor = colors[tick % colors.count].cgColor
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    }
}

let runner = Runner()
app.delegate = runner
app.run()
