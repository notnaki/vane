import AppKit

/// The shortcuts every Mac app is expected to honour, written down once.
///
/// Two kinds of row, because a browser answers a standard chord in two ways.
///
/// A `.selector` row is one AppKit already implements — Copy, Paste, Undo, Hide, Zoom. The
/// menu item carries the standard selector and no target, so it is dispatched *down the
/// responder chain*: it reaches the address bar's field editor, a rename field, and the
/// WKWebView's own editing machinery without Vane knowing anything about any of them, and it
/// greys itself out when nothing down there answers. That responder-chain dispatch is the
/// whole reason these are not Vane commands with closures behind them.
///
/// A `.command` row is one of Vane's own rebindable commands that happens to sit on a chord
/// the platform (or every other browser) has already spent — ⌘T, ⌘L, ⌘R, ⌘M. The table's job
/// there is to say what the shipped default has to be, so a rearrangement of Vane's own
/// shortcuts cannot quietly take ⌘M away.
///
/// Everything here is a pure value — no window server — so `selfcheck --pure` proves the
/// whole table, and `Standard.installed` proves the menu that was built from it. The rows
/// about Vane's own commands are asserted against `Command.defaultBinding`, the chord the
/// app *ships*, never against the live registry: the selfcheck is the release gate, and a
/// user who has moved New Tab in Settings ▸ Shortcuts has customised their copy, not broken
/// the standard set. The one row that reads a defaults suite plants a binding in a throwaway
/// one to prove exactly that.
enum Standard {

    /// What answers the chord.
    enum Answer: Equatable, Sendable {
        /// An AppKit selector, dispatched down the responder chain from a targetless item.
        case selector(String)
        /// One of Vane's rebindable commands, whose *default* binding this row pins.
        case command(Command)
    }

    struct Row: Sendable {
        let title: String
        let key: Keybinding
        let answer: Answer

        var selectorName: String? {
            if case .selector(let name) = answer { return name }
            return nil
        }
    }

    private static func app(_ title: String, _ key: String, _ mods: Keybinding.Mods,
                            _ selector: String) -> Row {
        Row(title: title, key: Keybinding(key, mods), answer: .selector(selector))
    }

    /// A standard item that carries no chord of its own — Show All, Zoom, Bring All to Front.
    /// Still in the table: "the Window menu has a Zoom" is exactly the kind of thing that goes
    /// missing when a menu is built by hand.
    private static func app(_ title: String, _ selector: String) -> Row {
        Row(title: title, key: .unassigned, answer: .selector(selector))
    }

    private static func vane(_ command: Command, _ key: String, _ mods: Keybinding.Mods) -> Row {
        Row(title: command.title, key: Keybinding(key, mods), answer: .command(command))
    }

