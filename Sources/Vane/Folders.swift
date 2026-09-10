import SwiftUI

/// A folder in Arc's Pinned section: a name, a glyph and whether it is folded shut. It holds
/// no children — see `Pins` for why.
struct Folder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// An SF Symbol name, or a single emoji the user picked with ⌃⌘Space. Which of the two
    /// it is, is decided by looking at the string (`isEmoji`) rather than by a second field:
    /// a symbol name is always ASCII and an emoji never is.
    var icon = Folder.defaultIcon
    var collapsed = false
    /// What fills the folder, when something other than the user does. Absent on every
    /// ordinary folder and on every folder saved before Live Folders existed — which is why
    /// it is an Optional with a default rather than a `kind` every folder has to answer.
    /// See LiveFolders.swift.
    var live: LiveSource? = nil
    /// The rows the live source put here, by the url each stands for. Written down with the
    /// folder, and the *only* thing that says which rows are the folder's own work: a page
    /// you dragged into a live folder is not in here, so a refresh never closes it, never
    /// reorders it, and never counts it as a pull request that has gone.
    ///
    /// It has to be on disk. Guessing it back after a relaunch — "a pull request page in a
    /// live folder must be the folder's" — is wrong exactly once, on the pull request you
    /// put there by hand, and being wrong there means closing a tab nobody asked to close.
    /// Optional for the same reason `live` is, and it is not decoration: Swift's synthesized
    /// decoder falls back to the property's default only for an Optional, so a non-optional
    /// `[String] = []` here would make every folder saved before today fail to decode — the
    /// whole Pinned section with it. nil and [] both mean "this folder has put nothing
    /// anywhere"; `GitHub.mine` takes it as a list and never sees the difference.
    var owned: [String]? = nil
    /// The pull requests this folder has been told to stop showing, by url: the ones whose
    /// row the user took out by hand — unpinned, dragged elsewhere, archived, its tab closed.
    /// Without it the next refresh finds the pull request still open, sees no row for it, and
    /// puts it straight back; with it a row taken out stays out until the pull request itself
    /// closes, or until "Show Hidden Again" in Edit Live Folder.
    ///
    /// Optional for exactly the reason `owned` is — a non-optional default would make every
    /// folder saved before today fail to decode — and nil and [] both mean "nothing hidden".
    /// See `GitHub.dismissed`.
    var dismissed: [String]? = nil

    static let defaultIcon = "folder"

    /// True when `icon` is something to draw as text rather than to look up in SF Symbols.
    var iconIsEmoji: Bool { !icon.allSatisfy(\.isASCII) }
}

/// The whole shape of a sidebar section: folders, the tabs in them, and the order they are
/// drawn in. Pinned has one and Today has one (`TabStore.pins` and `TabStore.todayShape`) —
/// two instances of the same value, deliberately, rather than one array with a section field
/// on every row: nothing here has ever had to know which section it is, so every drag, drop
/// and reorder already works in both.
///
/// ponytail: **one flat array with parent pointers**, not a tree of `children`. The sidebar
/// draws a flat list and `TabStore.tabs` is already a flat strip, so a tree would mean two
/// orderings to keep in step and a recursive rewrite of every drag, drop and reorder that
/// already works. Here a folder simply owns the rows that follow it — exactly the way an
/// outline view flattens one — so reordering stays the `remove`/`insert` pair it always was
/// and "delete the folder, keep the tabs" is one re-parenting loop.
///
/// A row names its tab with a `String` and never looks inside it: at runtime that is the
/// `Tab.ID`, on disk it is the tab's url, which is what a pin has always been written down
/// as. `mapped` is the translation, and it is why the same code runs in `check()`.
///
/// ponytail: nesting is capped at `maxDepth` (three levels). Arc allows deeper; three is
/// what fits a 250pt sidebar once each level is indented, and the cap lives in one constant
/// — raising it is changing that number, because nothing else counts levels.
struct Pins: Codable, Equatable, Sendable {
    /// What a row is. A folder carries its own record; a tab carries only its identity.
    enum Row: Codable, Equatable, Sendable {
        case folder(Folder)
        case tab(String)
    }

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var row: Row
        /// The folder this row sits in, nil at the top of the Pinned section. Always a
        /// folder that appears *earlier* in the array, which is what makes every walk up
        /// the parent chain terminate.
        var parent: UUID?

