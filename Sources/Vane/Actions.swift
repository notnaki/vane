import AppKit

// MARK: - One action

/// A palette entry that is an action rather than a place to go.
///
/// Nearly every row here *is* a menu item: it carries a `Command`, and running it looks the
/// closure up in `Keybindings.actions` — the same one `Menu.swift` handed the menu bar and
/// the key monitor. So the bar, the menu and the keystroke can never disagree about what
/// "Reload Page" does, and rebinding a key in Settings ▸ Shortcuts changes what the row
/// prints without this file knowing anything about keys.
struct PaletteCommand: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// The registry entry this row runs, when it is one. Kept rather than folded into `run`
    /// so the row can print the binding the user has *now*: the catalogue is built when the
    /// bar opens, but a binding can change under it in the Shortcuts pane.
    let command: Command?
    let run: @MainActor () -> Void

    /// What Arc prints down the right-hand side of an action row. Empty when the action has
    /// no key — which is most of them, and Arc leaves that side blank rather than writing
    /// out a placeholder.
    @MainActor var shortcut: String {
        guard let command else { return "" }
        let binding = Keybindings.binding(for: command)
        return binding.isAssigned ? binding.display : ""
    }

    /// An action of the bar's own: no menu item, no shortcut, no registry entry. `id`
    /// defaults to the title, which is unique for every fixed row; the rows built from the
    /// user's own data pass one, because two Spaces may well share a name.
    init(_ title: String, icon: String, id: String? = nil,
         run: @escaping @MainActor () -> Void) {
        self.id = id ?? title
        self.icon = icon
        self.title = title
        self.command = nil
        self.run = run
    }

    /// A menu item, by id. The closure is fetched when the row is *pressed*, never captured
    /// when the catalogue is built — `Keybindings.actions` is filled in by `buildMenu()`,
    /// and a nil captured before that would be a row that stayed dead for the process.
    ///
    /// ponytail: the registry is a dictionary, so a `Command` no menu item registers would
    /// be a row that does nothing. Every command named in `all(for:)` is an `item(.x)` in
    /// Menu.swift today and `check()` enumerates them, but nothing links the two at compile
    /// time. Ceiling reached the day a menu item is deleted without its row; the fix is
    /// `Command` carrying its own closure, which is a Menu.swift change, not this file's.
    init(_ command: Command, icon: String, title: String? = nil) {
        self.id = command.rawValue
        self.icon = icon
        self.title = title ?? command.title
        self.command = command
        self.run = { Keybindings.actions[command]?() }
    }
}

// MARK: - The catalogue

extension PaletteCommand {

