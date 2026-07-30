import AppKit
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

struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences

    @State private var draftFilenameTemplate: String = ""
    @FocusState private var filenameFieldFocused: Bool

    var body: some View {
        Form {
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
            }

            Section("After capture") {
                Toggle("Save to disk", isOn: $preferences.saveToDisk)
                Toggle("Copy to clipboard", isOn: $preferences.copyToClipboard)
                Toggle("Play shutter sound", isOn: $preferences.playsSound)
            }

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

            Section {
                Toggle("Show menu bar icon", isOn: $preferences.showsMenuBarIcon)
                    .onChange(of: preferences.showsMenuBarIcon) { _, _ in
                        preferences.onMenuBarIconChanged?()
                    }
                Toggle("Launch at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { preferences.launchAtLogin = $0 }
                ))
            } footer: {
                Text(preferences.launchAtLoginStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                    if let newCombo {
                                        preferences.hotkeys[action] = newCombo
                                    } else {
                                        preferences.hotkeys.removeValue(forKey: action)
                                    }
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
        }
        .formStyle(.grouped)
    }
}