        var id: String {
            switch row {
            case .folder(let f): f.id.uuidString
            case .tab(let t): t
            }
        }
        var folder: Folder? {
            if case .folder(let f) = row { return f }
            return nil
        }
        var tab: String? {
            if case .tab(let t) = row { return t }
            return nil
        }
    }

    var entries: [Entry] = []

    /// Three levels of folder. See the type's own note.
    static let maxDepth = 2

    // MARK: Reading

    var isEmpty: Bool { entries.isEmpty }

    func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }
    func index(of folder: UUID) -> Int? { index(of: folder.uuidString) }
    func folder(_ id: UUID) -> Folder? { index(of: id).flatMap { entries[$0].folder } }

    /// The folders a row sits inside, innermost first. Bounded by the array's length so a
    /// corrupt file cannot spin here.
    func ancestors(of i: Int) -> [UUID] {
        var out: [UUID] = []
        var next = entries[i].parent
        while let p = next, out.count <= entries.count, let j = index(of: p) {
            out.append(p)
            next = entries[j].parent
        }
        return out
    }

    func depth(of i: Int) -> Int { ancestors(of: i).count }

    /// The row at `i` together with everything nested under it. A tab is its own subtree.
    func subtree(at i: Int) -> Range<Int> {
        guard let f = entries[i].folder else { return i..<(i + 1) }
        var end = i + 1
        while end < entries.count, ancestors(of: end).contains(f.id) { end += 1 }
        return i..<end
    }

    /// Every tab id in the section, in drawing order — what the strip is re-sorted to and
    /// what is written down.
    var tabs: [String] { entries.compactMap(\.tab) }

    /// The folder a row sits directly in, nil at the top of the section. What a tab's
    /// accessibility value says after "pinned".
    func folder(holding id: String) -> Folder? {
        guard let i = index(of: id), let parent = entries[i].parent else { return nil }
        return folder(parent)
    }

    /// Whether a new folder would fit beside `to`. False at the deepest level, where
    /// `newFolder` refuses rather than quietly putting one somewhere else.
    func canNestFolder(next to: String?) -> Bool {
        guard let to, let t = index(of: to) else { return true }
        return (entries[t].parent.flatMap { index(of: $0).map { depth(of: $0) + 1 } } ?? 0)
            <= Pins.maxDepth
    }

    /// The tabs sitting *directly* in a folder, in order — not the ones inside a folder
    /// nested in it. What a live folder reconciles against: a sub-folder's rows belong to
    /// the sub-folder, whoever filled it.
    func children(of folder: UUID) -> [String] {
        entries.filter { $0.parent == folder }.compactMap(\.tab)
    }

    /// The tabs inside a folder, however deeply. "Archive all tabs in folder" is this list.
    func tabs(in folder: UUID) -> [String] {
        guard let i = index(of: folder) else { return [] }
        return entries[subtree(at: i)].compactMap(\.tab)
    }

    /// Whether a folder is live or is carrying a live folder somewhere under it. Asked of the
    /// whole subtree because a drag takes the whole subtree: a live folder that crossed the
    /// divider inside a plain one would stop being refilled and be swept up when its rows go.
    func holdsLive(_ folder: UUID) -> Bool {
        guard let i = index(of: folder) else { return false }
        return entries[subtree(at: i)].contains { $0.folder?.live != nil }
    }

    /// The tabs that are in some folder, however deeply — as opposed to loose at the top of
    /// the section. What "already tidy" means to `TidyTabs.candidates`, which is the one
    /// caller: a tab the shape has never heard of is not in a folder either, so the question
    /// is asked this way round rather than as "which rows are loose".
    var filed: Set<String> { Set(entries.filter { $0.parent != nil }.compactMap(\.tab)) }

    /// One drawable row: the entry and how far to indent it.
    struct Visible: Identifiable {
        let entry: Entry
        let depth: Int
        var id: String { entry.id }
    }

    /// What the sidebar draws: everything with no folded-up folder above it.
    var visible: [Visible] {
        var out: [Visible] = []
        var i = 0
        while i < entries.count {
            out.append(Visible(entry: entries[i], depth: depth(of: i)))
            if let f = entries[i].folder, f.collapsed {
                i = subtree(at: i).upperBound          // skip what it is hiding
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Writing

    /// The one move behind every drag: take `id` and everything under it out, and put it
    /// back at `raw` (an index into the array *before* the removal) inside `parent`.
    /// Refused — rather than clamped — when it would nest a folder inside itself or push
    /// anything past `maxDepth`: a drop that cannot mean what it looks like should do
    /// nothing, not something else.
    private mutating func relocate(_ id: String, to raw: Int, parent: UUID?) {
        guard let i = index(of: id) else { return }
        let range = subtree(at: i)
        // Into itself, or into one of its own children.
        if let p = parent, let pi = index(of: p), range.contains(pi) { return }
        // The cap counts *folders*, not rows: a tab is welcome at the bottom of the
        // deepest folder, which is the whole point of the deepest folder.
        if entries[i].folder != nil {
            let base = parent.flatMap { index(of: $0).map { depth(of: $0) + 1 } } ?? 0
            let here = depth(of: range.lowerBound)
            let deepest = range.filter { entries[$0].folder != nil }.map { depth(of: $0) }.max()
            guard base + ((deepest ?? here) - here) <= Pins.maxDepth else { return }
        }

        var moved = Array(entries[range])
        moved[0].parent = parent       // the rows under it still point at folders inside it
        entries.removeSubrange(range)
        var at = raw
        if raw > range.lowerBound { at = max(range.lowerBound, raw - range.count) }
        entries.insert(contentsOf: moved, at: min(max(at, 0), entries.count))
    }

    /// A drop on the top or bottom half of another row: land beside it, in its folder.
    mutating func move(_ id: String, next to: String, after: Bool) {
        guard id != to, let s = index(of: id), let t = index(of: to),
              !subtree(at: s).contains(t) else { return }
        let target = subtree(at: t)
        relocate(id, to: after ? target.upperBound : target.lowerBound, parent: entries[t].parent)
    }

    /// A row that has just joined the section beside another — a ⌘-click, a popup, Peek's
    /// ⌘O. It lands after `next` and in whatever folder `next` is in, and with nothing to be
    /// beside it goes to the very head of the section, outside every folder, which is where
    /// the strip puts a tab opened from a pinned row or a favourite. See `TabStore
    /// .placeBeside`.
    mutating func insert(_ id: String, after next: String?) {
        // The first row is always at the top level — a parent is always written down before
        // the rows in it — so landing in front of it is landing in no folder.
        guard let to = next ?? entries.first?.id, to != id else { return }
        move(id, next: to, after: next != nil)
    }

    /// A drop on the middle of a folder row: in it, at the end, which is where Arc puts one.
    mutating func move(_ id: String, into folder: UUID) {
        guard let f = index(of: folder), let s = index(of: id),
              !subtree(at: s).contains(f) else { return }
        relocate(id, to: subtree(at: f).upperBound, parent: folder)
    }

    /// A new folder at the top of the section, or beside `next` and in the same folder it
    /// is in. Returns nil when it would be too deep to nest, so the caller can say so
    /// rather than silently making a folder somewhere else.
    @discardableResult
    mutating func newFolder(named name: String = "New Folder", next to: String? = nil) -> Folder? {
        let folder = Folder(name: name)
        guard let to, let t = index(of: to) else {
            entries.append(Entry(row: .folder(folder), parent: nil))
            return folder
        }
        guard canNestFolder(next: to) else { return nil }
        entries.insert(Entry(row: .folder(folder), parent: entries[t].parent),
                       at: subtree(at: t).lowerBound)
        return folder
    }

    /// Arc's "Delete Folder": the folder goes, its tabs do not. Direct children take the
    /// folder's own parent and stay exactly where they were sitting, so the list does not
    /// reshuffle under a menu click.
    mutating func remove(folder id: UUID) {
        guard let i = index(of: id) else { return }
        let up = entries[i].parent
        for j in entries.indices where entries[j].parent == id { entries[j].parent = up }
        entries.remove(at: i)
    }

    /// A tab that stopped being pinned. Tabs have nothing under them, so this is one line.
    mutating func remove(tab id: String) { entries.removeAll { $0.id == id } }

    /// A folder and everything under it, taken out of the section — half of dragging one
    /// across the divider. The rows keep their order and their nesting, and the folder itself
    /// comes out parentless, because whatever it was sitting in is not going with it. The
    /// other half is `entries += rows` and then a `put`, which is `relocate` doing the
    /// depth check it always does. See `TabStore.moved`.
    mutating func lift(folder id: UUID) -> [Entry] {
        guard let i = index(of: id) else { return [] }
        let range = subtree(at: i)
        var rows = Array(entries[range])
        rows[0].parent = nil
        entries.removeSubrange(range)
        return rows
    }

    /// Where one row sits, and nothing else: the folder it is in — nil at the top of the
    /// section — and how many of that folder's own rows come before it. Enough to put the
    /// row back, and, unlike a copy of the whole section, it says nothing at all about any
    /// other row. `TabStore.unpin`'s Undo carries one of these: a snapshot of `pins` would
    /// take back the folder the user made and the row they dragged while the toast was up,
    /// and write that over the file too.
    struct Spot: Equatable, Sendable {
        var parent: UUID?
        var index: Int
    }

    func spot(of id: String) -> Spot? {
        guard let i = index(of: id) else { return nil }
        let parent = entries[i].parent
        let siblings = entries.indices.filter { entries[$0].parent == parent }
        return Spot(parent: parent, index: siblings.firstIndex(of: i) ?? 0)
    }

    /// Where a row let go beside `to` would sit: in whatever folder `to` is in, in front of
    /// it or behind it. A drop on a row's top or bottom edge, said as a `Spot` — which is
    /// what a row arriving from the *other* section is placed by, having no place here yet
    /// for `move(_:next:after:)` to move it from.
    func spot(next to: String, after: Bool) -> Spot? {
        spot(of: to).map { Spot(parent: $0.parent, index: $0.index + (after ? 1 : 0)) }
    }

    /// The same spot, unless the folder it names has gone since it was taken — then the end
    /// of the section, which is where `put` lands a row whose folder is missing. The toast's
    /// Undo asks: the drag can leave the folder it emptied to be swept up while the toast is
    /// still on screen, and "back where it was" then means back in the section.
    func landing(for spot: Spot) -> Spot {
        guard let p = spot.parent, index(of: p) == nil else { return spot }
        return Spot(parent: nil, index: .max)
    }

    /// Put one row back where a `Spot` says it was, and leave every other row exactly as it
    /// is. A folder that has gone in the meantime is not brought back with it: the row lands
    /// at the end of the section, which is where a freshly pinned tab lands anyway.
    mutating func put(_ id: String, at spot: Spot) {
        guard let i = index(of: id) else { return }
        // An index inside a folder means nothing outside it, so a folder that has gone since
        // sends the row to the end of the top level rather than to that many rows down it.
        let parent = spot.parent
        if let p = parent, index(of: p) == nil {
            relocate(id, to: entries.count, parent: nil)
            return
        }
        // The row's own place among them is the one being decided, so it is not a sibling
        // of itself — at the top level it is very much in this list already.
        let siblings = entries.indices.filter { $0 != i && entries[$0].parent == parent }
        let raw: Int
        if spot.index < siblings.count {
            raw = siblings[spot.index]                       // in front of the one it preceded
        } else if let last = siblings.last {
            raw = subtree(at: last).upperBound               // behind the last of them
        } else if let p = parent, let pi = index(of: p) {
            raw = subtree(at: pi).upperBound                 // an emptied folder: first row in
        } else {
            raw = entries.count
        }
        relocate(id, to: raw, parent: parent)
    }

    mutating func edit(folder id: UUID, _ change: (inout Folder) -> Void) {
        guard let i = index(of: id), var f = entries[i].folder else { return }
        change(&f)
        entries[i].row = .folder(f)
    }

    mutating func toggle(folder id: UUID) { edit(folder: id) { $0.collapsed.toggle() } }

    /// Bring the section in line with the tabs that are actually pinned: forget rows whose
    /// tab has gone, and take in any pinned tab nothing knows about yet — at the top level,
    /// at the end, which is where `TabStore.move` drops one.
    mutating func sync(tabs live: [String]) {
        let known = Set(live)
        entries.removeAll { entry in entry.tab.map { !known.contains($0) } ?? false }
        let have = Set(tabs)
        for id in live where !have.contains(id) {
            entries.append(Entry(row: .tab(id), parent: nil))
        }
    }

    /// The rows re-laid in `order`, each staying in the folder it is in and each folder
    /// arriving with the first of its tabs. The other direction from `TabStore.applyOrder`:
    /// there the strip is put in the shape's order, here the shape is put in the strip's.
    /// Today needs both — a tidy lays the folders out and the strip follows, while a tidy's
    /// undo hands the strip a whole order back at once and the shape follows that.
    ///
    /// A folder `order` names no tab for is dropped, which is `removeEmptyFolders` said as a
    /// side effect rather than as a second pass.
    mutating func relay(_ order: [String]) {
        var out: [Entry] = []
        var placed = Set<String>()
        for id in order {
            // `placed` is the guard, not a note: an order that names the same tab twice —
            // which `TidyTabs.order` cannot make but a caller handing over two runs can —
            // would otherwise write the row down twice and draw the tab twice.
            guard let i = index(of: id), entries[i].tab != nil,
                  placed.insert(id).inserted else { continue }
            // Outermost first, so a nested folder is written down inside the one it is in.
            for f in ancestors(of: i).reversed() where placed.insert(f.uuidString).inserted {
                if let j = index(of: f) { out.append(entries[j]) }
            }
            out.append(entries[i])
        }
        entries = out
    }

    /// Today's rule, which Pinned's is not: a folder with nothing left in it goes.
    ///
    /// ponytail: no empty-folder state in Today. A Today folder is a grouping of tabs that
    /// are still auto-archiving, so the last one leaving — swept, closed, cleared — is the
    /// end of the group, and there is nothing left for the row to be about. Pinned keeps its
    /// empty folders, because an empty folder there is a thing the user made on purpose.
    /// Ceiling: you cannot make an empty folder in Today and fill it later.
    mutating func removeEmptyFolders() {
        for f in entries.compactMap(\.folder) where tabs(in: f.id).isEmpty { remove(folder: f.id) }
    }

    /// The same shape with every tab renamed — ids to urls on the way to disk, urls to ids
    /// on the way back. A tab the mapping has no answer for is dropped; an empty folder is
    /// kept, because an empty folder is a thing the user made on purpose.
    func mapped(_ name: (String) -> String?) -> Pins {
        var out = Pins()
        for entry in entries {
            switch entry.row {
            case .folder: out.entries.append(entry)
            case .tab(let t):
                guard let renamed = name(t) else { continue }
                out.entries.append(Entry(row: .tab(renamed), parent: entry.parent))
            }
        }
        return out
    }
}

// MARK: - check

extension Pins {
    /// The model, proved offline: creating, moving in and out, reordering, deleting,
    /// the nesting cap, collapse and the codable round-trip.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }
        /// A section of loose tabs, named "a", "b"… so the assertions read as lists.
        func flat(_ ids: String...) -> Pins {
            Pins(entries: ids.map { Entry(row: .tab($0), parent: nil) })
        }
        func shown(_ p: Pins) -> [String] { p.visible.map(\.id) }

        // Making one.
        var p = flat("a", "b", "c")
        assert("a bare section is the pinned tabs in order", p.tabs == ["a", "b", "c"])
        let work = p.newFolder(named: "Work", next: "b")
        assert("a new folder lands where the row it was made from was",
               p.entries.count == 4 && p.entries[1].folder?.name == "Work")
        assert("…and it starts empty", work.map { p.tabs(in: $0.id) } == [])

        // Moving in and out.
        guard let work else { return out + [("a folder was made", false)] }
        p.move("b", into: work.id)
        assert("a tab dropped on a folder goes in it", p.tabs(in: work.id) == ["b"])
        assert("…without leaving its section", p.tabs == ["a", "b", "c"])
        p.move("c", into: work.id)
        assert("a second tab lands after the first", p.tabs(in: work.id) == ["b", "c"])
        assert("the folder's tabs are drawn under it, in order",
               shown(p) == ["a", work.id.uuidString, "b", "c"])
        p.move("b", next: "a", after: false)
        assert("a tab dragged out of a folder leaves it", p.tabs(in: work.id) == ["c"])
        assert("…and lands where it was dropped", p.tabs == ["b", "a", "c"])

        // Collapsing.
        p.toggle(folder: work.id)
        assert("a folded folder hides its tabs", shown(p) == ["b", "a", work.id.uuidString])
        assert("…but does not lose them", p.tabs(in: work.id) == ["c"])
        p.toggle(folder: work.id)
        assert("unfolding brings them back", shown(p).count == 4)

        // Deleting lifts the children out.
        var d = flat("a", "b")
        let box = d.newFolder(named: "Box", next: "b")!
        d.move("b", into: box.id)
        d.remove(folder: box.id)
        assert("deleting a folder keeps its tabs", d.tabs == ["a", "b"])
        assert("…in the place the folder was", shown(d) == ["a", "b"])
        assert("…and the folder itself is gone", d.folder(box.id) == nil)

        // Nesting, and its ceiling.
        var n = flat("a")
        let l0 = n.newFolder(named: "L0")!
        n.move("a", into: l0.id)
        let l1 = n.newFolder(named: "L1")!
        n.move(l1.id.uuidString, into: l0.id)
        assert("a folder can be dropped into a folder", n.depth(of: n.index(of: l1.id)!) == 1)
        let l2 = n.newFolder(named: "L2")!
        n.move(l2.id.uuidString, into: l1.id)
        assert("…two deep as well", n.depth(of: n.index(of: l2.id)!) == 2)
        let l3 = n.newFolder(named: "L3")!
        n.move(l3.id.uuidString, into: l2.id)
        assert("…and no deeper: a fourth level is refused, not clamped",
               n.depth(of: n.index(of: l3.id)!) == 0)
        assert("a tab still fits at the deepest level",
               { var c = n; c.move("a", into: l2.id); return c.depth(of: c.index(of: "a")!) == 3 }())
        n.move(l0.id.uuidString, into: l1.id)
        assert("a folder cannot be dropped inside itself",
               n.depth(of: n.index(of: l0.id)!) == 0)
        n.move(l0.id.uuidString, into: l2.id)
        assert("…nor inside one of its own children",
               n.depth(of: n.index(of: l0.id)!) == 0)
        n.move(l0.id.uuidString, next: l0.id.uuidString, after: true)
        assert("…nor next to itself", n.index(of: l0.id) == 0)
        var deep = flat("t")
        let outer = deep.newFolder(named: "Outer")!, inner = deep.newFolder(named: "Inner")!
        deep.move("t", into: inner.id)
        deep.move(inner.id.uuidString, into: outer.id)
        assert("a folder carrying tabs is measured in folders, not in rows",
               deep.depth(of: deep.index(of: inner.id)!) == 1
                   && deep.depth(of: deep.index(of: "t")!) == 2)

        // A folder moves with everything in it.
        var m = flat("a")
        let g = m.newFolder(named: "G")!
        m.move("a", into: g.id)
        m.move(g.id.uuidString, next: "a", after: true)
        assert("a folder dragged beside its own child does nothing",
               shown(m) == [g.id.uuidString, "a"])
        m.entries.append(Entry(row: .tab("z"), parent: nil))
        m.move(g.id.uuidString, next: "z", after: true)
        assert("a folder dragged past a tab takes its tabs with it",
               shown(m) == ["z", g.id.uuidString, "a"])
        m.move(g.id.uuidString, next: "z", after: false)
        assert("…and back again", shown(m) == [g.id.uuidString, "a", "z"])

        // Syncing against the strip.
        var s = flat("a", "b")
        let f = s.newFolder(named: "F", next: "b")!
        s.move("b", into: f.id)
        s.sync(tabs: ["a", "b", "c"])
        assert("a newly pinned tab joins at the end, at the top level",
               s.tabs == ["a", "b", "c"] && s.entries.last?.parent == nil)
        s.sync(tabs: ["a", "c"])
        assert("an unpinned tab leaves the folder it was in", s.tabs(in: f.id) == [])
        assert("…and the folder stays", s.folder(f.id) != nil)
        s.sync(tabs: ["a", "c"])
        assert("syncing twice changes nothing", s.tabs == ["a", "c"])

        // Renaming rows: the same shape, other identities.
        let names = s.mapped { $0 == "a" ? "https://a.example" : nil }
        assert("a mapped section keeps its folders", names.folder(f.id) != nil)
        assert("…renames the tabs it can", names.tabs == ["https://a.example"])
        assert("…and the original is untouched", s.tabs == ["a", "c"])
        assert("mapping back is the identity",
               names.mapped { $0 == "https://a.example" ? "a" : nil }.tabs == ["a"])

        // Editing a folder.
        var e = Pins()
        let icon = e.newFolder(named: "Icons")!
        e.edit(folder: icon.id) { $0.name = "Renamed"; $0.icon = "🎧" }
        assert("a folder can be renamed", e.folder(icon.id)?.name == "Renamed")
        assert("…and given an emoji", e.folder(icon.id)?.iconIsEmoji == true)
        assert("an SF Symbol name is not an emoji", Folder(name: "x").iconIsEmoji == false)
        assert("editing a folder that has gone does nothing",
               { var c = e; c.edit(folder: UUID()) { $0.name = "no" }; return c == e }())

        // Which folder a row is in — what a pinned tab's accessibility value says.
        var h = flat("a", "b")
        let box2 = h.newFolder(named: "Box", next: "b")!
        h.move("b", into: box2.id)
        assert("a tab in a folder knows which one", h.folder(holding: "b")?.name == "Box")
        assert("a tab at the top of the section is in none", h.folder(holding: "a") == nil)
        assert("a row nobody has heard of is in none", h.folder(holding: "zz") == nil)

        // The cap, asked before anything is moved.
        assert("there is always room for a folder at the top", h.canNestFolder(next: nil))
        assert("…and beside a tab at the top", h.canNestFolder(next: "a"))
        var cap = Pins()
        var last = cap.newFolder(named: "L0")!
        for i in 1...Pins.maxDepth {
            let next = cap.newFolder(named: "L\(i)")!
            cap.move(next.id.uuidString, into: last.id)
            last = next
        }
        cap.entries.append(Entry(row: .tab("t"), parent: nil))
        cap.move("t", into: last.id)
        assert("a tab still fits inside the deepest folder", cap.tabs(in: last.id) == ["t"])
        assert("but a folder beside that tab would be one level too deep",
               !cap.canNestFolder(next: "t"))
        assert("…and asking for one makes nothing",
               { var c = cap; return c.newFolder(next: "t") == nil }())
        assert("a sibling of the deepest folder is still allowed",
               cap.canNestFolder(next: last.id.uuidString))

        // Restoring: the shape's order, then whatever it has not heard of.
        func url(_ s: String) -> URL { URL(string: "https://e.example/\(s)")! }
        var r = Pins()
        r.entries = [Entry(row: .tab("https://e.example/b"), parent: nil),
                     Entry(row: .tab("https://e.example/a"), parent: nil)]
        assert("with no saved shape the urls come back as they are",
               TabStore.pinOrder(shape: nil, urls: [url("a"), url("b")]) == [url("a"), url("b")])
        assert("the saved shape decides the order",
               TabStore.pinOrder(shape: r, urls: [url("a"), url("b")]) == [url("b"), url("a")])
        assert("a url the shape has never heard of comes after the ones it has",
               TabStore.pinOrder(shape: r, urls: [url("a"), url("c"), url("b")])
                   == [url("b"), url("a"), url("c")])
        assert("a shape naming a url the window has not got skips it",
               TabStore.pinOrder(shape: r, urls: [url("a")]) == [url("a")])
        var dup = Pins()
        dup.entries = [Entry(row: .tab("https://e.example/a"), parent: nil),
                       Entry(row: .tab("https://e.example/b"), parent: nil),
                       Entry(row: .tab("https://e.example/a"), parent: nil)]
        assert("two pinned tabs on the same page both come back",
               TabStore.pinOrder(shape: dup, urls: [url("a"), url("a"), url("b")])
                   == [url("a"), url("b"), url("a")])
        assert("…and a shape asking for more of them than there are invents none",
               TabStore.pinOrder(shape: dup, urls: [url("a"), url("b")])
                   == [url("a"), url("b")])
        assert("…while a window holding more of them than the shape names keeps the rest",
               TabStore.pinOrder(shape: dup, urls: [url("a"), url("a"), url("a"), url("b")])
                   == [url("a"), url("b"), url("a"), url("a")])
        assert("an empty window restores nothing", TabStore.pinOrder(shape: dup, urls: []).isEmpty)

        // --- Today's folders: the same shape, in the section that auto-archives ---
        //
        // Every rule Today has that Pinned does not, driven through the same value the
        // sidebar draws — no window, no `Tab`, no defaults suite.
        func today() -> (Pins, UUID) {
            var t = Pins(entries: ["a", "b", "c"].map { Entry(row: .tab($0), parent: nil) })
            let box = t.newFolder(named: "Reading", next: "a")!
            t.move("a", into: box.id)
            t.move("b", into: box.id)
            return (t, box.id)
        }
        var (day, reading) = today()
        assert("a Today folder holds its tabs like any other",
               day.tabs(in: reading) == ["a", "b"] && day.tabs == ["a", "b", "c"])

        // A tab archived by any path — the sweep, ⌘W, ×, Archive Tab — just leaves its row.
        day.sync(tabs: ["a", "c"])
        day.removeEmptyFolders()
        assert("a tab archived out of a Today folder simply leaves it",
               day.tabs(in: reading) == ["a"] && day.folder(reading) != nil)
        day.sync(tabs: ["c"])
        day.removeEmptyFolders()
        assert("…and the last one out takes the folder with it",
               day.folder(reading) == nil && day.tabs == ["c"] && day.entries.count == 1)

        // Clear: every Today tab archived in one burst, folders and all.
        (day, reading) = today()
        day.sync(tabs: [])
        day.removeEmptyFolders()
        assert("Clear leaves no tabs and no folders behind in Today", day.entries.isEmpty)
        (day, reading) = today()
        var nested = day
        let deeper = nested.newFolder(named: "Inner")!
        nested.move(deeper.id.uuidString, into: reading)
        nested.sync(tabs: [])
        nested.removeEmptyFolders()
        assert("…however deep the folders went", nested.entries.isEmpty)

        // A new tab, an un-pinned one and one moved in from another Space: all outside every
        // folder. `sync` takes a row it has not seen at the top level; `put` is what
        // `TabStore.move(_:to:)` uses to land one at the head of the section instead.
        day.sync(tabs: ["a", "b", "c", "new"])
        assert("a new Today tab lands outside every folder, at the end of the section",
               day.folder(holding: "new") == nil && day.tabs.last == "new")
        day.sync(tabs: ["a", "b", "c", "new", "back"])
        day.put("back", at: Spot(parent: nil, index: 0))
        assert("an un-pinned tab lands at the top of Today, in no folder",
               day.tabs.first == "back" && day.folder(holding: "back") == nil)

        // Re-laying: the strip's order, said to the shape. Both directions are needed —
        // a tidy lays the folders out and the strip follows, its undo hands a whole order
        // back and the shape follows that.
        (day, reading) = today()
        day.relay(["c", "b", "a"])
        assert("re-laying puts the rows in the order it was given",
               day.tabs == ["c", "b", "a"])
        assert("…each still in the folder it was in", day.tabs(in: reading) == ["b", "a"])
        assert("…and the folder arrives with the first of its tabs",
               shown(day) == ["c", reading.uuidString, "b", "a"])
        (day, reading) = today()
        let laid = day
        day.relay(["a", "b", "c"])
        assert("re-laying an already-laid section changes nothing", day == laid)
        (day, reading) = today()
        day.relay(["c"])
        assert("a folder the new order names nothing for is dropped",
               day.folder(reading) == nil && day.tabs == ["c"])
        (day, reading) = today()
        day.relay(["c", "b", "a", "unheard-of"])
        assert("a row the shape has never heard of is not invented", day.tabs.count == 3)
        (day, reading) = today()
        day.relay(["c", "c", "a", "b"])
        assert("an order naming the same tab twice draws it once",
               day.tabs == ["c", "a", "b"] && day.entries.count == 4)

        // "Archive All Tabs in Folder" un-pins its rows to the *head* of the Today strip,
        // while `sync` takes a row it has not seen at the end of the shape. The relay is what
        // puts the section back in the order the strip has it.
        (day, reading) = today()
        day.sync(tabs: ["a", "b", "c", "unpinned"])
        day.relay(["unpinned", "a", "b", "c"])
        assert("a row un-pinned to the head of Today is drawn at the head",
               shown(day) == ["unpinned", reading.uuidString, "a", "b", "c"])

        // Beside the opener: what a ⌘-click, an adopted popup and Peek's ⌘O ask of the shape
        // once the strip has already put the tab there. See `TabStore.placeBeside`.
        (day, reading) = today()
        day.sync(tabs: ["a", "b", "c", "new"])
        day.insert("new", after: "a")
        assert("a tab opened beside one in a folder joins that folder",
               day.folder(holding: "new")?.id == reading && day.tabs(in: reading) == ["a", "new", "b"])
        (day, reading) = today()
        day.sync(tabs: ["a", "b", "c", "new"])
        day.insert("new", after: "c")
        assert("…and beside a loose one it stays loose",
               day.folder(holding: "new") == nil && day.tabs == ["a", "b", "c", "new"])
        (day, reading) = today()
        day.sync(tabs: ["a", "b", "c", "new"])
        day.insert("new", after: nil)
        assert("a tab opened from a pinned row lands at the head, outside every folder",
               shown(day) == ["new", reading.uuidString, "a", "b", "c"])
        var first = Pins()
        first.sync(tabs: ["only"])
        first.insert("only", after: nil)
        assert("the first tab of an empty section has nothing to be beside",
               first.tabs == ["only"])

        // What a tidy may touch. A tab the user filed by hand is already tidy.
        (day, reading) = today()
        assert("the tabs in a Today folder are filed, and the loose ones are not",
               day.filed == ["a", "b"])

        // --- The Today shape coming back off disk ---
        // Named by the url each tab was *opened with*: a restored tab is normally parked and
        // answers `currentURL` at once, but with suspension off it is still loading when this
        // runs, and keying on `currentURL` there dropped every folder on every launch.
        var onDisk = Pins(entries: ["https://e.example/a", "https://e.example/b"]
                              .map { Entry(row: .tab($0), parent: nil) })
        let read = onDisk.newFolder(named: "Reading", next: "https://e.example/a")!
        onDisk.move("https://e.example/a", into: read.id)
        let live = TabStore.adopted(onDisk, opened: [("https://e.example/a", "id-a"),
                                                     ("https://e.example/c", "id-c")])
        assert("a Today folder comes back around the tab restored for its url",
               live.tabs(in: read.id) == ["id-a"])
        assert("…a url the Space no longer has is dropped rather than invented",
               live.tabs == ["id-a", "id-c"])
        assert("…and a tab the shape never named is taken in, loose",
               live.folder(holding: "id-c") == nil)
        assert("a Space that has never had Today folders comes back as loose tabs",
               TabStore.adopted(nil, opened: [("https://e.example/a", "id-a")])
                   == Pins(entries: [Entry(row: .tab("id-a"), parent: nil)]))

        // An undone tidy: the folders it made go, every tab stays, and the order comes back.
        var undone = Pins(entries: ["a", "b", "c", "d"].map { Entry(row: .tab($0), parent: nil) })
        let g1 = undone.newFolder(named: "Work")!, g2 = undone.newFolder(named: "Rest")!
        undone.move("a", into: g1.id)
        undone.move("c", into: g1.id)
        undone.move("b", into: g2.id)
        undone.move("d", into: g2.id)
        undone.relay(["a", "c", "b", "d"])
        assert("a tidy lays its groups out as runs, in group order",
               shown(undone) == [g1.id.uuidString, "a", "c", g2.id.uuidString, "b", "d"])
        for made in [g1.id, g2.id] { undone.remove(folder: made) }
        undone.relay(["a", "b", "c", "d"])
        assert("undoing it puts the order back exactly", undone.tabs == ["a", "b", "c", "d"])
        assert("…and leaves no folder behind", undone.entries.allSatisfy { $0.folder == nil })

        // A Space with nothing under the Today key, and a Space with junk under it: both are
        // "no folders", and neither is allowed to be a failure to bring the Space up.
        var none = Pins?.none ?? Pins()
        none.sync(tabs: ["a", "b"])
        assert("a Space saved before Today had folders loads as loose tabs",
               none.tabs == ["a", "b"] && none.entries.allSatisfy { $0.folder == nil })
        assert("…and junk where a shape should be decodes to nothing rather than throwing",
               (try? JSONDecoder().decode(Pins.self, from: Data("{".utf8))) == nil)

        // --- A whole folder dragged across the divider ---
        // Everything `TabStore.move(folder:from:to:at:)` does before it re-kinds the tabs and
        // saves: two sections, one folder taken out of one and put into the other.
        func sections() -> (from: Pins, to: Pins, folder: UUID) {
            var from = Pins(entries: ["a", "b", "c"].map { Entry(row: .tab($0), parent: nil) })
            let box = from.newFolder(named: "Reading", next: "a")!
            from.move("a", into: box.id)
            from.move("b", into: box.id)
            return (from, flat("p"), box.id)
        }
        let (dayside, pinside, boxed) = sections()
        let sectionEnd = Pins.Spot(parent: nil, index: .max)
        guard let up = TabStore.moved(folder: boxed, from: dayside, to: pinside, at: sectionEnd)
        else { return out + [("a folder crosses the divider", false)] }
        assert("a folder dragged up to Pinned arrives with its rows",
               up.to.tabs(in: boxed) == ["a", "b"] && up.to.tabs == ["p", "a", "b"])
        assert("…at the end of the section, where a pinned tab lands",
               shown(up.to) == ["p", boxed.uuidString, "a", "b"])
        assert("…and Today keeps only what was not in it",
               up.from.folder(boxed) == nil && up.from.tabs == ["c"])
        // Which tabs change kind, said by the only thing that knows which they are: the store
        // re-kinds what the folder was holding, and nothing else in either section.
        assert("…so the tabs that change section are the ones the folder held",
               Set(dayside.tabs(in: boxed)) == Set(up.to.tabs).subtracting(pinside.tabs))
        var folded = dayside
        folded.edit(folder: boxed) { $0.collapsed = true; $0.icon = "🎧" }
        assert("…and the record arrives with its name, its glyph and its fold",
               TabStore.moved(folder: boxed, from: folded, to: pinside, at: sectionEnd)?
                   .to.folder(boxed) == folded.folder(boxed))
        // The other direction, which is also what the toast's Undo runs.
        assert("dragging it back down puts both sections back exactly",
               TabStore.moved(folder: boxed, from: up.to, to: up.from,
                              at: Pins.Spot(parent: nil, index: 0)).map {
                   $0.from == pinside && $0.to == dayside
               } == true)

        // Into a pinned folder rather than beside its rows, and the cap counted over the
        // whole subtree — a folder two levels tall needs two levels of room.
        var (tall, receiving, outermost) = sections()
        let within = tall.newFolder(named: "Inner")!
        tall.move(within.id.uuidString, into: outermost)
        var top = receiving.newFolder(named: "Top")!
        receiving.edit(folder: top.id) { $0.collapsed = true }
        assert("a folder two levels tall fits inside a top-level pinned folder",
               TabStore.moved(folder: outermost, from: tall, to: receiving,
                              at: Pins.Spot(parent: top.id, index: .max))
                   .map { $0.to.depth(of: $0.to.index(of: within.id)!) } == 2)
        // Unfolding a folded folder to show what arrived is the store's to do, and it waits
        // on this answer — rows in it, or nothing at all. See `TabStore.move(folder:into:)`.
        assert("…and the rows land inside it, folded though it is",
               TabStore.moved(folder: outermost, from: tall, to: receiving,
                              at: Pins.Spot(parent: top.id, index: .max))?
                   .to.tabs(in: top.id) == ["a", "b"])
        for _ in 1...Pins.maxDepth {
            let next = receiving.newFolder(named: "Down")!
            receiving.move(next.id.uuidString, into: top.id)
            top = next
        }
        assert("…but not inside one already at the cap, and then neither section moves",
               TabStore.moved(folder: outermost, from: tall, to: receiving,
                              at: Pins.Spot(parent: top.id, index: .max)) == nil)
        assert("…nor into a folder that has gone since the drag began",
               TabStore.moved(folder: outermost, from: tall, to: receiving,
                              at: Pins.Spot(parent: UUID(), index: 0)) == nil)

        // An Undo taken after the folder the drag emptied has been swept up: the row comes
        // back to the section rather than to a folder that is not there any more.
        let orphaned = Pins.Spot(parent: UUID(), index: 0)
        assert("an Undo whose old folder has gone lands at the end of the section",
               dayside.landing(for: orphaned) == sectionEnd)
        assert("…so the folder does come back, rather than the Undo quietly doing nothing",
               TabStore.moved(folder: boxed, from: up.to, to: up.from,
                              at: up.from.landing(for: orphaned))?.to.tabs == ["c", "a", "b"])
        assert("…while a spot whose folder is still there is the spot it was",
               dayside.landing(for: Pins.Spot(parent: boxed, index: 1))
                   == Pins.Spot(parent: boxed, index: 1))

        // A live folder stays pinned: its source keeps filling it, and Today would archive
        // the rows out from under the refresh that put them there.
        var filled = pinside
        let keptFull = filled.newFolder(named: "Review Requested")!
        filled.edit(folder: keptFull.id) { $0.live = .github(GitHubQuery(filter: .mentioned)) }
        assert("a live folder does not cross the divider",
               TabStore.moved(folder: keptFull.id, from: filled, to: dayside,
                              at: sectionEnd) == nil)
        // Asked of the whole subtree: what is dragged is the folder *and* everything under it.
        var carrying = pinside
        let plain = carrying.newFolder(named: "Work")!
        let mentions = carrying.newFolder(named: "Mentions")!
        carrying.move(mentions.id.uuidString, into: plain.id)
        carrying.edit(folder: mentions.id) { $0.live = .github(GitHubQuery(filter: .mentioned)) }
        assert("a plain folder carrying a live one does not cross either",
               TabStore.moved(folder: plain.id, from: carrying, to: dayside,
                              at: sectionEnd) == nil)
        carrying.edit(folder: mentions.id) { $0.live = nil }
        assert("…and the same two folders cross once nothing under them is live",
               TabStore.moved(folder: plain.id, from: carrying, to: dayside,
                              at: sectionEnd)?.to.folder(mentions.id) != nil)
        assert("a folder neither section has heard of crosses nothing",
               TabStore.moved(folder: UUID(), from: dayside, to: pinside, at: sectionEnd) == nil)

        // Codable, which is how the section survives a relaunch.
        if let data = try? JSONEncoder().encode(p),
           let back = try? JSONDecoder().decode(Pins.self, from: data) {
            assert("a section survives a codable round-trip", back == p)
            assert("…including what is folded and what is not",
                   back.folder(work.id)?.collapsed == p.folder(work.id)?.collapsed)
        } else {
            assert("a section survives a codable round-trip", false)
        }
        assert("an empty section round-trips too",
               (try? JSONDecoder().decode(Pins.self, from: JSONEncoder().encode(Pins()))) == Pins())

        // Nonsense in, nothing out.
        var junk = flat("a")
        junk.move("nope", into: UUID())
        junk.move("a", next: "nope", after: true)
        junk.remove(folder: UUID())
        junk.remove(tab: "nope")
        assert("moves naming rows that are not there do nothing", junk == flat("a"))
        assert("an empty section has nothing to draw", Pins().visible.isEmpty)

        // --- When a window with an empty section may clear the shape on disk ---
        var emptied = Pins()
        _ = emptied.newFolder(named: "Work")
        var owned = flat("a", "b")
        _ = owned.newFolder(named: "Work", next: "b")
        assert("a fresh profile has no shape to clear, and clearing nothing is harmless",
               TabStore.clearsShape(saved: nil))
        assert("folders left behind with no tabs in them are cleared",
               TabStore.clearsShape(saved: emptied))
        assert("…which is the whole of what an undone tidy leaves on a window with no pins",
               emptied.tabs.isEmpty && !emptied.entries.isEmpty)
        assert("a shape another window's rows are still in is left alone",
               !TabStore.clearsShape(saved: owned))
        assert("even a shape of loose tabs with no folders at all",
               !TabStore.clearsShape(saved: flat("a")))
        assert("an empty shape is cleared rather than kept", TabStore.clearsShape(saved: Pins()))

        // --- One row put back where it was, and nothing else touched ---
        // What the "Unpinned" toast's Undo does. The old undo put a snapshot of the whole
        // section back, so a folder made — or a row dragged — while the toast was up was
        // quietly reverted and written to disk with it.
        var sec = flat("a", "b", "c")
        let nest = sec.newFolder(named: "Nest", next: "b")!
        sec.move("b", into: nest.id)
        sec.move("c", into: nest.id)
        let bSpot = sec.spot(of: "b")!
        assert("a row's place is its folder and how far down it",
               bSpot == Pins.Spot(parent: nest.id, index: 0))

        // (1) The folder is still there: back into it, at the index it had.
        var back1 = sec
        back1.remove(tab: "b")
        back1.entries.append(Entry(row: .tab("b"), parent: nil))   // what `sync` does
        assert("…and it goes back into that folder, in front of the row it preceded",
               { var c = back1; c.put("b", at: bSpot)
                 return c.children(of: nest.id) == ["b", "c"] && c == sec }())

        // (2) The folder has gone: the end of the section, not a folder resurrected.
        var back2 = back1
        back2.remove(folder: nest.id)
        back2.put("b", at: bSpot)
        assert("a row whose folder has gone lands at the end of the section",
               back2.tabs == ["a", "c", "b"] && back2.folder(nest.id) == nil
                   && back2.folder(holding: "b") == nil)

        // (3) Everything the user did while the toast was up survives the undo.
        var back3 = back1
        let made = back3.newFolder(named: "Made")!
        back3.move("a", into: made.id)
        back3.put("b", at: bSpot)
        assert("a folder made while the toast was up survives the undo",
               back3.folder(made.id)?.name == "Made" && back3.children(of: made.id) == ["a"]
                   && back3.children(of: nest.id) == ["b", "c"])

        // The tail of a folder, and a folder emptied while the toast was up.
        let cSpot = sec.spot(of: "c")!
        var tail = sec
        tail.remove(tab: "c")
        tail.entries.append(Entry(row: .tab("c"), parent: nil))
        tail.put("c", at: cSpot)
        assert("a row that was last in its folder goes back last", tail == sec)
        var lone = flat("a")
        let empty = lone.newFolder(named: "Empty")!
        lone.entries.append(Entry(row: .tab("b"), parent: nil))
        lone.put("b", at: Pins.Spot(parent: empty.id, index: 0))
        assert("a row going back into a folder that is now empty is its only child",
               lone.children(of: empty.id) == ["b"])
        assert("a place is only ever asked for a row that is there", sec.spot(of: "nope") == nil)

        return out
    }
}

// MARK: - The store's side

extension TabStore {
    /// Which shape a section's rows are arranged by. Two sections have one; Favourites is a
    /// grid of tiles, and there is nowhere in a grid for a folder row to go.
    ///
    /// A key path rather than a `switch` at every call site: the folder row, its menu, its
    /// drop target and every store action below are written once and told which instance to
    /// read and write.
    static func shape(of kind: TabKind) -> ReferenceWritableKeyPath<TabStore, Pins>? {
        switch kind {
        case .pinned:    \.pins
        case .today:     \.todayShape
        case .favourite: nil
        }
    }

    /// Take in any tab that has just joined a section with a shape, and forget any that has
    /// left one. Called after every move, drop and close, so neither shape ever names a tab
    /// that is not in its section any more.
    func syncShapes() {
        pins.sync(tabs: tabs.filter { $0.kind == .pinned }.map(\.id.uuidString))
        todayShape.sync(tabs: tabs.filter { $0.kind == .today }.map(\.id.uuidString))
        // Today only. See `Pins.removeEmptyFolders`.
        todayShape.removeEmptyFolders()
    }

    /// Put a section's run of the strip in the order the sidebar draws it. The section is
    /// drawn from its shape, but ⌃⇥, ⌘1…9 and "tab 3 of 9" all read `tabs`, and a list that
    /// tabs through in a different order from the one on screen is a bug you cannot see.
    func applyOrder(_ kind: TabKind) {
        guard let shape = TabStore.shape(of: kind) else { return }
        // Every Today mutation ends here — a drop, a drag out of a folder, a tidy — so this
        // is where Today's own rule is settled: a folder with nothing left in it goes.
        // `syncShapes` says the same thing for the moves that do not come through here.
        if kind == .today { todayShape.removeEmptyFolders() }
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: an id the section somehow names
        // twice is a bug to survive, not one to trap the whole app on.
        let order = Dictionary(self[keyPath: shape].tabs.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { a, _ in a })
        let section = tabs.enumerated().filter { $0.element.kind == kind }
        let sorted = section.sorted {
            let a = order[$0.element.id.uuidString] ?? Int.max, b = order[$1.element.id.uuidString] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b          // sort() is not stable
        }
        for (slot, tab) in zip(section.map(\.offset), sorted.map(\.element)) { tabs[slot] = tab }
    }

    /// A drop on the strip, told to the section it landed in: a tab dropped on a row joins
    /// whatever folder that row is in, and one dragged out of a folder leaves it.
    func placeInShape(_ id: Tab.ID, onto target: Tab.ID, after: Bool) {
        syncShapes()
        guard let kind = tabs.first(where: { $0.id == id })?.kind,
              let shape = TabStore.shape(of: kind) else { return }
        self[keyPath: shape].move(id.uuidString, next: target.uuidString, after: after)
        applyOrder(kind)
    }

    /// The shape's half of "beside the opener". The strip move is `insertionIndexBeside`;
    /// this is the same move told to the section that is drawn from its shape, so the row
    /// lands after the opener and in whatever folder the opener sits in — and at the head of
    /// Today when the opener is a pinned row or a favourite, which is where the strip puts
    /// it. Without this the new tab draws at the bottom of the sidebar while ⌘1…9 has it
    /// beside its opener, and the next `applyOrder(.today)` drags the tab down to the bottom
    /// for real.
    ///
    /// Which of the three it is — including "leave it where `syncShapes` put it" for an
    /// opener that is nil or gone from this window — is `TabStore.rowBeside`, so the rule
    /// is proved beside `insertionIndexBeside` rather than trusted to a live window.
    func placeBeside(_ id: Tab.ID, opener: Tab.ID?) {
        syncShapes()        // the tab may be brand new to the shape; the opener never is
        switch TabStore.rowBeside(openerKind: tabs.first { $0.id == opener }?.kind) {
        case .leaveIt: break
        case .headOfToday: todayShape.insert(id.uuidString, after: nil)
        case .afterOpener: todayShape.insert(id.uuidString, after: opener?.uuidString)
        }
    }

    /// The section a shape stands for — what a tab dropped into one of its folders becomes.
    private func kind(of shape: ReferenceWritableKeyPath<TabStore, Pins>) -> TabKind {
        shape == \TabStore.todayShape ? .today : .pinned
    }

    /// Which section a folder is in — where a drag of it started. Nil for an id neither
    /// section knows, which is every folder of every other window. The `TabKind` version of
    /// the same question is `TabStore.shape(of:)`.
    func holder(of folder: UUID) -> ReferenceWritableKeyPath<TabStore, Pins>? {
        [\TabStore.pins, \TabStore.todayShape].first { self[keyPath: $0].folder(folder) != nil }
    }

    /// Whether a dragged folder may land in a section at all: its own always, the other one
    /// only when nothing else is filling it, or filling anything nested in it. Asked by the
    /// drop targets before they light up, so a live folder offers no target rather than
    /// landing and then explaining itself.
    func canDrag(folder id: UUID, into shape: ReferenceWritableKeyPath<TabStore, Pins>) -> Bool {
        guard let from = holder(of: id) else { return false }
        return from == shape || !self[keyPath: from].holdsLive(id)
    }

    /// A folder taken out of one section and put into the other: the folder, the tabs in it
    /// and the folders nested in it, in the order they were in. Nil when the drop cannot mean
    /// what it looks like — and then neither section is touched.
    ///
    /// ponytail: a live folder does not cross, and says nothing about it — nor does a plain
    /// folder carrying one. Its source is what fills it, and a copy of it in Today would be
    /// swept into the Library under the refresh that keeps putting the rows back.
    ///
    /// Pure, over the two values, so `selfcheck --pure` proves the whole move without a
    /// window: `move(folder:from:to:at:)` is this plus the tabs' kinds, the strip and the
    /// two saves.
    nonisolated static func moved(folder id: UUID, from source: Pins, to dest: Pins,
                                  at spot: Pins.Spot) -> (from: Pins, to: Pins)? {
        guard !source.holdsLive(id) else { return nil }
        var from = source, to = dest
        let rows = from.lift(folder: id)
        guard !rows.isEmpty else { return nil }
        to.entries += rows              // at the end, at the top level; the `put` places it
        to.put(id.uuidString, at: spot)
        // `Pins` refuses a spot too deep for what the folder is carrying rather than clamping
        // it, and the refused row is left where it was grafted. Asked after the fact, because
        // refusing is what the value already knows how to do — and a folder that did not land
        // where it was let go is a drop that did not happen.
        guard let i = to.index(of: id), to.entries[i].parent == spot.parent else { return nil }
        return (from, to)
    }

    /// A whole folder dragged across the divider: from Today up into Pinned, or from Pinned
    /// back down into Today. The record and its rows change section together, and every tab in
    /// it takes the new kind — pinned it stops auto-archiving, un-pinned it starts again. The
    /// folder keeps its name, its glyph and whether it is folded.
    ///
    /// The toast's Undo is this same move, back to the spot the folder came out of: one folder
    /// undone rather than a snapshot of two whole sections written back over everything the
    /// user has done since. `TabStore.unpin` puts one row back the same way.
    @discardableResult
    func move(folder id: UUID, from source: ReferenceWritableKeyPath<TabStore, Pins>,
              to dest: ReferenceWritableKeyPath<TabStore, Pins>, at spot: Pins.Spot,
              saying: Bool = true) -> Bool {
        let back = self[keyPath: source].spot(of: id.uuidString)
        let name = self[keyPath: source].folder(id)?.name ?? "folder"
        let moving = Set(self[keyPath: source].tabs(in: id))
        guard let shapes = TabStore.moved(folder: id, from: self[keyPath: source],
                                          to: self[keyPath: dest], at: spot) else { return false }
        let want = kind(of: dest)
        Motion.list {
            for tab in tabs where moving.contains(tab.id.uuidString) {
                tab.kind = want
                TidyTitles.refresh(tab)
            }
            // The rows have changed section, so the strip is grouped by section again before
            // either order is read off the shapes.
            normaliseSections()
            self[keyPath: source] = shapes.from
            self[keyPath: dest] = shapes.to
            applyOrder(kind(of: source))
            applyOrder(want)
        }
        savePins()
        guard saying else { return true }
        Toasts.show((want == .pinned ? "Pinned " : "Unpinned ") + name,
                    action: ("Undo", { [weak self] in
                        guard let self, let back else { return }
                        self.move(folder: id, from: dest, to: source,
                                  at: self[keyPath: source].landing(for: back), saying: false)
                    }), in: self)
        return true
    }

    /// A folder let go on a *section* rather than on a row of one: the space's name, the
    /// divider under Pinned, the New Tab row. It lands where a tab crossing the same divider
    /// lands — the end of Pinned, the head of Today. A folder let go on its own section has
    /// nowhere new to be and stays put.
    func move(folder id: UUID, to shape: ReferenceWritableKeyPath<TabStore, Pins>) {
        guard let from = holder(of: id), from != shape else { return }
        move(folder: id, from: from, to: shape,
             at: Pins.Spot(parent: nil, index: kind(of: shape) == .today ? 0 : .max))
    }

    /// A tab dragged onto a folder row — or sent there by "Move to Folder", which is the
    /// same move without a drag.
    func move(_ id: Tab.ID, into folder: UUID,
              in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        move(id, to: kind(of: shape))   // a Today tab pins itself into a pinned folder
        syncShapes()
        Motion.list {
            // Dropped into a folded folder the tab would simply vanish. Arc opens the
            // folder instead, so you can see where the thing you just moved went.
            self[keyPath: shape].edit(folder: folder) { $0.collapsed = false }
            self[keyPath: shape].move(id.uuidString, into: folder)
            applyOrder(kind(of: shape))
        }
        savePins()
        axAnnounce("Moved to \(self[keyPath: shape].folder(folder)?.name ?? "folder").")
    }

    /// A tab dropped on the top or bottom edge of a folder row: beside the folder, not in
    /// it — and after it means after everything the folder holds.
    func drop(_ id: Tab.ID, beside folder: UUID, after: Bool,
              in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        move(id, to: kind(of: shape))
        syncShapes()
        Motion.list {
            self[keyPath: shape].move(id.uuidString, next: folder.uuidString, after: after)
            applyOrder(kind(of: shape))
        }
        savePins()
    }

    /// A folder row dragged among a section's rows — its own, or the other one, which is the
    /// move that crosses the divider.
    func move(folder id: UUID, next to: String, after: Bool,
              in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        // Dragged in from the other section: this shape has never heard of the folder, so
        // there is no row here to move and it is placed by where the drop was instead.
        if let from = holder(of: id), from != shape,
           let spot = self[keyPath: shape].spot(next: to, after: after) {
            move(folder: id, from: from, to: shape, at: spot)
            return
        }
        Motion.list {
            self[keyPath: shape].move(id.uuidString, next: to, after: after)
            applyOrder(kind(of: shape))
        }
        savePins()
    }

    func move(folder id: UUID, into parent: UUID,
              in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        // From the other section: in at the end, which is where a drop on a folder's middle
        // lands anything. See `move(folder:next:after:in:)`. Opened only once something has
        // arrived — a drop the depth cap refuses leaves the folder as the drag found it.
        if let from = holder(of: id), from != shape {
            if move(folder: id, from: from, to: shape,
                    at: Pins.Spot(parent: parent, index: .max)) {
                Motion.list { self[keyPath: shape].edit(folder: parent) { $0.collapsed = false } }
                savePins()   // the fold is written down too
            }
            return
        }
        Motion.list {
            self[keyPath: shape].edit(folder: parent) { $0.collapsed = false }   // see above
            self[keyPath: shape].move(id.uuidString, into: parent)
            applyOrder(kind(of: shape))
        }
        savePins()
        axAnnounce("Moved to \(self[keyPath: shape].folder(parent)?.name ?? "folder").")
    }

    /// Arc's "New Folder": made where the click was, named in place. With a tab, that tab
    /// moves into it — right-clicking a pinned tab and asking for a folder means "put this
    /// in one", not "make an empty one somewhere".
    @discardableResult
    func newFolder(from tab: Tab.ID? = nil, beside folder: UUID? = nil,
                   in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) -> Folder? {
        // Where the new folder goes: beside the row that was right-clicked, at that row's
        // own level, or at the end of the section when nothing was.
        let next = tab?.uuidString ?? folder?.uuidString
        // Asked before anything moves: pinning the tab and *then* finding there is no room
        // for a folder around it would leave the tab moved with nothing to show for it.
        guard self[keyPath: shape].canNestFolder(next: next) else {
            axAnnounce("Folders nest \(Pins.maxDepth + 1) deep at most.")
            return nil
        }
        if let tab { move(tab, to: kind(of: shape)) }
        syncShapes()
        let folder = Motion.list { () -> Folder? in
            let made = self[keyPath: shape].newFolder(next: next)
            if let made, let tab { self[keyPath: shape].move(tab.uuidString, into: made.id) }
            applyOrder(kind(of: shape))
            return made
        }
        savePins()
        renamingFolder = folder?.id
        if let folder { axAnnounce("New folder \(folder.name).") }
        return folder
    }

    /// Folding is a list change like any other, so the rows under it collapse and the ones
    /// below slide up rather than blinking out.
    func toggleFolder(_ id: UUID, in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        Motion.list { self[keyPath: shape].toggle(folder: id) }
        savePins()
        // Unfolding a live folder refreshes it: what you are about to look at is the one
        // thing worth being up to date. Folding it does not — nobody is looking.
        if self[keyPath: shape].folder(id)?.collapsed == false {
            LiveFolders.shared(for: profileID).expanded(id)
        }
    }

    /// Arc's "Delete Folder": the folder goes, the tabs stay where they were sitting and
    /// simply become ordinary pinned rows. Nothing is closed — deleting a folder full of
    /// pages the user pinned on purpose is not something a menu item gets to do silently.
    func deleteFolder(_ id: UUID, in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        let name = self[keyPath: shape].folder(id)?.name ?? "folder"
        let kept = self[keyPath: shape].tabs(in: id).count
        let wasLive = self[keyPath: shape].folder(id)?.live != nil
        // In every window showing this Space, not just this one. Each holds its own copy of
        // the shape and each writes it back, so a window left holding the folder would put
        // it back on its next `savePins` — and a live folder that came back would start
        // filling itself again.
        for other in TabStore.all where other !== self && other.profileID == profileID
            && !other.isPrivate && !other.isLittle && other[keyPath: shape].folder(id) != nil {
            Motion.list {
                other[keyPath: shape].remove(folder: id)
                other.applyOrder(kind(of: shape))
            }
            other.savePins()
        }
        Motion.list {
            self[keyPath: shape].remove(folder: id)
            applyOrder(kind(of: shape))
        }
        savePins()
        // The one event that means a live folder is not coming back. Its rows stay, as
        // ordinary pinned tabs; what goes is the glyphs, so the map does not grow by one
        // entry per live folder ever made.
        if wasLive { LiveFolders.shared(for: profileID).forget(folder: id) }
        axAnnounce("Deleted \(name). \(kept) tab\(kept == 1 ? "" : "s") kept in "
                   + TabMenu.name(kind(of: shape)) + ".")
    }

    /// "Archive all tabs in folder": the pages go to the Library and the folder is left
    /// empty. They have to leave Pinned first — a pinned tab is never archived, which is
    /// the whole difference between the sections.
    func archiveFolder(_ id: UUID, in shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins) {
        // A live folder stops being one. Archiving its tabs empties it, and a folder that
        // keeps itself filled would put every one of them straight back on the next refresh
        // — which is not something "Archive All Tabs in Folder" can be made to mean. The
        // folder stays, with its name and its place; it simply stops being told what to hold.
        if self[keyPath: shape].folder(id)?.live != nil {
            LiveFolders.shared(for: profileID).stopKeepingFilled(id, saying: false)
        }
        // Only what is still open: the shape is synced on every change, but a tab named here
        // and gone by the time the menu item is clicked must not be counted or announced.
        let live = self[keyPath: shape].tabs(in: id).compactMap(UUID.init(uuidString:))
            .filter { want in tabs.contains { $0.id == want } }
        // One animation and one write for the lot. `move(_:to:)` per tab would be one of
        // each per tab, and the rows would leave Pinned in separate frames. A Today folder's
        // rows are already in Today and simply stay where they are — what archives them is
        // the sweep below, exactly as for any other Today tab.
        Motion.list {
            for want in live where kind(of: shape) == .pinned {
                guard let i = tabs.firstIndex(where: { $0.id == want }) else { continue }
                let tab = tabs.remove(at: i)
                tab.kind = .today
                TidyTitles.refresh(tab)
                tabs.insert(tab, at: TabStore.clampedDestination(
                    others: tabs.map(\.kind), moving: .today, to: 0))
            }
            syncShapes()
            // The rows that just left Pinned went to the *head* of the Today strip, and
            // `sync` takes a row it has not seen at the end of the section. Today is drawn
            // from its shape, so the shape follows the strip here — otherwise the next line
            // reads the shape back and drags them to the bottom.
            todayShape.relay(tabs.filter { $0.kind == .today }.map(\.id.uuidString))
            applyOrder(.pinned)
            applyOrder(.today)
        }
        savePins()
        // `archive` counts its own burst, so the rows sweep out one after another.
        live.forEach { archive($0) }
        axAnnounce("Archived \(live.count) tab\(live.count == 1 ? "" : "s").")
    }

    // MARK: Persistence

    /// ponytail: the section's shape in UserDefaults beside the urls it orders, one key per
    /// Space. A sidecar file (the way `Suspension.SpaceState` does it) would be the tidier
    /// home, but this is one `Data` of a few hundred bytes and the flat url list it belongs
    /// to already lives here. `forgetShape` is what takes a deleted Space's key with it.
    static func shapeKey(_ kind: TabKind = .pinned, space: UUID?, profileID: UUID) -> String {
        let name = kind == .today ? "todayShape" : "pinShape"
        return ProfileManager.defaultsKey(space.map { "\(name).\($0.uuidString)" } ?? name,
                                          profileID)
    }

    /// Both sections' shapes exactly as they sit in the defaults. Bytes rather than folders,
    /// because the one caller is `TabStore.fingerprint`, which has to notice *any* edit —
    /// see `Stash`.
    static func shapeData(space: UUID?, profileID: UUID) -> [Data?] {
        [TabKind.pinned, .today].map {
            UserDefaults.vane.data(forKey: shapeKey($0, space: space, profileID: profileID))
        }
    }

    /// A Space being deleted takes its folders with it; the key would otherwise sit in the
    /// defaults for the life of the profile, waiting for a Space id that will never come back.
    static func forgetShape(space: UUID, profileID: UUID) {
        for kind in [TabKind.pinned, .today] {
            UserDefaults.vane.removeObject(forKey: shapeKey(kind, space: space,
                                                            profileID: profileID))
        }
    }

    /// Whether a window whose own Pinned section is empty is allowed to clear the saved
    /// shape. The same ownership test `restorePins` makes, said from the writing end:
    ///
    /// - a saved shape that still names tabs belongs to a window that has them. This one was
    ///   never handed the profile's rows — a second Space-less window — and clearing would
    ///   take that window's folders with it.
    /// - a saved shape naming no tabs is folders and nothing else. The last pinned tab has
    ///   left the Space, and leaving the key behind would have `adoptPins` rebuild those
    ///   folders, empty, at the next launch.
    /// - no saved shape at all is a fresh profile, and clearing nothing is what it wants.
    ///
    /// Pure, so `selfcheck --pure` can drive it without a defaults suite.
    nonisolated static func clearsShape(saved: Pins?) -> Bool { saved?.tabs.isEmpty ?? true }

    /// nil for a Space that has never had folders in that section — and for junk in the key,
    /// which loads as "no folders" rather than as a failure to bring the Space up at all.
    static func savedShape(_ kind: TabKind = .pinned, space: UUID?, profileID: UUID) -> Pins? {
        guard let data = UserDefaults.vane.data(forKey: shapeKey(kind, space: space,
                                                                 profileID: profileID))
        else { return nil }
        return try? JSONDecoder().decode(Pins.self, from: data)
    }

    /// Both sections' folders, written down beside the urls they arrange. Today's key is a
    /// second one of exactly the same shape, so a Space saved before Today had folders comes
    /// back with none — see `savedShape`.
    func saveShape() {
        guard !isPrivate, !isLittle else { return }
        saveShape(.pinned, \.pins)
        saveShape(.today, \.todayShape)
    }

    /// The shape as it goes to disk: the same folders, with every tab named by the page it
    /// is on rather than by a `Tab.ID` that will not exist after a relaunch.
    private func saveShape(_ kind: TabKind, _ shape: ReferenceWritableKeyPath<TabStore, Pins>) {
        let key = TabStore.shapeKey(kind, space: currentSpaceID, profileID: profileID)
        // A window whose Pinned section is empty may have nothing to say about the shape —
        // it can be one that was never handed the profile's rows — so it is asked whether
        // it is allowed to speak first. It used to be told to say nothing at all, and the
        // cost of that was the last pinned tab leaving a Space with the folders it was in
        // still written down: `adoptPins` rebuilt them, empty, at the next launch. Undoing a
        // tidy on a window that had no pins to begin with hit it every time.
        if self[keyPath: shape].entries.isEmpty {
            if TabStore.clearsShape(saved: TabStore.savedShape(kind, space: currentSpaceID,
                                                              profileID: profileID)) {
                UserDefaults.vane.removeObject(forKey: key)
            }
            return
        }
        let byID = Dictionary(tabs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        // `pinnedURL`, like `savePins`: the shape and the list must name a row by the same url,
        // or `pinOrder` cannot put a wandered row back in its folder. See `Tab.homeURL`.
        let named = self[keyPath: shape].mapped { byID[$0].flatMap { TabStore.pinURL($0.pinnedURL) } }
        // Nothing but loose tabs is nothing worth writing: an empty shape is what a fresh
        // profile has, and leaving the key absent keeps `savedShape` honest about that.
        guard named.entries.contains(where: { $0.folder != nil }) else {
            UserDefaults.vane.removeObject(forKey: key)
            return
        }
        UserDefaults.vane.set(try? JSONEncoder().encode(named), forKey: key)
    }

    /// The pinned urls in the order the saved shape draws them, with anything the shape has
    /// never heard of after — a tab another window moved into this Space while it was shut.
nonisolated static func pinOrder(shape: Pins?, urls: [URL]) -> [URL] {
        guard let shape else { return urls }
        // Counted, not a Set: two pinned tabs can sit on the same page, and matching by
        // membership alone either drops the second one or invents one the window has not got.
        var left: [String: Int] = [:]
        for u in urls { left[u.absoluteString, default: 0] += 1 }
        var ordered: [URL] = []
        for name in shape.tabs {
            guard let n = left[name], n > 0, let url = URL(string: name) else { continue }
            left[name] = n - 1
            ordered.append(url)
        }
        var tail: [URL] = []
        for u in urls {
            guard let n = left[u.absoluteString], n > 0 else { continue }
            left[u.absoluteString] = n - 1
            tail.append(u)
        }
        return ordered + tail
    }

    /// The saved shape with every url replaced by the tab restored for it, in order, and any
    /// tab the shape has never heard of taken in at the end.
    ///
    /// The name is the url the tab was **opened with**, not the one it has now. A restored
    /// tab is normally parked, and a parked tab answers `currentURL` before it has loaded
    /// anything — but with `Prefs.suspendTabs` off it is handed straight to `go(url)`, and
    /// `WKWebView.url` is still nil when this runs. Keying on `currentURL` there matched
    /// nothing and dropped every folder in the section, on every launch.
    ///
    /// Pure, over strings, so `selfcheck --pure` can prove that without a window or a `Tab`.
    nonisolated static func adopted(_ saved: Pins?, opened: [(url: String, id: String)]) -> Pins {
        var byURL: [String: [String]] = [:]
        for o in opened { byURL[o.url, default: []].append(o.id) }
        // Counted off one at a time, so two tabs on the same page land in the folders they
        // were each in rather than both in the first one's.
        var out = (saved ?? Pins()).mapped { url in
            guard var waiting = byURL[url], !waiting.isEmpty else { return nil }
            let id = waiting.removeFirst()
            byURL[url] = waiting
            return id
        }
        out.sync(tabs: opened.map(\.id))
        return out
    }

    /// Rebuild the live shape once the tabs exist, each named by the url it was opened with.
    func adopt(_ shape: ReferenceWritableKeyPath<TabStore, Pins>, saved: Pins?,
               tabs made: [(url: URL, tab: Tab)]) {
        self[keyPath: shape] = TabStore.adopted(
            saved, opened: made.map { ($0.url.absoluteString, $0.tab.id.uuidString) })
    }

    /// The Today section's folders, once its tabs exist. The urls came back in the order the
    /// Space wrote them — which is the order the shape drew them — so there is no `pinOrder`
    /// to do here, only the names to translate and the rows to take in.
    ///
    /// A Space with nothing under the Today key loads as loose tabs and no folders, and so
    /// does one whose key holds junk: `savedShape` hands back nil for both.
    func adoptTodayShape(tabs made: [(url: URL, tab: Tab)]) {
        let saved = isPrivate || isLittle ? nil
            : TabStore.savedShape(.today, space: currentSpaceID, profileID: profileID)
        adopt(\.todayShape, saved: saved, tabs: made)
        // A folder whose every tab has gone from the Space since it was written down.
        todayShape.removeEmptyFolders()
        applyOrder(.today)
    }

    /// Everything a window has to do to bring the Pinned section up: the tabs, in the saved
    /// order, and the folders around them.
    @discardableResult
    func restorePins(urls: [URL], parked: [String: Parked]) -> [Tab] {
        // Only a window that was actually handed the pinned rows owns the section. A private
        // window and a Little Arc are handed none by design, and so is the second Space-less
        // window of a profile — reading the shape in any of them would draw the folders as
        // empty rows, and the next `saveShape` would write that folder-only shape back over
        // the real one, losing every membership in it.
        let saved = isPrivate || isLittle ? nil
            : TabStore.savedShape(space: currentSpaceID, profileID: profileID)
        let shape = urls.isEmpty && saved?.tabs.isEmpty == false ? nil : saved
        let order = TabStore.pinOrder(shape: shape, urls: urls)
        let made = restore(order, as: .pinned, parked: parked)
        adopt(\.pins, saved: shape, tabs: zip(order, made).map { (url: $0, tab: $1) })
        return made
    }
}

// MARK: - Views

/// A folder's name while it is being renamed. The tab version lives in `Rename.swift` and is
/// tied to a `Tab`'s page title; a folder has no page, so the rule is shorter: what is typed
/// is the name, and nothing typed keeps the one it had.
struct FolderNameField: View {
    @ObservedObject var store: TabStore
    let folder: Folder
    /// Which section's shape the name is written into — Pinned's or Today's.
    var shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins
    @State private var draft = ""
    @State private var done = false
    /// Whether this field ever held the caret. A field that never did holds the name the
    /// folder had when it was built, and committing that would quietly undo a rename made
    /// in the meantime — which is exactly what happened when the collapse animation left a
    /// second, stale field behind.
    @State private var armed = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Folder name", text: $draft)
            .textFieldStyle(.plain)
            .font(Look.rowTitle)
            .foregroundStyle(Look.inkPrimary)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onAppear { draft = folder.name }
            // Focus on the *next* turn, not inside `onAppear`. A click on a folder row also
            // folds it, so the rename starts while the list animation that click began is
            // still running — and a focus request made in that frame is dropped, leaving a
            // field nothing can be typed into. `RenameField` has no such race: clicking a
            // tab row only selects it.
            .task { focused = true }
            .onChange(of: focused) { _, now in
                if now { armed = true } else if armed { commit() }
            }
            .onDisappear { if armed { commit() } }
            .accessibilityLabel("Folder name")
            .accessibilityHint("Return renames the folder, Escape keeps its current name.")
    }

    private func commit() {
        guard !done else { return }
        done = true
        defer { if store.renamingFolder == folder.id { store.renamingFolder = nil } }
        guard let name = TabActions.cleanName(draft), name != folder.name else { return }
        store[keyPath: shape].edit(folder: folder.id) { $0.name = name }
        store.savePins()
        axAnnounce("Renamed to \(name).")
    }

    private func cancel() {
        done = true
        if store.renamingFolder == folder.id { store.renamingFolder = nil }
    }
}

/// Arc's "Change Icon": the same grid a Space picks from, plus a field for an emoji.
///
/// ponytail: no emoji browser of our own. The field is one character wide and macOS's own
/// picker (⌃⌘Space) is the browser — shipping a second one would mean bundling an emoji
/// catalogue to search, which is a data file, not a feature.
struct FolderIcons: View {
    @ObservedObject var store: TabStore
    let folder: Folder
    /// See `FolderNameField.shape`.
    var shape: ReferenceWritableKeyPath<TabStore, Pins> = \.pins
    @State private var emoji = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.rowHeight), spacing: 6),
                                     count: 6), spacing: 6) {
                ForEach([Folder.defaultIcon] + Spaces.icons, id: \.self) { name in
                    Button { pick(name) } label: { tile(name) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(folder.icon == name ? [.isButton, .isSelected]
                                                                    : .isButton)
                }
            }
            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji)
                    .textFieldStyle(.plain)
                    .font(Look.text)
                    .frame(width: Look.rowHeight)
                    .padding(.horizontal, 8)
                    .frame(height: Look.rowHeight)
                    .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
                    .onSubmit { pickEmoji() }
                    .accessibilityLabel("Folder emoji")
                Text("Control-Command-Space for the emoji picker.")
                    .font(Look.caption)
                    .foregroundStyle(Look.inkTertiary)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder icon")
    }

    private func tile(_ name: String) -> some View {
        Image(systemName: name)
            .font(Look.icon)
            .frame(width: Look.rowHeight, height: Look.rowHeight)
            .background(folder.icon == name ? Look.selected : .clear,
                        in: .rect(cornerRadius: Look.pillRadius))
    }

    /// One character, so a pasted sentence cannot become a folder's glyph.
    private func pickEmoji() {
        guard let first = emoji.first else { return }
        pick(String(first))
    }

    private func pick(_ icon: String) {
        store[keyPath: shape].edit(folder: folder.id) { $0.icon = icon }
        store.savePins()
        dismiss()
    }
}
