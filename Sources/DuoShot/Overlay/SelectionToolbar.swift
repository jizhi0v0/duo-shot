import AppKit

/// The bar that appears under a committed selection when the caller asked for a
/// confirmation step.
///
/// It sits one level above `OverlayPanel`, which is at `CGShieldingWindowLevel()`
/// — the overlay covers everything, so anything meant to be clicked during a
/// selection has to be above it. Nonactivating for the same reason the overlay
/// itself is: the app must not come to the front, or the thing about to be
/// recorded is a window that just lost focus.
final class SelectionToolbarPanel: NSPanel {
    /// Test hook, mirroring the other panels.
    static var usesSharingTypeNone = true

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, view: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // See OverlayPanel: `isFloatingPanel` resets `level`, so it goes first or
        // the level below is silently undone.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = Self.usesSharingTypeNone ? .none : .readOnly

        contentView = view
    }
}

/// Microphone, its input device, system audio, and the button that starts the
/// take.
///
/// The toggles write straight through to `Preferences` rather than holding
/// per-take state. One place decides what the next recording does, so this bar
/// and the Settings tab can never disagree — and a choice made here survives to
/// the next take, which is what someone who always narrates would expect.
final class SelectionToolbarView: NSView {
    struct Callbacks {
        var start: () -> Void = {}
        /// The bar's width depends on the device name, so the owner has to
        /// resize the panel when the selection changes.
        var resized: () -> Void = {}
    }

    private static let margin = HUDMetrics.margin
    private static let toggleWidth = HUDMetrics.iconWidth
    private static let chevronWidth: CGFloat = 14
    private static let controlHeight = HUDMetrics.controlHeight
    private static let gap: CGFloat = 6
    private static let groupGap = HUDMetrics.groupGap
    private static let height = HUDMetrics.height
    private static let recordTitle = "Record"
    private static let deviceFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    /// The device name is elided past this. "MacBook Pro Microphone" is already
    /// long, and a USB interface's name can be far longer — the bar has to stay
    /// something that fits under a selection.
    private static let deviceMaxWidth: CGFloat = 132

    private var callbacks: Callbacks
    private var background: NSVisualEffectView!
    private var microphoneButton: NSButton!
    private var deviceButton: NSButton!
    private var deviceLabel: NSTextField!
    private var audioButton: NSButton!
    private var divider: NSView!
    private var pill: HUDPill!

