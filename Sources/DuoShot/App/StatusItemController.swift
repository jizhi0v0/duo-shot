import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let coordinator: CaptureCoordinator
    private var lastOutput: OutputPipeline.Output?

    var onOpenSettings: () -> Void = {}

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder", accessibilityDescription: "DuoShot")
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func noteOutput(_ output: OutputPipeline.Output) {
        lastOutput = output
        statusItem?.menu = buildMenu()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        var actions: [HotKeyAction] = [.captureArea, .captureWindow, .captureFullscreen]
        if coordinator.hasPreviousArea { actions.append(.captureLastArea) }
        for action in actions {
            let item = NSMenuItem(
                title: action.title, action: #selector(trigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            if let combo = HotKeyManager.shared.combo(for: action) {
                item.keyEquivalent = ""
                item.toolTip = combo.displayString
                item.title = "\(action.title)  \(combo.displayString)"
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if let lastOutput {
            let reveal = NSMenuItem(
                title: "Show \"\(lastOutput.url.lastPathComponent)\" in Finder",
                action: #selector(revealLast), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
        }

        let folder = NSMenuItem(
            title: "Open Save Folder", action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit DuoShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func trigger(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let action = HotKeyAction(rawValue: raw)
        else { return }
        Task { await self.perform(action) }
    }

    func perform(_ action: HotKeyAction) async {
        switch action {
        case .captureArea:
            await coordinator.captureArea()
        case .captureWindow:
            await coordinator.captureWindow()
        case .captureFullscreen:
            await coordinator.captureDisplay()
        case .captureLastArea:
            await coordinator.captureLastArea()
        }
    }

    @objc private func revealLast() {
        guard let lastOutput else { return }
        OutputPipeline.shared.reveal(lastOutput.url)
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(Preferences.shared.saveDirectory)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
