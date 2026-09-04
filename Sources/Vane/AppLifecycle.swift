import AppKit

/// What the Dock icon does.
///
/// Vane had no `NSApplicationDelegate` at all — `main.swift` is a bare bootstrap — so with
/// every window closed the app was still running and there was no way back into it: clicking
/// the Dock icon did nothing, and the Dock's own menu offered Quit and nothing else. ⌘N was
/// the only route, and only if a window happened to have focus to receive it.
///
/// ponytail: a delegate that answers two questions and holds no state. Everything else
/// `NSApplicationDelegate` can do is already done in `main.swift`, and moving it here would
/// be a refactor rather than a fix.
@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static let shared = AppLifecycle()

    /// Clicking the Dock icon with no windows open. `flag` is false exactly when there is
    /// nothing on screen, which is the case worth answering.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppLifecycle.reopen() }
        return true
    }

    /// The window the user last had, the session they last had, or a new one — in that order,
    /// which is the same ladder `main.swift` climbs at launch.
    static func reopen() {
        if let last = TabStore.all.last?.window {
            last.makeKeyAndOrderFront(nil)
            return
        }
        if Session.restore() { return }
        Windows.open()
    }

    /// Right-clicking the Dock icon. The two things anyone wants from there, and the two the
    /// File menu leads with.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockItem("New Window") { Windows.open() })
        menu.addItem(dockItem("New Private Window") { Windows.open(isPrivate: true) })
        return menu
    }

    /// ponytail: the same closure-in-an-ObjC-target trick `Menu.swift` uses, kept here rather
    /// than shared, because its version is private and two of these are not worth an
    /// exported type.
    private func dockItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = DockAction(run)
        actions.append(action)          // NSMenuItem does not retain its target
        let item = NSMenuItem(title: title, action: #selector(DockAction.fire), keyEquivalent: "")
        item.target = action
        return item
    }

    private var actions: [DockAction] = []
}

@MainActor private final class DockAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
