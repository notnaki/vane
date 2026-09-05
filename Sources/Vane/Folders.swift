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

    static let defaultIcon = "folder"

    /// True when `icon` is something to draw as text rather than to look up in SF Symbols.
    var iconIsEmoji: Bool { !icon.allSatisfy(\.isASCII) }
}

/// The whole shape of Arc's Pinned section: folders, the tabs in them, and the order they
/// are drawn in.
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

    /// The tabs inside a folder, however deeply. "Archive all tabs in folder" is this list.
    func tabs(in folder: UUID) -> [String] {
        guard let i = index(of: folder) else { return [] }
        return entries[subtree(at: i)].compactMap(\.tab)
    }

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
        let parent = entries[t].parent
        guard (parent.flatMap { index(of: $0).map { depth(of: $0) + 1 } } ?? 0) <= Pins.maxDepth
        else { return nil }
        entries.insert(Entry(row: .folder(folder), parent: parent), at: subtree(at: t).lowerBound)
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

        return out
    }
}

// MARK: - The store's side

extension TabStore {
    /// Take in any tab that has just become pinned, and forget any that has stopped being
    /// one. Called after every move, drop and close, so `pins` never names a tab that is not
    /// in the Pinned section any more.
    func syncPins() {
        pins.sync(tabs: tabs.filter { $0.kind == .pinned }.map(\.id.uuidString))
    }

    /// Put the strip's pinned run in the order the sidebar draws it. The Pinned section is
    /// drawn from `pins`, but ⌃⇥, ⌘1…9 and "tab 3 of 9" all read `tabs`, and a list that
    /// tabs through in a different order from the one on screen is a bug you cannot see.
    func applyPinOrder() {
        let order = Dictionary(uniqueKeysWithValues: pins.tabs.enumerated().map { ($0.element, $0.offset) })
        let pinned = tabs.enumerated().filter { $0.element.kind == .pinned }
        let sorted = pinned.sorted {
            let a = order[$0.element.id.uuidString] ?? Int.max, b = order[$1.element.id.uuidString] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b          // sort() is not stable
        }
        for (slot, tab) in zip(pinned.map(\.offset), sorted.map(\.element)) { tabs[slot] = tab }
    }

    /// A drop on the strip, told to the Pinned section: a tab dropped on a pinned row joins
    /// whatever folder that row is in, and one dragged out of Pinned leaves its folder.
    func placeInPins(_ id: Tab.ID, onto target: Tab.ID, after: Bool) {
        syncPins()
        guard tabs.first(where: { $0.id == id })?.kind == .pinned else { return }
        pins.move(id.uuidString, next: target.uuidString, after: after)
        applyPinOrder()
    }

    /// A tab dragged onto a folder row.
    func move(_ id: Tab.ID, into folder: UUID) {
        move(id, to: .pinned)          // a Today tab pins itself on the way in
        syncPins()
        Motion.list {
            pins.move(id.uuidString, into: folder)
            applyPinOrder()
        }
        savePins()
    }

    /// A tab dropped on the top or bottom edge of a folder row: beside the folder, not in
    /// it — and after it means after everything the folder holds.
    func drop(_ id: Tab.ID, beside folder: UUID, after: Bool) {
        move(id, to: .pinned)
        syncPins()
        Motion.list {
            pins.move(id.uuidString, next: folder.uuidString, after: after)
            applyPinOrder()
        }
        savePins()
    }

    /// A folder row dragged among the pinned rows.
    func move(folder id: UUID, next to: String, after: Bool) {
        Motion.list {
            pins.move(id.uuidString, next: to, after: after)
            applyPinOrder()
        }
        savePins()
    }

    func move(folder id: UUID, into parent: UUID) {
        Motion.list {
            pins.move(id.uuidString, into: parent)
            applyPinOrder()
        }
        savePins()
    }

    /// Arc's "New Folder": made where the click was, named in place. With a tab, that tab
    /// moves into it — right-clicking a pinned tab and asking for a folder means "put this
    /// in one", not "make an empty one somewhere".
    @discardableResult
    func newFolder(from tab: Tab.ID? = nil) -> Folder? {
        if let tab { move(tab, to: .pinned) }
        syncPins()
        let folder = Motion.list { () -> Folder? in
            let made = pins.newFolder(next: tab?.uuidString)
            if let made, let tab { pins.move(tab.uuidString, into: made.id) }
            applyPinOrder()
            return made
        }
        savePins()
        renamingFolder = folder?.id
        if let folder { axAnnounce("New folder \(folder.name).") }
        return folder
    }

    /// Folding is a list change like any other, so the rows under it collapse and the ones
    /// below slide up rather than blinking out.
    func toggleFolder(_ id: UUID) {
        Motion.list { pins.toggle(folder: id) }
        savePins()
    }

