import AVFoundation

/// The microphone TCC gate, kept deliberately separate from `ScreenPermission`.
///
/// It behaves nothing like the screen one, and every difference matters:
///
/// - It **is** a usage-string service, so `NSMicrophoneUsageDescription` must be
///   in Info.plist or the process is killed rather than denied.
/// - A grant takes effect immediately. There is no relaunch dance.
/// - Its status is readable up front, which is the whole point of this file:
///   ScreenCaptureKit does not degrade gracefully when the grant is undecided.
///   Measured 2026-07-31, `SCStream.startCapture` with `captureMicrophone = true`
///   and an undecided grant never calls its completion handler at all, while the
///   stream runs and the writer keeps appending. So the question has to be
///   settled *before* a stream is built, never by starting one and seeing.
enum MicrophonePermission {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isGranted: Bool { status == .authorized }

    /// Shows the system prompt if the grant is still undecided.
    ///
    /// Call this from the foreground — from the Settings toggle — not from the
    /// recording path. TCC attributes a prompt to the *responsible* process, and
    /// for anything launched from a shell that is the terminal's ancestor, which
    /// is how a microphone prompt ends up addressed to some other app and never
    /// gets answered. Same attribution rule that `make tcc-check` exists for on
    /// the screen-recording side.
    static func request() async -> Bool {
        guard status == .notDetermined else { return isGranted }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var statusDescription: String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}