    /// The set, in menu order. A chord appears exactly once.
    static let rows: [Row] = [
        // MARK: Vane
        app("About Vane", "orderFrontStandardAboutPanel:"),
        vane(.settings, ",", .command),
        app("Hide Vane", "h", .command, "hide:"),
        app("Hide Others", "h", [.command, .option], "hideOtherApplications:"),
        app("Show All", "unhideAllApplications:"),
        app("Quit Vane", "q", .command, "terminate:"),

        // MARK: File
        vane(.newWindow, "n", .command),
        vane(.newTab, "t", .command),
        vane(.reopenClosedTab, "t", [.command, .shift]),
        vane(.openLocation, "l", .command),
        vane(.openFile, "o", .command),
        vane(.closeTab, "w", .command),
        vane(.closeWindow, "w", [.command, .shift]),
        vane(.printPage, "p", .command),

        // MARK: Edit — the six that must reach a text field *and* a web page
        app("Undo", "z", .command, "undo:"),
        app("Redo", "z", [.command, .shift], "redo:"),
        app("Cut", "x", .command, "cut:"),
        app("Copy", "c", .command, "copy:"),
        app("Paste", "v", .command, "paste:"),
        app("Paste and Match Style", "v", [.command, .option, .shift], "pasteAsPlainText:"),
        app("Select All", "a", .command, "selectAll:"),
        app("Emoji & Symbols", " ", [.command, .control], "orderFrontCharacterPalette:"),
        app("Show Spelling and Grammar", ":", .command, "showGuessPanel:"),
        app("Check Document Now", ";", .command, "checkSpelling:"),
        app("Use Selection for Find", "e", .command, "performTextFinderAction:"),
        vane(.find, "f", .command),
        vane(.findNext, "g", .command),
        vane(.findPrevious, "g", [.command, .shift]),

        // MARK: View
        vane(.reload, "r", .command),
        vane(.hardReload, "r", [.command, .shift]),
        vane(.actualSize, "0", .command),
        vane(.zoomIn, "+", .command),
        vane(.zoomOut, "-", .command),
        vane(.fullScreen, "f", [.command, .control]),
        vane(.showWebInspector, "i", [.command, .option]),

        // MARK: Archive
        vane(.back, "[", .command),
        vane(.forward, "]", .command),

        // MARK: Tabs
        vane(.selectTab1, "1", .command),
        vane(.selectTab2, "2", .command),
        vane(.selectTab3, "3", .command),
        vane(.selectTab4, "4", .command),
        vane(.selectTab5, "5", .command),
        vane(.selectTab6, "6", .command),
        vane(.selectTab7, "7", .command),
        vane(.selectTab8, "8", .command),
        vane(.selectLastTab, "9", .command),
        // Arc spends ⌘D on pinning rather than on a bookmark; it is still the chord that
        // must not move.
        vane(.pinTab, "d", .command),

        // MARK: Window
        vane(.minimizeWindow, "m", .command),
        app("Zoom", "performZoom:"),
        app("Bring All to Front", "arrangeInFront:"),

        // MARK: Help
        // No row: Vane Help carries no chord, exactly as Safari's does. ⇧⌘/ — which reaches
        // the app as ⌘? — is macOS's own "Show Help menu", and no Apple app spends it on its
        // help item. `Keybindings.reserved` refuses it so nobody can bind it either.
    ]

    /// The rows the window answers rather than the menu bar. ⌘1–⌘8 and ⌘9 are hidden
    /// zero-size SwiftUI buttons beside the sidebar (`Shortcuts` in UI.swift) reading the same
    /// registry binding, which is where Arc keeps them too: no browser lists "Select Tab 4"
    /// in a menu, and nine more rows in the Tabs menu would bury the four anybody opens it
    /// for. They are in this table all the same, because the chord still has to be Vane's and
    /// still has to be exactly ⌘N — and `installed` proves no menu item quietly takes it away
    /// from the window.
    static let inWindow: Set<Command> = [
        .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
        .selectTab6, .selectTab7, .selectTab8, .selectLastTab,
    ]

    /// The row a menu item is built from, by the title the menu shows.
    static func row(_ title: String) -> Row? {
        rows.first { $0.title == title }
    }

