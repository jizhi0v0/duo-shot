import AppKit

/// A menu item that runs a closure.
///
/// `NSMenuItem` dispatches through `target`/`action`, which needs an `@objc`
/// method on an `NSObject` — and neither place that raises a context menu here
/// can supply one: `ViewerWindowController` is a plain Swift class, and
/// `PreviewCardView`'s actions are already closures in a `Callbacks` struct.
///
/// Subclassing `NSMenuItem` would be the obvious shape and does not compile in
/// this module: its designated initialisers are `nonisolated`, the module's
/// default isolation is `MainActor`, and an override cannot change that. A
/// separate target object has no such constraint.
extension NSMenuItem {
    static func action(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(handler)
        let item = NSMenuItem(
            title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = target
        // `NSMenuItem.target` is weak, so nothing so far keeps this alive and
        // the item would fire into a deallocated object — which AppKit reads as
        // "no target", quietly disabling the item. `representedObject` is the
        // item's own strong reference and is otherwise unused here.
        item.representedObject = target
        return item
    }
}

private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }
}
