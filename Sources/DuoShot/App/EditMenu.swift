import AppKit

/// The main menu DuoShot never had.
///
/// `LSUIElement` apps have no menu bar, and it is easy to conclude they
/// therefore have no use for a main menu. They do: **`NSApplication` routes
/// every key equivalent through `mainMenu` before anything else sees it**, so
/// with no menu installed there is nothing to turn ⌘V into `paste:` on the first
/// responder. The Settings window's token field was unpastable for exactly this
/// reason — you could type into it, and ⌘V did nothing at all.
///
/// This is the same shape as the ⌘W bug the viewer window hit. That one was
/// fixed on the window because it was one command on one window; this cannot be,
/// because the six editing commands have to work in every text field the app
/// will ever have.
///
/// Nothing is drawn. `.accessory` apps still show no menu bar — the menu exists
/// only to be searched for key equivalents.
@MainActor
enum EditMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let edit = NSMenu(title: "Edit")
        // Undo and redo are on the list because a text field's field editor
        // provides them for free and their absence is felt immediately: typing a
        // long token, mistyping it, and having ⌘Z do nothing is the same class of
        // surprise as ⌘V doing nothing.
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]

        for (index, item) in items.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            let menuItem = NSMenuItem(
                title: item.0, action: item.1, keyEquivalent: item.2)
            menuItem.keyEquivalentModifierMask = item.3
            // No target: these have to travel the responder chain to reach
            // whichever field editor is first responder. Wiring them to anything
            // concrete would make them work in one window and nowhere else.
            edit.addItem(menuItem)
        }

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let menu = NSMenu()
        // The first submenu of a main menu is treated as the application menu and
        // is never searched for key equivalents, so it has to exist even though
        // nothing will ever display it.
        menu.addItem(NSMenuItem())
        menu.addItem(editItem)

        NSApp.mainMenu = menu
    }
}