    /// Every action this window can offer *right now*.
    ///
    /// Arc's rule, and the reason this is a function of a window rather than a static list:
    /// an action that cannot run is not listed at all. Greying rows out would leave a bar
    /// full of things Return refuses to do — half of them meaningless in a Little Arc, which
    /// has no sidebar, no Space and no strip to split — so each group below is gated on the
    /// one fact that makes it real, and the rest of the list closes up over it.
    ///
    /// The order is the order the bar shows them with nothing typed (see `topActions`), and
    /// then it is only a tie-break: `Palette.rank` decides everything once a letter is typed.
    @MainActor static func all(for store: TabStore) -> [PaletteCommand] {
        var out: [PaletteCommand] = [
            PaletteCommand(.newTab, icon: "plus"),
            PaletteCommand(.reopenClosedTab, icon: "arrow.uturn.left"),
            PaletteCommand(.newWindow, icon: "macwindow"),
            PaletteCommand(.newPrivateWindow, icon: "eyeglasses"),
        ]
        // The one row that carries the window it was opened from: ⌥⌘N out of a private
        // window has to stay private, and a menu item has no window to ask. In an ordinary
        // window `store.isPrivate` is false and this is the menu item's own closure.
        out.insert(PaletteCommand(.newLittleArc, icon: "rectangle.on.rectangle") {
            LittleArc.open(nil, isPrivate: store.isPrivate)
        }, at: 1)

        // The page in front of you. Everything here needs somewhere to act, and a window
        // showing nothing has nowhere.
        if let tab = store.active {
            out += [
                PaletteCommand(.copyPageURL, icon: "link", title: "Copy URL"),
                PaletteCommand("Copy URL as Markdown", icon: "doc.on.clipboard") {
                    copyAsMarkdown(tab)
                },
                PaletteCommand(.reload, icon: "arrow.clockwise"),
                PaletteCommand(.hardReload, icon: "arrow.clockwise.circle"),
                PaletteCommand(.find, icon: "magnifyingglass", title: "Find in Page"),
                PaletteCommand(.closeTab, icon: "archivebox"),
            ]
            // Back and Forward are the two rows whose absence is information: with nothing
            // behind the page, Arc does not offer to go there.
            if tab.web.canGoBack { out.append(PaletteCommand(.back, icon: "chevron.left")) }
            if tab.web.canGoForward { out.append(PaletteCommand(.forward, icon: "chevron.right")) }
            out += [
                PaletteCommand(.showReader, icon: "doc.plaintext", title: "Reader Mode"),
                PaletteCommand(.pictureInPicture, icon: "pip"),
                PaletteCommand(.muteTab, icon: TabAudio.isMuted(tab) ? "speaker.wave.2" : "speaker.slash",
                               title: TabAudio.isMuted(tab) ? "Unmute Tab" : "Mute Tab"),
                PaletteCommand(.zoomIn, icon: "plus.magnifyingglass"),
                PaletteCommand(.zoomOut, icon: "minus.magnifyingglass"),
                PaletteCommand(.actualSize, icon: "1.magnifyingglass"),
                PaletteCommand(.sharePage, icon: "square.and.arrow.up", title: "Share…"),
                PaletteCommand(.printPage, icon: "printer"),
                PaletteCommand(.savePageAs, icon: "square.and.arrow.down"),
                PaletteCommand("Rename Tab", icon: "pencil") { TabActions.renameTab(tab) },
                PaletteCommand("Duplicate Tab", icon: "plus.square.on.square") {
                    TabActions.duplicate(tab, in: store)
                },
                PaletteCommand("Toggle Developer Mode", icon: "chevron.left.forwardslash.chevron.right") {
                    SiteControl.setDeveloper(!tab.web.isInspectable, on: tab)
                },
                PaletteCommand("Clear Site Data…", icon: "trash") {
                    SiteControl.clearSiteData(host: SiteControl.host(of: tab), tab: tab)
                },
            ]
            // The inspector menu items grey themselves out for these two reasons; the bar
            // says the same thing by not offering the row.
            if Inspector.available, Settings.inspectorEnabled {
                out.append(PaletteCommand(.showWebInspector, icon: "hammer"))
            }
        }

        // The sidebar's own actions. A Little Arc is one page in a window with no sidebar,
        // and a private window has no Spaces — neither has anything for these to act on.
        if !store.isLittle {
            out.append(PaletteCommand(.toggleSidebar, icon: "sidebar.left"))
            if store.active != nil {
                out += [
                    PaletteCommand(store.active?.kind == .pinned ? "Unpin Tab" : "Pin Tab",
                                   icon: store.active?.kind == .pinned ? "pin.slash" : "pin",
                                   command: .pinTab),
                    PaletteCommand(store.active?.kind == .favourite
                                       ? "Unfavourite Tab" : "Favourite Tab",
                                   icon: store.active?.kind == .favourite ? "star.slash" : "star",
                                   command: .favouriteTab),
                    PaletteCommand(.addSplit, icon: "rectangle.split.2x1"),
                ]
            }
            if store.activeSplit != nil {
                out += [
                    PaletteCommand(.removeSplit, icon: "rectangle"),
                    PaletteCommand(.nextPane, icon: "arrow.left.arrow.right"),
                ]
            }
            if TidyTabs.shouldOffer(store) { out.append(PaletteCommand(.tidyTabs, icon: "wand.and.stars")) }
            if store.tabs.contains(where: { $0.kind == .today }) {
                out.append(PaletteCommand(.clearTabs, icon: "xmark.bin"))
            }
            out.append(PaletteCommand("New Folder", icon: "folder.badge.plus") {
                _ = store.newFolder()
            })
        }

        // Spaces: a private window is in none, and a Little Arc left the one it came from.
        if !store.isPrivate, !store.isLittle {
            out.append(PaletteCommand(.newSpace, icon: "square.stack"))
            if store.spaces.count > 1 {
                out += [
                    PaletteCommand(.nextSpace, icon: "arrow.right"),
                    PaletteCommand(.previousSpace, icon: "arrow.left"),
                ]
            }
            // Arc's "Move to Space ▸" is a submenu, and a search bar has no submenus — so it
            // is one row per Space, which is also the row typing the Space's name lands on.
            if let tab = store.active, tab.currentURL?.scheme?.hasPrefix("http") == true {
                for space in store.spaces where space.id != store.currentSpaceID {
                    out.append(PaletteCommand("Move Tab to \(space.name)",
                                              icon: space.icon ?? "square.on.square",
                                              id: "moveToSpace:" + space.id.uuidString) {
                        Spaces.move(tab.id, to: space.id, as: .today, from: store)
                    })
                }
            }
        }

        return out + [
            PaletteCommand(.showLibrary, icon: "books.vertical"),
            PaletteCommand(.viewArchive, icon: "tray.full"),
            PaletteCommand(.viewHistory, icon: "clock.arrow.circlepath"),
            PaletteCommand(.showDownloads, icon: "arrow.down.circle"),
            PaletteCommand(.settings, icon: "gearshape"),
            PaletteCommand(.keyboardShortcutsHelp, icon: "keyboard", title: "Shortcuts Settings"),
            PaletteCommand("Link Preferences", icon: "link.circle") {
                SettingsWindow.show(tab: "links")
            },
            PaletteCommand(.vaneHelp, icon: "questionmark.circle", title: "Help Center"),
            // No Quit row. Arc's palette has none, and for the reason you would guess: it
            // would sit one Return away from every half-finished download in the window.
        ]
    }

