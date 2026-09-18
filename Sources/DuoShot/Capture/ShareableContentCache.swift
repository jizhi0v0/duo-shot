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

    /// The only identity for this window that may be interpolated as
    /// `privacy: .public`.
    ///
    /// `displayName` must never be: a `.public` interpolation is written to the
    /// **persisted** log store in clear and swept up by `sysdiagnose`, so a
    /// window title — a browser tab, a document name, a chat thread — leaves the
    /// machine with any diagnostic the user shares. For a screenshot app that is
    /// the worst line in the tree to widen, and it was widened: up to 2026-09-18
    /// `instant window capture:` and the `placed N windows` notice both put
    /// `displayName` in public.
    ///
    /// The app name is enough to read every one of those lines, and it is what
    /// the picker's own rules are written in terms of (bundle, layer, app). Where
    /// the title genuinely decides which of five windows was picked, log
    /// `displayName` *beside* this with no privacy specifier: `.auto` redacts a
    /// runtime string to `<private>`, and anyone debugging their own machine can
    /// turn it back on for this subsystem alone.
    ///
    /// Deliberately does not fall back to `title` the way `displayName` does. A
    /// window with no app name is rare and its id is a better answer than its
    /// title is — a fallback that leaks is not a fallback.
    var logName: String {
        if let appName, !appName.isEmpty { return appName }
        return "Window \(id)"
    }
}

/// The Dock's window captured by itself — see
/// `ShareableContentCache.captureDockShape(among:)`.
struct DockShape {
    let id: CGWindowID
    let image: CGImage
    let scale: CGFloat
    /// CG global points: the Dock window's frame, which is the whole screen.
    let frame: CGRect
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
    /// The Dock as it was at the last refresh, alone, when its window was on
    /// screen. See `captureDockShape(among:)`.
    private(set) var dockShape: DockShape?

    func refresh(onScreenOnly: Bool = true) async throws {
        let fetched = try await SCKBridge.shareableContent(
            excludingDesktopWindows: true, onScreenWindowsOnly: onScreenOnly
        ).value
        content = fetched
        dockShape = await captureDockShape(among: fetched.windows)
        // The Dock's own pixels first, the strip it reserves only as the
        // fallback: that strip is the full width of the screen, and an outline
        // wider than what ends up in the file is exactly the mismatch to avoid.
        let dockStrip = dockShape.flatMap { drawnDockStrip(from: $0) }
            ?? ScreenIndex.dockStripInCGGlobal()
        let entries = WindowZOrder.entries()
        windows = WindowZOrder.sortedFrontToBack(
            fetched.windows.map { WindowInfo($0, dockStrip: dockStrip, entries: entries) },
            using: entries)
    }

    /// The Dock's window captured by itself, at the moment of the refresh —
    /// which, for an interactive capture, is the moment the shortcut fired.
    ///
    /// Isolated on purpose, and only for the *shape*: the glass comes out flat
    /// in it. Two uses: where a revealed auto-hide Dock is
    /// (`drawnDockStrip(from:)`), and the outline a Dock capture is cut to
    /// (`CaptureEngine.shaped`) — taken at the same instant as the photograph
    /// that capture is cut from, so shape and pixels agree even about an icon's
    /// name label, which comes and goes. Costs one capture per refresh while the
    /// Dock's window is on screen; a hidden auto-hide Dock is not listed at all.
    private func captureDockShape(among windows: [SCWindow]) async -> DockShape? {
        guard let dock = windows.first(where: {
            $0.owningApplication?.bundleIdentifier == WindowInfo.dockBundleID
                && $0.windowLayer == WindowInfo.dockLayer && $0.isOnScreen
        }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: dock)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCScreenshotConfiguration()
        let (width, height) = DisplayGeometry.pixelSize(of: filter.contentRect, scale: scale)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        guard let image = try? await SCKBridge.captureScreenshot(
                  filter: filter, configuration: configuration).image,
              !PixelCompare.isBlank(image)
        else { return nil }
        return DockShape(id: dock.windowID, image: image, scale: scale, frame: dock.frame)
    }

