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
    /// The window server's own opacity for this window, 0–1.
    ///
    /// ScreenCaptureKit does not report it, and `isOnScreen` is not a substitute:
    /// measured 2026-07-30, a DuoPaste panel sat at alpha 0.000, on screen, 701×596,
    /// ranked directly in front of Claude — completely invisible and completely
    /// pickable. Defaults to 1 for a window the window server did not list, so a
    /// missing measurement never hides anything.
    let alpha: Double
    /// The part of `frame` the window actually occupies, when the two differ.
    ///
    /// Only the Dock needs this today, and it needs it badly: its window is the
    /// entire screen while the dock itself is a strip along one edge. Left as
    /// the whole frame, it would rank in front of every ordinary window and
    /// swallow every hover on the display.
    ///
    /// Whatever is set here governs both the highlight and the capture, so the
    /// two can never disagree about what was picked.
    let visibleFrame: CGRect?

    /// What the picker hit-tests and outlines.
    var pickFrame: CGRect { visibleFrame ?? frame }

    var displayName: String {
        switch (appName, title) {
        // `title != app` because the Dock reports both as "Dock", and "Dock —
        // Dock" reads like a bug. Same for WeChat and a few others.
        case let (app?, title?) where !title.isEmpty && title != app: "\(app) — \(title)"
        case let (app?, _) where !app.isEmpty: app
        case let (_, title?) where !title.isEmpty: title
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
        let dockStrip = ScreenIndex.dockStripInCGGlobal()
        let entries = WindowZOrder.entries()
        windows = WindowZOrder.sortedFrontToBack(
            fetched.windows.map { WindowInfo($0, dockStrip: dockStrip, entries: entries) },
            using: entries)
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
    static let dockBundleID = "com.apple.dock"
    /// `NSWindow.Level.dock` and `.mainMenu` are deprecated; the CoreGraphics
    /// keys are the current spelling of the same window-server numbers, and the
    /// window server is what `SCWindow.windowLayer` reports.
    /// The top of the range ordinary app windows use.
    static let topAppLayer = Int(CGWindowLevelForKey(.modalPanelWindow))
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
    static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

    fileprivate init(
        _ window: SCWindow, dockStrip: CGRect?, entries: [CGWindowID: WindowZOrder.Entry]
    ) {
        let isDock = window.owningApplication?.bundleIdentifier == Self.dockBundleID
            && window.windowLayer == Self.dockLayer
        self.init(
            id: window.windowID,
            frame: window.frame,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            bundleID: window.owningApplication?.bundleIdentifier,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            alpha: entries[window.windowID]?.alpha ?? 1,
            visibleFrame: isDock ? dockStrip : nil
        )
    }
}
