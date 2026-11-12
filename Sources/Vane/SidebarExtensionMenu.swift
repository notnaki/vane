import AppKit
import SwiftUI
import WebKit

/// One opening of a sidebar menu. Keep the SDK's native items and dispatch through
/// their original menu: rebuilding a browser.action or JS call would change both
/// tab identity and WebKit's documented menu-click permission/user-gesture policy.
@MainActor enum SidebarExtensionMenus {
    struct Group: Identifiable {
        let id: ObjectIdentifier
        let title: String
        let items: [Item]
    }

    @MainActor final class Item: Identifiable {
        let native: NSMenuItem
        let children: [Item]
        private let session: Session
        private let ancestors: [NSMenuItem]
        // NSMenuItem.target is weak. The original SDK target must survive until the
        // SwiftUI command has dispatched, even if the menu closes first.
        private let nativeTarget: AnyObject?
        nonisolated let id: ObjectIdentifier
        var enabled: Bool {
            session.isValid && (ancestors + [native]).allSatisfy { !$0.isHidden && $0.isEnabled }
        }

        fileprivate init(_ native: NSMenuItem, children: [Item], session: Session, ancestors: [NSMenuItem]) {
            self.id = ObjectIdentifier(native)
            self.native = native
            self.children = children
            self.session = session
            self.ancestors = ancestors
            nativeTarget = native.target
        }

        func perform() {
            guard enabled, children.isEmpty, !native.isSeparatorItem,
                  let menu = native.menu, let index = menu.items.firstIndex(where: { $0 === native }),
                  native.action != nil else { return }
            // No selection change, synthetic user gesture, activeTab grant, or
            // browser-action invocation. WebKit owns this exact tab-menu action.
            withExtendedLifetime(nativeTarget) { menu.performActionForItem(at: index) }
        }
    }

    @MainActor fileprivate final class Session {
        weak var host: ExtensionHost?
        weak var context: WKWebExtensionContext?
        weak var store: TabStore?
        weak var tab: Tab?
        let adapter: ExtTab
        let menu = NSMenu()

        init(host: ExtensionHost, context: WKWebExtensionContext, store: TabStore, tab: Tab, adapter: ExtTab) {
            self.host = host; self.context = context; self.store = store; self.tab = tab; self.adapter = adapter
            menu.autoenablesItems = false
        }

        var isValid: Bool {
            guard let host, let context, let store, let tab,
                  accepts(tab, in: store), host.profileID == store.profileID,
                  context.isLoaded, hasMenuPermission(context),
                  host.installed.contains(where: { $0 === context }),
                  host.visible(in: tab).contains(where: { $0 === context }),
                  adapter.tab === tab, adapter.window(for: context) != nil,
                  adapter.indexInWindow(for: context) != NSNotFound else { return false }
            return true
        }
    }

    private static func hasMenuPermission(_ context: WKWebExtensionContext) -> Bool {
        // The SDK can retain native menu items after an API permission is revoked.
        // Check the declared capability again before capture and actual dispatch.
        context.webExtension.requestedPermissions.union(context.webExtension.optionalPermissions).contains {
            ["contextMenus", "menus"].contains($0.rawValue) && context.hasPermission($0)
        }
    }

    private static func accepts(_ tab: Tab, in store: TabStore) -> Bool {
        store.profileID == tab.profileID && store.isPrivate == tab.isPrivate
            && store.window != nil && !store.isParked && store.profileVisible && !store.isLittle
            && TabStore.all.contains(where: { $0 === store })
            && store.tabs.contains(where: { $0 === tab }) && !store.isTabLocked(tab.id)
    }

    static func capture(tab: Tab?, in store: TabStore) -> [Group] {
        guard let tab, accepts(tab, in: store) else { return [] }
        let host = ExtensionHost.host(for: store.profileID)
        host.sync()
        let adapter = host.adapter(for: tab, in: store)
        return host.visible(in: tab).compactMap { context in
            let session = Session(host: host, context: context, store: store, tab: tab, adapter: adapter)
            guard session.isValid else { return nil }
            // Fetch at menu-content construction, never cache across openings.
            context.menuItems(for: adapter).forEach(session.menu.addItem)
            let items = entries(in: session.menu, session: session, ancestors: [])
            guard !items.isEmpty else { return nil }
            return Group(id: ObjectIdentifier(context), title: context.webExtension.displayName ?? "Extension", items: items)
        }
    }

    private static func entries(in menu: NSMenu, session: Session, ancestors: [NSMenuItem]) -> [Item] {
        var result: [Item] = []
        for native in menu.items where !native.isHidden {
            let children = native.submenu.map { entries(in: $0, session: session, ancestors: ancestors + [native]) } ?? []
            if native.submenu != nil && children.isEmpty { continue }
            if native.isSeparatorItem && (result.isEmpty || result.last?.native.isSeparatorItem == true) { continue }
            result.append(Item(native, children: children, session: session, ancestors: ancestors))
        }
        if result.last?.native.isSeparatorItem == true { result.removeLast() }
        return result
    }
}

/// Shared by tab/favourite, individual pane, split-container and bulk row menus.
/// SwiftUI constructs context-menu content on opening; each construction gets new
/// public SDK items. Native action objects survive only in this menu's closures.
struct SidebarExtensionMenu: View {
    let store: TabStore
    let tab: Tab?

    var body: some View {
        let groups = SidebarExtensionMenus.capture(tab: tab, in: store)
        if !groups.isEmpty {
            Divider()
            ForEach(groups) { group in
                Menu(group.title) { entries(group.items) }
            }
        }
    }

    private func entries(_ items: [SidebarExtensionMenus.Item]) -> some View {
        ForEach(items) { item in entry(item) }
    }

    private func entry(_ item: SidebarExtensionMenus.Item) -> AnyView {
        if item.native.isSeparatorItem { return AnyView(Divider()) }
        if !item.children.isEmpty {
            return AnyView(Menu { entries(item.children) } label: { label(item.native) }.disabled(!item.enabled))
        }
        if item.native.state == .on {
            return AnyView(Toggle(isOn: Binding(get: { item.native.state == .on }, set: { _ in item.perform() })) {
                label(item.native)
            }.disabled(!item.enabled))
        }
        return AnyView(Button(action: item.perform) { label(item.native) }.disabled(!item.enabled))
    }

    @ViewBuilder private func label(_ item: NSMenuItem) -> some View {
        if item.state == .mixed {
            Label(item.title, systemImage: "minus")
        } else if let image = item.image {
            Label { Text(item.title) } icon: { Image(nsImage: image) }
        } else { Text(item.title) }
    }
}
