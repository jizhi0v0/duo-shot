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

/// The Record button.
///
/// Hand-drawn rather than an `NSButton`. Getting predictable padding out of a
/// borderless button carrying both an image and a title means guessing at
/// AppKit's own insets and at the rendered width of an SF Symbol, and the guess
/// was wrong: the dot ended up flush against the left edge. A view that places
/// its own two subviews cannot be wrong about that.
private final class RecordPill: NSView {
    var onClick: () -> Void = {}

    private static let horizontalPadding: CGFloat = 13
    private static let dotSize: CGFloat = 11
    private static let dotTextGap: CGFloat = 7
    private static let title = "Record"
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private static var titleWidth: CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    static var width: CGFloat {
        horizontalPadding * 2 + dotSize + dotTextGap + titleWidth
    }

    private let dot = NSView()
    private let label = NSTextField(labelWithString: RecordPill.title)

    init(height: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemRed.cgColor

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.white.cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.frame = CGRect(
            x: Self.horizontalPadding,
            y: ((height - Self.dotSize) / 2).rounded(),
            width: Self.dotSize, height: Self.dotSize)
        addSubview(dot)

        label.font = Self.font
        label.textColor = .white
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(
            x: Self.horizontalPadding + Self.dotSize + Self.dotTextGap,
            y: ((height - label.frame.height) / 2).rounded()))
        addSubview(label)

        toolTip = "Start recording  ⏎"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The two subviews are decoration; the pill owns the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.systemRed.blended(withFraction: 0.2, of: .black)?.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.systemRed.cgColor
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
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

    private static let margin: CGFloat = 8
    private static let toggleWidth: CGFloat = 30
    private static let chevronWidth: CGFloat = 14
    private static let controlHeight: CGFloat = 28
    private static let gap: CGFloat = 6
    private static let groupGap: CGFloat = 8
    private static let height: CGFloat = 40
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
    private var pill: RecordPill!

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
        background = NSVisualEffectView(frame: bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        addSubview(background)

        microphoneButton = button(action: #selector(toggleMicrophone))
        addSubview(microphoneButton)

        // A separate hit target rather than a long-press or a right-click: the
        // overlay owns the keyboard and the pointer during a selection, so a
        // gesture that takes time to recognise competes with the drag the user
        // may be about to restart.
        deviceButton = button(action: #selector(showDeviceMenu))
        deviceButton.image = Self.symbol("chevron.down", pointSize: 8)
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

        pill = RecordPill(height: Self.controlHeight)
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

    private static func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    /// Redraws both toggles from the preferences they write to, then re-lays out
    /// — the device name changes the bar's width.
    func refresh() {
        let granted = MicrophonePermission.isGranted
        let micOn = granted && preferences.recordingMicrophone
        microphoneButton.image = Self.symbol(micOn ? "mic.fill" : "mic.slash.fill", pointSize: 13)
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
        audioButton.image = Self.symbol(
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

        pill.frame = CGRect(x: x, y: y, width: RecordPill.width, height: Self.controlHeight)
        x += RecordPill.width + Self.margin

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
        let gap: CGFloat = 10
        let visible = anchor.screen.visibleFrame

        var origin = CGPoint(
            x: anchor.selection.midX - size.width / 2,
            y: anchor.selection.minY - gap - size.height)
        if origin.y < visible.minY + 8 {
            origin.y = anchor.selection.maxY + gap
        }
        // Still off? The selection is taller than the screen's usable height, so
        // put the bar inside it rather than off-screen entirely.
        if origin.y + size.height > visible.maxY - 8 {
            origin.y = max(visible.minY + 8, anchor.selection.minY + gap)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
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