    /// Where the Dock is, from its own pixels — see
    /// `ScreenIndex.dockStrip(drawn:in:)`. The only answer for a revealed
    /// auto-hide Dock, which reserves no strip, and the better one for any Dock:
    /// this rect is both the outline the picker draws and the size of the file.
    ///
    /// `tightBounds`, not `opaqueBounds`. Reported 2026-09-11 as "实际框的大小和
    /// 图片的会有点不一致": `opaqueBounds` rounds out by a cell or two on a
    /// downscale, and measured on the Dock that was 1588x105.5 pt around a
    /// platter of 1563x90 — 12 pt of nothing on each side, in the outline and
    /// in the file alike. The platter itself is the same at alpha > 0 as at
    /// alpha > 200 (to a point), so there is no halo to allow for.
    private func drawnDockStrip(from shape: DockShape) -> CGRect? {
        guard let bounds = PixelCompare.tightBounds(shape.image) else { return nil }
        let scale = shape.scale
        // `tightBounds` is top-left pixels, like CG global — a divide, no flip.
        let drawn = CGRect(
            x: shape.frame.minX + bounds.minX / scale, y: shape.frame.minY + bounds.minY / scale,
            width: bounds.width / scale, height: bounds.height / scale)
        let strip = ScreenIndex.dockStrip(drawn: drawn, in: shape.frame)
        Log.capture.notice("""
            Dock drawn at \(Int(drawn.minX), privacy: .public),\(Int(drawn.minY), privacy: .public) \
            \(Int(drawn.width), privacy: .public)x\(Int(drawn.height), privacy: .public) pt: \
            \(strip == nil ? "not against an edge, not offered" : "offered as its strip", privacy: .public)
            """)
        return strip
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

    /// The windows that draw the desktop icons, for a take that leaves them out.
    ///
    /// Its own enumeration, because `refresh` asks with
    /// `excludingDesktopWindows: true` and the icons are exactly what that
    /// drops: measured 2026-09-11, Finder's icon window is absent from that list
    /// and present in this one. Picked by the documented level rather than by
    /// Finder's bundle ID — the same line `DesktopWallpaper` draws, from the
    /// other side.
    func desktopIconWindows() async throws -> [SCWindow] {
        let all = try await SCKBridge.shareableContent(
            excludingDesktopWindows: false, onScreenWindowsOnly: true).value
        return all.windows.filter { $0.windowLayer == Self.desktopIconLayer }
    }

    static let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
}

extension WindowInfo {
    static let dockBundleID = "com.apple.dock"
    /// `NSWindow.Level.dock` and `.mainMenu` are deprecated; the CoreGraphics
    /// keys are the current spelling of the same window-server numbers, and the
    /// window server is what `SCWindow.windowLayer` reports.
    /// The top of the range ordinary app windows use.
    static let topAppLayer = Int(CGWindowLevelForKey(.modalPanelWindow))
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
    /// `NSWindow.Level.floating`, 3: an app's palette or inspector.
    static let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))

    /// One of the pair the Dock raises while a swipe between desktops is
    /// landing, and draws nothing in — see `WindowPickerModel.rejectionReason`.
    var isDesktopSwipeWindow: Bool {
        bundleID == Self.dockBundleID && layer == Self.floatingLayer
    }
    static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    /// Where a menu-bar app's popup panel sits — and `NSMenu`, and tooltips.
    /// 101, the same number as `NSWindow.Level.popUpMenu`.
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
    /// 102, one above `popUpMenuLayer`: where a panel goes that has to sit over
    /// another app's own 101 window. See `WindowPickerModel.isPickable(layer:)`.
    static let overlayLayer = Int(CGWindowLevelForKey(.overlayWindow))

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
