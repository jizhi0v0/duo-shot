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
    private(set) var windows: [WindowInfo] = []
    private var content: SCShareableContent?
    private var ownWindows: SCShareableContent?

    func refresh(onScreenOnly: Bool = true) async throws {
        let fetched = try await SCKBridge.shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: onScreenOnly
        ).value
        content = fetched
        windows = fetched.windows.map(WindowInfo.init(_:))
    }

    func scWindow(for id: CGWindowID) -> SCWindow? {
        content?.windows.first { $0.windowID == id }
    }

    func scDisplay(for id: CGDirectDisplayID) -> SCDisplay? {
        content?.displays.first { $0.displayID == id }
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
