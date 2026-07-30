import AppKit
import CoreGraphics

/// The Screen Recording (`kTCCServiceScreenCapture`) gate.
///
/// The one non-obvious rule, which shapes the whole first-run flow:
///
/// > **A running process does not observe a newly granted Screen Recording
/// > permission.** macOS hands the grant to the process only on next launch.
///
/// So "user granted it" must be followed by relaunching ourselves, or the
/// first-run experience is "I granted it and nothing works".
enum ScreenPermission {
    nonisolated static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system dialog. Returns the *immediate* answer, which is `false`
    /// on first ask even if the user then grants it — poll `isGranted` afterwards.
    @concurrent
    nonisolated static func request() async -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Polls `isGranted` until it flips true or the deadline passes.
    static func waitForGrant(timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isGranted { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return isGranted
    }

    /// Relaunch so the freshly granted TCC entry actually reaches us.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        Log.permission.notice("relaunching to pick up screen-capture grant")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }
}
