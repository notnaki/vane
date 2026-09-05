import AppKit
import SwiftUI
import WebKit

/// The everyday link gestures every browser has and Vane did not: ⌘-click and middle-click
/// open a link in a new tab *beside* the one it came from, ⇧⌘-click does the same and goes
/// there, and Escape stops a page that is still loading.
enum TabActions {

    /// What a click on a link should do, given the modifiers it was made with.
    /// `focus` is only meaningful when `beside` is true.
    struct Intent: Equatable {
        let beside: Bool
        let focus: Bool
    }

    /// `WKNavigationAction.buttonNumber` is a *mask*, not an index, whatever its name says:
    /// measured against a real mouse it reports 1 for a left click and 4 for a wheel click,
    /// which is `NSEvent.pressedMouseButtons` bit order (left 1, right 2, other 4). Guessing
    /// WebCore's `MouseButton` enum here — where middle is 1 — would have turned every
    /// ordinary left click into a background tab.
    /// ponytail ceiling: a mouse that reports its wheel click as something else navigates in
    /// place, which is what happened before this existed.
    static let middleButton = 4

    /// Nil means "let it navigate here", which is the answer for an ordinary click and for
    /// every navigation that is not a click at all (a redirect, a form post, JavaScript).
    ///
    /// ⌘ opens beside and stays put — the point of ⌘-click is to keep reading and collect
    /// links as you go. ⇧⌘ opens beside and goes there. A middle-click is ⌘-click with the
    /// wheel, the way every other browser has it.
    static func intent(command: Bool, shift: Bool, button: Int) -> Intent? {
        if button == middleButton { return Intent(beside: true, focus: false) }
        guard command else { return nil }
        return Intent(beside: true, focus: shift)
    }

    /// The same question asked of a real navigation. Only a click on a link counts: a ⌘ held
    /// down while a page redirects itself is not a request for a tab.
    @MainActor static func intent(for action: WKNavigationAction) -> Intent? {
        guard action.navigationType == .linkActivated else { return nil }
        return intent(command: action.modifierFlags.contains(.command),
                      shift: action.modifierFlags.contains(.shift),
                      button: action.buttonNumber)
    }

    /// Escape while a page is still coming in. Arc stops the load; every other browser does
    /// too, and Vane only had the Stop button in the sidebar's top row.
    ///
    /// Returns true when it acted, so the caller swallows the key. A page that is *not*
    /// loading never sees Escape taken away from it — closing its own dialog, leaving its own
    /// full-screen video and dismissing its own menu are all Escape, and all of them matter
    /// more than a stop that has nothing to stop.
    @MainActor static func stopLoading(in window: NSWindow?) -> Bool {
        guard let store = TabStore.all.first(where: { $0.window === window }),
              let tab = store.active, tab.loading else { return false }
        tab.stop()
        axAnnounce("Stopped loading.")
        return true
    }
}

extension TabStore {
    /// Where a tab opened from another tab goes. Beside its opener when the opener is an
    /// ordinary Today tab — which is what "beside" means to anyone who has ⌘-clicked a link —
    /// and at the head of Today when it came from a favourite or a pinned tab, since those
    /// live in sections a new page has no business joining.
    ///
    /// Pure index arithmetic over the strip's kinds, like `clampedDestination` next door, so
    /// `selfcheck --pure` can prove it. `kinds` is the strip *without* the new tab in it.
    static func insertionIndexBeside(current: Int?, kinds: [TabKind]) -> Int {
        let firstToday = kinds.firstIndex(of: .today) ?? kinds.count
        guard let i = current, kinds.indices.contains(i) else { return kinds.count }
        return kinds[i] == .today ? i + 1 : firstToday
    }

    /// An empty tab, placed beside `opener`. ⌘-click loads a url into it; Peek's ⌘O parks
    /// its page into it instead — which is the only reason the placement is separable from
    /// `openBeside` at all.
    @discardableResult
    func newTabBeside(_ opener: Tab.ID?) -> Tab {
        // One animation for the append and the move, so the row grows in beside its opener
        // rather than appearing at the bottom and flying up.
        Motion.list {
            let tab = newBlankTab()          // appends, and takes focus
            if let from = tabs.firstIndex(where: { $0.id == tab.id }) {
                let moved = tabs.remove(at: from)
                let dest = TabStore.insertionIndexBeside(
                    current: tabs.firstIndex { $0.id == opener }, kinds: tabs.map(\.kind))
                tabs.insert(moved, at: min(dest, tabs.count))
            }
            return tab
        }
    }

    /// Open a url in a new tab beside the current one. `focus` false leaves the user where
    /// they were, which is the whole point of ⌘-click.
    func openBeside(_ url: URL, focus: Bool) {
        let opener = current
        newTabBeside(opener).web.load(URLRequest(url: url))
        if !focus {
            current = opener
            axAnnounce("Opened in a background tab.")
        }
    }
}

