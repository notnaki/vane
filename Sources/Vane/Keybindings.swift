import AppKit
import SwiftUI
import WebKit

// MARK: - Keybinding

/// One key plus its modifiers. The empty key is "unassigned" and displays as `---`.
///
/// Everything here is a pure value: no window server, no defaults, so `selfcheck --pure`
/// can prove the formatting and the round-trips on a headless box.
struct Keybinding: Codable, Hashable, Sendable {

    /// ponytail: our own flag set rather than `NSEvent.ModifierFlags`, purely because that
    /// one is not Codable and this has to survive in UserDefaults.
    struct Mods: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Mods(rawValue: 1 << 0)
        static let option  = Mods(rawValue: 1 << 1)
        static let shift   = Mods(rawValue: 1 << 2)
        static let command = Mods(rawValue: 1 << 3)
    }

    /// Always canonical: lowercased, one character (or one function-key scalar). Empty
    /// means unassigned.
    private(set) var key: String
    private(set) var mods: Mods

    static let unassigned = Keybinding("", [])

    /// The only initialiser, so every binding — a default, a decoded one, a recorded one —
    /// goes through the same canonicalisation and can therefore be compared with `==`.
    init(_ key: String, _ mods: Mods = []) {
        var key = key, mods = mods
        // Backtab is just shift-tab spelled as a control character (AppKit's
        // NSBackTabCharacter). Store one spelling so a recorded ⌃⇧⇥ equals the default.
        if key == "\u{19}" {
            key = "\t"
            mods.insert(.shift)
        }
        // A shifted punctuation glyph already says "shift" — "+" *is* shift-"=" — and
        // `charactersIgnoringModifiers` hands us the shifted glyph. Storing the flag as
        // well would make a recorded ⌘+ differ from the ⌘+ the menu uses today.
        // ponytail ceiling: US-ish layouts. On a layout where "+" needs no shift this
        // drops a modifier the user really pressed; the fix is a keyCode-based binding,
        // which is a lot of table for a case nobody has hit yet.
        if key.count == 1, let s = key.unicodeScalars.first,
           (0x21...0x7E).contains(s.value), !CharacterSet.alphanumerics.contains(s) {
            mods.remove(.shift)
        }
        self.key = key.lowercased()
        self.mods = mods
    }

    /// From a key-down event, so a recorder view can capture one. Nil for events that
    /// carry no character at all (modifier presses, dead keys).
    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        var mods: Mods = []
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        self.init(chars, mods)
    }

    var isAssigned: Bool { !key.isEmpty }

    // MARK: Display

    /// Conventional macOS order: ⌃⌥⇧⌘ then the key. `---` when unassigned.
    var display: String {
        guard isAssigned else { return "---" }
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option)  { out += "⌥" }
        if mods.contains(.shift)   { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out + Self.label(key)
    }

    /// How a key prints on its own. Everything not in the table is just uppercased, which
    /// is what letters and digits want.
    static func label(_ key: String) -> String {
        guard let s = key.unicodeScalars.first, key.unicodeScalars.count == 1 else {
            return key.uppercased()
        }
        switch s.value {
        case 0x09, 0x19: return "⇥"                       // tab / backtab
        case 0x08, 0x7F: return "⌫"                       // backspace / delete
        case 0x1B:       return "⎋"
        case 0x0D:       return "⏎"
        case 0x03:       return "⌤"                       // numeric-keypad enter
        case 0x20:       return "␣"
        case 0xF700:     return "↑"
        case 0xF701:     return "↓"
        case 0xF702:     return "←"
        case 0xF703:     return "→"
        case 0xF728:     return "⌦"                       // forward delete
        case 0xF729:     return "↖"                       // home
        case 0xF72B:     return "↘"                       // end
        case 0xF72C:     return "⇞"
        case 0xF72D:     return "⇟"
        case 0xF704...0xF726: return "F\(s.value - 0xF704 + 1)"
        default:         return key.uppercased()
        }
    }

    // MARK: Conversions

    /// What `NSMenuItem.keyEquivalent` wants. Shift-tab goes back to being backtab, which
    /// is the spelling AppKit matches on.
    var menuKeyEquivalent: String {
        key == "\t" && mods.contains(.shift) ? "\u{19}" : key
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods.contains(.control) { f.insert(.control) }
        if mods.contains(.option)  { f.insert(.option) }
        if mods.contains(.shift)   { f.insert(.shift) }
        if mods.contains(.command) { f.insert(.command) }
        return f
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var f: SwiftUI.EventModifiers = []
        if mods.contains(.control) { f.insert(.control) }
        if mods.contains(.option)  { f.insert(.option) }
        if mods.contains(.shift)   { f.insert(.shift) }
        if mods.contains(.command) { f.insert(.command) }
        return f
    }

    /// Nil when unassigned — `.keyboardShortcut(nil)` is how SwiftUI spells "no shortcut".
    var keyboardShortcut: KeyboardShortcut? {
        guard let c = key.first, key.count == 1 else { return nil }
        return KeyboardShortcut(KeyEquivalent(c), modifiers: eventModifiers)
    }
}