    /// A standard menu item: the selector from the table, no target, so AppKit dispatches it
    /// down the responder chain. A title the table does not know gets a dead item rather than
    /// a wrong one — `installed` then reports the row as missing, which is the point.
    @MainActor static func item(_ title: String) -> NSMenuItem {
        guard let row = row(title), let name = row.selectorName else {
            return NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        let entry = NSMenuItem(title: row.title, action: NSSelectorFromString(name),
                               keyEquivalent: row.key.menuKeyEquivalent)
        entry.keyEquivalentModifierMask = row.key.menuModifierMask
        return entry
    }

    // MARK: - ⌘M

    /// Which window ⌘M puts in the Dock.
    ///
    /// `performMiniaturize:` on a window that cannot be miniaturised does nothing at all, and
    /// a Peek — a link opened over the page, borderless, key, and a child of the window it
    /// covers (see Peek.swift) — is exactly that. With one up, ⌘M reached a window with no
    /// minimise button and the keystroke died there; the menu item greyed out for the same
    /// reason. A child window minimises with its parent anyway, so the parent is the honest
    /// answer.
    enum MinimizeTarget: Equatable, Sendable {
        /// The key window itself.
        case key
        /// The window the key one is a child of — a Peek.
        case parent
        /// There is no key window at all: the frontmost browser window instead.
        case browser
        /// Nothing to minimise, and doing nothing is the answer.
        case none
    }

    /// Pure, so `selfcheck --pure` proves the ladder without a window server.
    nonisolated static func minimizeTarget(hasKey: Bool, keyMiniaturizable: Bool,
                                           keyHasParent: Bool, hasBrowser: Bool,
                                           modal: Bool) -> MinimizeTarget {
        // A modal session owns the app. The "Quit Vane?" card runs `NSApp.runModal(for:)` on
        // the very window it dims (its scrim is a view inside it — see QuitDialog.swift), so
        // minimising anything here puts a window in the Dock that still holds the modal loop:
        // the only thing that can answer the question is no longer on screen.
        if modal { return .none }
        if hasKey {
            if keyMiniaturizable { return .key }
            // A key window that cannot be miniaturised and hangs off nothing is its own
            // answer: the Extensions window is `[.titled, .closable, .resizable]`, and ⌘M
            // over it used to minimise the browser window *behind* it, which is not the
            // window the user was looking at.
            return keyHasParent ? .parent : .none
        }
        return hasBrowser ? .browser : .none
    }

    // MARK: - check

    /// The table checked against the registry beside it: a standard chord is either one of
    /// Vane's own commands — in which case this is the chord that command has to *ship* on —
    /// or it is nobody's, so the keystroke reaches AppKit.
    ///
    /// `Command.defaultBinding` throughout, never `Keybindings.binding(for:)`. What a user
    /// has since chosen in Settings ▸ Shortcuts is their business; what the app hands them on
    /// day one is this file's.
    nonisolated static func shipped() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for row in rows where row.key.isAssigned {
            switch row.answer {
            case .command(let command):
                out.append(("\(row.title) ships on \(row.key.display)",
                            command.defaultBinding == row.key))
            case .selector:
                out.append(("\(row.key.display) is left to AppKit — no Vane command ships on it",
                            !Command.allCases.contains { $0.defaultBinding == row.key }))
            }
        }
        // Said once more from the registry's end, so a command shipping on a standard chord
        // cannot hide behind a row that does not mention it.
        out.append(("no Vane command ships on a standard chord that is not its own",
                    Command.allCases.allSatisfy { command in
                        let binding = command.defaultBinding
                        guard binding.isAssigned,
                              let row = rows.first(where: { $0.key == binding }) else { return true }
                        return row.answer == .command(command)
                    }))
        return out
    }

    /// Everything the table can say about itself, and about the registry beside it.
    @MainActor static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []

        // The set itself: one row per chord.
        let chords = rows.map(\.key).filter(\.isAssigned)
        out.append(("no two standard shortcuts share a chord", Set(chords).count == chords.count))

        // Every chord this file promises is really in the table, spelled the way it displays.
        let wanted = ["⌘H", "⌥⌘H", "⌘Q", "⌘,", "⌘N", "⌘T", "⇧⌘T", "⌘L", "⌘O", "⌘W", "⇧⌘W",
                      "⌘P", "⌘Z", "⇧⌘Z", "⌘X", "⌘C", "⌘V", "⌥⇧⌘V", "⌘A", "⌘F", "⌘G", "⇧⌘G",
                      "⌘R", "⇧⌘R", "⌘0", "⌘+", "⌘-", "⌃⌘F", "⌥⌘I", "⌘[", "⌘]", "⌘1", "⌘9",
                      "⌘D", "⌘M"]
        let have = Set(chords.map(\.display))
        for chord in wanted {
            out.append(("\(chord) is in the standard set", have.contains(chord)))
        }

        // The three the Window and app menus must carry with no chord of their own.
        for title in ["Show All", "Zoom", "Bring All to Front", "About Vane"] {
            out.append(("the menus carry a \u{201C}\(title)\u{201D}",
                        row(title)?.selectorName != nil))
        }

        // A `.selector` row names a selector AppKit really implements — spelled as ObjC sees
        // it, since a typo here is a menu item that silently does nothing.
        out.append(("every standard selector ends in a colon and round-trips through ObjC",
                    rows.compactMap(\.selectorName).allSatisfy { name in
                        name.hasSuffix(":")
                            && NSStringFromSelector(NSSelectorFromString(name)) == name
                    }))