extension TabActions {
    /// Offline proof of the modifier table and the insertion arithmetic.
    @MainActor static func check() -> [(String, Bool)] {
        let plain = 0
        var out: [(String, Bool)] = [
            ("an ordinary click navigates in place",
             intent(command: false, shift: false, button: plain) == nil),
            ("⇧-click on its own navigates in place",
             intent(command: false, shift: true, button: plain) == nil),
            ("⌘-click opens beside, in the background",
             intent(command: true, shift: false, button: plain) == Intent(beside: true, focus: false)),
            ("⇧⌘-click opens beside and goes there",
             intent(command: true, shift: true, button: plain) == Intent(beside: true, focus: true)),
            ("middle-click opens beside, in the background",
             intent(command: false, shift: false, button: middleButton)
                == Intent(beside: true, focus: false)),
            ("…whatever else is held down",
             intent(command: true, shift: true, button: middleButton)
                == Intent(beside: true, focus: false)),
            ("the right button is not the middle one",
             intent(command: false, shift: false, button: 2) == nil),
            ("…and neither is the left one, which is 1 and not 0",
             intent(command: false, shift: false, button: 1) == nil),
        ]

        // Insertion. The strip is always sorted favourite → pinned → today.
        let strip: [TabKind] = [.favourite, .pinned, .today, .today, .today]
        out += [
            ("a tab opened from a Today tab lands right after it",
             TabStore.insertionIndexBeside(current: 3, kinds: strip) == 4),
            ("…including from the last one",
             TabStore.insertionIndexBeside(current: 4, kinds: strip) == 5),
            ("a tab opened from a favourite lands at the head of Today",
             TabStore.insertionIndexBeside(current: 0, kinds: strip) == 2),
            ("…and so does one opened from a pinned tab",
             TabStore.insertionIndexBeside(current: 1, kinds: strip) == 2),
            ("with nothing selected it goes to the end",
             TabStore.insertionIndexBeside(current: nil, kinds: strip) == strip.count),
            ("an index that is not in the strip goes to the end",
             TabStore.insertionIndexBeside(current: 99, kinds: strip) == strip.count),
            ("an empty strip takes it at zero",
             TabStore.insertionIndexBeside(current: nil, kinds: []) == 0),
            ("with no Today tabs at all it still lands after the ones that stay",
             TabStore.insertionIndexBeside(current: 0, kinds: [.favourite, .pinned]) == 2),
            ("nothing downloading is no ring at all", downloadFraction([]) == nil),
            ("one download is its own progress", downloadFraction([0.4]) == 0.4),
            ("two downloads read as their mean", downloadFraction([0.2, 0.8]) == 0.5),
            ("a ring never runs past full", downloadFraction([2, 2]) == 1),
            ("…or below empty", downloadFraction([-1]) == 0),
            ("a dropped link is trimmed",
             droppedText("  https://example.com  ") == "https://example.com"),
            ("a dropped paragraph becomes one line",
             droppedText("hello\nworld") == "hello world"),
            ("an empty drop opens nothing", droppedText("   \n  ") == nil),
            ("a typed name is trimmed", cleanName("  Docs  ") == "Docs"),
            ("a name that is only spaces clears the rename", cleanName("   ") == nil),
            ("an empty name clears it too", cleanName("") == nil),
            ("a newline is whitespace as far as a name goes", cleanName("\n Docs \n") == "Docs"),
            ("spaces inside a name are left alone", cleanName(" Pull Requests ") == "Pull Requests"),
            ("the result is always a valid insertion point",
             (0..<strip.count).allSatisfy {
                 let i = TabStore.insertionIndexBeside(current: $0, kinds: strip)
                 return i >= 0 && i <= strip.count
             }),
        ]
        return out
    }
}

// MARK: - Renaming and duplicating

extension TabActions {
    /// What a typed name means. Trimmed; nothing left means "clear the override and give the
    /// tab its page's own title back", which is the only way out of a rename.
    /// Pure, so the rule is proved rather than trusted to a dialog.
    static func cleanName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The user's own name for a tab, or nil if it is still wearing the page's.
    @MainActor static func rename(_ tab: Tab) -> String? {
        tab.currentURL.flatMap { TidyTitles.override(for: $0, in: tab.profileID) }
    }

    /// Arc renames a tab from a double-click on its row. ponytail: the same `askForName`
    /// alert that renames a space and a profile, not an in-place field — a name is one
    /// string, and a third spelling of "type a name" is a third thing to keep honest.
    /// Ceiling: Arc edits in the row itself, so the tab stays visible while it is renamed.
    @MainActor static func renameTab(_ tab: Tab) {
        let shown = TidyTitles.title(for: tab)
        // askForName returns nil for both Cancel and an empty field, so an empty field
        // cannot mean "clear it" here — `Use the Page's Own Title` is that route.
        guard let typed = askForName("Rename tab", shown), let name = cleanName(typed) else { return }
        TidyTitles.rename(tab, to: name)
        axAnnounce("Renamed to \(name).")
    }

