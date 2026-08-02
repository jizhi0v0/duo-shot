import AppKit
import SwiftUI

/// The window behind "Search Captures…".
///
/// Shaped exactly like `AllLinksWindowController`, for the reasons that one
/// gives: one window reused rather than a second copy of the same list, a model
/// that outlives the window so re-opening shows the last answer instead of an
/// empty frame, and `isReleasedWhenClosed = false` because this controller owns
/// the lifetime.
@MainActor
final class CaptureSearchWindowController {
    static let shared = CaptureSearchWindowController()

    private var window: NSWindow?
    private var observer: (any NSObjectProtocol)?
    private let model = CaptureSearchModel()

    /// Self-tests set this to false, for the reason the other window controllers
    /// give: `NSApp.activate` takes the keyboard away from whatever the person
    /// running the test is typing in.
    var activatesOnShow = true

    private init() {}

    func show() {
        model.refresh()

        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingController(rootView: CaptureSearchView(model: model))
        hosting.title = "Search Captures"
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Search Captures"
        window.setContentSize(NSSize(width: 560, height: 420))
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }

        bringToFront(window)
    }

    private func forget() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window = nil
    }

    func close() { window?.close() }

    private func bringToFront(_ window: NSWindow) {
        if activatesOnShow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// For the self-tests, which have no way to click a menu item.
    var isOpen: Bool { window != nil }
}