    /// How many actions Arc's bar shows before a single character is typed. Enough to say
    /// "there are verbs in here too", not so many that ⌘⇧P opens on a wall of them.
    static let topCount = 5

    /// Arc's bar at rest lists a few suggested actions under the open tabs. The head of the
    /// catalogue is that list — the five rows above are the ones that need nothing to be
    /// true, so the suggested set never changes shape as tabs come and go.
    @MainActor static func topActions(for store: TabStore) -> [PaletteCommand] {
        Array(all(for: store).prefix(topCount))
    }

    /// A menu item whose row has to know something the menu item cannot: which window the
    /// bar was opened in. It keeps the command's id, title and key — so the row still reads
    /// and prints as that menu item — and supplies its own closure. Only for that: two
    /// spellings of one action is exactly how the bar and the menu drift apart.
    init(_ command: Command, icon: String, title: String? = nil,
         run: @escaping @MainActor () -> Void) {
        self.id = command.rawValue
        self.icon = icon
        self.title = title ?? command.title
        self.command = command
        self.run = run
    }

    /// A row whose title is written here but whose action, key and enabled-ness belong to a
    /// menu item: Pin/Unpin and Favourite/Unfavourite say what they will do to *this* tab,
    /// the way Arc's menu items do, while still running the registry's closure.
    init(_ title: String, icon: String, command: Command) {
        self.id = command.rawValue
        self.icon = icon
        self.title = title
        self.command = command
        self.run = { Keybindings.actions[command]?() }
    }
}

/// ⇧⌘C copies the url; this copies the link the way it would be pasted into a document.
/// The tab's *shown* title, so a renamed tab pastes under the name you gave it.
@MainActor private func copyAsMarkdown(_ tab: Tab) {
    guard let url = tab.currentURL else { return }
    let title = TidyTitles.title(for: tab)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("[\(title)](\(url.absoluteString))", forType: .string)
    axAnnounce("Markdown link copied.")
    Toasts.show("Copied Markdown link")
}

// MARK: - check

extension PaletteCommand {
    /// Every `Command` the catalogue can hand a row. Kept as a list so the checks below can
    /// walk it without a window: `all(for:)` needs a real `TabStore`, which needs WebKit.
    ///
    /// This is the list Menu.swift must keep registering. It is written down rather than
    /// derived because there is nothing to derive it from — see the ceiling on `init`.
    static let registered: [Command] = [
        .newTab, .newLittleArc, .reopenClosedTab, .newWindow, .newPrivateWindow,
        .copyPageURL, .reload, .hardReload, .find, .closeTab, .back, .forward,
        .showReader, .pictureInPicture, .muteTab, .zoomIn, .zoomOut, .actualSize,
        .sharePage, .printPage, .savePageAs, .showWebInspector,
        .toggleSidebar, .pinTab, .favouriteTab, .addSplit, .removeSplit, .nextPane,
        .tidyTabs, .clearTabs, .newSpace, .nextSpace, .previousSpace,
        .showLibrary, .viewArchive, .viewHistory, .showDownloads,
        .settings, .keyboardShortcutsHelp, .vaneHelp,
    ]

    static func check() -> [(String, Bool)] {
        let titles = registered.map(\.title)
        // `defaultBinding`, never `Keybindings.binding(for:)`: this runs in the `--pure`
        // set, and reading the store would read — and its migration could *write* — the
        // preferences of whoever is running the release gate. Somebody with New Tab
        // rebound would fail a check about the shipped catalogue. What is asserted here is
        // the shipped default and the rule `shortcut` applies to it: an assigned binding
        // prints, an unassigned one prints nothing at all.
        func shipped(_ command: Command) -> String {
            command.defaultBinding.isAssigned ? command.defaultBinding.display : ""
        }
        let shortcuts = registered.map(shipped)
        return [
            ("the catalogue is Arc's dozens, not a handful", registered.count >= 35),
            ("no action is listed twice", Set(registered).count == registered.count),
            ("every action has a title", titles.allSatisfy { !$0.isEmpty }),
            // The whole point of going through the registry: the row prints the key the
            // menu item wears, so rebinding one moves both.
            ("an action prints the shortcut its menu item wears", shipped(.newTab) == "⌘T"),
            // Arc leaves that side of the row blank rather than writing out a placeholder,
            // and plenty of these ship unbound — Favourite Tab among them.
            ("an unbound action prints nothing, not `---`",
             shipped(.favouriteTab).isEmpty && !shortcuts.contains("---")),
            ("…but most of the catalogue does carry a key",
             shortcuts.filter { !$0.isEmpty }.count > registered.count / 2),

            // The catalogue is searched, so the obvious word has to find the obvious row.
            ("typing a verb finds its action",
             Palette.rank("reload", titles, key: { $0 }).first == "Reload Page"),
            ("…and an abbreviation does too",
             Palette.rank("pip", titles, key: { $0 }).first == "Picture in Picture"),
            ("…and a word from the middle of the title",
             Palette.rank("inspector", titles, key: { $0 }).first == "Show Web Inspector"),
            ("one character is enough to match, the way Arc's bar is",
             !Palette.rank("z", titles, key: { $0 }).isEmpty),
        ]
    }
}
