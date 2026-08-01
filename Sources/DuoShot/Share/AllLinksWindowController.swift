import AppKit
import SwiftUI

/// The window behind "All Links…".
///
/// One window, reused, for the reason `ViewerWindowController` gives: a second
/// copy of the same list is never what the second click meant, and two of them
/// could disagree the moment a row is deleted in one.
///
/// SwiftUI hosted in an `NSWindow` rather than an `NSTableView`, following
/// `PreferencesWindowController`: the content is a handful of rows over an
/// async load with three states, which is exactly what `@Observable` plus a
/// `List` is for. A table view would need a data source, a cell view and manual
/// reloads to say the same thing, and it buys nothing here — there are no
/// columns to sort, resize or reorder.
@MainActor
final class AllLinksWindowController {
    static let shared = AllLinksWindowController()

    private var window: NSWindow?
    private var observer: (any NSObjectProtocol)?
    /// Outlives the window on purpose. Re-opening the window during the same
    /// session shows what was last fetched while the refresh runs, rather than
    /// an empty list with a spinner over it.
    private let model = AllLinksModel()

    /// Self-tests set this to false, for the reason the other two window
    /// controllers give: `NSApp.activate` takes the keyboard away from whatever
    /// the person running the test is typing in.
    var activatesOnShow = true

    private init() {}

    func show() {
        // On every open, not only the first: the list is a picture of the
        // server, and one taken minutes ago is worth nothing. There is no
        // polling behind this — a window nobody is looking at should not be
        // asking the service anything.
        model.refresh()

        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingController(rootView: AllLinksView(model: model))
        hosting.title = "All Links"
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "All Links"
        window.setContentSize(NSSize(width: 520, height: 420))
        // This controller decides the window's lifetime, so a released-on-close
        // window would be freed while `self.window` still pointed at it.
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

    func close() {
        window?.close()
    }

    private func bringToFront(_ window: NSWindow) {
        // Same reasoning as Settings: the app is LSUIElement, so it does not
        // come forward on its own.
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