        // The item AppKit gets, built here rather than described: the action, the key and the
        // mask together, because a right key under the wrong mask is a shortcut that does not
        // fire.
        let copy = item("Copy"), pasteStyle = item("Paste and Match Style")
        let emoji = item("Emoji & Symbols"), hideOthers = item("Hide Others")
        out += [
            ("Copy is built as ⌘C on copy:",
             copy.action == NSSelectorFromString("copy:") && copy.keyEquivalent == "c"
                && copy.keyEquivalentModifierMask == .command),
            ("Paste and Match Style is built as ⌥⇧⌘V on pasteAsPlainText:",
             pasteStyle.action == NSSelectorFromString("pasteAsPlainText:")
                && pasteStyle.keyEquivalent == "v"
                && pasteStyle.keyEquivalentModifierMask == [.command, .option, .shift]),
            ("Emoji & Symbols is built as ⌃⌘Space",
             emoji.keyEquivalent == " " && emoji.keyEquivalentModifierMask == [.command, .control]),
            ("Hide Others is built as ⌥⌘H on hideOtherApplications:",
             hideOthers.action == NSSelectorFromString("hideOtherApplications:")
                && hideOthers.keyEquivalentModifierMask == [.command, .option]),
            ("a standard item has no target, so it goes down the responder chain",
             copy.target == nil && pasteStyle.target == nil),
            ("a title the table does not know gets no action rather than a wrong one",
             item("Nothing Like This").action == nil),
        ]

        out += shipped()
        // The proof that the section above is about the table this app ships and not about
        // the person running it: plant a customised binding in a throwaway defaults suite —
        // the very blob Settings ▸ Shortcuts writes when somebody moves New Tab to ⌥⌘T — and
        // every one of those rows still passes. It read the live registry once, and the
        // release gate then failed for anybody who had ever changed a shortcut.
        out.append(("a user who has rebound a shortcut still passes this check",
                    Keybindings.withScratchDefaults("standard") {
                        Keybindings.set(Keybinding("t", [.command, .option]), for: .newTab)
                        return shipped().allSatisfy(\.1)
                            && Keybindings.binding(for: .newTab) == Keybinding("t", [.command, .option])
                    } ?? false))

        out += [
            ("⌘1–⌘9 are the window's rows, and only those",
             inWindow == [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
                          .selectTab6, .selectTab7, .selectTab8, .selectLastTab]),
            ("every row the window answers is a Vane command, never an AppKit selector",
             rows.allSatisfy { row in
                 guard case .command(let c) = row.answer else { return true }
                 return !inWindow.contains(c) || row.selectorName == nil
             }),
        ]

