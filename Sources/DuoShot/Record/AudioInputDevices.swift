import AVFoundation

/// The microphones the user can pick between.
///
/// Only the input side is enumerable, and that is not a gap: `capturesAudio` on
/// `SCStreamConfiguration` is a plain Bool over the whole system mix, so there is
/// no output device to choose. `microphoneCaptureDeviceID` is the one device
/// knob ScreenCaptureKit exposes.
enum AudioInputDevices {
    struct Device: Identifiable, Hashable {
        /// `AVCaptureDevice.uniqueID`, which is what
        /// `SCStreamConfiguration.microphoneCaptureDeviceID` expects.
        let id: String
        let name: String
    }

    /// Sentinel for "whatever the system is using". Empty rather than a made-up
    /// identifier so it cannot collide with a real `uniqueID`.
    static let systemDefaultID = ""

    static var all: [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Maps a stored preference onto what ScreenCaptureKit should be handed.
    ///
    /// nil means the system default, and an identifier that no longer resolves
    /// becomes nil too — a device can be unplugged between the moment it was
    /// chosen in Settings and the moment a take starts.
    static func resolve(_ storedID: String) -> String? {
        guard storedID != systemDefaultID else { return nil }
        guard AVCaptureDevice(uniqueID: storedID) != nil else { return nil }
        return storedID
    }

    /// What the Settings picker shows for a stored identifier that no longer
    /// resolves, so a vanished device reads as gone rather than as a blank row.
    static func displayName(for storedID: String) -> String? {
        guard storedID != systemDefaultID else { return nil }
        return AVCaptureDevice(uniqueID: storedID)?.localizedName
    }
}