    /// Chrome's Duplicate Tab, in Arc's placement: the copy lands beside the original and
    /// takes focus, because duplicating is something you did on purpose.
    /// ponytail: the url, not the back/forward list — `interactionState` would carry the
    /// history too, and a duplicate that can go "back" to where the original has been is a
    /// different feature.
    @MainActor static func duplicate(_ tab: Tab, in store: TabStore) {
        guard let url = tab.currentURL else { return }
        store.openBeside(url, focus: true)
    }
}

// MARK: - Dropping a link onto the sidebar

/// Arc's other way of making a tab: drag a link, a url or a piece of text out of a page —
/// or out of another app — and drop it on the sidebar.
///
/// ponytail: one delegate on the sidebar as a whole rather than a drop target per section.
/// The per-section `TabDrop`s already own reordering and only ever accept Vane's own tab
/// drags, so this one steps aside whenever one of those is in flight and otherwise takes
/// everything: `.url` and `.fileURL` for a real link, plain text for a selection.
/// Ceiling: a dropped tab always lands beside the current one, not at the row it was dropped
/// on — Arc puts it where the pointer is, which needs a section-aware delegate per section.
struct SidebarDrop: DropDelegate {
    let store: TabStore

    func validateDrop(info: DropInfo) -> Bool {
        // Our own tab or folder, being reordered. `TabDrop` and `FolderDrop` handle those,
        // and this must not eat them.
        guard !Dragging.shared.active else { return false }
        return info.hasItemsConforming(to: [.url, .fileURL, .plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: Dragging.shared.active ? .cancel : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        // A drag of ours that reached the sidebar as a whole was refused by every row it
        // passed over. End it here: the flag would otherwise outlive the gesture, and the
        // guard above would stand aside from every url and file drop from then on.
        if Dragging.shared.active { _ = Dragging.shared.take(); return false }
        // A url first: a link dragged out of a page carries both a url and its own text, and
        // the url is the one that does not have to be guessed at.
        if let provider = info.itemProviders(for: [.url, .fileURL]).first {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in TabActions.openDropped(url.absoluteString, in: store) }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let text = text as? String else { return }
            Task { @MainActor in TabActions.openDropped(text, in: store) }
        }
        return true
    }
}

extension TabActions {
    /// What a dropped payload is worth opening as. Trimmed, and a multi-line selection is
    /// flattened — a paragraph dragged out of a page arrives with its newlines, and a search
    /// query with a line break in it is not a query anyone typed.
    /// Nil for nothing at all, which is what an empty drag amounts to.
    static func droppedText(_ raw: String) -> String? {
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        let text = flat.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Open a dropped url or a dropped phrase. `Search.url(for:)` already decides which of
    /// the two it is, and is the same call the command bar makes, so a dropped string and a
    /// typed one land in exactly the same place.
    @MainActor static func openDropped(_ raw: String, in store: TabStore) {
        guard let text = droppedText(raw), let url = Search.url(for: text) else { return }
        store.openBeside(url, focus: true)
        axAnnounce("Opened \(text) in a new tab.")
    }
}

// MARK: - The footer's download ring

/// How far along the downloads are, as one number for the sidebar's Library glyph. Lives
/// here rather than in `Downloads` because it is a fact about the *footer* — the downloader
/// itself has no opinion about how several downloads add up.
///
/// nil means "nothing is running", which is the footer's resting state. Everything else is
/// the mean of what is in flight: two downloads at 20% and 80% read as one ring at half,
/// which is the honest summary of "the downloads are half done".
extension TabActions {
    static func downloadFraction(_ running: [Double]) -> Double? {
        guard !running.isEmpty else { return nil }
        let total = running.reduce(0, +) / Double(running.count)
        return Swift.min(Swift.max(total, 0), 1)
    }
}

extension Look {
    /// The ring drawn around a footer glyph — the Library button while a download runs. A
    /// ring tight on the glyph reads as a border, so it stands off it by a couple of points.
    /// ponytail: declared here rather than in Look.swift only to keep this branch's diff to
    /// that file at zero while it is being restyled in parallel. It belongs with the other
    /// sidebar metrics the day the two land.
    static let iconRing: CGFloat = 22
}

/// A determinate ring around the Library glyph while anything is downloading. Arc puts the
/// progress in the footer; Vane had it only inside the popover, so a download the user had
/// walked away from was invisible.
struct DownloadRing: View {
    @ObservedObject var downloads: Downloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let fraction = TabActions.downloadFraction(
            downloads.items.filter { $0.state == .running }.map(\.fraction)) {
            Circle()
                .trim(from: 0, to: Swift.max(fraction, 0.02))    // never an invisible ring
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))                   // noon, the way a clock runs
                .frame(width: Look.iconRing, height: Look.iconRing)
                .animation(reduceMotion ? nil : Look.quick, value: fraction)
                // The button it sits on already says how many downloads there are and how
                // they are doing; a ring with its own label would say it twice.
                .accessibilityHidden(true)
        }
    }
}