        // ⌘M, and the borderless window that used to eat it.
        out += [
            ("⌘M minimises the key window",
             minimizeTarget(hasKey: true, keyMiniaturizable: true, keyHasParent: false,
                            hasBrowser: true, modal: false) == .key),
            ("over a Peek — borderless, key, and a child of the window behind it — ⌘M minimises that window",
             minimizeTarget(hasKey: true, keyMiniaturizable: false, keyHasParent: true,
                            hasBrowser: true, modal: false) == .parent),
            ("a key window that can neither be minimised nor has a parent is left alone — the browser window behind it is not what ⌘M was aimed at",
             minimizeTarget(hasKey: true, keyMiniaturizable: false, keyHasParent: false,
                            hasBrowser: true, modal: false) == .none),
            ("with no key window at all, ⌘M still minimises the browser window",
             minimizeTarget(hasKey: false, keyMiniaturizable: false, keyHasParent: false,
                            hasBrowser: true, modal: false) == .browser),
            ("and with nothing on screen it does nothing",
             minimizeTarget(hasKey: false, keyMiniaturizable: false, keyHasParent: false,
                            hasBrowser: false, modal: false) == .none),
            ("while the quit card has a modal session up, ⌘M does nothing at all — minimising its host would carry the modal into the Dock",
             minimizeTarget(hasKey: true, keyMiniaturizable: true, keyHasParent: false,
                            hasBrowser: true, modal: true) == .none),
            ("…however the rest of the ladder stands",
             [true, false].allSatisfy { key in
                 [true, false].allSatisfy { parent in
                     minimizeTarget(hasKey: key, keyMiniaturizable: key, keyHasParent: parent,
                                    hasBrowser: true, modal: true) == .none
                 }
             }),
        ]
        return out
    }

    // MARK: - the menu that was built

    /// The table proved against the menu bar the app actually builds: every standard chord on
    /// exactly one item, with the selector the table names, and no two items anywhere in the
    /// bar quietly sharing a chord.
    ///
    /// Not pure — it needs `NSApp` — so it runs in the full `selfcheck` rather than
    /// `--pure`. Everything it reads is a menu built in this process; no window is opened.
    @MainActor static func installed(_ root: NSMenu, windows: NSMenu?, help: NSMenu?,
                                     services: NSMenu?) -> [(String, Bool)] {
        var items: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            for entry in menu.items {
                items.append(entry)
                if let sub = entry.submenu { walk(sub) }
            }
        }
        walk(root)

        var out: [(String, Bool)] = []
        func matches(_ key: Keybinding) -> [NSMenuItem] {
            items.filter {
                $0.keyEquivalent == key.menuKeyEquivalent
                    && $0.keyEquivalentModifierMask == key.menuModifierMask
            }
        }
        for row in rows {
            if case .command(let command) = row.answer, inWindow.contains(command) {
                out.append(("\(row.key.display) is the window's, and no menu item takes it away",
                            matches(row.key).isEmpty))
                continue
            }
            guard row.key.isAssigned else {
                out.append(("the menu bar has \u{201C}\(row.title)\u{201D}",
                            items.contains {
                                $0.title == row.title
                                    && $0.action == row.selectorName.map(NSSelectorFromString)
                            }))
                continue
            }
            let hits = matches(row.key)
            out.append(("\(row.key.display) is on exactly one menu item", hits.count == 1))
            if let name = row.selectorName {
                out.append(("\(row.key.display) runs \(name)",
                            hits.first?.action == NSSelectorFromString(name)))
            }
        }

        // Nothing in the whole bar doubles up on a chord — including Vane's own, which is
        // what would shadow a standard one.
        var seen: Set<Keybinding> = []
        var doubled: [String] = []
        for entry in items where !entry.keyEquivalent.isEmpty {
            var mods: Keybinding.Mods = []
            let mask = entry.keyEquivalentModifierMask
            if mask.contains(.command) { mods.insert(.command) }
            if mask.contains(.control) { mods.insert(.control) }
            if mask.contains(.option)  { mods.insert(.option) }
            if mask.contains(.shift)   { mods.insert(.shift) }
            let key = Keybinding(entry.keyEquivalent, mods)
            if !seen.insert(key).inserted { doubled.append(key.display + " (" + entry.title + ")") }
        }
        out.append(("no two menu items share a chord" + (doubled.isEmpty ? "" : ": " + doubled.joined(separator: ", ")),
                    doubled.isEmpty))

        // The three menus AppKit itself fills in or defers to.
        out += [
            ("NSApp.windowsMenu is the Window menu, so AppKit lists the windows and ⌘` cycles them",
             windows != nil && windows?.title == "Window"),
            ("NSApp.helpMenu is the Help menu", help != nil && help?.title == "Help"),
            ("NSApp.servicesMenu is set, so the app menu has a live Services submenu",
             services != nil),
            // Vane's own action, not `performMiniaturize:`. A targetless standard item is
            // dispatched down the responder chain, so with a Peek up — borderless and
            // unminiaturisable — AppKit found nobody to answer and greyed the item out,
            // while ⌘M itself went through the monitor and worked. The item runs the same
            // ladder the keystroke does, and greys out only when that ladder says there is
            // nothing to minimise.
            ("the Window menu carries Minimize on ⌘M, running Vane's ladder rather than performMiniaturize:",
             windows?.items.contains {
                 $0.title == Command.minimizeWindow.title
                     && $0.keyEquivalent == "m" && $0.keyEquivalentModifierMask == .command
                     && $0.action != #selector(NSWindow.performMiniaturize(_:))
                     && $0.target != nil
             } == true),
            ("…and it validates itself, so it is live exactly when there is a window to minimise",
             windows?.items.first { $0.title == Command.minimizeWindow.title }
                 .flatMap { $0.target as? NSMenuItemValidation }
                 .map { $0.validateMenuItem(NSMenuItem()) == (minimizeVictim() != nil) } == true),
        ]
        return out
    }
}
