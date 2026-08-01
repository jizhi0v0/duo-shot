import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// The only SwiftUI in the project. Everything latency- or pixel-critical is
// AppKit; a settings form is neither.
//
// Split into one view per tab because the window is an `NSTabViewController`
// with the toolbar style rather than a SwiftUI `TabView`. A SwiftUI TabView
// renders as a segmented control floating inside the content area, which is not
// what a macOS settings window looks like — the real thing is a toolbar with
// icon-over-label items and a window that resizes as you switch tabs.

// MARK: - General

/// The app itself: how it shows up, and the one piece of capture feedback that
/// belongs to the app rather than to the image.
struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show menu bar icon", isOn: $preferences.showsMenuBarIcon)
                    .onChange(of: preferences.showsMenuBarIcon) { _, _ in
                        preferences.onMenuBarIconChanged?()
                    }
                // Reads through the mirrored status, so the setter's effect is
                // observable and the switch actually settles on what the system
                // now reports.
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                if preferences.launchAtLoginStatus == .requiresApproval {
                    Button("Open Login Items…") { preferences.openLoginItemsSettings() }
                }
            } footer: {
                Text(preferences.launchAtLoginStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play shutter sound", isOn: $preferences.playsSound)
            } footer: {
                Text("DuoShot has no Dock icon. With the menu bar icon hidden, the keyboard shortcuts are the only way to reach it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the selection UI to screen sharing",
                       isOn: $preferences.overlayVisibleToScreenSharing)
            } header: {
                Text("Screen sharing")
            } footer: {
                Text("""
                    Off, the dimming, the selection outline and the recording toolbar are invisible to every kind of screen capture — including the one a remote-desktop app uses to send you the screen, which leaves you selecting an area you cannot see.

                    On, they become visible to it, and to anything else recording your screen. DuoShot's own screenshots still leave them out. They are hidden again for the length of a recording, where they could not be excluded from the video.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Approving a login item — or switching it back off — happens in System
        // Settings, so the only moment we can be sure the mirrored status is
        // stale is when the app comes back to the front.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            preferences.refreshLaunchAtLoginStatus()
        }
    }
}

// MARK: - Saving

/// Where a capture ends up: the two destinations, the folder and the filename.
struct SavingSettingsView: View {
    @Bindable var preferences: Preferences

    @State private var draftFilenameTemplate: String = ""
    @FocusState private var filenameFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Save to disk", isOn: $preferences.saveToDisk)
                Toggle("Copy to clipboard", isOn: $preferences.copyToClipboard)
            } header: {
                Text("After capture")
            } footer: {
                Text("Both apply to every mode — area, window and fullscreen alike.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Text(preferences.saveDirectory.lastPathComponent)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseSaveDirectory)
                            .controlSize(.small)
                    }
                }
                .help(preferences.saveDirectoryPath)
                .disabled(!preferences.saveToDisk)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Filename")
                    FilenameTemplateEditor(template: $preferences.filenameTemplate)
                    Text(FilenameFormatter.preview(
                        template: preferences.filenameTemplate,
                        contentType: preferences.imageFormat))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // The escape hatch for anyone who would rather type the
                    // template than assemble it. Still committed on Return or on
                    // losing focus, never per keystroke: a direct binding
                    // persists half-typed templates and names real captures with
                    // them — observed in the wild as files called "in.png".
                    DisclosureGroup("Edit as text") {
                        TextField("", text: $draftFilenameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($filenameFieldFocused)
                            .onSubmit(commitFilenameTemplate)
                            .onChange(of: filenameFieldFocused) { _, isFocused in
                                if !isFocused { commitFilenameTemplate() }
                            }
                            .help("%Y year · %m month · %d day · %H hour · %M minute · %S second")
                            .padding(.top, 4)
                    }
                    .font(.caption)
                    .onChange(of: preferences.filenameTemplate) { _, new in
                        // Keep the text field in step with the chips above it.
                        if !filenameFieldFocused { draftFilenameTemplate = new }
                    }
                    .onAppear { draftFilenameTemplate = preferences.filenameTemplate }
                }
                // NOT disabled with "Save to disk": the template also names the
                // staged file, which is what a drag-out or a Finder reveal from
                // the floating preview hands over.
            }
        }
        .formStyle(.grouped)
    }

    /// Refuses to persist a template that would produce an empty filename,
    /// falling back to what was there rather than silently keeping junk.
    private func commitFilenameTemplate() {
        let trimmed = draftFilenameTemplate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            draftFilenameTemplate = preferences.filenameTemplate
            return
        }
        preferences.filenameTemplate = trimmed
        draftFilenameTemplate = trimmed
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.saveDirectory
        panel.prompt = "Choose"
        // Non-sandboxed, so the plain path is enough — no security-scoped
        // bookmark to create, store or resolve.
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveDirectory = url
        }
    }
}

// MARK: - Preview

struct PreviewSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show after capture", isOn: $preferences.showsPreviewOverlay)
                Picker("Position", selection: $preferences.previewCorner) {
                    ForEach(PreviewCorner.allCases, id: \.self) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                .disabled(!preferences.showsPreviewOverlay)
                LabeledContent("Dismiss after") {
                    HStack(spacing: 8) {
                        Slider(value: $preferences.previewTimeout, in: 2...30, step: 1)
                        Text("\(Int(preferences.previewTimeout))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                .disabled(!preferences.showsPreviewOverlay)
            } header: {
                Text("Floating preview")
            } footer: {
                Text("Hovering the stack pauses the countdown. Drag a card toward the screen edge to throw it away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Bindable var preferences: Preferences
    var onHotkeysChanged: () -> Void
    var onRecordingChanged: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    let combo = preferences.hotkeys[action]
                    LabeledContent(action.title) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ShortcutRecorder(
                                combo: combo,
                                onRecord: { newCombo in
                                    // `bind` rather than a write into `hotkeys`:
                                    // a combo another action already holds is
                                    // taken off it, so the two can never both
                                    // claim it. The row above or below goes
                                    // blank, which is the whole point — the
                                    // alternative is a binding that looks set
                                    // and never fires.
                                    preferences.bind(newCombo, to: action)
                                    onHotkeysChanged()
                                },
                                onRecordingChanged: onRecordingChanged
                            )
                            .frame(width: 132, height: 22)

                            if let combo,
                               let owner = SystemHotKeyProbe.systemBinding(matching: combo) {
                                // RegisterEventHotKey succeeds for a combo the
                                // system owns and then never fires, so this
                                // warning is the only signal the user gets.
                                Label("macOS uses this for \(owner)",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } footer: {
                Text("Click to record · ⌫ clears · ⎋ cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Keyboard Shortcuts Settings…") {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                    else { return }
                    NSWorkspace.shared.open(url)
                }
            } footer: {
                Text("DuoShot never changes the system's own ⌘⇧3/4/5 bindings. Turn them off there if you want DuoShot to take them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

/// The recording counterpart to Capture — and the only place the microphone
/// grant can be asked for.
///
/// `RecordingEngine` refuses to hand ScreenCaptureKit an undecided grant
/// (`startCapture` hangs forever on one) and drops narration instead, so if the
/// prompt were never raised here the toggle would be a switch that quietly does
/// nothing. It is raised from this view because the app is frontmost here, which
/// is what makes TCC address the dialog to DuoShot rather than to whatever
/// process it holds responsible.
struct RecordingSettingsView: View {
    @Bindable var preferences: Preferences

    /// Mirrored rather than read inline so the view redraws when the answer
    /// arrives — and re-read on activation, because revoking the grant happens
    /// over in System Settings where nothing notifies us.
    @State private var microphoneStatus = MicrophonePermission.status
    /// Re-enumerated on the same signal as the grant. Devices come and go while
    /// this window is open — plugging in headphones is exactly the moment
    /// someone opens it — and nothing pushes that at us.
    @State private var devices = AudioInputDevices.all

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $preferences.recordingFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Include the pointer", isOn: $preferences.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $preferences.recordingShowsClicks)
            } footer: {
                Text("The frame rate is a ceiling, not a promise: ScreenCaptureKit sends a frame when the screen changes, so a still screen costs nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Record system audio", isOn: $preferences.recordingSystemAudio)
                Toggle("Record microphone", isOn: $preferences.recordingMicrophone)
                    .onChange(of: preferences.recordingMicrophone) { _, isOn in
                        guard isOn else { return }
                        Task { await resolveMicrophoneGrant() }
                    }
                Picker("Input", selection: $preferences.recordingMicrophoneDeviceID) {
                    Text("System default").tag(AudioInputDevices.systemDefaultID)
                    Divider()
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                    // A device chosen earlier and since unplugged still has to
                    // have a row, or SwiftUI shows the picker blank and the
                    // stored preference reads as corrupt rather than as absent.
                    if !preferences.recordingMicrophoneDeviceID.isEmpty,
                       !devices.contains(where: { $0.id == preferences.recordingMicrophoneDeviceID }) {
                        Text("Unavailable device")
                            .tag(preferences.recordingMicrophoneDeviceID)
                    }
                }
                .disabled(!preferences.recordingMicrophone)

                if microphoneStatus == .denied || microphoneStatus == .restricted {
                    Button("Open Microphone Settings…", action: openMicrophoneSettings)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text(audioFooter)
                    .font(.caption)
                    .foregroundStyle(microphoneStatus == .denied ? .orange : .secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            microphoneStatus = MicrophonePermission.status
            devices = AudioInputDevices.all
        }
        .onAppear { devices = AudioInputDevices.all }
    }

    private var audioFooter: String {
        switch microphoneStatus {
        case .denied:
            "The microphone is turned off for DuoShot in System Settings, so narration would be dropped from the take."
        case .restricted:
            "Microphone access is restricted on this Mac, so narration is unavailable."
        default:
            "System audio is the whole system mix, so it has no device to choose. “System default” follows the input macOS is using, which is what you want as headphones come and go."
        }
    }

    /// Raises the prompt, then makes the switch tell the truth.
    ///
    /// A denied grant cannot be re-prompted — only System Settings can change it
    /// — so leaving the toggle on would promise narration that the engine then
    /// silently drops. Better a switch that snaps back with a reason next to it.
    private func resolveMicrophoneGrant() async {
        _ = await MicrophonePermission.request()
        microphoneStatus = MicrophonePermission.status
        if microphoneStatus != .authorized {
            preferences.recordingMicrophone = false
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Capture

struct CaptureSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $preferences.imageFormatIdentifier) {
                    Text("PNG").tag(UTType.png.identifier)
                    Text("JPEG").tag(UTType.jpeg.identifier)
                    Text("HEIC").tag(UTType.heic.identifier)
                }
                if preferences.imageFormat != .png {
                    LabeledContent("Quality") {
                        HStack(spacing: 8) {
                            Slider(value: $preferences.jpegQuality, in: 0.3...1, step: 0.05)
                            Text("\(Int(preferences.jpegQuality * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text("Captures are saved at the display's full pixel density and tagged with the matching DPI, so they paste at their true size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include the pointer", isOn: $preferences.showsCursor)
                Toggle("Include the menu bar in fullscreen captures",
                       isOn: $preferences.includeMenuBar)
            }

            Section {
                Toggle("Include attached sheets and panels",
                       isOn: $preferences.includeChildWindows)
                LabeledContent("Padding") {
                    HStack(spacing: 8) {
                        Slider(value: $preferences.windowPadding, in: 0...96, step: 4)
                        Text(preferences.windowPadding == 0
                             ? "Off" : "\(Int(preferences.windowPadding))pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            } header: {
                Text("Window captures")
            } footer: {
                Text("""
                    Off, a window capture is exactly the window you picked. On, it is the whole window group — so picking an alert also brings in the window behind it.

                    Padding adds a margin filled with the desktop wallpaper. Area and fullscreen captures are unaffected; they have a backdrop already.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
