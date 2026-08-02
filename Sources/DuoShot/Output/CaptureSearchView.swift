import AppKit
import Observation
import SwiftUI

/// The model behind "Search Captures…".
///
/// Follows `AllLinksModel`: one search in flight at a time, and the previous
/// answer stays on screen while the next one runs rather than being replaced by
/// a spinner. The difference is that this one is answering from a local file, so
/// the wait is milliseconds and the flicker would be the only thing anybody
/// noticed about it.
@Observable
@MainActor
final class CaptureSearchModel {
    var query = "" {
        didSet { if query != oldValue { run() } }
    }
    private(set) var hits: [CaptureIndex.Hit] = []
    private(set) var hasSearched = false
    private(set) var indexed = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Bumped per search so an answer that arrives after a newer one has already
    /// landed is dropped. Typing is faster than the disk, and without this the
    /// list settles on whichever query happened to finish last.
    @ObservationIgnored private var generation = 0

    func refresh() {
        Task {
            await CaptureIndex.shared.forgetMissingFiles()
            indexed = await CaptureIndex.shared.count
            run()
        }
    }

    private func run() {
        generation += 1
        let token = generation
        let query = query
        task?.cancel()
        task = Task {
            let found = await CaptureIndex.shared.search(query)
            guard !Task.isCancelled, token == self.generation else { return }
            self.hits = found
            self.hasSearched = true
        }
    }
}

struct CaptureSearchView: View {
    @Bindable var model: CaptureSearchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a capture by what was written in it", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if model.hits.isEmpty {
                let title: String = model.query.isEmpty
                    ? "Nothing indexed yet"
                    : "No capture said that"
                let detail: String = model.query.isEmpty
                    ? "Captures are read and indexed as they are taken."
                    : "Only captures taken since indexing began are searchable."
                ContentUnavailableView {
                    Label { Text(title) } icon: { Image(systemName: "text.magnifyingglass") }
                } description: {
                    Text(detail)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(model.hits, id: \.url) { hit in
                    row(hit)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(hit) }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(model.indexed) capture\(model.indexed == 1 ? "" : "s") indexed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Double-click to open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 460, minHeight: 320)
        .onAppear { model.refresh() }
    }

    private func row(_ hit: CaptureIndex.Hit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.name).lineLimit(1)
                Spacer()
                Text(hit.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Opens in DuoShot's own viewer rather than in Preview, because everything
    /// the viewer offers -- redact, copy text, annotate -- is the reason
    /// somebody went looking for an old capture in the first place.
    private func open(_ hit: CaptureIndex.Hit) {
        // A zero point size and an empty thumbnail, because neither is read on
        // this path: the viewer decodes the file itself and the thumbnail is the
        // preview card's business, not the window's.
        ViewerWindowController.shared.show(PreviewEntry(
            kind: .image(pointSize: .zero),
            thumbnail: NSImage(size: PreviewCardView.cardSize),
            url: hit.url, sourceDisplayID: CGMainDisplayID()))
    }
}