    /// Arc's "Delete Folder": the folder goes, the tabs stay where they were sitting and
    /// simply become ordinary pinned rows. Nothing is closed — deleting a folder full of
    /// pages the user pinned on purpose is not something a menu item gets to do silently.
    func deleteFolder(_ id: UUID) {
        let name = pins.folder(id)?.name ?? "folder"
        let kept = pins.tabs(in: id).count
        Motion.list {
            pins.remove(folder: id)
            applyPinOrder()
        }
        savePins()
        axAnnounce("Deleted \(name). \(kept) tab\(kept == 1 ? "" : "s") kept in Pinned.")
    }

    /// "Archive all tabs in folder": the pages go to the Library and the folder is left
    /// empty. They have to leave Pinned first — a pinned tab is never archived, which is
    /// the whole difference between the sections.
    func archiveFolder(_ id: UUID) {
        let ids = pins.tabs(in: id).compactMap { UUID(uuidString: $0) }
        for tab in ids where tabs.contains(where: { $0.id == tab }) {
            move(tab, to: .today)
            archive(tab)
        }
        syncPins()
        savePins()
        axAnnounce("Archived \(ids.count) tab\(ids.count == 1 ? "" : "s").")
    }

    // MARK: Persistence

    /// ponytail: the section's shape in UserDefaults beside the urls it orders, one key per
    /// Space. A sidecar file (the way `Suspension.SpaceState` does it) would be the tidier
    /// home, but this is one `Data` of a few hundred bytes and the flat url list it belongs
    /// to already lives here. Ceiling: deleting a Space leaves its key behind.
    static func shapeKey(space: UUID?, profileID: UUID) -> String {
        ProfileManager.defaultsKey(space.map { "pinShape.\($0.uuidString)" } ?? "pinShape",
                                   profileID)
    }

    static func savedShape(space: UUID?, profileID: UUID) -> Pins? {
        guard let data = UserDefaults.standard.data(forKey: shapeKey(space: space, profileID: profileID))
        else { return nil }
        return try? JSONDecoder().decode(Pins.self, from: data)
    }

    /// The shape as it goes to disk: the same folders, with every tab named by the page it
    /// is on rather than by a `Tab.ID` that will not exist after a relaunch.
    func saveShape() {
        guard !isPrivate else { return }
        let byID = Dictionary(tabs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let shape = pins.mapped { byID[$0].flatMap { TabStore.pinURL($0.currentURL) } }
        let key = TabStore.shapeKey(space: currentSpaceID, profileID: profileID)
        // Nothing but loose tabs is nothing worth writing: an empty shape is what a fresh
        // profile has, and leaving the key absent keeps `savedShape` honest about that.
        guard shape.entries.contains(where: { $0.folder != nil }) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(shape), forKey: key)
    }

    /// The pinned urls in the order the saved shape draws them, with anything the shape has
    /// never heard of after — a tab another window moved into this Space while it was shut.
    static func pinOrder(shape: Pins?, urls: [URL]) -> [URL] {
        guard let shape else { return urls }
        let known = Set(urls.map(\.absoluteString))
        let ordered = shape.tabs.filter(known.contains).compactMap(URL.init(string:))
        let seen = Set(ordered.map(\.absoluteString))
        return ordered + urls.filter { !seen.contains($0.absoluteString) }
    }

    /// Rebuild the live shape once the tabs exist. The saved one names its tabs by url; this
    /// is where those names become the ids of the tabs just made for them, in order, so two
    /// pinned tabs on the same page still land in the folders they were each in.
    func adoptPins(shape: Pins?, tabs made: [Tab]) {
        var byURL: [String: [Tab.ID]] = [:]
        for t in made { byURL[t.currentURL?.absoluteString ?? "", default: []].append(t.id) }
        pins = (shape ?? Pins()).mapped { url in
            guard var waiting = byURL[url], !waiting.isEmpty else { return nil }
            let id = waiting.removeFirst()
            byURL[url] = waiting
            return id.uuidString
        }
        pins.sync(tabs: made.map(\.id.uuidString))
    }

    /// Everything a window has to do to bring the Pinned section up: the tabs, in the saved
    /// order, and the folders around them.
    @discardableResult
    func restorePins(urls: [URL], parked: [String: Parked]) -> [Tab] {
        let shape = TabStore.savedShape(space: currentSpaceID, profileID: profileID)
        let made = restore(TabStore.pinOrder(shape: shape, urls: urls), as: .pinned, parked: parked)
        adoptPins(shape: shape, tabs: made)
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
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Folder name", text: $draft)
            .textFieldStyle(.plain)
            .font(Look.rowTitle)
            .foregroundStyle(Look.inkPrimary)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onAppear { draft = folder.name; focused = true }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onDisappear { commit() }
            .accessibilityLabel("Folder name")
            .accessibilityHint("Return renames the folder, Escape keeps its current name.")
    }

    private func commit() {
        guard !done else { return }
        done = true
        defer { if store.renamingFolder == folder.id { store.renamingFolder = nil } }
        guard let name = TabActions.cleanName(draft), name != folder.name else { return }
        store.pins.edit(folder: folder.id) { $0.name = name }
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
        store.pins.edit(folder: folder.id) { $0.icon = icon }
        store.savePins()
        dismiss()
    }
}