// MARK: - Commands

/// Every rebindable action, by stable id. The raw value is what lands in UserDefaults, so
/// renaming a case renames the user's setting — don't.
enum Command: String, CaseIterable, Codable, Sendable {
    // File
    case newWindow, newPrivateWindow, newTab, reopenClosedTab, closeTab, closeWindow
    case printPage, settings
    case openFile, savePageAs, sharePage
    // View
    case reload, hardReload, openLocation, find, toggleSidebar
    case findNext, findPrevious
    case actualSize, zoomIn, zoomOut, fullScreen
    case copyPageURL, showLibrary
    case showReader, biggerReaderText, smallerReaderText, readerSerif
    // History / Archive
    case back, forward, clearHistory
    case viewArchive, viewHistory, showDownloads, clearArchive
    // Bookmarks
    case bookmarkPage
    // Passwords
    case fillPassword, importPasswords, importHistoryAndBookmarks, manageSavedPasswords
    // Sites
    case blockAds, addFilterList, makeDefaultBrowser
    case forgetCertificateExceptions, resetMediaPermissions
    // Extensions
    case installExtension
    // Develop
    case showWebInspector, showJavaScriptConsole, viewSource, allowWebInspector
    // Profiles
    case newProfile, renameProfile, deleteProfile
    // Spaces
    case newSpace, nextSpace, previousSpace
    case goToSpace1, goToSpace2, goToSpace3, goToSpace4
    case goToSpace5, goToSpace6, goToSpace7, goToSpace8, goToSpace9
    // Tabs
    case nextTab, previousTab
    case tabSwitcher, tabSwitcherBackwards
    case selectTab1, selectTab2, selectTab3, selectTab4
    case selectTab5, selectTab6, selectTab7, selectTab8, selectLastTab
    case pictureInPicture
    case tidyTabs, undoTidyTabs, clearTabs
    case favouriteTab, pinTab
    case muteTab
    case commandPalette, searchTabs
    // Window / Help
    case minimizeWindow
    case vaneHelp, keyboardShortcutsHelp

    enum Category: String, CaseIterable, Sendable {
        case file = "File", view = "View", history = "History", bookmarks = "Bookmarks"
        case passwords = "Passwords", sites = "Sites", extensions = "Extensions"
        case develop = "Develop", profiles = "Profiles", spaces = "Spaces", tabs = "Tabs"
        case window = "Window", help = "Help"
    }

    var title: String {
        switch self {
        case .newWindow: "New Window"
        case .newPrivateWindow: "New Private Window"
        case .newTab: "New Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .closeTab: "Archive Tab"
        case .closeWindow: "Close Window"
        case .printPage: "Print…"
        case .settings: "Settings…"
        case .openFile: "Open File…"
        case .savePageAs: "Save Page As…"
        case .sharePage: "Share…"
        case .reload: "Reload Page"
        case .hardReload: "Reload Ignoring Cache"
        case .openLocation: "Open Location…"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .toggleSidebar: "Toggle Sidebar"
        case .actualSize: "Actual Size"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .fullScreen: "Enter Full Screen"
        case .copyPageURL: "Copy Page URL"
        case .showLibrary: "Show Library"
        case .showReader: "Show Reader"
        case .biggerReaderText: "Bigger Reader Text"
        case .smallerReaderText: "Smaller Reader Text"
        case .readerSerif: "Reader Uses Serif"
        case .back: "Back"
        case .forward: "Forward"
        case .clearHistory: "Clear History…"
        case .viewArchive: "View Archive"
        case .viewHistory: "View History"
        case .showDownloads: "Downloads"
        case .clearArchive: "Clear Archive…"
        case .bookmarkPage: "Bookmark This Page"
        case .fillPassword: "Fill Password"
        case .importPasswords: "Import Passwords…"
        case .importHistoryAndBookmarks: "Import History & Bookmarks…"
        case .manageSavedPasswords: "Manage Saved Passwords…"
        case .blockAds: "Block Ads and Trackers"
        case .addFilterList: "Add Filter List…"
        case .makeDefaultBrowser: "Make Vane the Default Browser"
        case .forgetCertificateExceptions: "Forget Certificate Exceptions…"
        case .resetMediaPermissions: "Reset Camera & Microphone Permissions…"
        case .installExtension: "Install Extension…"
        case .showWebInspector: "Show Web Inspector"
        case .showJavaScriptConsole: "Show JavaScript Console"
        case .viewSource: "View Source"
        case .allowWebInspector: "Allow Web Inspector"
        case .newProfile: "New Profile…"
        case .renameProfile: "Rename Profile…"
        case .deleteProfile: "Delete Profile…"
        case .newSpace: "New Space…"
        case .nextSpace: "Next Space"
        case .previousSpace: "Previous Space"
        case .goToSpace1: "Go to Space 1"
        case .goToSpace2: "Go to Space 2"
        case .goToSpace3: "Go to Space 3"
        case .goToSpace4: "Go to Space 4"
        case .goToSpace5: "Go to Space 5"
        case .goToSpace6: "Go to Space 6"
        case .goToSpace7: "Go to Space 7"
        case .goToSpace8: "Go to Space 8"
        case .goToSpace9: "Go to Space 9"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .tabSwitcher: "Tab Switcher"
        case .tabSwitcherBackwards: "Tab Switcher Backwards"
        case .selectTab1: "Select Tab 1"
        case .selectTab2: "Select Tab 2"
        case .selectTab3: "Select Tab 3"
        case .selectTab4: "Select Tab 4"
        case .selectTab5: "Select Tab 5"
        case .selectTab6: "Select Tab 6"
        case .selectTab7: "Select Tab 7"
        case .selectTab8: "Select Tab 8"
        case .selectLastTab: "Select Last Tab"
        case .pictureInPicture: "Picture in Picture"
        case .tidyTabs: "Tidy Tabs"
        case .undoTidyTabs: "Undo Tidy Tabs"
        case .clearTabs: "Clear Tabs"
        case .favouriteTab: "Favourite Tab"
        case .pinTab: "Pin Tab"
        case .muteTab: "Mute Tab"
        case .commandPalette: "Search…"
        case .searchTabs: "Search Tabs…"
        case .minimizeWindow: "Minimize"
        case .vaneHelp: "Vane Help"
        case .keyboardShortcutsHelp: "Keyboard Shortcuts"
        }
    }

