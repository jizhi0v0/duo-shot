import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers

/// UserDefaults-backed settings.
///
/// Stored properties rather than computed accessors over `UserDefaults`:
/// `@Observable` only tracks stored properties, so computed passthroughs would
/// leave the SwiftUI settings window unable to see its own edits. Each setter
/// persists through `didSet`.
///
/// Non-sandboxed, so the save location is a plain path string — no
/// security-scoped bookmarks. That is a real simplification the sandbox would
/// have cost us.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let copyToClipboard = "copyToClipboard"
        static let saveToDisk = "saveToDisk"
        static let playsSound = "playsSound"
        static let showsMenuBarIcon = "showsMenuBarIcon"
        static let showsPreviewOverlay = "showsPreviewOverlay"
        static let previewTimeout = "previewTimeout"
        static let previewCorner = "previewCorner"
        static let showsCursor = "showsCursor"
        static let includeMenuBar = "includeMenuBar"
        static let includeChildWindows = "includeChildWindows"
        static let windowPadding = "windowPadding"
        static let filenameTemplate = "filenameTemplate"
        static let hotkeys = "hotkeys.v1"
    }

    // MARK: - Stored settings

    var saveDirectoryPath: String {
        didSet { defaults.set(saveDirectoryPath, forKey: Key.saveDirectory) }
    }
    var imageFormatIdentifier: String {
        didSet { defaults.set(imageFormatIdentifier, forKey: Key.imageFormat) }
    }
    var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }
    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) }
    }
    var saveToDisk: Bool {
        didSet { defaults.set(saveToDisk, forKey: Key.saveToDisk) }
    }
    var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Key.playsSound) }
    }
    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }
    var showsPreviewOverlay: Bool {
        didSet { defaults.set(showsPreviewOverlay, forKey: Key.showsPreviewOverlay) }
    }
    var previewTimeout: Double {
        didSet { defaults.set(previewTimeout, forKey: Key.previewTimeout) }
    }
    var previewCorner: PreviewCorner {
        didSet { defaults.set(previewCorner.rawValue, forKey: Key.previewCorner) }
    }
    var showsCursor: Bool {
        didSet { defaults.set(showsCursor, forKey: Key.showsCursor) }
    }
    var includeMenuBar: Bool {
        didSet { defaults.set(includeMenuBar, forKey: Key.includeMenuBar) }
    }
    /// See `CaptureOptions.includeChildWindows` for why this is off by default
    /// and why the name flatters what it does.
    var includeChildWindows: Bool {
        didSet { defaults.set(includeChildWindows, forKey: Key.includeChildWindows) }
    }
    /// Points of wallpaper margin around a window capture. 0 is off.
    ///
    /// On by default at 32 pt. This does change the dimensions of every window
    /// screenshot the app produces, which is why it started at 0 — but a bare
    /// window capture has hard edges against whatever it is pasted into, and the
    /// padded one carries its own backdrop and shadow. The slider's left stop is
    /// labelled "Off", so turning it back off is one drag.
    var windowPadding: Double {
        didSet { defaults.set(windowPadding, forKey: Key.windowPadding) }
    }
    var filenameTemplate: String {
        didSet { defaults.set(filenameTemplate, forKey: Key.filenameTemplate) }
    }
    var hotkeys: [HotKeyAction: KeyCombo] {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkeys) else { return }
            defaults.set(data, forKey: Key.hotkeys)
        }
    }

    /// Fires whenever a binding changes, so `AppDelegate` can re-register.
    @ObservationIgnored var onHotkeysChanged: (() -> Void)?
    /// Fires when the menu-bar icon setting changes.
    @ObservationIgnored var onMenuBarIconChanged: (() -> Void)?

    private init() {
        defaults.register(defaults: [
            Key.imageFormat: UTType.png.identifier,
            Key.jpegQuality: 0.9,
            Key.copyToClipboard: true,
            Key.saveToDisk: true,
            Key.playsSound: true,
            Key.showsMenuBarIcon: true,
            Key.showsPreviewOverlay: true,
            Key.previewTimeout: 6.0,
            Key.previewCorner: PreviewCorner.bottomRight.rawValue,
            Key.showsCursor: false,
            Key.includeMenuBar: true,
            Key.includeChildWindows: false,
            Key.windowPadding: 32.0,
            Key.filenameTemplate: FilenameFormatter.defaultTemplate,
        ])

        let fallbackDirectory = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        saveDirectoryPath = defaults.string(forKey: Key.saveDirectory).flatMap {
            $0.isEmpty ? nil : $0
        } ?? fallbackDirectory
        imageFormatIdentifier = defaults.string(forKey: Key.imageFormat) ?? UTType.png.identifier
        jpegQuality = defaults.double(forKey: Key.jpegQuality)
        copyToClipboard = defaults.bool(forKey: Key.copyToClipboard)
        saveToDisk = defaults.bool(forKey: Key.saveToDisk)
        playsSound = defaults.bool(forKey: Key.playsSound)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        showsPreviewOverlay = defaults.bool(forKey: Key.showsPreviewOverlay)
        previewTimeout = defaults.double(forKey: Key.previewTimeout)
        previewCorner = defaults.string(forKey: Key.previewCorner)
            .flatMap(PreviewCorner.init(rawValue:)) ?? .bottomRight
        showsCursor = defaults.bool(forKey: Key.showsCursor)
        includeMenuBar = defaults.bool(forKey: Key.includeMenuBar)
        includeChildWindows = defaults.bool(forKey: Key.includeChildWindows)
        windowPadding = defaults.double(forKey: Key.windowPadding)
        filenameTemplate = defaults.string(forKey: Key.filenameTemplate)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? FilenameFormatter.defaultTemplate

        if let data = defaults.data(forKey: Key.hotkeys),
           let decoded = try? JSONDecoder().decode([HotKeyAction: KeyCombo].self, from: data) {
            hotkeys = decoded
        } else {
            hotkeys = HotKeyAction.allCases.reduce(into: [:]) { result, action in
                if let combo = action.defaultCombo { result[action] = combo }
            }
        }
    }

    // MARK: - Derived

    var saveDirectory: URL {
        get { URL(fileURLWithPath: saveDirectoryPath) }
        set { saveDirectoryPath = newValue.path }
    }

    var imageFormat: UTType {
        get { UTType(imageFormatIdentifier) ?? .png }
        set { imageFormatIdentifier = newValue.identifier }
    }

    var captureOptions: CaptureOptions {
        var options = CaptureOptions.default
        options.showsCursor = showsCursor
        options.includeMenuBar = includeMenuBar
        options.includeChildWindows = includeChildWindows
        options.windowPadding = windowPadding
        return options
    }

    // MARK: - Launch at login

    /// The system's answer, mirrored into a stored property.
    ///
    /// `SMAppService` keeps this state in the background-task database rather
    /// than in our defaults, so it has to be asked — but `@Observable` only
    /// tracks stored properties, and reading `SMAppService.mainApp.status`
    /// straight from the Toggle's getter is exactly why the switch looked dead:
    /// nothing SwiftUI observes changed when the setter ran, so the body never
    /// re-evaluated and the toggle snapped back to the value it was already
    /// showing. The registration itself had worked.
    ///
    /// Kept current by every mutation below plus `refreshLaunchAtLoginStatus()`,
    /// which the settings window calls when it opens and whenever the app comes
    /// forward — approval happens in System Settings, out of our process.
    private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status

    /// Set when `register()`/`unregister()` throws; cleared by the next success.
    private(set) var launchAtLoginFailure: String?

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else if launchAtLoginStatus != .notFound {
                    // `unregister()` throws when the database holds no record of
                    // the service, and `.notFound` *is* that state. There is
                    // nothing to switch off, so don't manufacture an error.
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginFailure = nil
            } catch {
                launchAtLoginFailure = error.localizedDescription
                Log.app.error("""
                    launch-at-login \(newValue ? "register" : "unregister", privacy: .public) \
                    failed: \(error.localizedDescription, privacy: .public)
                    """)
            }
            launchAtLoginStatus = SMAppService.mainApp.status
        }
    }

    /// Re-reads the system state. Cheap, and the only way to notice an approval
    /// (or a revocation) the user performed in System Settings.
    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    /// Footer copy under the toggle.
    ///
    /// The `.notFound` line is the one worth spelling out, because the enum name
    /// invites the wrong reading. Measured on macOS 26.5 with this bundle in
    /// /Applications, signed Developer ID:
    ///
    ///   never registered            -> .notFound
    ///   after register()            -> .enabled
    ///   after unregister()          -> .notRegistered
    ///
    /// So `.notFound` is the *pristine* state — the background-task database has
    /// no row for us yet — and it says nothing whatsoever about where the app is
    /// installed. Reading it as "wrong install location" is how this shipped
    /// telling people to move an app that was already in /Applications. To the
    /// user `.notFound` and `.notRegistered` are one state: it is off.
    ///
    /// A genuinely un-registerable location surfaces as a *thrown* error from
    /// `register()`, which is the only branch allowed to mention the location.
    var launchAtLoginStatusDescription: String {
        if let launchAtLoginFailure {
            return "Could not change this setting: \(launchAtLoginFailure)\(installLocationHint)"
        }
        switch launchAtLoginStatus {
        case .enabled:
            return "DuoShot starts automatically when you log in."
        case .notRegistered, .notFound:
            return "DuoShot does not start automatically."
        case .requiresApproval:
            return "DuoShot is switched off in System Settings › General › Login Items. Turn it back on there."
        @unknown default:
            return "The system reports an unrecognized login-item state (\(launchAtLoginStatus.rawValue))."
        }
    }

    /// Appended to a registration *failure* only, and only when the app is
    /// somewhere the system might legitimately refuse to register from.
    private var installLocationHint: String {
        isInstalledInApplicationsDirectory
            ? ""
            : " DuoShot is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path)"
              + " — moving it to /Applications may help."
    }

    /// True for /Applications and ~/Applications, resolving symlinks so a copy
    /// reached through one does not read as an unusual location.
    var isInstalledInApplicationsDirectory: Bool {
        let parent = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        return FileManager.default
            .urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .contains { $0.resolvingSymlinksInPath().path == parent.path }
    }

    /// The Login Items pane, for the `.requiresApproval` case — the one state the
    /// toggle cannot resolve on its own.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Drives every branch of the footer copy from `--selftest-preferences`
    /// without touching the real background-task database.
    func setLaunchAtLoginStateForTest(_ status: SMAppService.Status, failure: String? = nil) {
        launchAtLoginStatus = status
        launchAtLoginFailure = failure
    }
}
