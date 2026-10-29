import AppKit
import WebKit

/// Ordinary page clicks get browser commands; WebKit keeps ownership of menus for
/// links, images, media, selection, editable fields, PDFs and other specialized content.
@MainActor final class PageContextMenu: NSObject, NSMenuItemValidation {
    private enum Action: String {
        case back, forward, reload, save, printPage, copyAddress, source

        var title: String {
            switch self {
            case .back: "Back"
            case .forward: "Forward"
            case .reload: "Reload"
            case .save: "Save Page As…"
            case .printPage: "Print…"
            case .copyAddress: "Copy Page Address"
            case .source: "View Page Source"
            }
        }
    }

    private static let navigationIDs: Set<String> = [
        "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierStop"
    ]
    private static let inspectID = "WKMenuItemIdentifierInspectElement"
    private weak var tab: Tab?
    private weak var web: WKWebView?
    private weak var store: TabStore?
    private let document: UUID
    private let url: URL?

    init?(originals: [NSMenuItem], tab: Tab, web: WKWebView) {
        // Native identifiers remain stable when menu titles are localized. Unknown
        // WebKit actions denote a specialized menu; extension commands are retained.
        guard !originals.contains(where: { item in
            guard let id = item.identifier?.rawValue, id.hasPrefix("WKMenuItemIdentifier") else { return false }
            return !Self.navigationIDs.contains(id) && id != Self.inspectID
        }) else { return nil }
        self.tab = tab
        self.web = web
        document = tab.readingDocumentGeneration
        url = tab.currentURL
        store = TabStore.all.first { owner in
            owner.window === web.window && owner.everyTab.contains { $0 === tab }
        }
    }

    /// The web view retains one context per menu opening. An asynchronous bridge
    /// update can rebuild its items, but cannot recapture a replacement document.
    func populate(_ menu: NSMenu, originals: [NSMenuItem]) {
        for action in [Action.back, .forward, .reload] { menu.addItem(item(action)) }
        menu.addItem(.separator())
        for action in [Action.save, .printPage, .copyAddress] { menu.addItem(item(action)) }

        let extras = originals.filter { !Self.navigationIDs.contains($0.identifier?.rawValue ?? "") }
        var separated = false
        for item in extras where item.identifier?.rawValue != Self.inspectID {
            if item.isSeparatorItem {
                if separated && menu.items.last?.isSeparatorItem == false { menu.addItem(item) }
            } else {
                if !separated { menu.addItem(.separator()); separated = true }
                menu.addItem(item)
            }
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        menu.addItem(item(.source))
        for item in extras where item.identifier?.rawValue == Self.inspectID {
            item.title = "Inspect"
            menu.addItem(item)
        }
    }

    private func item(_ action: Action) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.identifier = .init("VanePage" + action.rawValue)
        item.target = self
        // NSMenuItem.target is weak. Keep the captured page identity until the action
        // has fired, even when WebKit closes its menu before dispatching the item.
        item.representedObject = self
        item.isEnabled = allows(action)
        return item
    }

    private var isCurrent: Bool {
        guard let tab, let web else { return false }
        return tab.existingWeb === web && tab.readingDocumentGeneration == document
    }

    private func allows(_ action: Action) -> Bool {
        guard isCurrent, let web else { return false }
        switch action {
        case .back: return web.canGoBack
        case .forward: return web.canGoForward
        case .reload: return url != nil
        case .save, .copyAddress: return url != nil
        case .printPage: return url != nil && web.window != nil
        case .source: return url != nil && store?.everyTab.contains { $0 === tab } == true
        }
    }

    private func action(for item: NSMenuItem) -> Action? {
        guard let id = item.identifier?.rawValue, id.hasPrefix("VanePage") else { return nil }
        return Action(rawValue: String(id.dropFirst("VanePage".count)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        action(for: menuItem).map(allows) ?? false
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = action(for: sender), allows(action), let tab, let web else { return }
        switch action {
        case .back: tab.back()
        case .forward: tab.forward()
        case .reload: tab.reload()
        case .save: PageSaving.save(tab)
        case .printPage: PagePrinting.run(for: web)
        case .copyAddress:
            guard let url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case .source:
            if let store { tab.viewSource(into: store) }
        }
    }
}