    var category: Category {
        switch self {
        case .newWindow, .newPrivateWindow, .newTab, .reopenClosedTab, .closeTab,
             .closeWindow, .printPage, .settings, .openFile, .savePageAs, .sharePage: .file
        case .reload, .hardReload, .openLocation, .find, .findNext, .findPrevious,
             .toggleSidebar, .actualSize,
             .zoomIn, .zoomOut, .fullScreen, .showReader, .biggerReaderText,
             .smallerReaderText, .readerSerif, .copyPageURL, .showLibrary: .view
        case .back, .forward, .clearHistory, .viewArchive, .viewHistory, .showDownloads,
             .clearArchive: .history
        case .bookmarkPage: .bookmarks
        case .fillPassword, .importPasswords, .importHistoryAndBookmarks,
             .manageSavedPasswords: .passwords
        case .blockAds, .addFilterList, .makeDefaultBrowser, .forgetCertificateExceptions,
             .resetMediaPermissions: .sites
        case .installExtension: .extensions
        case .showWebInspector, .showJavaScriptConsole, .viewSource, .allowWebInspector: .develop
        case .newProfile, .renameProfile, .deleteProfile: .profiles
        case .newSpace, .nextSpace, .previousSpace, .goToSpace1, .goToSpace2, .goToSpace3,
             .goToSpace4, .goToSpace5, .goToSpace6, .goToSpace7, .goToSpace8,
             .goToSpace9: .spaces
        case .minimizeWindow: .window
        case .vaneHelp, .keyboardShortcutsHelp: .help
        default: .tabs
        }
    }

