import AppKit
import Linkdrop
import SwiftUI

/// What the All Links window is looking at.
///
/// The server is the source of truth here, and nothing about this list is
/// derived from `ShareHistory`: a link uploaded from another Mac, or before this
/// build kept a history at all, exists on the server and has to appear. What the
/// two do share is `ShareService.revoke`, so a row deleted here also leaves the
/// menu's Recent Links.
@Observable
@MainActor
final class AllLinksModel {
    /// Far above the ten the menu shows and at the service's own ceiling for one
    /// page. A window with a scroller is the right place for the long list, and
    /// paging a screenshot bucket would be UI for a problem nobody has.
    static let limit = 200

    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var items: [LinkdropItem] = []
    /// The server walked as much of the bucket as it was willing to, so these
    /// are the newest of what it saw rather than everything there is.
    private(set) var truncated = false

    /// Keys whose delete is in flight, so a row cannot be revoked twice while
    /// the first request is still out.
    private(set) var deleting: Set<String> = []

    /// The refresh in flight. One at a time: the refresh control and the window
    /// opening can both fire within a frame of each other, and two answers
    /// landing in either order would make the list flicker between them.
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh() {
        guard task == nil else { return }
        state = .loading
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                let listing = try await ShareService.shared.allLinks(limit: Self.limit)
                guard let self else { return }
                items = listing.items
                truncated = listing.truncated
                state = .loaded
            } catch {
                self?.state = .failed(LinkdropError.from(error).message)
            }
        }
    }

    /// Revokes server-side first and only then takes the row away.
    ///
    /// No confirmation, deliberately: the menu's ⌥-delete already treats a
    /// revoke as a small deliberate action, and a sheet here would make the same
    /// operation feel like two different ones depending on where it was started.
    /// The failure is audible rather than silent — `ShareService.revoke` beeps —
    /// and the row staying put is the other half of that message.
    func delete(_ item: LinkdropItem) {
        guard !deleting.contains(item.key) else { return }
        deleting.insert(item.key)
        Task { [weak self] in
            let revoked = await ShareService.shared.revoke(item.key)
            guard let self else { return }
            deleting.remove(item.key)
            if revoked { items.removeAll { $0.key == item.key } }
        }
    }

    /// A listing row carries everything a link does except the guarantee that
    /// the bytes have an address: a sidecar with no extension cannot name one.
    /// Such a row is never an image embed, so falling back to the page URL is
    /// only ever the target `write(markdown:)` would have picked anyway.
    func copy(_ item: LinkdropItem) {
        let link = LinkdropLink(
            key: item.key, pageURL: item.pageURL, fileURL: item.fileURL ?? item.pageURL)
        ShareService.copy(link, name: item.name, isImage: item.kind == .image
            && item.fileURL != nil)
    }

    func openPage(_ item: LinkdropItem) {
        NSWorkspace.shared.open(item.pageURL)
    }
}

/// The list itself.
///
/// Rows are the server's, so there is nothing to edit and no selection to act
/// on: each row carries its own three verbs, which is what keeps "copy this one"
/// a single click rather than a click and then a menu.
struct AllLinksView: View {
    /// Not `@Bindable`: nothing in this window edits the model, it only asks it
    /// for things. Observation still redraws the list when the model changes.
    let model: AllLinksModel

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 260)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.items.isEmpty:
            centred { ProgressView() }
        case .failed(let message):
            centred {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    // The sentence `LinkdropError` went to the trouble of
                    // writing, not a code.
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }
        case .loaded where model.items.isEmpty:
            centred {
                Text("No links on the server.")
                    .foregroundStyle(.secondary)
            }
        case .loading, .loaded:
            // The old rows stay up during a refresh rather than being replaced
            // by a spinner: a list that empties itself on every refresh reads as
            // the links having gone away.
            List(model.items) { item in
                row(for: item)
            }
            .listStyle(.inset)
        }
    }

    private func row(for item: LinkdropItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: item.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name.isEmpty ? item.key : item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relativeDate(item.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.copy(item) } label: { Image(systemName: "link") }
                .help("Copy Link")
            Button { model.openPage(item) } label: { Image(systemName: "safari") }
                .help("Open Page")
            Button { model.delete(item) } label: { Image(systemName: "trash") }
                .help("Delete from the server. The link stops working for everyone.")
                .disabled(model.deleting.contains(item.key))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack {
            if model.truncated {
                Text("The server has more links than it will list at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { model.refresh() }
                .disabled(model.state == .loading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func centred(@ViewBuilder _ body: () -> some View) -> some View {
        VStack { body() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `distantPast` is what a sidecar with an unreadable date leaves behind, and
    /// "56 years ago" would read as a fact about the upload rather than as the
    /// absence of one.
    private func relativeDate(_ date: Date) -> String {
        guard date > .distantPast else { return "Date unknown" }
        return date.formatted(.relative(presentation: .named))
    }

    private func symbol(for kind: LinkdropDescriptor.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .file: "doc"
        }
    }
}
