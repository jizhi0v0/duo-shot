import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController {
    /// One tab per *decision the user is making*, which is why there are five of
    /// them and not three.
    ///
    /// General used to carry the save folder, the filename builder, the
    /// after-capture switches, the whole floating-preview block and the two app
    /// switches: 680 pt of form in a 480 pt-wide window, i.e. a tab you scan
    /// rather than read. Splitting Saving and Preview out of it puts every tab
    /// under ~380 pt, and the window no longer changes height dramatically as you
    /// move along the toolbar.
    ///
    /// Order follows the life of a capture — take it, store it, look at it — with
    /// the two "settings about the app itself" tabs at the ends.
    enum Tab: String, CaseIterable {
        case general, capture, recording, saving, preview, shortcuts

        var label: String {
            switch self {
            case .general: "General"
            case .capture: "Capture"
            case .recording: "Recording"
            case .saving: "Saving"
            case .preview: "Preview"
            case .shortcuts: "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .capture: "camera.viewfinder"
            case .recording: "record.circle"
            case .saving: "folder"
            case .preview: "rectangle.stack"
            case .shortcuts: "command"
            }
        }

        /// Every tab is this wide; only the height varies, and that comes from
        /// SwiftUI (see `measuredContentSize`).
        static let width: CGFloat = 480

        /// Used only if the SwiftUI measurement comes back nonsense. Deliberately
        /// generous: these never clip, they just leave dead space at the bottom.
        var fallbackHeight: CGFloat {
            switch self {
            case .general: 320
            case .capture: 360
            case .recording: 420
            case .saving: 420
            case .preview: 360
            case .shortcuts: 420
            }
        }
    }

    /// Reports every selection change, whoever caused it.
    ///
    /// The reason this subclass exists: clicking a toolbar item does NOT go
    /// through `PreferencesWindowController.select(_:)`, so hanging the resize off
    /// that method fixed only the programmatic path — the one no user takes.
    private final class ResizingTabViewController: NSTabViewController {
        var willSelect: (Int) -> Void = { _ in }

        override func tabView(_ tabView: NSTabView, willSelect item: NSTabViewItem?) {
            super.tabView(tabView, willSelect: item)
            guard let item, let index = tabView.tabViewItems.firstIndex(of: item) else { return }
            willSelect(index)
        }
    }

    private var window: NSWindow?
    private var tabController: ResizingTabViewController?
    private var contentSizes: [Tab: NSSize] = [:]
    private let windowTitle = "DuoShot Settings"

    /// Self-tests set this to false. They open this window repeatedly, and
    /// `NSApp.activate(ignoringOtherApps:)` yanks the keyboard out of whatever the
    /// user is typing in — which is not hypothetical: a test run stole focus
    /// mid-keystroke and the keystroke landed in the filename field, replacing
    /// the whole template.
    var activatesOnShow = true

    var onHotkeysChanged: () -> Void = {}
    /// While the shortcut recorder is armed every global binding is released,
    /// otherwise Carbon swallows the combo before the local monitor sees it.
    var onRecordingChanged: (Bool) -> Void = { _ in }

    func show(tab: Tab = .general) {
        // Nothing tells us when the login-item state changes underneath us, so
        // it is re-read on the way in.
        Preferences.shared.refreshLaunchAtLoginStatus()
        if let window {
            select(tab)
            bringToFront(window)
            return
        }

        // An NSTabViewController in `.toolbar` style plus `toolbarStyle =
        // .preference` is what produces the native settings look: icon-over-label
        // items in a centred toolbar. A SwiftUI `TabView` renders as a segmented
        // control floating inside the content area, which is what this window
        // looked like before and why it read as not-a-Mac-app.
        let controller = ResizingTabViewController()
        controller.tabStyle = .toolbar
        // No crossfade. The window now resizes on the same runloop turn as the
        // switch, so a fading tab is the only thing left that reads as lag — the
        // content dissolves in over the new, already-correct frame. System
        // Settings swaps panes with no animation either.
        controller.transitionOptions = []
        controller.willSelect = { [weak self] index in
            guard let self, index < Tab.allCases.count else { return }
            resize(to: Tab.allCases[index])
        }

        for tab in Tab.allCases {
            let hosting = NSHostingController(rootView: content(for: tab))
            // Left on (it is also the default) so the window follows content
            // that grows *within* a tab — the filename chips wrap to another row
            // as variables are added. What it must NOT be relied on for is the
            // tab switch: SwiftUI pushes the new size asynchronously, which is
            // the ~650 ms lag `resize(to:)` exists to beat.
            hosting.sizingOptions = [.preferredContentSize]
            // NSTabViewController pushes the selected child's title to the window,
            // so a nil title here showed the window as "Untitled" the moment the
            // selection was anything but the first tab. Same string on every tab
            // rather than the tab label: the app is LSUIElement, so this titlebar
            // is the only place its name appears.
            hosting.title = windowTitle
            hosting.preferredContentSize = measuredContentSize(for: tab)
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            item.identifier = tab.rawValue
            controller.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = windowTitle
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        self.tabController = controller
        // Force every tab's SwiftUI view to load and lay out once, then take its
        // size from SwiftUI itself. The throwaway measurement in
        // `measuredContentSize` is close but not exact — 8 pt out on the Capture
        // tab, enough for a visible flinch the first time you switch to it.
        for (index, item) in controller.tabViewItems.enumerated()
        where Tab.allCases.indices.contains(index) {
            item.viewController?.view.setFrameSize(
                NSSize(width: Tab.width, height: measuredContentSize(for: Tab.allCases[index]).height))
            item.viewController?.view.layoutSubtreeIfNeeded()
            if let live = liveContentSize(for: Tab.allCases[index]) {
                contentSizes[Tab.allCases[index]] = live
            }
        }
        select(tab)
        bringToFront(window)
    }

    /// A grouped Form insets its content from the top but not the bottom, so the
    /// last card sits flush against the window edge. The padding goes *in the
    /// content* rather than into the window height: SwiftUI's own
    /// preferredContentSize is live (see `sizingOptions`), so any height this
    /// controller invents on top of it just gets overwritten a frame later.
    private func content(for tab: Tab) -> some View {
        // The width is pinned here, not just in `measuredContentSize`: with
        // `sizingOptions` on, SwiftUI pushes its ideal WIDTH up too, and the
        // window went to 744 pt on the General tab because a few footers would
        // rather not wrap.
        tabContent(for: tab)
            .frame(width: Tab.width)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(preferences: Preferences.shared)
        case .capture:
            CaptureSettingsView(preferences: Preferences.shared)
        case .recording:
            RecordingSettingsView(preferences: Preferences.shared)
        case .saving:
            SavingSettingsView(preferences: Preferences.shared)
        case .preview:
            PreviewSettingsView(preferences: Preferences.shared)
        case .shortcuts:
            ShortcutsSettingsView(
                preferences: Preferences.shared,
                onHotkeysChanged: { [weak self] in self?.onHotkeysChanged() },
                onRecordingChanged: { [weak self] in self?.onRecordingChanged($0) }
            )
        }
    }

    private func select(_ tab: Tab) {
        guard let index = Tab.allCases.firstIndex(of: tab) else { return }
        // Setting the index is enough: the resize rides on the tab controller's
        // own will-select, so the programmatic path and the toolbar click land in
        // the same place.
        tabController?.selectedTabViewItemIndex = index
        resize(to: tab)
    }

    /// NSTabViewController does get to the selected item's preferredContentSize on
    /// its own — measured ~650 ms later, in one jump. For that whole time the new
    /// tab is laid out at the *previous* tab's height, which reads as the window
    /// flashing tall and then settling.
    ///
    /// Top-left is pinned deliberately: a settings window that grows downward
    /// keeps its toolbar under the pointer that just clicked the tab.
    private func resize(to tab: Tab) {
        // Before leaving, take the size the tab actually settled at. Content can
        // grow while it is on screen — add three filename chips and the flow
        // wraps — and SwiftUI's number is only trustworthy for the tab that has
        // been laid out. Reading it for the *incoming* tab was measurably wrong:
        // 8 pt off, i.e. a visible flinch on the first switch.
        if let current = selectedTab, let live = liveContentSize(for: current) {
            contentSizes[current] = live
        }
        let size = measuredContentSize(for: tab)
        guard let window, window.contentView?.frame.size != size else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: window.frame.minX, y: top - window.frame.height))
    }

    /// The height SwiftUI actually needs for a tab, measured once and cached.
    ///
    /// Hardcoded per-tab heights were fine until they weren't: they are padded to
    /// whatever looked safe when the tab was written, so the Capture tab carried
    /// 115 pt of dead space under its last row and every edit to a tab silently
    /// invalidated its number. `fallbackHeight` still backs this up in case the
    /// measurement ever returns something absurd.
    private func measuredContentSize(for tab: Tab) -> NSSize {
        if let cached = contentSizes[tab] { return cached }
        let ideal = Self.idealHeight(of: content(for: tab), width: Tab.width)
        let height = (100...1200).contains(Int(ideal)) ? ideal.rounded(.up) : tab.fallbackHeight
        let size = NSSize(width: Tab.width, height: height)
        contentSizes[tab] = size
        return size
    }

    private var selectedTab: Tab? {
        guard let index = tabController?.selectedTabViewItemIndex,
              Tab.allCases.indices.contains(index)
        else { return nil }
        return Tab.allCases[index]
    }

    /// What the tab's hosting controller currently reports, if it is plausible.
    private func liveContentSize(for tab: Tab) -> NSSize? {
        guard let index = Tab.allCases.firstIndex(of: tab),
              let controller = tabController,
              index < controller.tabViewItems.count,
              let size = controller.tabViewItems[index].viewController?.preferredContentSize,
              (100...1200).contains(Int(size.height))
        else { return nil }
        return size
    }

    /// SwiftUI's own ideal height for a tab at the fixed window width, measured
    /// in a throwaway hosting view.
    private static func idealHeight(of view: some View, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.widthAnchor.constraint(equalToConstant: width).isActive = true
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func bringToFront(_ window: NSWindow) {
        // The app is an accessory (LSUIElement), so it is not in the Dock and
        // does not activate on its own. Settings is the one window that needs
        // real focus, so activation is explicit here.
        if activatesOnShow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    /// For `--selftest-settings-window`.
    var windowNumber: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    var frame: CGRect? { window?.frame }

    /// Switches tabs the way the toolbar does — straight at the tab controller,
    /// bypassing `select(_:)` entirely. Testing through `show(tab:)` instead is
    /// what let the resize bug survive a passing test.
    func debugSelectAsToolbarWould(_ tab: Tab) {
        guard let index = Tab.allCases.firstIndex(of: tab) else { return }
        tabController?.selectedTabViewItemIndex = index
    }

    /// What SwiftUI would pick for each tab at the fixed window width, next to
    /// the hardcoded number. Used by `--selftest-settings-resize --trace` to keep
    /// `Tab.contentSize` honest as the tabs gain and lose rows.
    var debugFittingSizes: [(tab: Tab, declared: CGFloat, fitting: CGFloat)] {
        Tab.allCases.map { tab in
            (tab, tab.fallbackHeight, measuredContentSize(for: tab).height)
        }
    }
}