    /// What the app ships with. These must stay equal to the key equivalents Menu.swift
    /// and UI.swift hardcode today, or upgrading would silently move somebody's keys.
    var defaultBinding: Keybinding {
        switch self {
        case .newWindow:        Keybinding("n", .command)
        case .newPrivateWindow: Keybinding("n", [.command, .shift])
        case .newTab:           Keybinding("t", .command)
        case .reopenClosedTab:  Keybinding("t", [.command, .shift])
        case .closeTab:         Keybinding("w", .command)
        case .closeWindow:      Keybinding("w", [.command, .shift])
        case .printPage:        Keybinding("p", .command)
        case .settings:         Keybinding(",", .command)
        case .reload:           Keybinding("r", .command)
        case .hardReload:       Keybinding("r", [.command, .shift])
        case .openLocation:     Keybinding("l", .command)
        case .openFile:         Keybinding("o", .command)
        // Arc's ⌘S is the sidebar, and Save Page As is one modifier up — see §G.
        case .savePageAs:       Keybinding("s", [.command, .shift])
        case .find:             Keybinding("f", .command)
        case .findNext:         Keybinding("g", .command)
        case .findPrevious:     Keybinding("g", [.command, .shift])
        case .toggleSidebar:    Keybinding("s", .command)
        case .actualSize:       Keybinding("0", .command)
        case .zoomIn:           Keybinding("+", .command)
        case .zoomOut:          Keybinding("-", .command)
        case .fullScreen:       Keybinding("f", [.command, .control])
        case .showReader:       Keybinding("r", [.command, .option])
        case .back:             Keybinding("[", .command)
        case .forward:          Keybinding("]", .command)
        // Arc's ⌘D pins the tab. Bookmarking keeps the adjacent ⌥⌘D it already had, and
        // Favourite ships unbound — Arc gives it no default either, it is a menu item and
        // a right-click. ⇧⌘D is left free (Arc spends it on the toolbar, which Vane has
        // no equivalent of).
        case .bookmarkPage:     Keybinding("d", [.command, .option])
        case .pinTab:           Keybinding("d", .command)
        case .clearTabs:        Keybinding("k", [.command, .shift])
        case .copyPageURL:      Keybinding("c", [.command, .shift])
        // ⌘⇧L is Arc's Library; Fill Password moves to the adjacent ⌥⌘L.
        case .showLibrary:      Keybinding("l", [.command, .shift])
        case .fillPassword:     Keybinding("l", [.command, .option])
        case .nextSpace:        Keybinding("\u{F703}", [.command, .option])
        case .previousSpace:    Keybinding("\u{F702}", [.command, .option])
        case .goToSpace1:       Keybinding("1", .control)
        case .goToSpace2:       Keybinding("2", .control)
        case .goToSpace3:       Keybinding("3", .control)
        case .goToSpace4:       Keybinding("4", .control)
        case .goToSpace5:       Keybinding("5", .control)
        case .goToSpace6:       Keybinding("6", .control)
        case .goToSpace7:       Keybinding("7", .control)
        case .goToSpace8:       Keybinding("8", .control)
        case .goToSpace9:       Keybinding("9", .control)
        case .showWebInspector: Keybinding("i", [.command, .option])
        case .showJavaScriptConsole: Keybinding("c", [.command, .option])
        case .viewSource:       Keybinding("u", [.command, .option])
        // Arc: ⌥⌘↑/↓ walk the sidebar, ⌃⇥ is the switcher and goes *forwards*.
        // The init folds backtab + ⌃⇧ to tab + ⌃⇧.
        case .nextTab:          Keybinding("\u{F701}", [.command, .option])
        case .previousTab:      Keybinding("\u{F700}", [.command, .option])
        case .tabSwitcher:      Keybinding("\t", .control)
        case .tabSwitcherBackwards: Keybinding("\u{19}", [.control, .shift])
        case .selectTab1:       Keybinding("1", .command)
        case .selectTab2:       Keybinding("2", .command)
        case .selectTab3:       Keybinding("3", .command)
        case .selectTab4:       Keybinding("4", .command)
        case .selectTab5:       Keybinding("5", .command)
        case .selectTab6:       Keybinding("6", .command)
        case .selectTab7:       Keybinding("7", .command)
        case .selectTab8:       Keybinding("8", .command)
        case .selectLastTab:    Keybinding("9", .command)
        case .pictureInPicture: Keybinding("p", [.command, .option])
        case .tidyTabs:         Keybinding("t", [.command, .control])
        case .undoTidyTabs:     .unassigned
        case .muteTab:          Keybinding("m", [.command, .option])
        case .commandPalette:   Keybinding("p", [.command, .shift])
        case .searchTabs:       Keybinding("a", [.command, .shift])
        case .viewHistory:      Keybinding("y", .command)
        case .showDownloads:    Keybinding("j", [.command, .shift])
        case .minimizeWindow:   Keybinding("m", .command)
        // Everything else ships unbound — it is a menu item with no key equivalent today.
        default: .unassigned
        }
    }
}

// MARK: - Store

/// The model a Shortcuts pane binds to: read a binding, rebind it, reset it, and route a
/// key event to whatever action the app registered.
@MainActor enum Keybindings {

    /// Whether the browser or the page gets first refusal on a key.
    enum Priority: String, Codable, Sendable { case browser, page }

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    static var defaults: UserDefaults = .standard
    private static let storeKey = "keybindings.v1"

    private struct Saved: Codable {
        var bindings: [String: Keybinding] = [:]
        var priorities: [String: Priority] = [:]
        /// Optional so a blob written before migrations existed still decodes; nil is 0.
        var migrated: Int?
    }

    // MARK: Migration

    /// Defaults that moved after they had already shipped, and what they used to be.
    /// A *saved* binding equal to the old default is not a decision anybody made about
    /// those keys — it is the default they were handed, written down by a pane that stores
    /// whatever it records — so it is dropped and the new default takes over. A binding
    /// the user actually chose is left exactly where it is, even if that now collides.
    nonisolated static let movedDefaults: [Command: Keybinding] = [
        .nextTab: Keybinding("\u{19}", [.control, .shift]),
        .previousTab: Keybinding("\t", .control),
        .favouriteTab: Keybinding("d", .command),
        .pinTab: Keybinding("d", [.command, .shift]),
    ]

    /// Bumped when `movedDefaults` grows, so each migration runs once per user.
    nonisolated static let migration = 1

    /// Pure, so `selfcheck --pure` can prove the rule without a defaults suite.
    nonisolated static func migrate(_ bindings: [String: Keybinding],
                                    moved: [Command: Keybinding]) -> [String: Keybinding] {
        var out = bindings
        for (command, old) in moved where out[command.rawValue] == old {
            out[command.rawValue] = nil
        }
        return out
    }

