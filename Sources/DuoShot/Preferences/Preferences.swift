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
        return options
    }

    // MARK: - Launch at login

    /// `SMAppService` reports state rather than storing it in our defaults, so
    /// this is a live query, not a cached flag.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.app.error("""
                    launch-at-login \(newValue ? "register" : "unregister", privacy: .public) \
                    failed: \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Not enabled"
        case .requiresApproval: "Waiting for approval in Login Items"
        case .notFound: "Unavailable — move DuoShot to /Applications"
        @unknown default: "Unknown"
        }
    }
}
