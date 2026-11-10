import Foundation

/// Use the same chrome menu as the rest of the sidebar, with the current shortcut labels.
@MainActor enum NavigationOverflow {
    static func items(tab: Tab?, toggleSidebar: @escaping () -> Void) -> [ChromeMenuItem] {
        var items: [ChromeMenuItem] = []
        if let tab {
            let loading = tab.loading
            items.append(ChromeMenuItem(title: loading ? "Stop Loading" : "Reload",
                symbol: loading ? "xmark" : "arrow.clockwise",
                shortcut: loading ? "" : shortcut(.reload)) {
                if loading { tab.stop() } else { tab.reload() }
            })
        }
        items.append(ChromeMenuItem(title: "Toggle Sidebar", symbol: "sidebar.left",
                                   shortcut: shortcut(.toggleSidebar), action: toggleSidebar))
        return items
    }

    private static func shortcut(_ command: Command) -> String {
        let binding = Keybindings.binding(for: command)
        return binding.isAssigned ? binding.display : ""
    }
}