    private static var cached: Saved?
    private static var state: Saved {
        get {
            if let cached { return cached }
            var s = defaults.data(forKey: storeKey)
                .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
            if (s.migrated ?? 0) < migration {
                s.bindings = migrate(s.bindings, moved: movedDefaults)
                s.migrated = migration
                // Not `state = s`: this is the getter, and the setter would re-enter it.
                if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: storeKey) }
            }
            cached = s
            return s
        }
        set {
            cached = newValue
            if let d = try? JSONEncoder().encode(newValue) { defaults.set(d, forKey: storeKey) }
        }
    }

    // MARK: Bindings

    static func binding(for command: Command) -> Keybinding {
        state.bindings[command.rawValue] ?? command.defaultBinding
    }

    /// Setting `.unassigned` is a real choice (unbind it), not a reset — it is stored.
    static func set(_ binding: Keybinding, for command: Command) {
        state.bindings[command.rawValue] = binding
    }

    static func reset(_ command: Command) {
        state.bindings[command.rawValue] = nil
        state.priorities[command.rawValue] = nil
    }

    static func resetAll() {
        state = Saved()
    }

    /// Every command already holding these keys. Unassigned collides with nothing —
    /// forty unbound commands are not forty conflicts.
    static func conflicts(_ binding: Keybinding) -> [Command] {
        guard binding.isAssigned else { return [] }
        return Command.allCases.filter { Keybindings.binding(for: $0) == binding }
    }

    // MARK: Priority

    static func priority(for command: Command) -> Priority {
        state.priorities[command.rawValue] ?? .browser
    }

    static func setPriority(_ p: Priority, for command: Command) {
        state.priorities[command.rawValue] = p
    }

    // MARK: Reserved

    /// A reason the system (or Vane's own app menu) will take this combination first, or
    /// nil if it is free. Returning the reason lets the UI warn instead of just refusing.
    static func reserved(_ binding: Keybinding) -> String? {
        guard binding.isAssigned else { return nil }
        let m = binding.mods
        let isFunctionKey = binding.key.unicodeScalars.first.map {
            (0xF704...0xF726).contains($0.value)
        } ?? false
        // A binding with no ⌘/⌃/⌥ fires while you are typing into a text field.
        if m.isDisjoint(with: [.command, .control, .option]), !isFunctionKey {
            return "Needs at least one of ⌘, ⌃ or ⌥ — otherwise it fires while you type."
        }
        switch (binding.key, m) {
        case ("q", [.command]):                  return "⌘Q quits Vane."
        case ("q", [.command, .shift]):          return "⌘⇧Q logs you out of macOS."
        case ("q", [.command, .control]):        return "⌃⌘Q locks the screen."
        case ("\t", [.command]), ("\t", [.command, .shift]):
            return "macOS keeps ⌘⇥ for the app switcher; apps never see it."
        case (" ", [.command]), (" ", [.control]), (" ", [.command, .option]):
            return "macOS keeps this for Spotlight and input-source switching."
        case ("\u{1b}", [.command, .option]):    return "⌥⌘⎋ opens Force Quit."
        case ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]):
            return "macOS keeps this for screenshots."
        case ("h", [.command]):                  return "⌘H hides Vane."
        case ("m", [.command]):                  return "⌘M minimises the window."
        default:                                 return nil
        }
    }

    // MARK: Search

    /// Matches a command by name *or* by shortcut, so "new tab", "⌘T", "cmd t" and
    /// "command+t" all land on New Tab. Pure — no defaults, no AppKit.
    static func search(_ query: String) -> [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Command.allCases }
        // Shortcut matches first: typing "cmd t" is a deliberate spelling of ⌘T, and it
        // would otherwise lose to a fuzzy name hit ("Command Palette" contains c, m, d…).
        var hits: [Command] = []
        if let wanted = parseShortcut(q) {
            hits = Command.allCases.filter { c in
                let b = binding(for: c)
                guard b.isAssigned else { return false }
                // A modifiers-only query ("⌥⌘") lists everything using them.
                return wanted.isAssigned ? b == wanted : b.mods.isSuperset(of: wanted.mods)
            }
        }
        // Then names, best-ranked: the palette's matcher already does this well and a
        // second fuzzy scorer would be a second thing to keep honest.
        hits += Palette.rank(q, Command.allCases, key: \.title).filter { !hits.contains($0) }
        return hits
    }

    private static let modWords: [(String, Keybinding.Mods)] = [
        ("command", .command), ("cmd", .command),
        ("control", .control), ("ctrl", .control),
        ("option", .option), ("opt", .option), ("alt", .option),
        ("shift", .shift),
    ]
    private static let modSymbols: [Character: Keybinding.Mods] = [
        "⌘": .command, "⌃": .control, "⌥": .option, "⇧": .shift,
    ]
    private static let keyWords: [String: String] = [
        "tab": "\t", "space": " ", "esc": "\u{1b}", "escape": "\u{1b}",
        "return": "\r", "enter": "\r", "delete": "\u{7f}", "backspace": "\u{7f}",
        "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
    ]

    /// "cmd shift t" / "⇧⌘T" / "control+tab" → a binding. Nil when the text does not read
    /// as a shortcut at all, which is the common case ("new tab") and means "name search
    /// only".
    private static func parseShortcut(_ query: String) -> Keybinding? {
        var rest = Substring(query.lowercased())
        var mods: Keybinding.Mods = []
        func trimSeparators() {
            while let c = rest.first, c == " " || c == "+" || c == "-", rest.count > 1 {
                rest.removeFirst()
            }
        }
        var consumed = true
        while consumed {
            consumed = false
            trimSeparators()
            if let c = rest.first, let m = modSymbols[c] {
                mods.insert(m); rest.removeFirst(); consumed = true; continue
            }
            for (word, m) in modWords where rest.hasPrefix(word) {
                // "optionally" is a word, not ⌥ + "ally": require a separator after it.
                let after = rest.dropFirst(word.count)
                guard after.isEmpty || after.first == " " || after.first == "+"
                        || after.first == "-" else { continue }
                mods.insert(m); rest = after; consumed = true; break
            }
        }
        trimSeparators()
        let tail = String(rest)
        if tail.isEmpty { return mods.isEmpty ? nil : Keybinding("", mods) }
        if let named = keyWords[tail] { return Keybinding(named, mods) }
        if tail.count >= 2, tail.first == "f", let n = Int(tail.dropFirst()), (1...20).contains(n) {
            return Keybinding(String(UnicodeScalar(0xF704 + n - 1)!), mods)
        }
        return tail.count == 1 ? Keybinding(tail, mods) : nil
    }

    // MARK: Routing

    /// Populated from Menu.swift. A command with no entry simply does not fire, which is
    /// what keeps this file from importing the rest of the app.
    static var actions: [Command: @MainActor () -> Void] = [:]

    static func command(for binding: Keybinding) -> Command? {
        guard binding.isAssigned else { return nil }
        return Command.allCases.first { Keybindings.binding(for: $0) == binding }
    }

    /// Install with:
    ///   NSEvent.addLocalMonitorForEvents(matching: .keyDown) { Keybindings.handle($0) ? nil : $0 }
    /// True means "consumed" — the caller must swallow the event.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let b = Keybinding(event: event),
              let cmd = command(for: b), let action = actions[cmd] else { return false }
        // ponytail: WKWebView gives no synchronous "did the page take it?", so `.page`
        // means "hands off whenever web content has focus" and Vane's action is simply
        // unreachable there. Ceiling: doing better needs a JS keydown listener reporting
        // defaultPrevented back over a message handler, i.e. an async round-trip per key.
        if priority(for: cmd) == .page, webContentHasFocus() { return false }
        action()
        return true
    }

    private static func webContentHasFocus() -> Bool {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let v = view {
            if v is WKWebView { return true }
            view = v.superview
        }
        return false
    }
}

