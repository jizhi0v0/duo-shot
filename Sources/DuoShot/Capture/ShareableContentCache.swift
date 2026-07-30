import AppKit
import ScreenCaptureKit

/// Sendable projection of an `SCWindow`, safe to pass anywhere.
nonisolated struct WindowInfo: Sendable, Identifiable, Hashable {
    let id: CGWindowID
    /// CG global points.
    let frame: CGRect
    let title: String?
    let appName: String?
    let bundleID: String?
    let layer: Int
    let isOnScreen: Bool

    var displayName: String {
        switch (appName, title) {
        case let (app?, title?) where !title.isEmpty: "\(app) — \(title)"
        case let (app?, _): app
        case let (_, title?): title
        default: "Window \(id)"
        }
    }
}

/// Holds the live, non-Sendable SCK objects and never lets them escape.
///
/// The rule this type exists to enforce:
/// **Sendable structs cross isolation boundaries; live SCK objects stay pinned
/// to `@MainActor`.** `SCContentFilter` needs the real `SCWindow`/`SCDisplay`
/// instances, so we cannot work from projections alone — hence the MainActor-only
/// accessors alongside the Sendable `WindowInfo` list.
final class ShareableContentCache {
    /// Front-to-back, frontmost first. SCK does not hand them over that way — see
    /// `WindowZOrder` — and the window picker's hit-test depends on it, so the
    /// ordering is established here once rather than at each use site.
    private(set) var windows: [WindowInfo] = []
    private var content: SCShareableContent?
    private var ownWindows: SCShareableContent?

    func refresh(onScreenOnly: Bool = true) async throws {
        let fetched = try await SCKBridge.shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: onScreenOnly
        ).value
        content = fetched
        windows = WindowZOrder.sortedFrontToBack(fetched.windows.map(WindowInfo.init(_:)))
    }

    func scWindow(for id: CGWindowID) -> SCWindow? {
        content?.windows.first { $0.windowID == id }
    }

    func scDisplay(for id: CGDirectDisplayID) -> SCDisplay? {
        content?.displays.first { $0.displayID == id }
    }

    /// A filter containing only the desktop: every running application excluded,
    /// so what is left to render is the wallpaper. See `DesktopWallpaper`.
    func wallpaperFilter(for displayID: CGDirectDisplayID) -> SCContentFilter? {
        guard let content, let display = scDisplay(for: displayID) else { return nil }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications,
            exceptingWindows: [])
        // The menu bar belongs to no application, so excluding every application
        // does not exclude it — and `includeMenuBar` defaults to true, measured.
        // It leaked into the padding backdrop, where it showed up as a strip of
        // some other app's menus across the top of the card, but only sometimes:
        // the backdrop is aspect-filled, so a tall capture keeps the wallpaper's
        // top edge while a wide one crops it away. Reported as "why does a window
        // screenshot occasionally have a menu in the top-left".
        filter.includeMenuBar = false
        return filter
    }

    var displayIDs: [CGDirectDisplayID] {
        content?.displays.map(\.displayID) ?? []
    }

    /// Our own windows, for `SCContentFilter(display:excludingWindows:)`.
    ///
    /// Uses `getCurrentProcessShareableContent`, which needs **no TCC** and only
    /// walks our process — so excluding the overlay can never be affected by the
    /// monthly re-prompt state, and it is far cheaper than a full enumeration.
    ///
    /// Ordering constraint: the panels must already be on screen when this runs,
    /// or they will not be in the list. It is cheap enough to do at capture time.
    func ownWindows(matching ids: Set<CGWindowID>) async throws -> [SCWindow] {
        guard !ids.isEmpty else { return [] }
        let mine = try await SCKBridge.currentProcessShareableContent().value
        ownWindows = mine
        return mine.windows.filter { ids.contains($0.windowID) }
    }
}

extension WindowInfo {
    fileprivate init(_ window: SCWindow) {
        self.init(
            id: window.windowID,
            frame: window.frame,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            bundleID: window.owningApplication?.bundleIdentifier,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen
        )
    }
}
