import Foundation
import Linkdrop
import Observation

/// The last few links, for the menu bar.
///
/// Exists because an upload outlives the card that started it. A preview card
/// times out after six seconds and a recording can take a minute to upload, so
/// without somewhere for the link to land, finishing after the card is gone
/// would mean the link only ever existed on the clipboard -- and one ⌘C
/// elsewhere would lose it for good.
@Observable
@MainActor
final class ShareHistory {
    static let shared = ShareHistory()

    struct Entry: Codable, Identifiable, Sendable {
        let link: LinkdropLink
        let name: String
        let uploadedAt: Date
        var id: String { link.key }
    }

    private static let maximum = 10
    private static let storageKey = "share.history.v1"

    @ObservationIgnored private let defaults = UserDefaults.standard

    private(set) var entries: [Entry] = []

    private init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func record(_ link: LinkdropLink, name: String) {
        entries.removeAll { $0.link.key == link.key }
        entries.insert(Entry(link: link, name: name, uploadedAt: .now), at: 0)
        if entries.count > Self.maximum { entries.removeLast(entries.count - Self.maximum) }
        persist()
    }

    /// Only forgets the link locally. Deleting the upload itself is
    /// `ShareUploader.delete(key:from:)` -- and the menu has to offer that
    /// separately, because "remove from this list" and "make the link stop
    /// working" are the two things a user could mean and they are not the same.
    func forget(_ key: String) {
        entries.removeAll { $0.link.key == key }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.storageKey)
    }
}