// MARK: - check

extension Keybindings {
    /// Runs against a throwaway defaults suite that is deleted afterwards; the user's real
    /// preferences are never read or written. Everything asserted here is offline.
    static func check() -> [(String, Bool)] {
        let suite = "vane.check.keys.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        let realCache = cached
        defaults = scratch
        cached = nil
        defer {
            defaults = real
            cached = realCache
            scratch.removePersistentDomain(forName: suite)
        }

        let t = Keybinding("t", [.command, .shift])
        let all = Keybinding("x", [.control, .option, .shift, .command])
        var out: [(String, Bool)] = [
            ("modifiers print in ⌃⌥⇧⌘ order", all.display == "⌃⌥⇧⌘X"),
            ("a letter prints uppercase after its modifiers", t.display == "⇧⌘T"),
            ("⌥⌘I formats the way the Develop menu shows it",
             Keybinding("i", [.command, .option]).display == "⌥⌘I"),
            ("an unassigned binding displays as ---", Keybinding.unassigned.display == "---"),
            ("tab, delete and escape print as glyphs",
             Keybinding("\t").display == "⇥" && Keybinding("\u{7f}").display == "⌫"
                && Keybinding("\u{1b}").display == "⎋"),
            ("return and the arrows print as glyphs",
             Keybinding("\r").display == "⏎" && Keybinding("\u{F700}").display == "↑"
                && Keybinding("\u{F701}").display == "↓" && Keybinding("\u{F702}").display == "←"
                && Keybinding("\u{F703}").display == "→"),
            ("function keys print as F1…F12",
             Keybinding("\u{F704}").display == "F1" && Keybinding("\u{F70E}").display == "F11"),
            ("case does not make two different bindings",
             Keybinding("T", .command) == Keybinding("t", .command)),
            ("backtab is stored as shift-tab", Keybinding("\u{19}", .control).display == "⌃⇧⇥"),
            ("…and turns back into backtab for the menu",
             Keybinding("\u{19}", .control).menuKeyEquivalent == "\u{19}"),
            ("a shifted punctuation glyph does not also carry ⇧",
             Keybinding("+", [.command, .shift]).display == "⌘+"),
            ("the menu mask matches the modifiers",
             t.menuModifierMask == [.command, .shift] && t.menuKeyEquivalent == "t"),
            ("an unassigned binding has no SwiftUI shortcut",
             Keybinding.unassigned.keyboardShortcut == nil && t.keyboardShortcut != nil),
        ]

        // Codable, then the same trip through UserDefaults.
        let encoded = try? JSONEncoder().encode(t)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(Keybinding.self, from: $0) }
        out.append(("a binding round-trips through Codable", decoded == t))

