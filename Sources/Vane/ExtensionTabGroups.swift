import SwiftUI
import WebKit

/// `chrome.tabGroups`, `tabs.group` and `tabs.ungroup` for system WebKit, which has none
/// of them, mapped onto Vane's sidebar folders. Vendor resources remain unchanged.
///
/// What a group is in Vane: a folder in Today, in the Space a window is showing. Pinned
/// tabs and Favourites are never grouped; they stay where the user put them. A tab's
/// group is the folder it sits in directly. Locked folders and live folders are not
/// groups. An extension may read every group, but it may change, fill or empty only the
/// folders an extension made (`Folder.extensionOwner`). A folder the user made is theirs.
/// An extension-made folder that loses its last tab goes, as Chrome removes an empty
/// group; Today removes empty folders anyway (`Pins.removeEmptyFolders`).
@MainActor enum ExtensionTabGroupsAPI {
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_tab_groups__"
    nonisolated static let permission = "tabGroups"
    nonisolated static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    // Requests travel as `ExtensionDebuggerAPI`'s do: a `tabs.create` for a reserved URL,
    // answered by a "tab" whose title is JSON. WebKit resolves `openerTabId` and
    // `windowId`, so a tab or window the extension may not see never reaches the host.
    // WebKit's tabs carry no `groupId`; `tabs.get` and `tabs.query` add it from one call
    // per window, which answers each tab's group by its index.
    // ponytail: a group's `windowId` is learned from those per-window calls. A group first
    // heard of in an event costs one call per window to place.
    nonisolated static let script = #"""
        ;(() => {
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!api?.tabs?.create || !api.runtime?.getManifest || api.tabGroups !== undefined) continue;
              const runtime = api.runtime, tabs = api.tabs, manifest = runtime.getManifest();
              if (manifest.manifest_version !== 3 || !manifest.permissions?.includes('tabGroups')) continue;
              // WebKit weakly caches nested API wrappers; keep these and their additions.
              Object.defineProperty(api, Symbol('Vane tab group owners'), {value: [runtime, tabs, api.windows]});
              const NONE = -1;
              const original = {get: tabs.get.bind(tabs), query: tabs.query.bind(tabs), create: tabs.create.bind(tabs)};
              const call = async (op, target = {}, values = {}) => {
                const properties = {url: runtime.getURL('/__vane_tab_groups__?' + new URLSearchParams({op, ...values})), active: false};
                if (Number.isInteger(target.tabId)) properties.openerTabId = target.tabId;
                if (Number.isInteger(target.windowId)) properties.windowId = target.windowId;
                let tab;
                try { tab = await original.create(properties); }
                catch (error) { throw new Error(String(error?.message ?? error).replace(/^Invalid call to tabs\.create\(\)\. /, '')); }
                return JSON.parse(tab.title).result;
              };
              const settle = (promise, callback) => {
                if (typeof callback !== 'function') return promise;
                promise.then(callback, error => { console.error(error); callback(); });
              };
              const windowIds = new Map();
              const inWindow = async windowId => {
                const reply = await call('window', {windowId});
                windowIds.set(reply.window, windowId);
                return reply;
              };
              const shape = group => ({id: group.id, collapsed: group.collapsed, color: group.color, title: group.title,
                                       windowId: windowIds.get(group.window) ?? -1, shared: false});
              const snapshot = async () => {
                const ids = [...new Set((await original.query({})).map(tab => tab.windowId).filter(Number.isInteger))];
                const groups = new Map();
                for (const reply of await Promise.all(ids.map(inWindow)))
                  for (const group of reply.groups) if (!groups.has(group.id)) groups.set(group.id, shape(group));
                return [...groups.values()];
              };
              const place = async group => {
                if (!windowIds.has(group.window)) await snapshot();
                return shape(group);
              };
              const annotate = async list => {
                const members = new Map();
                await Promise.all([...new Set(list.map(tab => tab.windowId))].filter(Number.isInteger)
                  .map(async id => members.set(id, (await inWindow(id)).members)));
                for (const tab of list) tab.groupId = members.get(tab.windowId)?.[tab.index] ?? NONE;
                return list;
              };
              const tabIds = value => {
                const ids = [value].flat();
                if (!ids.length || !ids.every(Number.isInteger)) throw new Error('A tab id must be an integer.');
                return ids;
              };
              const extra = {
                get(tabId, callback) { return settle(original.get(tabId).then(async tab => (await annotate([tab]))[0]), callback); },
                query(info, callback) {
                  if (typeof info === 'function') [info, callback] = [{}, info];
                  const {groupId, ...rest} = info ?? {};
                  return settle(original.query(rest).then(annotate)
                    .then(list => groupId === undefined ? list : list.filter(tab => tab.groupId === groupId)), callback);
                },
                // ponytail: `createProperties.windowId` is not read. Vane groups a tab in its
                // own window and refuses to join a group in another.
                group(options, callback) {
                  return settle((async () => {
                    let groupId = options?.groupId;
                    for (const tabId of tabIds(options?.tabIds))
                      groupId = (await call('group', {tabId}, groupId === undefined ? {} : {groupId: String(groupId)})).groupId;
                    return groupId;
                  })(), callback);
                },
                ungroup(ids, callback) {
                  return settle((async () => { for (const tabId of tabIds(ids)) await call('ungroup', {tabId}); })(), callback);
                }
              };
              const listeners = {created: new Set(), updated: new Set(), removed: new Set(), moved: new Set()};
              const listening = () => Object.values(listeners).some(set => set.size > 0);
              let polling = false, cursor;
              // ponytail: while it has listeners, a context keeps one call open, and so stays awake.
              const poll = async () => {
                if (polling || !listening()) return;
                polling = true;
                try {
                  cursor ??= (await call('events')).cursor;
                  while (listening()) {
                    const reply = await call('events', {}, {after: String(cursor)});
                    cursor = reply.cursor;
                    for (const item of reply.events) {
                      const group = await place(item.group);
                      for (const listener of [...listeners[item.type]]) {
                        try { listener(group); } catch (error) { console.error(error); }
                      }
                    }
                  }
                } catch (error) { console.error(error); } finally { polling = false; }
              };
              const event = set => Object.freeze({
                addListener(listener) { if (typeof listener === 'function') { set.add(listener); poll(); } },
                removeListener(listener) { set.delete(listener); },
                hasListener: listener => set.has(listener),
                hasListeners: () => set.size > 0
              });
              const Color = Object.freeze({GREY: 'grey', BLUE: 'blue', RED: 'red', YELLOW: 'yellow', GREEN: 'green',
                                           PINK: 'pink', PURPLE: 'purple', CYAN: 'cyan', ORANGE: 'orange'});
              Object.defineProperty(api, 'tabGroups', {configurable: true, value: Object.freeze({
                TAB_GROUP_ID_NONE: NONE,
                Color,
                get(groupId, callback) { return settle(call('get', {}, {groupId: String(groupId)}).then(place), callback); },
                query(info, callback) {
                  if (typeof info === 'function') [info, callback] = [{}, info];
                  return settle((async () => {
                    const {collapsed, color, title, windowId, shared} = info ?? {};
                    const window = windowId === -2 ? (await api.windows.getCurrent()).id : windowId;
                    const pattern = typeof title === 'string'
                      ? new RegExp('^' + title.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$') : null;
                    return (await snapshot()).filter(group => (collapsed === undefined || group.collapsed === collapsed)
                      && (color === undefined || group.color === color) && (!pattern || pattern.test(group.title))
                      && (window === undefined || group.windowId === window) && (shared === undefined || group.shared === shared));
                  })(), callback);
                },
                update(groupId, properties, callback) {
                  const {title, color, collapsed} = properties ?? {}, values = {groupId: String(groupId)};
                  if (typeof title === 'string') values.title = title;
                  if (typeof color === 'string') values.color = color;
                  if (typeof collapsed === 'boolean') values.collapsed = String(collapsed);
                  return settle(call('update', {}, values).then(place), callback);
                },
                move(groupId, properties, callback) {
                  return settle((async () => {
                    const {index, windowId} = properties ?? {};
                    if (!Number.isInteger(index)) throw new Error('A group moves to an integer index.');
                    if (Number.isInteger(windowId) && windowId !== (await api.tabGroups.get(groupId)).windowId)
                      throw new Error('Vane cannot move a group to another window.');
                    return place(await call('move', {}, {groupId: String(groupId), index: String(index)}));
                  })(), callback);
                },
                onCreated: event(listeners.created),
                onUpdated: event(listeners.updated),
                onRemoved: event(listeners.removed),
                onMoved: event(listeners.moved)
              })});
              for (const [key, value] of Object.entries(extra)) {
                try { Object.defineProperty(tabs, key, {configurable: true, writable: true, value}); }
                catch (error) { console.error(error); }
              }
            } catch (error) { console.error(error); }
          }
        })();
        """#

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }

    nonisolated static func declared(_ manifest: [String: Any]) -> Bool {
        (manifest["permissions"] as? [String])?.contains(permission) == true
    }
}

/// One profile's tab groups as extensions see them: a stable number per folder for the
/// session, and the events each extension is owed.
@MainActor final class ExtensionTabGroups {
    private typealias Failure = ExtensionHost.Failure
    private let profileID: UUID
    private var numbers: [UUID: Int] = [:]
    private var folders: [Int: UUID] = [:]
    private var windowNumbers: [ObjectIdentifier: Int] = [:]
    private var nextNumber = 1
    /// What the last look found, by group number; nil until the first look announces nothing.
    private var seen: [Int: (state: String, json: [String: Any], isPrivate: Bool)]?
    private var logs: [ObjectIdentifier: (next: Int, items: [(sequence: Int, item: [String: Any])])] = [:]
    private var waiters: [ObjectIdentifier: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var crowdedPollDelay: TimeInterval = 1

    init(profileID: UUID) { self.profileID = profileID }

    private var stores: [TabStore] {
        TabStore.all.filter { $0.profileID == profileID && !$0.isParked && $0.window != nil && !$0.isLittle }
    }

    private func visible(_ store: TabStore, to context: WKWebExtensionContext) -> Bool {
        !store.isPrivate || context.hasAccessToPrivateData
    }

    /// The folders that are groups: Today's, unlocked, and not filled by a live source.
    private func groups(in store: TabStore) -> [Folder] {
        store.todayShape.entries.compactMap(\.folder).filter { $0.live == nil && !store.isFolderLocked($0.id) }
    }

    func number(for folder: UUID) -> Int {
        if let known = numbers[folder] { return known }
        defer { nextNumber += 1 }
        numbers[folder] = nextNumber
        folders[nextNumber] = folder
        return nextNumber
    }

    private func windowNumber(_ store: TabStore) -> Int {
        if let known = windowNumbers[ObjectIdentifier(store)] { return known }
        defer { nextNumber += 1 }
        windowNumbers[ObjectIdentifier(store)] = nextNumber
        return nextNumber
    }

    private func json(_ folder: Folder, in store: TabStore) -> [String: Any] {
        ["id": number(for: folder.id), "title": folder.name, "color": folder.groupColor ?? "grey",
         "collapsed": folder.collapsed, "window": windowNumber(store)]
    }

    private func locate(_ value: String?, for context: WKWebExtensionContext) throws -> (store: TabStore, folder: Folder) {
        guard let id = value.flatMap(Int.init).flatMap({ folders[$0] }),
              let store = stores.first(where: { visible($0, to: context) && groups(in: $0).contains { $0.id == id } }),
              let folder = store.todayShape.folder(id) else { throw Failure("No group with id: \(value ?? "").") }
        return (store, folder)
    }

    private func editable(_ folder: Folder) throws {
        guard folder.extensionOwner != nil else {
            throw Failure("“\(folder.name)” is a folder the user made. Extensions may change only the folders extensions made.")
        }
    }

    /// A tab the extension may group: a Today tab, in a browser window it may see.
    func groupable(_ shim: ExtTab?, for context: WKWebExtensionContext) throws -> (tab: Tab, store: TabStore) {
        guard let tab = shim?.tab, let store = shim?.store, store.profileID == profileID,
              TabStore.all.contains(where: { $0 === store }), !store.isParked, store.window != nil,
              store.tabs.contains(where: { $0 === tab }), !store.isTabLocked(tab.id) else {
            throw Failure("No tab with that id.")
        }
        guard !tab.isPrivate || context.hasAccessToPrivateData else {
            throw Failure("This extension is not allowed in private windows.")
        }
        guard !store.isLittle else { throw Failure("A Little Vane window has no sidebar to hold a group.") }
        guard tab.kind == .today else {
            throw Failure("Vane groups only Today tabs. Pinned tabs and Favourites stay where the user put them.")
        }
        return (tab, store)
    }

    /// `tabs.group` for one tab: into the group `into`, or into a new folder made where the
    /// tab is. Returns the group's number.
    func group(_ tab: Tab, in store: TabStore, into value: String?, for context: WKWebExtensionContext) throws -> Int {
        let key = tab.id.uuidString
        store.syncShapes()
        let current = store.todayShape.folder(holding: key)
        if let current { try editable(current) }
        if let value {
            let target = try locate(value, for: context).folder
            guard store.todayShape.folder(target.id) != nil else { throw Failure("Vane cannot group tabs across windows.") }
            try editable(target)
            guard current?.id != target.id else { return number(for: target.id) }
            Motion.list {
                store.todayShape.move(key, into: target.id)
                store.applyOrder(.today)
            }
            store.savePins()
            return number(for: target.id)
        }
        // Beside the tab, or beside the extension's folder it is leaving, at that level.
        guard let made = Motion.list({ () -> Folder? in
            var shape = store.todayShape
            guard let made = shape.newFolder(named: context.webExtension.displayName ?? "Group", next: current?.id.uuidString ?? key)
            else { return nil }
            let owner = context.baseURL.host ?? ""
            shape.edit(folder: made.id) { $0.extensionOwner = owner; $0.groupColor = "grey" }
            shape.move(key, into: made.id)
            store.todayShape = shape
            store.applyOrder(.today)
            return made
        }) else { throw Failure("Folders nest \(Pins.maxDepth + 1) deep at most.") }
        store.savePins()
        return number(for: made.id)
    }

    /// `tabs.ungroup` for one tab: out of its folder, to just after it. A tab in no group
    /// is left alone, as in Chrome.
    func ungroup(_ tab: Tab, in store: TabStore) throws {
        let key = tab.id.uuidString
        store.syncShapes()
        guard let folder = store.todayShape.folder(holding: key) else { return }
        try editable(folder)
        Motion.list {
            store.todayShape.move(key, next: folder.id.uuidString, after: true)
            store.applyOrder(.today)
        }
        store.savePins()
    }

    func handle(_ request: ExtensionDebuggerAPI.Request, tab shim: ExtTab?, window: ExtWindow?,
                contexts: [WKWebExtensionContext], for context: WKWebExtensionContext,
                reply: (Any) -> ExtensionBridgeReply) async throws -> ExtensionBridgeReply {
        guard ExtensionTabGroupsAPI.declared(context.webExtension.manifest) else {
            throw Failure("This extension has not requested the tabGroups permission.")
        }
        let values = request.values
        switch request.operation {
        case "window":
            guard let store = window?.store, store.profileID == profileID, TabStore.all.contains(where: { $0 === store }),
                  visible(store, to: context) else { throw Failure("No window with that id.") }
            let groups = store.isLittle ? [] : groups(in: store)
            let numbered = Dictionary(groups.map { ($0.id, number(for: $0.id)) }, uniquingKeysWith: { a, _ in a })
            var holder: [String: UUID] = [:]
            for entry in store.todayShape.entries { if let tab = entry.tab, let parent = entry.parent { holder[tab] = parent } }
            return reply(["window": windowNumber(store), "groups": groups.map { json($0, in: store) },
                          "members": store.accessibleTabs.map { holder[$0.id.uuidString].flatMap { numbered[$0] } ?? -1 }])
        case "get":
            let found = try locate(values["groupId"], for: context)
            return reply(json(found.folder, in: found.store))
        case "group":
            let found = try groupable(shim, for: context)
            let number = try group(found.tab, in: found.store, into: values["groupId"], for: context)
            sync(contexts: contexts)
            return reply(["groupId": number])
        case "ungroup":
            let found = try groupable(shim, for: context)
            try ungroup(found.tab, in: found.store)
            sync(contexts: contexts)
            return reply([String: Any]())
        case "update":
            let (store, folder) = try locate(values["groupId"], for: context)
            try editable(folder)
            if let color = values["color"], !ExtensionTabGroupsAPI.colors.contains(color) {
                throw Failure("Invalid color: \(color).")
            }
            Motion.list {
                store.todayShape.edit(folder: folder.id) { folder in
                    if let title = values["title"] { folder.name = title }
                    if let color = values["color"] { folder.groupColor = color }
                    if let collapsed = values["collapsed"].flatMap(Bool.init) { folder.collapsed = collapsed }
                }
            }
            store.savePins()
            sync(contexts: contexts)
            return reply(json(store.todayShape.folder(folder.id) ?? folder, in: store))
        case "move":
            let (store, folder) = try locate(values["groupId"], for: context)
            try editable(folder)
            guard let index = values["index"].flatMap(Int.init) else { throw Failure("A group moves to an integer index.") }
            move(folder.id, to: index, in: store)
            sync(contexts: contexts)
            let moved = json(store.todayShape.folder(folder.id) ?? folder, in: store)
            for listener in listeners(contexts) where visible(store, to: listener) {
                emit(["type": "moved", "group": moved], to: listener)
            }
            return reply(moved)
        case "events":
            let key = ObjectIdentifier(context)
            if let after = values["after"].flatMap(Int.init), after >= logs[key]?.next ?? 0 {
                // Eight calls are held open per extension; one more is answered empty, later.
                if (waiters[key]?.count ?? 0) < 8 { await wait(key) } else { try? await Task.sleep(for: .seconds(crowdedPollDelay)) }
            }
            let after = values["after"].flatMap(Int.init) ?? .max
            let log = logs[key]
            return reply(["cursor": log?.next ?? 0, "events": (log?.items ?? []).filter { $0.sequence >= after }.map(\.item)])
        default:
            throw Failure("Unknown tab group request.")
        }
    }

    /// `tabGroups.move`: the folder lands before the tab now at `index`, or at the end of
    /// Today for -1 or an index past the last tab. An index among the pinned rows and
    /// Favourites, which come first, means the head of Today.
    private func move(_ folder: UUID, to index: Int, in store: TabStore) {
        let key = folder.uuidString
        let tabs = store.accessibleTabs
        Motion.list {
            var shape = store.todayShape
            let inside = Set(shape.tabs(in: folder))
            if index >= 0, index < tabs.count, !inside.contains(tabs[index].id.uuidString) {
                let target = tabs[index].id.uuidString
                if tabs[index].kind == .today, let i = shape.index(of: target) {
                    shape.move(key, next: shape.ancestors(of: i).last?.uuidString ?? target, after: false)
                } else { shape.put(key, at: Pins.Spot(parent: nil, index: 0)) }
            } else if index < 0 || index >= tabs.count {
                shape.put(key, at: Pins.Spot(parent: nil, index: .max))
            }
            store.todayShape = shape
            store.applyOrder(.today)
        }
        store.savePins()
    }

    // MARK: Events

    private func listeners(_ contexts: [WKWebExtensionContext]) -> [WKWebExtensionContext] {
        contexts.filter { ExtensionTabGroupsAPI.declared($0.webExtension.manifest) }
    }

    /// Announce groups made, changed and gone since the last look, whoever changed them.
    // ponytail: looked at when the host syncs (tab changes) and after each extension call.
    // A user's rename or fold with no tab change is announced at the next of those.
    func sync(contexts: [WKWebExtensionContext]) {
        let listening = listeners(contexts)
        guard !listening.isEmpty else { seen = nil; return }
        var now: [Int: (state: String, json: [String: Any], isPrivate: Bool)] = [:]
        for store in stores {
            for folder in groups(in: store) where now[number(for: folder.id)] == nil {
                now[number(for: folder.id)] = ("\(folder.name)\u{0}\(folder.groupColor ?? "")\u{0}\(folder.collapsed)",
                                               json(folder, in: store), store.isPrivate)
            }
        }
        let live = Set(stores.map(ObjectIdentifier.init))
        windowNumbers = windowNumbers.filter { live.contains($0.key) }
        guard let before = seen else { seen = now; return }
        seen = now
        func send(_ type: String, _ group: (state: String, json: [String: Any], isPrivate: Bool)) {
            for listener in listening where !group.isPrivate || listener.hasAccessToPrivateData {
                emit(["type": type, "group": group.json], to: listener)
            }
        }
        for (number, group) in before.sorted(by: { $0.key < $1.key }) where now[number] == nil { send("removed", group) }
        for (number, group) in now.sorted(by: { $0.key < $1.key }) {
            if let old = before[number] { if old.state != group.state { send("updated", group) } } else { send("created", group) }
        }
    }

    private func wait(_ key: ObjectIdentifier) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[key, default: [:]][id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.waiters[key]?.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func emit(_ item: [String: Any], to context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        var log = logs[key] ?? (0, [])
        log.items.append((log.next, item))
        log.next += 1
        if log.items.count > 256 { log.items.removeFirst(log.items.count - 256) }
        logs[key] = log
        for waiter in (waiters.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }

    func forget(_ context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        logs[key] = nil
        for waiter in (waiters.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }
}