    private var preferences: Preferences { .shared }

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: Self.height))
        wantsLayer = true
        buildSubviews()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildSubviews() {
        background = HUDMetrics.background(in: bounds)
        addSubview(background)

        microphoneButton = button(action: #selector(toggleMicrophone))
        addSubview(microphoneButton)

        // A separate hit target rather than a long-press or a right-click: the
        // overlay owns the keyboard and the pointer during a selection, so a
        // gesture that takes time to recognise competes with the drag the user
        // may be about to restart.
        deviceButton = button(action: #selector(showDeviceMenu))
        deviceButton.image = HUDMetrics.symbol("chevron.down", pointSize: 8)
        addSubview(deviceButton)

        // Shown even when it says "System default". The point of putting the
        // input on the bar is that you can see what the take will record without
        // opening a menu, and a bar that only names the device once you have
        // chosen a specific one answers the question exactly when you no longer
        // need to ask it.
        deviceLabel = NSTextField(labelWithString: "")
        deviceLabel.font = Self.deviceFont
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.maximumNumberOfLines = 1
        addSubview(deviceLabel)

        audioButton = button(action: #selector(toggleSystemAudio))
        addSubview(audioButton)

        divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        addSubview(divider)

        pill = HUDPill(title: Self.recordTitle, mark: .dot, tint: .systemRed)
        pill.toolTip = "Start recording  ⏎"
        pill.onClick = { [weak self] in self?.callbacks.start() }
        addSubview(pill)
    }

    private func button(action: Selector) -> NSButton {
        let button = FirstMouseButton(frame: .zero)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        return button
    }

    /// Redraws both toggles from the preferences they write to, then re-lays out
    /// — the device name changes the bar's width.
    func refresh() {
        let granted = MicrophonePermission.isGranted
        let micOn = granted && preferences.recordingMicrophone
        microphoneButton.image = HUDMetrics.symbol(micOn ? "mic.fill" : "mic.slash.fill", pointSize: 13)
        microphoneButton.contentTintColor = micOn ? .white : .tertiaryLabelColor
        // The grant is *not* requested from here. A TCC prompt would have to
        // appear over a shielding-level overlay that holds the keyboard, and the
        // Settings toggle is the place designed to raise it — see
        // `MicrophonePermission.request`.
        microphoneButton.isEnabled = granted
        deviceButton.isEnabled = granted
        deviceButton.contentTintColor = micOn ? .white : .tertiaryLabelColor
        microphoneButton.toolTip = granted
            ? (micOn ? "Microphone on" : "Microphone off")
            : "Allow the microphone in DuoShot Settings first"

        deviceLabel.stringValue = currentDeviceName
        deviceLabel.textColor = micOn ? .secondaryLabelColor : .tertiaryLabelColor
        deviceLabel.toolTip = "Input device — \(currentDeviceName)"
        deviceButton.toolTip = "Choose the input device"

        let audioOn = preferences.recordingSystemAudio
        audioButton.image = HUDMetrics.symbol(
            audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill", pointSize: 13)
        audioButton.contentTintColor = audioOn ? .white : .tertiaryLabelColor
        // Named, not just on/off. "Speaker" is not self-explanatory on a
        // recording bar — what it captures is the audio other apps are playing.
        audioButton.toolTip = audioOn
            ? "Recording system audio — everything your Mac is playing"
            : "Not recording system audio"

        layoutControls()
    }

    /// Places every control left to right and sizes the view to fit.
    private func layoutControls() {
        let y = ((Self.height - Self.controlHeight) / 2).rounded()
        var x = Self.margin

        microphoneButton.frame = CGRect(
            x: x, y: y, width: Self.toggleWidth, height: Self.controlHeight)
        x += Self.toggleWidth

        deviceButton.frame = CGRect(
            x: x, y: y, width: Self.chevronWidth, height: Self.controlHeight)
        x += Self.chevronWidth + 3

        deviceLabel.sizeToFit()
        let labelWidth = min(deviceLabel.frame.width, Self.deviceMaxWidth)
        deviceLabel.frame = CGRect(
            x: x, y: ((Self.height - deviceLabel.frame.height) / 2).rounded(),
            width: labelWidth, height: deviceLabel.frame.height)
        x += labelWidth + Self.gap

        audioButton.frame = CGRect(
            x: x, y: y, width: Self.toggleWidth, height: Self.controlHeight)
        x += Self.toggleWidth + Self.groupGap

        divider.frame = CGRect(x: x, y: y + 4, width: 1, height: Self.controlHeight - 8)
        x += 1 + Self.groupGap

        let pillWidth = HUDPill.width(for: Self.recordTitle)
        pill.frame = CGRect(x: x, y: y, width: pillWidth, height: Self.controlHeight)
        x += pillWidth + Self.margin

        let size = CGSize(width: x.rounded(.up), height: Self.height)
        if frame.size != size {
            setFrameSize(size)
            background.frame = CGRect(origin: .zero, size: size)
            callbacks.resized()
        }
    }

    private var currentDeviceName: String {
        AudioInputDevices.displayName(for: preferences.recordingMicrophoneDeviceID)
            ?? "System default"
    }

    @objc private func toggleMicrophone() {
        preferences.recordingMicrophone.toggle()
        refresh()
    }

    @objc private func toggleSystemAudio() {
        preferences.recordingSystemAudio.toggle()
        refresh()
    }

    @objc private func showDeviceMenu() {
        let menu = NSMenu()
        let stored = preferences.recordingMicrophoneDeviceID

        let systemDefault = NSMenuItem(
            title: "System default", action: #selector(selectDevice(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.representedObject = AudioInputDevices.systemDefaultID
        systemDefault.state = stored == AudioInputDevices.systemDefaultID ? .on : .off
        menu.addItem(systemDefault)

        let devices = AudioInputDevices.all
        if !devices.isEmpty { menu.addItem(.separator()) }
        for device in devices {
            let item = NSMenuItem(
                title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = stored == device.id ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: deviceButton.bounds.maxY + 4),
                   in: deviceButton)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.recordingMicrophoneDeviceID = id
        refresh()
    }
}

/// Owns the toolbar panel for the length of one armed selection.
@MainActor
final class SelectionToolbar {
    private var panel: SelectionToolbarPanel?
    private var view: SelectionToolbarView?
    /// Kept so a width change — a longer device name — can re-place the bar
    /// without the controller having to be told.
    private var anchor: (selection: CGRect, screen: NSScreen)?

    var onStart: () -> Void = {}

    var isVisible: Bool { panel != nil }

    var windowIDs: Set<CGWindowID> {
        guard let panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    /// Places the bar under `selection`, or above it when there is no room
    /// below — a selection dragged to the bottom of the screen is the common
    /// case, not an edge case.
    func show(under selection: CGRect, on screen: NSScreen) {
        if panel == nil {
            var callbacks = SelectionToolbarView.Callbacks()
            callbacks.start = { [weak self] in self?.onStart() }
            callbacks.resized = { [weak self] in self?.applySize() }
            let view = SelectionToolbarView(callbacks: callbacks)
            let created = SelectionToolbarPanel(contentRect: view.frame, view: view)
            created.orderFrontRegardless()
            panel = created
            self.view = view
        }
        anchor = (selection, screen)
        view?.refresh()
        applySize()
    }

    func reposition(under selection: CGRect, on screen: NSScreen) {
        anchor = (selection, screen)
        applySize()
    }

    /// Matches the panel to the view's current width, then re-places it.
    private func applySize() {
        guard let panel, let view, let anchor else { return }
        let size = view.frame.size
        let origin = HUDPlacement.origin(for: size, under: anchor.selection, on: anchor.screen)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        anchor = nil
    }

    var frameForTest: CGRect? { panel?.frame }
}