        // Defaults, spot-checked against the key equivalents Menu.swift/UI.swift hardcode.
        out += [
            ("New Tab defaults to ⌘T", binding(for: .newTab).display == "⌘T"),
            ("Reopen Closed Tab defaults to ⇧⌘T", binding(for: .reopenClosedTab).display == "⇧⌘T"),
            ("Reload Ignoring Cache defaults to ⇧⌘R", binding(for: .hardReload).display == "⇧⌘R"),
            ("Show Web Inspector defaults to ⌥⌘I", binding(for: .showWebInspector).display == "⌥⌘I"),
            ("Enter Full Screen defaults to ⌃⌘F", binding(for: .fullScreen).display == "⌃⌘F"),
            ("Back defaults to ⌘[", binding(for: .back).display == "⌘["),
            ("Fill Password defaults to ⌥⌘L", binding(for: .fillPassword).display == "⌥⌘L"),
            ("Show Library defaults to ⇧⌘L, the way Arc binds it",
             binding(for: .showLibrary).display == "⇧⌘L"),
            ("Pin Tab defaults to ⌘D, the way Arc binds it",
             binding(for: .pinTab).display == "⌘D"),
            ("Favourite Tab ships unbound, as Arc does",
             binding(for: .favouriteTab).display == "---"),
            ("⇧⌘D is left free", conflicts(Keybinding("d", [.command, .shift])).isEmpty),
            ("Bookmark This Page keeps ⌥⌘D",
             binding(for: .bookmarkPage).display == "⌥⌘D"),
            ("Clear Tabs defaults to ⇧⌘K", binding(for: .clearTabs).display == "⇧⌘K"),
            ("Copy Page URL defaults to ⇧⌘C", binding(for: .copyPageURL).display == "⇧⌘C"),
            ("⌘W archives rather than closes, the way Arc names it",
             Command.closeTab.title == "Archive Tab" && binding(for: .closeTab).display == "⌘W"),
            ("Next and Previous Space default to ⌥⌘→ and ⌥⌘←",
             binding(for: .nextSpace).display == "⌥⌘→"
                && binding(for: .previousSpace).display == "⌥⌘←"),
            ("Go to Space N defaults to ⌃N",
             binding(for: .goToSpace1).display == "⌃1" && binding(for: .goToSpace9).display == "⌃9"),
            ("the Tab Switcher goes forwards on ⌃⇥, not backwards",
             binding(for: .tabSwitcher).display == "⌃⇥"
                && binding(for: .tabSwitcherBackwards).display == "⌃⇧⇥"),
            ("Next and Previous Tab walk the sidebar on ⌥⌘↓ and ⌥⌘↑",
             binding(for: .nextTab).display == "⌥⌘↓"
                && binding(for: .previousTab).display == "⌥⌘↑"),
            ("View History defaults to ⌘Y", binding(for: .viewHistory).display == "⌘Y"),
            ("Downloads defaults to ⇧⌘J", binding(for: .showDownloads).display == "⇧⌘J"),
            ("Minimize defaults to ⌘M", binding(for: .minimizeWindow).display == "⌘M"),
            ("Open File defaults to ⌘O", binding(for: .openFile).display == "⌘O"),
            ("Save Page As defaults to ⇧⌘S, leaving ⌘S the sidebar's",
             binding(for: .savePageAs).display == "⇧⌘S"
                && binding(for: .toggleSidebar).display == "⌘S"),
            ("Find Next and Previous default to ⌘G and ⇧⌘G",
             binding(for: .findNext).display == "⌘G"
                && binding(for: .findPrevious).display == "⇧⌘G"),
            ("Select Tab 1 defaults to ⌘1", binding(for: .selectTab1).display == "⌘1"),
            // The local monitor sees every keyDown in the app. If a bare keystroke ever
            // resolved to a command, typing would stop working everywhere.
            ("a bare letter matches no command", command(for: Keybinding("a", [])) == nil),
            ("a bare digit matches no command", command(for: Keybinding("1", [])) == nil),
            ("shift alone matches no command", command(for: Keybinding("A", [.shift])) == nil),
            ("an unassigned binding matches no command", command(for: .unassigned) == nil),
            ("Command Palette defaults to ⇧⌘P", binding(for: .commandPalette).display == "⇧⌘P"),
            ("Zoom In defaults to ⌘+", binding(for: .zoomIn).display == "⌘+"),
            ("Import Passwords ships unbound", binding(for: .importPasswords).display == "---"),
        ]

        // Conflicts.
        out.append(("the shipped defaults do not collide with each other",
                    Command.allCases.filter { binding(for: $0).isAssigned }
                        .allSatisfy { conflicts(binding(for: $0)) == [$0] }))
        // The same thing said about `defaultBinding` itself rather than about what the
        // store hands back, so a duplicate cannot hide behind an override.
        let shipped = Command.allCases.map(\.defaultBinding).filter(\.isAssigned)
        out.append(("no two commands ship with the same default binding",
                    Set(shipped).count == shipped.count))
        out.append(("an unassigned binding conflicts with nothing",
                    conflicts(.unassigned).isEmpty))
        set(Keybinding("t", .command), for: .newWindow)
        out.append(("a rebind onto another command's keys is reported",
                    Set(conflicts(Keybinding("t", .command))) == [.newTab, .newWindow]))
        out.append(("the override wins over the default",
                    binding(for: .newWindow).display == "⌘T"))

