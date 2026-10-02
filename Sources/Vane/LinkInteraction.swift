import AppKit

/// One decision for the navigation delegate and the modifier hint. Page scripts can
/// override a click themselves; this describes the browser's handling of an ordinary link.
enum LinkInteraction {
    enum Target: String, Equatable, Sendable { case main, newWindow, subframe }
    enum Action: Equatable, Sendable {
        case navigate, tab(focus: Bool), split, little, peek
        /// WebKit must construct this page with its opener-linked configuration.
        case popup(floating: Bool)

        var hint: String? {
            switch self {
            case .navigate: nil
            case .popup(let floating): floating ? " in Little Vane" : " in a new tab and focus it"
            case .tab(let focus): focus ? " in a new tab and focus it" : " in a new tab"
            case .split: " in Split View"
            case .little: " in Little Vane"
            case .peek: " in Peek"
            }
        }
    }

    struct Context {
        var kind: TabKind
        var source: URL
        var target: Target = .main
        var canPeek = true
        var canSplit = true
        var floating = false
    }

    struct Preferences {
        var littleLinks = true
        var shiftPeek = true
        var automaticPeek = true

        static let littleKey = "optionCommandClickLittleVane"
        static let shiftKey = "shiftClickPeek"

        @MainActor static var current: Self {
            .init(littleLinks: UserDefaults.vane.object(forKey: littleKey) as? Bool ?? true,
                  shiftPeek: UserDefaults.vane.object(forKey: shiftKey) as? Bool ?? true,
                  automaticPeek: Prefs.peekLinks)
        }
    }

    nonisolated static func route(to url: URL, context: Context,
                                  modifiers: NSEvent.ModifierFlags, button: Int = 1,
                                  preferences: Preferences = .init()) -> Action {
        // Control-left-click belongs to the context menu. Custom and script schemes are
        // handled before this table by the navigation delegate, never in a browser tab.
        guard (!modifiers.contains(.control) || button == TabActions.middleButton),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return .navigate }
        let web = scheme == "http" || scheme == "https"
        if button == TabActions.middleButton {
            return context.floating ? .little : .tab(focus: false)
        }
        guard button == 0 || button == 1 else { return .navigate }
        if modifiers.contains(.command) {
            if modifiers.contains(.option), preferences.littleLinks,
               context.target != .subframe { return .little }
            return context.floating ? .little : .tab(focus: modifiers.contains(.shift))
        }
        if web, modifiers.contains(.option), context.canSplit,
           context.target != .subframe { return .split }
        if web, context.target != .subframe, context.canPeek,
           modifiers.contains(.shift), preferences.shiftPeek { return .peek }
        if context.target == .newWindow { return .popup(floating: context.floating) }
        guard web, context.target == .main, context.canPeek else { return .navigate }
        // Shift has already been handled, or explicitly disabled. The automatic pinned
        // link rule still applies independently of that preference.
        switch Peek.route(sourceKind: context.kind, from: context.source, to: url,
                          modifiers: [], enabled: preferences.automaticPeek) {
        case .navigate: return .navigate
        case .peek: return .peek
        case .newTab(let focus): return .tab(focus: focus)
        }
    }

    nonisolated static func hint(to url: URL, context: Context,
                                 modifiers: NSEvent.ModifierFlags,
                                 preferences: Preferences = .init()) -> String? {
        guard !modifiers.intersection([.command, .option, .shift]).isEmpty else { return nil }
        return route(to: url, context: context, modifiers: modifiers,
                     preferences: preferences).hint
    }
}

extension Tab {
    func linkContext(target: LinkInteraction.Target = .main, source: URL? = nil) -> LinkInteraction.Context {
        .init(kind: kind, source: source ?? web.url ?? currentURL ?? URL(string: "about:blank")!,
              target: target, canPeek: onPeek != nil, canSplit: onOpenInSplit != nil,
              floating: linkOpensInFloatingWindow)
    }
}
