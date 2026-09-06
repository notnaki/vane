import AppKit
import SwiftUI
import WebKit

/// Arc's back and forward glyphs are two controls in one: a click steps once, and a press
/// held past `Look.holdDelay` — or a right-click — drops that direction's history under the
/// glyph so a page four steps back is one click away instead of four.
///
/// The order and the cap live here, away from WebKit, so they can be proved offline. WebKit
/// hands `backList` back oldest-first and `forwardList` nearest-first; a menu is always
/// nearest-first, because "the page I was just on" is the row the hand is reaching for.
enum NavHistory {
    /// How many rows the menu shows. The point of it is the last handful of pages, not the
    /// session — `Show Full History` at the foot is the way to the rest, and a menu longer
    /// than this stops being scannable and starts being a list to read.
    static let cap = 12

    /// Which entries of `count`, in which order, the menu for this direction shows.
    nonisolated static func order(count: Int, back: Bool) -> [Int] {
        guard count > 0 else { return [] }
        let nearestFirst = back ? Array((0..<count).reversed()) : Array(0..<count)
        return Array(nearestFirst.prefix(cap))
    }

    /// What one row is called. A page that never got a title — one that failed, or was
    /// restored from a session — still has to be recognisable, so its host stands in; a url
    /// with no host at all (`about:blank`, a `data:` page) falls back to the url itself,
    /// which is at least something rather than an empty menu row.
    nonisolated static func label(title: String?, url: URL) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }
}

// MARK: - The menu

/// A menu item whose action is a closure. `NSMenuItem` needs an ObjC target and does not
/// retain it; Menu.swift's version of this is private to that file, as LittleArc's is to
/// its own.
@MainActor private final class Jump: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
    /// Items live only as long as the menu is up, but ARC does not know that.
    static var kept: [Jump] = []
}

@MainActor private func entry(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let act = Jump(run)
    Jump.kept.append(act)
    let item = NSMenuItem(title: title, action: #selector(Jump.fire), keyEquivalent: "")
    item.target = act
    return item
}

extension NavHistory {
    /// This tab's history in one direction, or nil when there is none — the caller draws
    /// nothing rather than an empty menu, and the glyph is disabled in that state anyway.
    @MainActor static func menu(for tab: Tab, back: Bool) -> NSMenu? {
        let list = tab.web.backForwardList
        let entries = back ? list.backList : list.forwardList
        let picks = order(count: entries.count, back: back)
        guard !picks.isEmpty else { return nil }
        // Kept only for the life of one menu: a new one supersedes the last, and holding
        // every jump the session ever offered would leak a closure per press.
        Jump.kept.removeAll()
        let menu = NSMenu()
        for index in picks {
            let item = entries[index]
            let row = entry(label(title: item.title, url: item.url)) { [weak tab] in
                tab?.web.go(to: item)
            }
            // The favicon cache already has these hosts — they are pages this tab loaded —
            // so this is normally a dictionary hit and a miss simply draws no image. Never
            // from a private window, though: `icon(for:)` warms on a miss and *writes the
            // icon to disk*, and a file in the cache directory is a record that the host was
            // visited. `Previews` goes without one for the same reason.
            // A copy, because the size is the cached image's own and the cache is shared:
            // resizing it here would resize it in every row and tile that draws it.
            if !tab.isPrivate, let cached = tab.favicons.icon(for: item.url),
               let icon = cached.copy() as? NSImage {
                icon.size = NSSize(width: Look.rowIcon, height: Look.rowIcon)
                row.image = icon
            }
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // Arc's own last row. It runs the same closure ⌘Y does, so the two can never drift.
        menu.addItem(entry("Show Full History") { Keybindings.actions[.viewHistory]?() })
        return menu
    }
}

// MARK: - The glyph

/// The AppKit end of a glyph that can be held. It draws nothing and takes no left clicks —
/// SwiftUI's `Button` underneath keeps those, and with them its disabled and pressed looks —
/// but it owns a real `NSView` to hang the menu off, and it is where a right-click lands.
///
/// ponytail: `hitTest` reading the event being dispatched rather than a second, cleverer
/// layer of hit testing. It is the shortest way to say "the secondary click only" to a view
/// that has to be on top to get one at all. Ceiling: an event dispatched with no
/// `NSApp.currentEvent` — none that a pointer generates — falls through to the button.
private final class HoldTarget: NSView {
    var build: @MainActor () -> NSMenu? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return super.hitTest(point)
        // Control-click is the secondary click on every Mac with one button, and it must
        // open the menu rather than step back a page.
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
        default: return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { pop() }
    override func mouseDown(with event: NSEvent) { pop() }

    /// Under the glyph, the way a pop-up button drops its list, and blocking until the menu
    /// closes — which is what lets the caller know the press is over. An `NSView` is not
    /// flipped, so under it is *below* the origin.
    func pop() {
        guard let menu = build() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Look.rowGap), in: self)
    }
}

