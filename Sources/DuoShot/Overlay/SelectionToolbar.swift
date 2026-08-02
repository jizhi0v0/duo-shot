import AppKit

/// Microphone, its input device, system audio, and the button that starts the
/// take.
///
/// One of the two faces of `FloatingBarPanel` — it holds controls and nothing
/// else. The glass, the level and the placement belong to the window, which
/// outlives this view: pressing Record swaps this face for the recording one
/// inside the same bar.
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

    /// What the armed selection is *for*, which decides the bar's controls.
    /// `.scroll` is only the start pill: a scrolling capture has no audio to
    /// configure, and the absent controls are genuinely absent — a hidden
    /// control still hit-tests, which is how a hidden pill once ate the click
    /// meant for the one beside it.
    enum Style {
        case record
        case scroll

        var pillTitle: String {
            switch self {
            case .record: "Record"
            case .scroll: "Start"
            }
        }

        var pillTint: NSColor {
            switch self {
            case .record: .systemRed
            case .scroll: .systemBlue
            }
        }

        var pillToolTip: String {
            switch self {
            case .record: "Start recording  ⏎"
            case .scroll: "Start the scrolling capture  ⏎"
            }
        }
    }

    private static let margin = HUDMetrics.margin
    private static let toggleWidth = HUDMetrics.iconWidth
    private static let chevronWidth: CGFloat = 14
    private static let controlHeight = HUDMetrics.controlHeight
    private static let gap: CGFloat = 6
    private static let groupGap = HUDMetrics.groupGap
    private static let height = HUDMetrics.height
    private static let deviceFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    /// The device name is elided past this. "MacBook Pro Microphone" is already
    /// long, and a USB interface's name can be far longer — the bar has to stay
    /// something that fits under a selection.
    private static let deviceMaxWidth: CGFloat = 132

    private let style: Style
    private var callbacks: Callbacks
    private var microphoneButton: NSButton!
    private var deviceButton: NSButton!
    private var deviceLabel: NSTextField!
    private var audioButton: NSButton!
    private var divider: NSView!
    private var pill: HUDPill!

    private var preferences: Preferences { .shared }

    init(callbacks: Callbacks, style: Style = .record) {
        self.style = style
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
        if style == .scroll {
            pill = HUDPill(title: style.pillTitle, mark: .dot, tint: style.pillTint)
            pill.toolTip = style.pillToolTip
            pill.onClick = { [weak self] in self?.callbacks.start() }
            addSubview(pill)
            return
        }

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

        pill = HUDPill(title: style.pillTitle, mark: .dot, tint: style.pillTint)
        pill.toolTip = style.pillToolTip
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
        if style == .scroll {
            layoutControls()
            return
        }

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

        if style == .scroll {
            let pillWidth = HUDPill.width(for: style.pillTitle)
            pill.frame = CGRect(x: x, y: y, width: pillWidth, height: Self.controlHeight)
            x += pillWidth + Self.margin
            let size = CGSize(width: x.rounded(.up), height: Self.height)
            if frame.size != size {
                setFrameSize(size)
                callbacks.resized()
            }
            return
        }

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

        let pillWidth = HUDPill.width(for: style.pillTitle)
        pill.frame = CGRect(x: x, y: y, width: pillWidth, height: Self.controlHeight)
        x += pillWidth + Self.margin

        let size = CGSize(width: x.rounded(.up), height: Self.height)
        if frame.size != size {
            setFrameSize(size)
            callbacks.resized()
        }
    }

    /// Goes inert on the way out: Record stops being a red button the instant it
    /// has been pressed.
    ///
    /// Not just feedback for the press. The HUD arrives underneath this bar with
    /// its own Stop already grey, and a scarlet Record fading out over it was the
    /// one frame of the hand-over where the eye could still see two different
    /// bars. Both ends of the dissolve are the same colour now.
    func goInert() {
        pill.setLive(false, animated: false)
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

/// Owns the bar for the length of one armed selection — and only that long.
///
/// The window itself can outlive the selection: `handOver()` gives it to the
/// recording, which re-levels it and swaps its face. That is the whole reason
/// this class does not own an `NSPanel` subclass of its own any more.
@MainActor
final class SelectionToolbar {
    private var panel: FloatingBarPanel?
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
    /// `hiddenFromCapture` is decided per presentation by `OverlayController`,
    /// and so is `style` — the bar for a recording and the bar for a scrolling
    /// capture differ only in their controls, not their window.
    func show(
        under selection: CGRect, on screen: NSScreen, hiddenFromCapture: Bool = true,
        style: SelectionToolbarView.Style = .record
    ) {
        if panel == nil {
            var callbacks = SelectionToolbarView.Callbacks()
            callbacks.start = { [weak self] in self?.onStart() }
            callbacks.resized = { [weak self] in self?.applySize() }
            let view = SelectionToolbarView(callbacks: callbacks, style: style)
            let created = FloatingBarPanel(
                role: .selection, size: view.frame.size,
                hiddenFromCapture: hiddenFromCapture)
            created.setFace(view, animated: false)
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
        panel.morph(to: CGRect(origin: origin, size: size), animated: false)
    }

    /// Gives the bar to whoever comes next, still on screen.
    ///
    /// The one exit that is not a dismissal: pressing Record does not end this
    /// bar, it changes what it is for. The caller is responsible for the window
    /// from here — nothing in this class will take it down again.
    ///
    /// Record goes inert on the way out. Not just feedback for the press: the
    /// recording face arrives with its own Stop already grey, and a scarlet
    /// Record dissolving into it is the one frame where the eye can still see
    /// two different bars.
    func handOver() -> FloatingBarPanel? {
        guard let panel else { return nil }
        view?.goInert()
        self.panel = nil
        self.view = nil
        anchor = nil
        return panel
    }

    func hide() {
        guard let panel else { return }
        view?.goInert()
        self.panel = nil
        self.view = nil
        anchor = nil
        panel.dismiss()
    }

    var frameForTest: CGRect? { panel?.frame }
}
