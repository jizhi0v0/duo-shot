import Linkdrop
import SwiftUI

/// The one settings tab where a switch means "captures leave this machine".
///
/// Written to be read, not just filled in: the auto-upload footers say what
/// turning them on actually does, because "Upload screenshots automatically" on
/// its own reads like a convenience rather than a standing decision to publish
/// every screenshot to a URL.
struct ShareSettingsView: View {
    @Bindable var settings: ShareSettings

    /// Not bound to any store. The Keychain is not observable, and a `SecureField`
    /// wants somewhere to type; this is the buffer between the two.
    @State private var token: String = ""
    @State private var status: Status = .idle
    @State private var isTesting = false

    private enum Status: Equatable {
        case idle
        case ok
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Endpoint", text: $settings.endpointString, prompt: Text("s.example.com"))
                    .textContentType(.URL)
                SecureField("Upload token", text: $token)
                    .onSubmit(saveToken)
                HStack {
                    Button(isTesting ? "Testing…" : "Test connection", action: test)
                        .disabled(isTesting || settings.endpointString.isEmpty || token.isEmpty)
                    Spacer()
                    statusLabel
                }
            } header: {
                Text("Server")
            } footer: {
                // This footer used to promise iCloud Keychain sync. It was
                // wrong: a Developer ID app without the App Sandbox or an
                // application-identifier entitlement cannot write a
                // synchronizable item at all (-34018, measured). The token is
                // stored locally and has to be entered on each Mac, and saying
                // so is better than a promise the build cannot keep.
                Text("Your own Cloudflare Worker and R2 bucket — see Worker/README.md. "
                     + "The token is kept in this Mac's Keychain; enter it once per Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Screenshots", isOn: $settings.autoUploadScreenshots)
                Toggle("Recordings", isOn: $settings.autoUploadRecordings)
            } header: {
                Text("Upload automatically")
            } footer: {
                Text("Off, every capture stays on this Mac until you press the link "
                     + "button on its preview card. On, every capture of that kind is "
                     + "uploaded the moment it is taken.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Put the link on the clipboard", isOn: $settings.linkToClipboard)
                Toggle("Expire recordings", isOn: $settings.ephemeralRecordings)
                Toggle("Expire screenshots", isOn: $settings.ephemeralScreenshots)
            } header: {
                Text("After uploading")
            } footer: {
                Text("Expiring uploads are deleted by your bucket's lifecycle rule — "
                     + "30 days unless you changed it. Recordings default to expiring "
                     + "because a handful of them fills the free 10 GB; screenshots do not.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { token = ShareService.credentials.load() ?? "" }
        .onChange(of: token) { _, _ in
            status = .idle
            saveToken()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            // The sentence, not a code. `LinkdropError` exists to produce it.
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func saveToken() {
        ShareService.credentials.save(token)
    }

    private func test() {
        guard let endpoint = LinkdropEndpoint(base: settings.endpointString, token: token) else {
            status = .failed("That endpoint is not a usable https address.")
            return
        }
        isTesting = true
        Task {
            let failure = await ShareService.shared.probe(endpoint)
            isTesting = false
            status = failure.map(Status.failed) ?? .ok
        }
    }
}