/// Handed to SwiftUI so the long press and the VoiceOver action can reach the view above
/// without SwiftUI having to own it.
@MainActor final class HoldMenu: ObservableObject {
    fileprivate weak var target: HoldTarget?
    func pop() { target?.pop() }
}

private struct HoldAnchor: NSViewRepresentable {
    let holder: HoldMenu
    let build: @MainActor () -> NSMenu?

    func makeNSView(context: Context) -> NSView {
        let view = HoldTarget()
        holder.target = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? HoldTarget)?.build = build
    }
}

extension View {
    /// Press-and-hold, right-click and a VoiceOver action, all opening the same menu.
    ///
    /// ponytail: a `LongPressGesture` beside the button rather than an AppKit control that
    /// does both. A hold that has to leave the click alone is exactly one gesture; taking
    /// the clicks as well would mean redrawing the button's disabled and pressed states by
    /// hand. Ceiling: the hold fires while the button is still down, so a hold that is then
    /// dragged off the glyph has already opened the menu.
    @MainActor func holdMenu(_ holder: HoldMenu, enabled: Bool,
                             named: String,
                             _ build: @escaping @MainActor () -> NSMenu?) -> some View {
        overlay { if enabled { HoldAnchor(holder: holder, build: build) } }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: Look.holdDelay)
                    .onEnded { _ in if enabled { holder.pop() } })
            // Only where there is a history to show: an action VoiceOver offers on a
            // disabled glyph is a promise of a menu that never opens.
            .accessibilityActions { if enabled { Button(named) { holder.pop() } } }
    }
}

// MARK: - check

extension NavHistory {
    nonisolated static func check() -> [(String, Bool)] {
        let untitled = URL(string: "https://example.com/deep/page")!
        let hostless = URL(string: "about:blank")!
        return [
            ("back's list is turned round, so the page just left is the first row",
             order(count: 4, back: true) == [3, 2, 1, 0]),
            ("forward's list already reads nearest first and is left alone",
             order(count: 4, back: false) == [0, 1, 2, 3]),
            ("one entry each way is one row", order(count: 1, back: true) == [0]
                && order(count: 1, back: false) == [0]),
            ("no entries is no menu", order(count: 0, back: true).isEmpty
                && order(count: 0, back: false).isEmpty),
            ("a negative count is nonsense and shows nothing",
             order(count: -3, back: true).isEmpty),
            ("a long history stops at the cap", order(count: 40, back: true).count == cap
                && order(count: 40, back: false).count == cap),
            ("…keeping the nearest pages, not the oldest",
             order(count: 40, back: true).first == 39 && order(count: 40, back: false).first == 0),
            ("the cap is a menu you can scan, not a history window",
             cap >= 8 && cap <= 20),
            ("a page's title names its row", label(title: "Example", url: untitled) == "Example"),
            ("a title of nothing but spaces is no title",
             label(title: "   ", url: untitled) == "example.com"),
            ("an untitled page falls back to its host", label(title: nil, url: untitled) == "example.com"),
            ("a url with no host falls back to the url itself",
             label(title: nil, url: hostless) == "about:blank"),
        ]
    }
}
