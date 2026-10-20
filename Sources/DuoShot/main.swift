import AppKit

// Top-level code is MainActor-isolated.
//
// Every path runs a real NSApplication: the overlay self-test needs windows to
// actually composite, and running the same environment as the shipping app keeps
// the tests honest. A bare RunLoop would be enough for the pure-capture modes but
// not for anything that puts a panel on screen.

let arguments = Array(CommandLine.arguments.dropFirst())
// The command line's client is not in this binary, nor in this bundle: it is
// the standalone `duoshot` tool (build/duoshot, ~/.local/bin/duoshot after
// `make install`), whose code is not linked in here. Anything run through this
// binary — or through any binary inside DuoShot.app — would read files with
// DuoShot's privacy grants. See `CLIWire`.
if arguments.first == "cli" {
    FileHandle.standardError.write(Data("""
        The command line is the standalone `duoshot` tool, not this binary.

        """.utf8))
    exit(2)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// The self-tests are compiled in only when the Makefile passes
// -DDUOSHOT_SELFTEST, which every target does except `dist`. They are an entry
// point into this process's Screen Recording grant: launched through
// LaunchServices, DuoShot is its own responsible process, so any app that can
// say `open -n -b <id> --args --selftest-capture <path>` would get the whole
// screen written wherever it liked without holding the grant itself. A release
// build has no dispatch at all -- a `--selftest-*` argument launches the app.
#if DUOSHOT_SELFTEST
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
#endif

let delegate: any NSApplicationDelegate

#if DUOSHOT_SELFTEST
if let mode = SelfTest.Mode(arguments: arguments) {
    delegate = SelfTestRunner(mode: mode)
} else if arguments.contains(where: { $0.hasPrefix("--selftest") }) {
    FileHandle.standardError.write(Data("""
        unknown or malformed self-test mode.

          --selftest-permission
          --selftest-windows
          --selftest-popup-capture <app-name> [rounds]
          --selftest-preferences
          --selftest-edit-menu
          --selftest-copy-text <dir>
          --selftest-edit <dir>
          --selftest-trim <dir>
          --selftest-share-card <dir>
          --selftest-capture <out.png> [--display N]
          --selftest-rect <x,y,w,h> [--display N] [--out <file.png>]
          --selftest-overlay <x,y,w,h> [--out <file.png>] [--no-exclude] [--sharing-default]
          --selftest-sourcerect-space
          --selftest-output <dir>
          --selftest-save-failure <dir>
          --selftest-failure-notice
          --selftest-failure-notice-ui   (not in `make test`: reads the Keychain)
          --selftest-delete <dir>
          --selftest-annotate <dir>
          --selftest-preview <dir> [--sharing-default]
          --selftest-window <dir>
          --selftest-fullscreen <dir>
          --selftest-scroll-stitch <dir> [--broken]
          --selftest-scroll-flow <dir>
          --selftest-microphone
          --selftest-record <dir> [--seconds N] [--rect <x,y,w,h>] [--fps N]
                                  [--no-audio] [--mic]
          --selftest-record-flow <dir> [--seconds N]
          --selftest-record-hud <dir> [--seconds N] [--sharing-none]
                                  [--hud-first] [--plain-window] [--status-item]
          --selftest-share (--configured | --endpoint <url> --token <t>)
                           [--file <f>] [--big <MB>]
          --selftest-share-compat <recording.mp4>
          --selftest-share-flow          (uploads to your real bucket, then deletes)
          --selftest-cli <dir>
          --selftest-click-timeline <dir>

        Rects are in AppKit global points (origin bottom-left of the main screen).

        """.utf8))
    exit(64)
} else {
    delegate = AppDelegate()
}
#else
delegate = AppDelegate()
#endif

application.delegate = delegate
application.run()
