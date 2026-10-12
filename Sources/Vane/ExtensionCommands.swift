import AppKit
import WebKit

/// Keyboard commands are user gestures. Route them only from their originating browser
/// window, after Vane shortcuts. Editors retain text-insertion chords while modified
/// extension commands remain available for workflows such as password autofill.
@MainActor enum ExtensionCommands {
    struct Descriptor: Identifiable {
        let id: String
        let title: String
        let shortcut: String
        let conflict: String?
    }

    static func descriptors(for context: WKWebExtensionContext) -> [Descriptor] {
        context.commands.map { command in
            let binding = binding(for: command)
            return Descriptor(id: command.id, title: command.title.isEmpty ? command.id : command.title,
                              shortcut: binding.isAssigned ? binding.display : "Not assigned",
                              conflict: conflict(for: command))
        }
    }

    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat,
              NSApp.modalWindow == nil, let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil,
              let store = TabStore.all.first(where: { $0.window === window && !$0.isParked && !$0.isLittle }),
              !store.isPrivate, let tab = store.active, !store.isTabLocked(tab.id),
              let key = Keybinding(event: event),
              browserConflict(for: key) == nil else { return false }
        // Option and Shift can produce text (including accents). Command/Control
        // chords are intentional shortcuts and must work inside login fields too.
        if isTextEntry(in: window),
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) { return false }
        let host = ExtensionHost.host(for: store.profileID)
        // Sorting by the persistent installation path keeps duplicate shortcuts stable
        // across restart. Details disclose the collision for both extensions.
        for (_, context) in host.loaded.sorted(by: { $0.path < $1.path }) where context.isLoaded {
            guard context.command(for: event) != nil else { continue }
            host.sync()
            return context.performCommand(for: event)
        }
        return false
    }

    private static func isTextEntry(in window: NSWindow) -> Bool {
        if window.firstResponder is NSText || window.firstResponder is NSTextField { return true }
        var view = window.firstResponder as? NSView
        while let current = view {
            if let web = current as? WKWebView {
                return TabStore.all.lazy.flatMap(\.tabs).first { $0.existingWeb === web }?.editableFocused == true
            }
            view = current.superview
        }
        return false
    }

    private static func binding(for command: WKWebExtension.Command) -> Keybinding {
        var mods: Keybinding.Mods = []
        if command.modifierFlags.contains(.command) { mods.insert(.command) }
        if command.modifierFlags.contains(.control) { mods.insert(.control) }
        if command.modifierFlags.contains(.option) { mods.insert(.option) }
        if command.modifierFlags.contains(.shift) { mods.insert(.shift) }
        return Keybinding(command.activationKey ?? "", mods)
    }

    private static func browserConflict(for binding: Keybinding) -> String? {
        guard binding.isAssigned else { return nil }
        if let command = Keybindings.command(for: binding)
            ?? Keybindings.aliases.first(where: { $0.value == binding })?.key {
            return "Vane’s \(command.title) shortcut takes precedence."
        }
        // Reserve responder-chain editing equivalents even before the app menu has
        // been assembled, or when a menu item is temporarily absent.
        if let row = Standard.rows.first(where: { $0.selectorName != nil && $0.key == binding }) {
            return "Vane’s \(row.title) shortcut takes precedence."
        }
        // Unregistered standard AppKit equivalents also precede extension commands.
        func match(_ menu: NSMenu?) -> String? {
            guard let menu else { return nil }
            for item in menu.items {
                let key = Keybinding(item.keyEquivalent, flags(item.keyEquivalentModifierMask))
                if !item.keyEquivalent.isEmpty, key == binding { return "Vane’s \(item.title) shortcut takes precedence." }
                if let result = match(item.submenu) { return result }
            }
            return nil
        }
        return match(NSApp.mainMenu)
    }

    private static func flags(_ flags: NSEvent.ModifierFlags) -> Keybinding.Mods {
        var result: Keybinding.Mods = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func conflict(for command: WKWebExtension.Command) -> String? {
        let key = binding(for: command)
        guard key.isAssigned else { return nil }
        if let conflict = browserConflict(for: key) { return conflict }
        guard let context = command.webExtensionContext,
              let controller = context.webExtensionController else { return nil }
        let others = controller.extensionContexts.filter { $0 !== context && $0.isLoaded }
        if let other = others.first(where: { $0.commands.contains { binding(for: $0) == key } }) {
            return "Also used by \(other.webExtension.displayName ?? "another extension"). Only one extension receives this shortcut."
        }
        return nil
    }
}
