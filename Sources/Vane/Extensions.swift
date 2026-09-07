import AppKit
import SwiftUI
import WebKit

// MARK: - Wiring (read this before touching Engine.swift)
//
// A WKWebView only participates in the extension system if the *configuration it was
// created with* names the controller. There is no way to attach one afterwards, so this
// has to happen inside `Tab.configuration(isPrivate:)`:
//
//     cfg.webExtensionController = ExtensionHost.host(for: profileID).controller
//
// One line, and it must run before `WKWebView(frame:configuration:)`. There is one host per
// *profile*, so an extension loaded in one profile never sees another profile's tabs. Private
// tabs share their profile's controller: WebKit gates them on each context's
// `hasAccessToPrivateData` (off by default here), and Vane already satisfies the isolation
// rule WebKit requires — a non-persistent data store plus a fresh WKUserContentController
// per Tab.
//
// `configuration(for:)` below is the same thing spelled for a call site that has a store.
//
// Menu.swift needs nothing but:
//
//     item("Install Extension…", "") { ExtensionHost.shared.chooseAndInstall(); rebuild() }
//
// and, to list/remove, `ExtensionHost.shared.installed` mapped to items calling
// `ExtensionHost.shared.remove(ctx)`.

/// Host for Apple's WebExtension API. Owns the one controller, the loaded contexts, and
/// the adapters that let an extension see Vane's tabs and windows.
///
/// ponytail: one controller per profile, not per window — WKWebExtension is modelled that
/// way (windows are things the controller asks *you* about). Profiles are exactly the level
/// where a separate persistent store identifier is warranted. Upgrade path if private windows
/// ever need their own extension set: a third host built on `.nonPersistent()`.
@MainActor final class ExtensionHost: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    /// The active profile's host. One host — one controller, one extension set, one set of
    /// background pages — per profile, so an extension in one profile cannot see another
    /// profile's tabs or storage.
    static var shared: ExtensionHost { host(for: ProfileManager.shared.active.id) }

    private static var hosts: [UUID: ExtensionHost] = [:]

    static func host(for profileID: UUID) -> ExtensionHost {
        if let hit = hosts[profileID] { return hit }
        let fresh = ExtensionHost(profileID: profileID)
        hosts[profileID] = fresh
        return fresh
    }

    /// Unload everything and forget the host. Called when a profile is deleted.
    static func forget(_ profileID: UUID) {
        guard let host = hosts[profileID] else { return }
        for context in host.installed { try? host.controller.unload(context) }
        host.loaded.removeAll()
        hosts[profileID] = nil
    }

    let profileID: UUID
    let controller: WKWebExtensionController

    /// Folder path alongside the context, because WKWebExtension does not report the
    /// resource base URL it was built from and uninstall has to erase the stored path.
    @Published private(set) var loaded: [(path: String, context: WKWebExtensionContext)] = []

    var installed: [WKWebExtensionContext] { loaded.map(\.context) }

    private init(profileID: UUID) {
        self.profileID = profileID
        // A profile-scoped controller configuration is what keeps extension storage and
        // background state from crossing profiles; the default profile keeps `.default()`
        // so already-installed extensions keep their storage.
        let configuration = profileID == ProfileManager.defaultID
            ? WKWebExtensionController.Configuration.default()
            : WKWebExtensionController.Configuration(identifier: profileID)
        configuration.defaultWebsiteDataStore = ProfileManager.dataStore(for: profileID)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        for folder in ScopedPaths.urls(Self.key(for: profileID)) { begin(folder) }
    }

    /// The controller a new WKWebView's configuration must be pointed at. See the wiring note
    /// at the top of this file. Resolves through the store's *profile*, so calling it on the
    /// wrong host still returns the right controller.
    func configuration(for store: TabStore) -> WKWebExtensionController {
        Self.host(for: store.profileID).controller
    }

    // MARK: Install / remove

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// Validates the folder synchronously (so a bad pick fails loudly and nothing is
    /// persisted), then loads it.
    ///
    /// ponytail: the actual load is fire-and-forget, because `WKWebExtension(resourceBaseURL:)`
    /// is async-only in this SDK and the requested signature is not. A manifest that parses
    /// but that WebKit rejects therefore surfaces as an alert a beat later rather than as a
    /// thrown error. Upgrade path: make this `async throws` the day the call sites can await.
    func install(folder: URL) throws {
        _ = try Self.validate(folder)
        // A path is not enough under the sandbox: powerbox's grant on a panel selection
        // dies with the process, so the folder must be kept as a scoped bookmark.
        guard ScopedPaths.add(folder, to: myKey) else {
            throw Failure("macOS would not let Vane keep access to \(folder.lastPathComponent) "
                + "after quitting, so it was not installed.")
        }
        begin(folder)
    }

    private var myKey: String { Self.key(for: profileID) }

    func remove(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        forget(context, tab: nil)
        if let path = loaded.first(where: { $0.context === context })?.path {
            ScopedPaths.remove(path: path, from: myKey)
            claimed.remove(path)
            // An uninstalled extension must not keep a slot in the pill: the cap is three,
            // and a pin nothing can fill would silently cost one of them.
            setPins(pins.filter { $0 != path })
        }
        loaded.removeAll { $0.context === context }
        if loaded.isEmpty { poller?.invalidate(); poller = nil }   // no timer is started any more
    }

    /// Paths loaded or in flight. Installing the same folder twice would otherwise give the
    /// extension two contexts, two background pages, and two of every event.
    private var claimed: Set<String> = []

    private func begin(_ folder: URL) {
        guard claimed.insert(folder.path).inserted else { return }
        Task {
            do {
                let ext = try await WKWebExtension(resourceBaseURL: folder)
                let context = WKWebExtensionContext(for: ext)
                context.isInspectable = Settings.inspectorEnabled
                context.inspectionName = ext.displayName
                grantRequested(on: context, of: ext)
                try controller.load(context)
                loaded.append((folder.path, context))
                startPolling()
                prunePins()
            } catch {
                claimed.remove(folder.path)
                warn("Could not load the extension in \(folder.lastPathComponent).",
                     error.localizedDescription)
            }
        }
    }

    /// ponytail: an unpacked extension is installed by the user pointing a file panel at a
    /// folder, so everything the manifest asks for is granted up front. The runtime prompts
    /// below are still wired, so anything requested *later* does ask. Upgrade path: a real
    /// permissions sheet at install time listing what is about to be granted.
    private func grantRequested(on context: WKWebExtensionContext, of ext: WKWebExtension) {
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    // MARK: Manifest validation (pure — this is what `check()` exercises)

    /// The cheap half of what WebKit will do, done synchronously so a wrong folder is
    /// rejected before anything is written down. Returns the parsed manifest.
    static func validate(_ folder: URL) throws -> [String: Any] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure("\(folder.lastPathComponent) is not a folder.")
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw Failure("No manifest.json in \(folder.lastPathComponent) — pick the folder that "
                + "contains the manifest, not the one above it.")
        }
        guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure("manifest.json is not valid JSON.")
        }
        guard let name = manifest["name"] as? String, !name.isEmpty else {
            throw Failure("manifest.json has no \"name\".")
        }
        // WebKit implements MV2 and MV3. Anything else is not going to load.
        let version = (manifest["manifest_version"] as? NSNumber)?.doubleValue ?? 0
        guard version == 2 || version == 3 else {
            throw Failure("manifest_version must be 2 or 3 (found \(manifest["manifest_version"] ?? "nothing")).")
        }
        return manifest
    }

    // MARK: Persistence

    /// ponytail: plain paths, not security-scoped bookmarks — Vane is not sandboxed, so a
    /// path is all the access it needs. Sandbox it and this becomes bookmark data.
    static let baseKey = "extensionFolders"

    /// Per profile, so an extension installed in one profile is not loaded into another.
    static func key(for profileID: UUID) -> String {
        ProfileManager.defaultsKey(baseKey, profileID)
    }

    // MARK: Actions
    //
    // An extension's *action* is its button: the icon, the badge and the enabled flag it
    // sets with `browser.action.*`, all of them per tab. Vane draws it in two places — a
    // row in the Site Control Center, and a glyph in the address pill once pinned — and
    // both go through here so the anchoring, the caching and the private-window rule are
    // decided once.

    /// The extensions a window may show. A private window offers only the ones that have
    /// been let into private browsing: WebKit gates every other extension API on the same
    /// flag, so a button for one of them would be a button that does nothing.
    func visible(private isPrivate: Bool) -> [WKWebExtensionContext] {
        installed.filter { !isPrivate || $0.hasAccessToPrivateData }
    }

    func visible(in tab: Tab?) -> [WKWebExtensionContext] {
        guard let tab else { return [] }
        return visible(private: tab.isPrivate)
    }

    /// The action as *this tab* sees it. With a tab, the default action (`for: nil`) is the
    /// wrong one to draw — the badge a page's content script just set lives on the tab's.
    /// With no tab, the default action is exactly right: it is what an empty pill shows.
    func action(_ context: WKWebExtensionContext, for tab: Tab?) -> WKWebExtension.Action? {
        context.action(for: shim(tab))
    }

    /// The action's icon in a `Look.rowIcon` box, cached. `icon(for:)` re-decodes the
    /// extension's PNG on every call and the pill asks on every redraw; an entry is dropped
    /// the moment WebKit says that action changed, so nothing here can go stale.
    func icon(_ context: WKWebExtensionContext, for tab: Tab?) -> NSImage? {
        let key = ActionKey(context, tab)
        if let hit = icons[key] { return hit }
        let box = CGSize(width: Look.rowIcon, height: Look.rowIcon)
        // WebKit already falls back to the extension's own icon; this is the second fall,
        // for an extension whose icons will not load at all.
        guard let image = action(context, for: tab)?.icon(for: box)
            ?? context.webExtension.icon(for: box) else { return nil }
        icons[key] = image
        return image
    }

    /// Run an action the way a click on its button does — fire its event, or present its
    /// popup hanging off `view`. `performAction` also marks the tab as having had a user
    /// gesture, which is what `activeTab` extensions actually wait for.
    func run(_ context: WKWebExtensionContext, for tab: Tab?, from view: NSView?) {
        let shim = shim(tab)
        // Only an action that *has* a popup will ever ask for its anchor. Recording one for
        // an onClicked-only extension would leave it in the table with nothing to consume
        // it, and the next popup would come up on a button nobody pressed.
        if let view, context.action(for: shim)?.presentsPopup == true {
            anchors[ActionKey(context, tab)] = WeakView(view: view)
        }
        context.performAction(for: shim)
    }

    /// The button each pending popup was run from, keyed by extension *and* tab.
    ///
    /// WebKit calls `presentActionPopup` once the popup has finished loading, not on the
    /// next turn of the loop, so two clicks can be in flight at once — and one shared slot
    /// would open a slow popup on whichever button was pressed last, in whichever window.
    /// Weak, because the row that was clicked can be gone by then, and the fallback below
    /// is what that falls back to.
    private var anchors: [ActionKey: WeakView] = [:]

    /// One extension's action on one tab: what an anchor and a cached icon are both about.
    /// A `nil` tab is the default action, which is what an empty pill draws.
    struct ActionKey: Hashable {
        let context: ObjectIdentifier
        let tab: Tab.ID?
        init(_ context: WKWebExtensionContext, _ tab: Tab?) {
            self.context = ObjectIdentifier(context)
            self.tab = tab?.id
        }
        init(_ context: ObjectIdentifier, _ tab: Tab.ID?) {
            self.context = context
            self.tab = tab
        }
    }

    private struct WeakView { weak var view: NSView? }

    private var icons: [ActionKey: NSImage] = [:]

    private func shim(_ tab: Tab?) -> (any WKWebExtensionTab)? {
        guard let tab, let store = store(holding: tab) else { return nil }
        return adapter(for: tab, in: store)
    }

    /// The Tab behind an action, when WebKit says which one it is about.
    private func subject(of action: WKWebExtension.Action) -> Tab? {
        (action.associatedTab as? ExtTab)?.tab
    }

    /// Everything remembered about one extension's buttons. `tab` of `.some(id)` forgets one
    /// tab's, `.some(nil)` the default action's, and `nil` the lot — which is what unloading
    /// an extension does.
    private func forget(_ context: WKWebExtensionContext, tab: Tab.ID??) {
        let id = ObjectIdentifier(context)
        guard case .some(let one) = tab else {
            icons = icons.filter { $0.key.context != id }
            anchors = anchors.filter { $0.key.context != id }
            return
        }
        icons[ActionKey(id, one)] = nil
        anchors[ActionKey(id, one)] = nil
    }

    // MARK: Pinned to the pill

    private var pinKey: String { ProfileManager.defaultsKey(ExtensionPins.key, profileID) }

    /// The raw stored list. It can still name an extension that is not here — a folder
    /// deleted or moved between launches — which is why nothing counts or draws from it.
    var pins: [String] { UserDefaults.vane.stringArray(forKey: pinKey) ?? [] }

    /// The pins that have an extension behind them, in order and capped. This is what the
    /// cap is counted against and what the pill draws from: a pin left behind by a folder
    /// that will never load again must not hold one of the three slots for ever.
    var livePins: [String] { ExtensionPins.visible(stored: pins, installed: loaded.map(\.path)) }

    private func setPins(_ paths: [String]) {
        // No explicit bump: writing defaults posts `didChangeNotification`, which is exactly
        // what `SiteChanges` listens to. Bumping as well would redraw every pill twice.
        UserDefaults.vane.set(paths, forKey: pinKey)
    }

    /// Once nothing is still loading, the stored list is rewritten to the pins that survived
    /// it, so a dead pin is dropped for good rather than re-examined every launch.
    private func prunePins() {
        guard claimed.count == loaded.count else { return }   // something is still loading
        let live = livePins
        if live != pins { setPins(live) }
    }

    /// What the pill draws, in pin order, capped — and in a private window, only what is
    /// allowed there. Takes the window's privacy rather than a tab, because a window with no
    /// tab still draws its pinned glyphs; the pill's chrome does not come and go.
    func pinned(private isPrivate: Bool) -> [WKWebExtensionContext] {
        let allowed = visible(private: isPrivate)
        let live = loaded.filter { pair in allowed.contains { $0 === pair.context } }
        return ExtensionPins.visible(stored: pins, installed: live.map(\.path))
            .compactMap { path in live.first { $0.path == path }?.context }
    }

    func isPinned(_ context: WKWebExtensionContext) -> Bool {
        path(of: context).map(livePins.contains) ?? false
    }

    /// True when the pill has room. False is the cap being reached, which the menu item says
    /// out loud rather than quietly dropping somebody else's pin.
    var canPin: Bool { livePins.count < ExtensionPins.cap }

    func togglePin(_ context: WKWebExtensionContext) {
        guard let path = path(of: context),
              let next = ExtensionPins.toggled(path, in: livePins) else { return }
        setPins(next)
    }

    func path(of context: WKWebExtensionContext) -> String? {
        loaded.first { $0.context === context }?.path
    }

    // MARK: UI

    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.title = "Install Extension"
        panel.message = "Choose an unpacked extension folder — the one containing manifest.json."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try install(folder: folder) }
        catch { warn("Could not install that folder.", error.localizedDescription) }
    }

    private func warn(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }

    /// One modal for all three permission prompts. Returns what the user allowed.
    private func ask(_ context: WKWebExtensionContext, _ what: [String]) -> Bool {
        let a = NSAlert()
        a.messageText = "“\(context.webExtension.displayName ?? "An extension")” wants more access."
        a.informativeText = what.sorted().joined(separator: "\n")
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Deny")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Adapters
    //
    // WebKit identifies tabs and windows by object identity, so an adapter has to be the
    // same object for as long as the Tab or TabStore it wraps is alive. Hence the tables.

    private var tabShims: [Tab.ID: ExtTab] = [:]
    private var windowShims: [ObjectIdentifier: ExtWindow] = [:]

    func adapter(for store: TabStore) -> ExtWindow {
        let key = ObjectIdentifier(store)
        if let existing = windowShims[key] { return existing }
        let shim = ExtWindow(store)
        windowShims[key] = shim
        return shim
    }

    func adapter(for tab: Tab, in store: TabStore) -> ExtTab {
        if let existing = tabShims[tab.id] { return existing }
        let shim = ExtTab(tab, in: store)
        tabShims[tab.id] = shim
        return shim
    }

    private func store(holding tab: Tab) -> TabStore? {
        myStores.first { $0.tabs.contains { $0 === tab } }
    }

    // MARK: Change notification
    //
    // ponytail: Engine.swift is not mine to edit, so open/close/activate events are found by
    // diffing rather than pushed from TabStore's mutators. Queries (`browser.tabs.query`)
    // are always exact because the delegate reads TabStore.all live; only *events*
    // (`onCreated`, `onUpdated`, `onActivated`) are up to half a second late. Upgrade path:
    // call `sync()` at the bottom of `newBlankTab`, `close`, and the `current` didSet, and
    // delete the timer.

    private var poller: Timer?
    private var announcedWindows: Set<ObjectIdentifier> = []
    private var announcedTabs: Set<Tab.ID> = []
    private var focusedWindow: ObjectIdentifier?
    private var activeTabs: [ObjectIdentifier: Tab.ID] = [:]
    private var tabState: [Tab.ID: String] = [:]

    /// Engine.swift pushes sync() on tab open/close/activate and on url/title changes, so
    /// there is nothing left for a timer to notice. Kept as a single call site in case a
    /// future mutator forgets to push.
    private func startPolling() { sync() }

    /// Tell the controller about anything that changed since last time. Safe to call as
    /// often as you like; it does nothing when nothing moved.
    /// Only this profile's windows exist as far as this host is concerned.
    private var myStores: [TabStore] { TabStore.all.filter { $0.profileID == profileID } }

    private var myFocusedStore: TabStore? {
        // An extension's idea of "the active tab" is a tab in the browser window; a Little
        // Arc is a page passing through and has no row for an extension to act on.
        guard let current = Windows.main, current.profileID == profileID else { return nil }
        return current
    }

    func sync() {
        guard !loaded.isEmpty else { return }
        let stores = myStores
        let liveWindows = Set(stores.map(ObjectIdentifier.init))

        for key in announcedWindows.subtracting(liveWindows) {
            if let shim = windowShims[key] { controller.didCloseWindow(shim) }
            windowShims[key] = nil
            activeTabs[key] = nil
        }
        announcedWindows.formIntersection(liveWindows)

        for store in stores where !announcedWindows.contains(ObjectIdentifier(store)) {
            announcedWindows.insert(ObjectIdentifier(store))
            controller.didOpenWindow(adapter(for: store))
        }

        let liveTabs = Set(stores.flatMap { $0.tabs.map(\.id) })
        for id in announcedTabs.subtracting(liveTabs) {
            if let shim = tabShims[id] { controller.didCloseTab(shim) }
            tabShims[id] = nil
            tabState[id] = nil
        }
        announcedTabs.formIntersection(liveTabs)

        for store in stores {
            for tab in store.tabs where !announcedTabs.contains(tab.id) {
                announcedTabs.insert(tab.id)
                controller.didOpenTab(adapter(for: tab, in: store))
            }
            // Title and URL together: onUpdated does not care which of the two moved.
            for tab in store.tabs {
                let state = tab.title + "\u{0}" + (tab.web.url?.absoluteString ?? "")
                    + "\u{0}" + (tab.loading ? "L" : "")
                guard tabState[tab.id] != state else { continue }
                let first = tabState[tab.id] == nil
                tabState[tab.id] = state
                guard !first else { continue }
                controller.didChangeTabProperties([.title, .URL, .loading],
                                                  for: adapter(for: tab, in: store))
            }
            let key = ObjectIdentifier(store)
            if let current = store.current, activeTabs[key] != current, let tab = store.active {
                let previous = activeTabs[key].flatMap { tabShims[$0] }
                activeTabs[key] = current
                controller.didActivateTab(adapter(for: tab, in: store), previousActiveTab: previous)
            }
        }

        let current = myFocusedStore
        let focused = current.map(ObjectIdentifier.init)
        if focused != focusedWindow {
            focusedWindow = focused
            controller.didFocusWindow(current.map { adapter(for: $0) })
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        myStores
            .filter { context.hasAccessToPrivateData || !$0.isPrivate }
            .map { adapter(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let store = myFocusedStore,
              context.hasAccessToPrivateData || !store.isPrivate else { return nil }
        return adapter(for: store)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        let store = (configuration.window as? ExtWindow)?.store ?? myFocusedStore ?? myStores.last
            ?? Windows.open(profile: ProfileManager.shared.profiles.first { $0.id == profileID })
        let tab = store.newBlankTab()
        if let url = configuration.url { tab.web.load(URLRequest(url: url)) }
        if !configuration.shouldBeActive, let first = store.tabs.first { store.current = first.id }
        sync()
        return adapter(for: tab, in: store)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        let store = Windows.open(isPrivate: configuration.shouldBePrivate,
                                 urls: configuration.tabURLs,
                                 profile: ProfileManager.shared.profiles.first { $0.id == profileID })
        if !configuration.frame.isNull, let window = store.window {
            window.setFrame(flip(configuration.frame, into: window), display: true)
        }
        sync()
        return adapter(for: store)
    }

    /// The options page lives at a `webkit-extension:` URL, and WebKit cancels those in any
    /// web view not built from `context.webViewConfiguration`. A Vane Tab builds its own
    /// configuration, so the page cannot go in a tab — it gets its own window instead.
    /// ponytail: separate window rather than tab-with-swapped-web-view. Upgrade path is the
    /// web-view swap Apple documents, once Tab can be told to adopt a foreign configuration.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext) async throws {
        guard let url = context.optionsPageURL, let cfg = context.webViewConfiguration else { return }
        present(url, cfg, title: context.webExtension.displayName ?? "Extension Options")
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        // Taken first, whatever happens next: an anchor left in the table would come up
        // under the *next* popup, on a button nobody pressed.
        let anchor = anchors.removeValue(forKey: ActionKey(context, subject(of: action)))?.view
        let name = context.webExtension.displayName ?? "An extension"
        guard let popover = action.popupPopover else {
            throw Failure("“\(name)” has no popup to show.")
        }
        // The button that ran the action: the pill's pinned glyph, or the extension's row in
        // the Site Control Center. Each window — a Little Vane and a private one included —
        // hands over its own, so a popup never opens over the wrong pill.
        if let anchor, anchor.window != nil {
            return popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        // Nothing was clicked: an extension opened its own popup from a background script.
        // The top of the frontmost window is where a toolbar would be, which is the honest
        // fallback — and a popup with nowhere at all to go is an error, not a silent no-op.
        guard let host = frontmostStore?.window?.contentView else {
            throw Failure("There is no window open to show “\(name)”'s popup in.")
        }
        let rect = NSRect(x: host.bounds.maxX - 40, y: host.bounds.maxY - 8, width: 32, height: 4)
        popover.show(relativeTo: rect, of: host, preferredEdge: .minY)
    }

    /// Any of this profile's windows that is actually key, Little Vane included — unlike
    /// `myFocusedStore`, which is the browser window an extension is allowed to *act* on and
    /// deliberately skips a Little Vane. A popup only needs somewhere to be drawn.
    private var frontmostStore: TabStore? {
        myStores.first { $0.window?.isKeyWindow == true } ?? myFocusedStore ?? myStores.first
    }

    /// Live badges and icons. WebKit says when an extension has changed its action, so the
    /// pill's glyph and the popover's row redraw off that rather than off a timer.
    ///
    /// Two guards, because an extension counting in the background fires this per tab per
    /// tick and every bump rebuilds a `SiteControlModel` for each window's pill and any open
    /// popover: a change to a tab nobody is looking at is dropped outright, and the ones that
    /// survive are coalesced into a single bump per turn of the loop.
    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        let tab = subject(of: action)
        forget(context, tab: .some(tab?.id))
        guard drawn(tab) else { return }
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task { @MainActor in
            bumpScheduled = false
            SiteChanges.shared.bump()
        }
    }

    private var bumpScheduled = false

    /// Whether anybody can see this tab's action. Only a window's *current* tab has a pill,
    /// and the default action (no tab) is what a pill with no tab draws — so both count and
    /// a background tab's badge does not.
    private func drawn(_ tab: Tab?) -> Bool {
        guard let tab else { return true }
        return myStores.contains { $0.current == tab.id }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        ask(context, permissions.map(\.rawValue)) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        ask(context, urls.map(\.absoluteString)) ? (urls, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        ask(context, patterns.map(\.string)) ? (patterns, nil) : ([], nil)
    }

    // MARK: Helpers

    private var pages: [NSWindow] = []

    private func present(_ url: URL, _ cfg: WKWebViewConfiguration, title: String) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 620), configuration: cfg)
        web.isInspectable = Settings.inspectorEnabled
        let window = NSWindow(contentRect: web.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        pages.append(window)
        web.load(URLRequest(url: url))
    }

    /// Extensions speak web coordinates (origin top-left of the main screen); AppKit puts
    /// the origin at the bottom-left.
    private func flip(_ rect: CGRect, into window: NSWindow) -> CGRect {
        guard let screen = window.screen ?? NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    // MARK: Offline check

    /// `check()` — everything here is pure: temp folders on disk and a throwaway defaults
    /// suite. No network, no real extension, no WebKit.
    static func check() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func expect(_ name: String, _ body: () throws -> Bool) {
            results.append((name, (try? body()) ?? false))
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vane-extcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func folder(_ name: String, manifest: String?) -> URL {
            let dir = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let manifest {
                try? Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
            }
            return dir
        }

        func rejects(_ url: URL) -> Bool {
            do { _ = try validate(url); return false } catch { return true }
        }

        let good = folder("good", manifest:
            #"{"manifest_version":3,"name":"Vane Test","version":"1.0"}"#)
        expect("a valid MV3 folder validates") { try validate(good)["name"] as? String == "Vane Test" }

        let mv2 = folder("mv2", manifest: #"{"manifest_version":2,"name":"Old","version":"1"}"#)
        expect("MV2 is still accepted") { _ = try validate(mv2); return true }

        expect("a folder with no manifest.json is rejected") { rejects(folder("empty", manifest: nil)) }
        expect("malformed JSON is rejected") { rejects(folder("junk", manifest: "{ not json")) }
        expect("a manifest with no name is rejected") {
            rejects(folder("noname", manifest: #"{"manifest_version":3,"version":"1"}"#))
        }
        expect("manifest_version 1 is rejected") {
            rejects(folder("mv1", manifest: #"{"manifest_version":1,"name":"Ancient"}"#))
        }
        expect("a file rather than a folder is rejected") {
            rejects(good.appendingPathComponent("manifest.json"))
        }
        expect("a folder that does not exist is rejected") {
            rejects(root.appendingPathComponent("nope"))
        }

        let suite = "vane-extcheck-\(UUID().uuidString)"
        defer { UserDefaults.vane.removePersistentDomain(forName: suite) }
        expect("a bookmarked folder round-trips through UserDefaults") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            return ScopedPaths.add(good, to: "folders", in: defaults)
                && ScopedPaths.paths("folders", in: defaults).count == 1
        }
        expect("the same folder is not bookmarked twice") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            _ = ScopedPaths.add(good, to: "folders", in: defaults)
            return ScopedPaths.paths("folders", in: defaults).count == 1
        }
        expect("removing a folder by path actually removes it") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            ScopedPaths.remove(path: good.path, from: "folders", in: defaults)
            return ScopedPaths.paths("folders", in: defaults).isEmpty
        }

        // Pure WebKit parsing, no extension and no network — proves the match-pattern type
        // the permission prompts hand around actually behaves.
        expect("<all_urls> matches an https page") {
            let all = try WKWebExtension.MatchPattern(string: "<all_urls>")
            return all.matches(URL(string: "https://example.com/x")!)
        }
        expect("a host pattern does not match another host") {
            let one = try WKWebExtension.MatchPattern(string: "https://example.com/*")
            return !one.matches(URL(string: "https://evil.test/")!)
        }

        return results
    }
}

// MARK: - Pinning an action to the pill

/// Which extensions show their action button in the address pill, and what it may say.
/// Pure: the order, the cap and the badge's truncation are rules rather than state, so
/// `selfcheck --pure` proves them with no extension to load and no window to draw in.
///
/// ponytail: paths, not `WKWebExtensionContext.uniqueIdentifier` — that identifier is a
/// fresh UUID on every load unless the app assigns one, while the folder path is what
/// `ExtensionHost` already writes down and already keeps unique per profile.
enum ExtensionPins {
    /// Three. The pill is a sidebar-width button holding a host, a zoom chip and two hover
    /// glyphs; a fourth extension icon starts eating the address. Asking for a fourth is
    /// refused out loud (the menu item says the bar is full) rather than pushing one out.
    static let cap = 3

    static let key = "pinnedExtensions"

    /// The stored order, minus anything no longer installed, then capped — filtered first,
    /// so an uninstalled extension does not spend one of the three slots.
    static func visible(stored: [String], installed: [String]) -> [String] {
        let live = Set(installed)
        return Array(stored.filter(live.contains).prefix(cap))
    }

    /// Pin at the end, unpin from anywhere. `nil` is the cap: no room, nothing written.
    /// Unpinning is always allowed, cap or no cap.
    static func toggled(_ path: String, in stored: [String]) -> [String]? {
        if stored.contains(path) { return stored.filter { $0 != path } }
        guard stored.count < cap else { return nil }
        return stored + [path]
    }

    /// What a badge reads on a 16pt glyph. An extension can set its badge to anything —
    /// "1", "99+", or a sentence — and four characters is what fits before the icon under
    /// it stops being visible. Empty is no badge, which is what WebKit means by "".
    static func badge(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count <= 4 ? t : String(t.prefix(3)) + "…"
    }

    /// The rules, proved offline.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let all = ["a", "b", "c", "d"]
        out.append(("the pill holds three pinned extensions", cap == 3))
        out.append(("a pin whose extension is gone takes no slot",
                    visible(stored: ["gone", "a", "b"], installed: all) == ["a", "b"]))
        out.append(("…and the ones that remain keep the order they were pinned in",
                    visible(stored: ["c", "a"], installed: all) == ["c", "a"]))
        out.append(("a fourth pin is not drawn even if one is stored",
                    visible(stored: all, installed: all).count == cap))
        out.append(("nothing pinned draws nothing", visible(stored: [], installed: all).isEmpty))
        out.append(("pinning appends, so the pill does not reshuffle",
                    toggled("c", in: ["a", "b"]) == ["a", "b", "c"]))
        out.append(("unpinning from the middle leaves the others in order",
                    toggled("b", in: ["a", "b", "c"]) == ["a", "c"]))
        out.append(("a fourth pin is refused rather than pushing one out",
                    toggled("d", in: ["a", "b", "c"]) == nil))
        // What the cap is counted against. A folder deleted between launches leaves its pin
        // in the stored list for ever, and counting *that* would cost a slot nothing fills.
        let surviving = visible(stored: ["gone", "a", "b"], installed: all)
        out.append(("a pin left by a deleted extension does not spend one of the three",
                    surviving.count == 2))
        out.append(("…so there is still room to pin another",
                    toggled("c", in: surviving) == ["a", "b", "c"]))
        out.append(("…and the dead pin is gone from what gets written back",
                    !(toggled("c", in: surviving) ?? []).contains("gone")))
        out.append(("three dead pins leave the bar completely empty",
                    visible(stored: ["x", "y", "z"], installed: all).isEmpty))
        out.append(("…and unpinning still works at the cap",
                    toggled("a", in: ["a", "b", "c"]) == ["b", "c"]))
        out.append(("an empty badge is no badge", badge("") == nil))
        out.append(("…and so is a badge of spaces", badge("  ") == nil))
        out.append(("a count is shown as it is", badge("7") == "7"))
        out.append(("99+ fits", badge("99+") == "99+"))
        out.append(("four characters still fit", badge("1234") == "1234"))
        out.append(("a longer badge is truncated rather than overflowing the glyph",
                    badge("12345") == "123…"))
        out.append(("…and a sentence never grows past four characters",
                    badge("blocked 12 trackers")?.count == 4))
        out.append(("surrounding whitespace is not mistaken for a character",
                    badge(" 3 ") == "3"))
        return out
    }
}

/// An extension action's button face: its icon at `Look.rowIcon` with its badge on it. One
/// view, because the Site Control Center's row and the pill's pinned glyph draw the same
/// button — and because the badge belongs *on* the icon, not beside it.
struct ActionIcon: View {
    /// Passed rather than taken off the tab, because a pill with no tab still draws its
    /// pinned glyphs and the profile's host is the only thing that knows about them.
    let host: ExtensionHost
    let context: WKWebExtensionContext
    let tab: Tab?
    /// Already truncated by `ExtensionPins.badge`. Nil is no badge.
    let badge: String?

    var body: some View {
        glyph(host.icon(context, for: tab))
            .frame(width: Look.rowIcon, height: Look.rowIcon)
            .overlay(alignment: .topTrailing) { mark }
    }

    @ViewBuilder private func glyph(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "puzzlepiece.extension").resizable().aspectRatio(contentMode: .fit)
        }
    }

    @ViewBuilder private var mark: some View {
        if let badge {
            Text(badge)
                .font(Look.badgeText).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1)
                // Four characters of "99+"-sized type is wider than the 16pt icon under it,
                // and a capsule that keeps growing reaches the glyph beside it. The width is
                // capped and the type shrinks inside it instead. The ellipsis
                // `ExtensionPins.badge` appends is a neutral character, so bidi puts it at
                // the trailing end in an RTL layout, which is where it belongs.
                .minimumScaleFactor(Look.badgeShrink)
                .padding(.horizontal, Look.badgeInset)
                .frame(minWidth: Look.badgeHeight, maxWidth: Look.badgeWidth,
                       minHeight: Look.badgeHeight)
                .background(Color.accentColor, in: .capsule)
                .offset(x: Look.badgeOffset, y: -Look.badgeOffset)
        }
    }
}

/// The AppKit view an action popup hangs off, handed to `ExtensionHost` without SwiftUI
/// having to own it — the trick `HoldMenu` plays for the back/forward menu.
@MainActor final class ActionAnchor: ObservableObject {
    private(set) weak var view: NSView?
    fileprivate func adopt(_ view: NSView) { self.view = view }
}

private struct ActionAnchorView: NSViewRepresentable {
    let holder: ActionAnchor
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        holder.adopt(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Nothing but a rectangle for a popover to point at. It must be invisible to the mouse:
/// sitting in a SwiftUI `background` it is a real AppKit view, and a plain `NSView` hit-tests
/// to itself — which swallows the button's own mouseDown and lets whatever tap gesture is
/// wrapped around the button fire instead. Measured: with this returning `self`, clicking a
/// pinned glyph opened the pill's search bar rather than the extension.
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Marks this view as the thing an extension popup should point at.
    @MainActor func actionAnchor(_ holder: ActionAnchor) -> some View {
        background { ActionAnchorView(holder: holder) }
    }
}

// MARK: - Tab / window adapters
//
// Tab and TabStore cannot conform to the WebKit protocols directly (they are not mine to
// edit), so these wrap them. Both hold their subject weakly: the tables in ExtensionHost
// own the adapters, and a dead subject just makes every accessor return its default.

/// A Vane `Tab`, as an extension sees it.
@MainActor final class ExtTab: NSObject, WKWebExtensionTab {
    private(set) weak var tab: Tab?
    private(set) weak var store: TabStore?

    init(_ tab: Tab, in store: TabStore) {
        self.tab = tab
        self.store = store
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store.map { ExtensionHost.host(for: $0.profileID).adapter(for: $0) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let i = store?.tabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return i
    }

    // Everything WebKit can read straight off the web view (url, zoom, loading, snapshots,
    // back/forward, reload) is deliberately left unimplemented — the protocol's documented
    // defaults already do it against `webView(for:)`.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.web }

    func title(for context: WKWebExtensionContext) -> String? { tab?.title }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let store else { return false }
        return store.current == tab.id
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { tab?.isPrivate ?? false }

    /// activeTab is the permission almost every extension actually relies on.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab, let store else { return }
        store.current = tab.id
        store.window?.makeKeyAndOrderFront(nil)
        ExtensionHost.host(for: store.profileID).sync()
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        // ponytail: Vane has no multi-select, so selecting a tab is activating it and
        // deselecting is a no-op. Upgrade path: a selection set on TabStore.
        if selected { try await activate(for: context) }
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab, let store else { return }
        store.close(tab.id)
        ExtensionHost.host(for: store.profileID).sync()
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration,
                   for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let store, let url = tab?.web.url else { return nil }
        let copy = store.newBlankTab()
        copy.web.load(URLRequest(url: url))
        let host = ExtensionHost.host(for: store.profileID)
        host.sync()
        return host.adapter(for: copy, in: store)
    }
}

/// A Vane window (`TabStore` + its `NSWindow`), as an extension sees it.
@MainActor final class ExtWindow: NSObject, WKWebExtensionWindow {
    private(set) weak var store: TabStore?

    init(_ store: TabStore) { self.store = store }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store else { return [] }
        let host = ExtensionHost.host(for: store.profileID)
        return store.tabs.map { host.adapter(for: $0, in: store) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store, let tab = store.active else { return nil }
        return ExtensionHost.host(for: store.profileID).adapter(for: tab, in: store)
    }

    // Vane never opens popup windows, so every window is a normal one.
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { store?.isPrivate ?? false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = store?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState,
                        for context: WKWebExtensionContext) async throws {
        guard let window = store?.window else { return }
        let full = window.styleMask.contains(.fullScreen)
        switch state {
        case .minimized:  window.miniaturize(nil)
        case .maximized:  if window.isMiniaturized { window.deminiaturize(nil) }
                          if !window.isZoomed { window.zoom(nil) }
        case .fullscreen: if !full { window.toggleFullScreen(nil) }
        default:          if full { window.toggleFullScreen(nil) }
                          if window.isMiniaturized { window.deminiaturize(nil) }
        }
    }

    // frame/screenFrame are both prerequisites for setFrame on macOS, hence all three.
    func frame(for context: WKWebExtensionContext) -> CGRect { store?.window?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        store?.window?.screen?.frame ?? NSScreen.screens.first?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        store?.window?.setFrame(frame, display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        store?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.map { ExtensionHost.host(for: $0.profileID).sync() }
    }

    func close(for context: WKWebExtensionContext) async throws {
        store?.window?.performClose(nil)
        store.map { ExtensionHost.host(for: $0.profileID).sync() }
    }
}