        // Persistence: drop the cache so the read has to come back off the suite.
        cached = nil
        out.append(("an override survives a trip through UserDefaults",
                    binding(for: .newWindow).display == "⌘T"))

        // Migration: the ⌃⇥ swap and ⌘D moving from Favourite to Pin.
        let stale: [String: Keybinding] = [
            Command.previousTab.rawValue: Keybinding("\t", .control),
            Command.favouriteTab.rawValue: Keybinding("d", .command),
            Command.pinTab.rawValue: Keybinding("f", [.command, .control, .option]),
            Command.newTab.rawValue: Keybinding("t", .command),
        ]
        let migrated = migrate(stale, moved: movedDefaults)
        out += [
            ("a saved binding that was only the old default is dropped",
             migrated[Command.previousTab.rawValue] == nil
                && migrated[Command.favouriteTab.rawValue] == nil),
            ("a binding the user really chose is not touched",
             migrated[Command.pinTab.rawValue] == Keybinding("f", [.command, .control, .option])),
            ("a command whose default never moved is not touched",
             migrated[Command.newTab.rawValue] == Keybinding("t", .command)),
            ("migrating twice changes nothing more",
             migrate(migrated, moved: movedDefaults) == migrated),
            ("every moved default is a binding the app no longer ships",
             movedDefaults.allSatisfy { $0.key.defaultBinding != $0.value }),
        ]

        // Reset.
        reset(.newWindow)
        out.append(("reset restores the default", binding(for: .newWindow).display == "⌘N"))
        set(.unassigned, for: .newTab)
        out.append(("unbinding is a real choice, not a reset",
                    binding(for: .newTab).display == "---"))
        resetAll()
        out.append(("reset all restores every default",
                    binding(for: .newTab).display == "⌘T" && binding(for: .newWindow).display == "⌘N"))

        // Search.
        out += [
            ("an empty query lists everything", search("  ").count == Command.allCases.count),
            ("search by name", search("new tab").first == .newTab),
            ("search by name is fuzzy and case-insensitive", search("RLDIGN").first == .hardReload),
            ("search by shortcut glyphs", search("⌘T").contains(.newTab)),
            ("search by spelled-out shortcut", search("cmd t").contains(.newTab)),
            ("search by shortcut with a plus", search("command+t").contains(.newTab)),
            ("every spelling of a shortcut ranks the same command first",
             search("⌘T").first == .newTab && search("cmd t").first == .newTab
                && search("command+t").first == .newTab),
            ("…including the option key's three names",
             search("⌥⌘i").first == .showWebInspector
                && search("option cmd i").first == .showWebInspector
                && search("alt+command+i").first == .showWebInspector),
            ("modifiers are order-insensitive in a query",
             search("shift cmd t").contains(.reopenClosedTab)
                && search("cmd shift t").contains(.reopenClosedTab)),
            ("a shortcut query does not return the wrong modifiers",
             !search("cmd t").contains(.reopenClosedTab)),
            ("named keys can be typed", search("ctrl tab").contains(.tabSwitcher)),
            ("a modifiers-only query lists everything using them",
             search("⌥⌘").contains(.showWebInspector) && !search("⌥⌘").contains(.newTab)),
            ("a plain word is not mistaken for a shortcut",
             !search("options").contains(.newTab)),
            ("a query matching nothing returns nothing", search("zzzz").isEmpty),
        ]

        // Reserved.
        out += [
            ("⌘Q is refused", reserved(Keybinding("q", .command)) != nil),
            ("⌘⇧Q is refused", reserved(Keybinding("q", [.command, .shift])) != nil),
            ("⌘⇥ is refused", reserved(Keybinding("\t", .command)) != nil),
            ("⌘Space is refused", reserved(Keybinding(" ", .command)) != nil),
            ("a bare key with no ⌘/⌃/⌥ is refused", reserved(Keybinding("t")) != nil),
            ("a bare function key is allowed", reserved(Keybinding("\u{F704}")) == nil),
            ("an ordinary binding is allowed", reserved(Keybinding("t", .command)) == nil),
            ("unassigned is not reserved", reserved(.unassigned) == nil),
        ]

        // Priority.
        out.append(("commands default to browser priority", priority(for: .find) == .browser))
        setPriority(.page, for: .find)
        cached = nil
        out.append(("page priority round-trips through UserDefaults", priority(for: .find) == .page))
        out.append(("priority is per command", priority(for: .newTab) == .browser))
        reset(.find)
        out.append(("reset clears the priority too", priority(for: .find) == .browser))

        // Routing, minus the NSEvent (which needs an app to be meaningful).
        out.append(("a binding resolves to its command", command(for: Keybinding("t", .command)) == .newTab))
        out.append(("an unassigned binding resolves to nothing", command(for: .unassigned) == nil))
        out.append(("an unbound key resolves to nothing",
                    command(for: Keybinding("j", [.command, .control, .option])) == nil))

        resetAll()
        return out
    }
}
