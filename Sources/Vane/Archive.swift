import AppKit
import SwiftUI

extension Prefs {
    /// Arc's Auto Archive. A Today tab nobody has looked at for this long is archived: it
    /// leaves the sidebar, and stays reachable from the Library. Arc's default is 12 hours,
    /// with 24 hours, 7 days and 30 days offered beside it; 0 is "never", which is a real
    /// answer and so is stored rather than falling back to the default.
    static var archiveAfter: TimeInterval {
        get { UserDefaults.standard.object(forKey: "archiveAfter") as? Double ?? 12 * 3600 }
        set { UserDefaults.standard.set(newValue, forKey: "archiveAfter") }
    }

    /// What the setting offers, in Arc's order. ponytail: a fixed list, not a duration
    /// field — "13 hours" is not a thing anyone wants, and a free field needs parsing,
    /// validation and a unit picker to say the same four things.
    static let archiveChoices: [(name: String, after: TimeInterval)] = [
        ("After 12 hours", 12 * 3600),
        ("After 24 hours", 24 * 3600),
        ("After 7 days", 7 * 86_400),
        ("After 30 days", 30 * 86_400),
        ("Never", 0),
    ]
}

/// Arc's archive: where a Today tab goes when it is closed or auto-archived, so closing a
/// tab is never destructive. Favourites and pinned tabs never come here — they stay in the
/// sidebar, which is the whole point of them.
///
/// ponytail: a capped list of url/title/date in UserDefaults, one per profile, not a table
/// in the history database. Two hundred entries is ~30 KB, the only queries are "newest
/// first" and "drop this one", and history already records every one of these pages
/// anyway — the archive's job is to remember that the tab *was open*, not to be a second
/// history. Ceiling: no full-text search over it, and no per-space archive.
@MainActor final class Archive: ObservableObject {
    /// One archived tab. Identified by url, so re-archiving the same page moves the
    /// existing entry to the top instead of listing it twice.
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var url: String
        var title: String
        var at: Date
        var id: String { url }
    }

    /// Older entries fall off the end. Arc keeps everything; two hundred is where a list
    /// nobody scrolls stops being worth the bytes.
    static let limit = 200

    private static var caches: [UUID: Archive] = [:]
    static func shared(for profileID: UUID) -> Archive {
        if let a = caches[profileID] { return a }
        let a = Archive(profileID: profileID)
        caches[profileID] = a
        return a
    }

    private let profileID: UUID
    @Published private(set) var entries: [Entry] = []

    private init(profileID: UUID) {
        self.profileID = profileID
        let key = ProfileManager.defaultsKey("archivedTabs", profileID)
        entries = (UserDefaults.standard.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: ProfileManager.defaultsKey("archivedTabs", profileID))
    }

    func add(url: URL, title: String, at: Date = .now) {
        entries = Archive.merged(entries, adding: Entry(url: url.absoluteString,
                                                        title: title.isEmpty ? url.absoluteString : title,
                                                        at: at),
                                 limit: Archive.limit)
        save()
    }

    /// Taking a tab back out: the entry goes, because it is open again.
    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    // MARK: The rules, as pure functions

    /// Newest first, one entry per url, capped. Pure so `selfcheck --pure` can drive it.
    nonisolated static func merged(_ existing: [Entry], adding new: Entry, limit: Int) -> [Entry] {
        var out = existing.filter { $0.url != new.url }
        out.insert(new, at: 0)
        return Array(out.prefix(limit))
    }

    /// Whether the auto-archive sweep takes this tab. Only Today tabs, only idle ones, never
    /// the tab someone is looking at, and never a tab with nothing loaded — an empty tab has
    /// no page to remember, so archiving it would silently delete it.
    /// `after` of 0 or less is "never".
    nonisolated static func due(kind: TabKind, idle: TimeInterval, after: TimeInterval,
                                active: Bool, loaded: Bool) -> Bool {
        guard after > 0, kind == .today, loaded, !active else { return false }
        return idle >= after
    }

    // MARK: Running

    /// Called off `Suspension`'s one timer — see `Suspension.begin`. A minute of slop on a
    /// twelve-hour rule is not worth a second timer.
    static func sweep(now: Date = .now) {
        let after = Prefs.archiveAfter
        guard after > 0 else { return }
        for store in TabStore.all where !store.isPrivate {
            let active = store.current
            for tab in store.tabs where due(kind: tab.kind,
                                            idle: now.timeIntervalSince(tab.lastActive),
                                            after: after,
                                            active: tab.id == active,
                                            loaded: tab.currentURL != nil) {
                store.archive(tab.id)
            }
        }
    }

    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let t0 = Date(timeIntervalSince1970: 0)
        let a = Entry(url: "https://a.example", title: "A", at: t0)
        let b = Entry(url: "https://b.example", title: "B", at: t0)
        out.append(("archiving puts the newest entry first",
                    merged([a], adding: b, limit: 10).map(\.url) == [b.url, a.url]))
        var again = a; again.title = "A again"
        out.append(("re-archiving a url moves it to the top instead of listing it twice",
                    merged([a, b], adding: again, limit: 10) == [again, b]))
        out.append(("the list is capped, oldest off the end",
                    merged([a, b], adding: Entry(url: "https://c.example", title: "C", at: t0),
                           limit: 2).count == 2))

        let hour: TimeInterval = 3600
        out.append(("an idle Today tab is due after the interval",
                    due(kind: .today, idle: 13 * hour, after: 12 * hour, active: false, loaded: true)))
        out.append(("a Today tab inside the interval is not",
                    !due(kind: .today, idle: 11 * hour, after: 12 * hour, active: false, loaded: true)))
        out.append(("a pinned tab never auto-archives",
                    !due(kind: .pinned, idle: 400 * hour, after: 12 * hour, active: false, loaded: true)))
        out.append(("a favourite never auto-archives",
                    !due(kind: .favourite, idle: 400 * hour, after: 12 * hour, active: false, loaded: true)))
        out.append(("the tab being looked at never auto-archives",
                    !due(kind: .today, idle: 400 * hour, after: 12 * hour, active: true, loaded: true)))
        out.append(("a tab with nothing loaded is not archived out from under the user",
                    !due(kind: .today, idle: 400 * hour, after: 12 * hour, active: false, loaded: false)))
        out.append(("\"Never\" means never",
                    !due(kind: .today, idle: 4000 * hour, after: 0, active: false, loaded: true)))
        out.append(("every offered interval but Never is a real duration",
                    Prefs.archiveChoices.filter { $0.after > 0 }.count == 4
                        && Prefs.archiveChoices.last?.after == 0))
        return out
    }
}
