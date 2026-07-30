import AppKit

// Top-level code is MainActor-isolated.
//
// Every path runs a real NSApplication: the overlay self-test needs windows to
// actually composite, and running the same environment as the shipping app keeps
// the tests honest. A bare RunLoop would be enough for the pure-capture modes but
// not for anything that puts a panel on screen.

let arguments = Array(CommandLine.arguments.dropFirst())
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

/// Runs a self-test once AppKit is up, then exits with its status.
final class SelfTestRunner: NSObject, NSApplicationDelegate {
    private let mode: SelfTest.Mode

    init(mode: SelfTest.Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { exit(await SelfTest.run(self.mode)) }
    }
}

let delegate: any NSApplicationDelegate

if let mode = SelfTest.Mode(arguments: arguments) {
    delegate = SelfTestRunner(mode: mode)
} else if arguments.contains(where: { $0.hasPrefix("--selftest") }) {
    FileHandle.standardError.write(Data("""
        unknown or malformed self-test mode.

          --selftest-permission
          --selftest-windows
          --selftest-preferences
          --selftest-capture <out.png> [--display N]
          --selftest-rect <x,y,w,h> [--display N] [--out <file.png>]
          --selftest-overlay <x,y,w,h> [--out <file.png>] [--no-exclude] [--sharing-default]
          --selftest-sourcerect-space
          --selftest-output <dir>
          --selftest-preview <dir> [--sharing-default]
          --selftest-window <dir>
          --selftest-fullscreen <dir>

        Rects are in AppKit global points (origin bottom-left of the main screen).

        """.utf8))
    exit(64)
} else {
    delegate = AppDelegate()
}

application.delegate = delegate
application.run()
