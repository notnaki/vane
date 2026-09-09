import AppKit
import WebKit

/// Where a window a page asked for actually goes — and, next door in Engine.swift, what it
/// is made of.
///
/// `window.open` and `target=_blank` have always meant two different things on the web. One
/// is "another page, please": the link that opens a tab. The other is the sign-in popup — a
/// small window with no chrome that talks back to the page that opened it over
/// `window.opener` and closes itself when it is done. Arc answers the first with a tab beside
/// the opener and the second with a Little Arc, and this is that fork, written down once.
///
/// The half that matters most is not here: a popup's web view has to be built from the
/// `WKWebViewConfiguration` WebKit hands the delegate, because that configuration is the
/// only thing that links the popup to its opener. Vane used to ignore it and open a plain
/// tab on the popup's url instead, which cost the popup its `window.opener` — so every
/// "Sign in with Google" completed in a window that had nobody to hand the credential back
/// to — left a popup opened as `about:blank` and written into afterwards showing a blank
/// page, and made `window.close()` a no-op. See `Tab.init(popup:isPrivate:profileID:)`.
enum Popup {
    /// The two shapes a popup can take.
    enum Placement: Equatable, Sendable {
        /// A tab beside the opener. `focus` false leaves the user where they were.
        case tab(focus: Bool)
        /// A Little Vane: one floating page, one row of chrome, no sidebar.
        case little
    }

    /// The whole decision, as a pure function of what the page asked for. `nonisolated` so
    /// `selfcheck --pure` can prove the table without a window server.
    ///
    /// A size is the tell. A page that asks for 451×600 has drawn a sign-in sheet and wants
    /// a window the shape of one; a page that asks for nothing wants a page, which in Arc is
    /// a tab. `toolbars` is the older way of saying the same thing — `window.open(u, n,
    /// 'toolbar=no')` — and a page that says it means it whatever size it named.
    ///
    /// Without a gesture behind it, nothing floats and nothing takes the focus: a window put
    /// in front of the user by a page they were only reading is the whole reason popup
    /// blockers exist. It still opens, as a tab behind the one being read, because a popup
    /// silently dropped is the failure nobody can debug.
    ///
    /// `background` is ⌘ held on a `target=_blank` link, which asks for a tab behind this
    /// one and gets exactly that whatever size the page named — a Little Vane in front of
    /// you is the one thing a ⌘-click is a request *not* to do. `decidePolicyFor` catches
    /// the ordinary ⌘-click before WebKit ever asks for a window, so this is the belt to
    /// that brace.
    nonisolated static func placement(width: Double?, height: Double?, toolbars: Bool?,
                                      userInitiated: Bool, background: Bool = false) -> Placement {
        guard userInitiated, !background else { return .tab(focus: false) }
        if toolbars == false { return .little }
        if let width, let height,
           width <= Double(Look.popupWidth), height <= Double(Look.popupHeight) { return .little }
        return .tab(focus: true)
    }

    /// The same, over WebKit's own answer. `WKWindowFeatures` leaves every field nil for a
    /// `window.open` with no third argument and for `target=_blank`, which is exactly the
    /// "no size asked for" row.
    @MainActor static func placement(features: WKWindowFeatures, userInitiated: Bool,
                                     background: Bool = false) -> Placement {
        placement(width: features.width?.doubleValue, height: features.height?.doubleValue,
                  toolbars: features.toolbarsVisibility?.boolValue,
                  userInitiated: userInitiated, background: background)
    }

    /// Whether something the user did is behind this popup.
    ///
    /// ponytail: `javaScriptCanOpenWindowsAutomatically` is false on every configuration Vane
    /// makes, so WebKit has already refused every popup with no gesture behind it long before
    /// the delegate is called — this is the belt to that pair of braces, and it reads
    /// WebKit's own flag through the one SPI accessor there is, guarded the way `_close` and
    /// `developerExtrasEnabled` are. Ceiling: if the accessor is ever renamed this answers
    /// "yes" and the gate above is all that is left, which is where Vane already stands.
    ///
    /// The accessor is called through its own IMP, never through KVC. `WKNavigationAction`
    /// declares the property `getter=_isUserInitiated`, and key-value coding looks for
    /// `getKey`, `key`, `isKey` and `_key` — never `_isKey` — so `value(forKey: "userInitiated")`
    /// found nothing and raised `NSUnknownKeyException`, an Objective-C exception and so
    /// uncatchable from Swift: every popup was a crash. Asking the object for the selector
    /// and calling it is all KVC was ever standing in for here, and it cannot raise.
    ///
    /// Typed `NSObject` rather than `WKNavigationAction` for one reason: the only thing this
    /// asks of its argument is a selector, and `check()` needs a plain object that does *not*
    /// answer to it to drive the branch that comes back "yes" with no SPI at all.
    nonisolated static func userInitiated(_ action: NSObject) -> Bool {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let sel = NSSelectorFromString("_isUserInitiated")
        guard action.responds(to: sel), let imp = action.method(for: sel) else { return true }
        return unsafeBitCast(imp, to: Getter.self)(action, sel)
    }

    /// Whether the window a popup lands in comes to the front.
    ///
    /// A Little Vane is only ever *chosen* for a popup the user's own gesture asked for, so
    /// it takes the key. A popup placed as a tab and floated anyway — which is what happens
    /// inside a Little Vane or a Peek, where there is no sidebar to put a tab beside — keeps
    /// the answer the placement gave it: `focus: false` is a ⌘-click or a popup with no
    /// gesture behind it, and a floating window jumping in front of the page being read is
    /// precisely what that asked *not* to happen.
    nonisolated static func takesFocus(_ placement: Placement) -> Bool {
        switch placement {
        case .little: true
        case .tab(let focus): focus
        }
    }

    // MARK: - Checks

    nonisolated static func check() -> [(String, Bool)] {
        func p(_ w: Double?, _ h: Double?, _ toolbars: Bool?, _ gesture: Bool,
               background: Bool = false) -> Placement {
            placement(width: w, height: h, toolbars: toolbars,
                      userInitiated: gesture, background: background)
        }

        return [
            ("a popup that asked for no size is a tab, and the user is taken to it",
             p(nil, nil, nil, true) == .tab(focus: true)),
            ("Google's 451×600 sign-in popup is a Little Vane",
             p(451, 600, nil, true) == .little),
            ("a page that asks for no toolbars is a Little Vane whatever size it named",
             p(nil, nil, false, true) == .little),
            ("…and toolbars it does want are no reason not to float a small one",
             p(451, 600, true, true) == .little),
            ("a popup nothing the user did asked for opens behind, not in front",
             p(nil, nil, nil, false) == .tab(focus: false)),
            ("…and never as a window, however small it asked to be",
             p(451, 600, false, false) == .tab(focus: false)),
            ("a window.open the size of a browser window is another page, so it is a tab",
             p(1400, 900, nil, true) == .tab(focus: true)),
            ("half a size is not a size", p(451, nil, nil, true) == .tab(focus: true)),
            ("the threshold is inclusive on both edges",
             p(Double(Look.popupWidth), Double(Look.popupHeight), nil, true) == .little),
            ("…and one pixel over it either way is a page",
             p(Double(Look.popupWidth) + 1, 600, nil, true) == .tab(focus: true)
                && p(451, Double(Look.popupHeight) + 1, nil, true) == .tab(focus: true)),
            ("a ⌘-clicked target=_blank stays behind the page it was clicked on",
             p(nil, nil, nil, true, background: true) == .tab(focus: false)),
            ("…and does not float, however much the page wanted a window",
             p(451, 600, false, true, background: true) == .tab(focus: false)),

            // The gesture flag itself. Both branches, on real objects: one that does not
            // answer to the SPI at all — the day WebKit renames it — and one that does and
            // says no. The version of this that asked KVC for the flag raised
            // NSUnknownKeyException on every popup there was, and no row could have caught
            // it, because an Objective-C exception is not something Swift can hold.
            ("with no gesture accessor to read, a popup is taken at its word",
             userInitiated(NSObject())),
            ("…and where there is one, its answer is the answer",
             userInitiated(GestureStub(answer: false)) == false
                && userInitiated(GestureStub(answer: true))),

            // Where a floated popup lands in the stack, for the Little Vane / Peek case in
            // `TabStore.popup` — the one place a `.tab` placement is floated anyway.
            ("a Little Vane opened for a popup comes to the front", takesFocus(.little)),
            ("a popup that asked for a tab in front floats in front",
             takesFocus(.tab(focus: true))),
            ("…and one that asked to stay behind stays behind, floating or not",
             takesFocus(.tab(focus: false)) == false),

            // ⇧⌘T. A sign-in window nobody chose to open is not a page anyone wants back.
            ("an ordinary tab closed with ⌘W is remembered for Reopen Closed Tab",
             TabStore.remembersClosed(keep: false, byScript: false, isPrivate: false)),
            ("a popup that closed itself is not",
             TabStore.remembersClosed(keep: false, byScript: true, isPrivate: false) == false),
            ("a favourite is not closed at all, so nothing is remembered for it",
             TabStore.remembersClosed(keep: true, byScript: false, isPrivate: false) == false),
            ("and a private tab is never written down anywhere",
             TabStore.remembersClosed(keep: false, byScript: false, isPrivate: true) == false),
        ]
    }
}

/// An object that answers to WebKit's gesture accessor, so `Popup.check` can drive the
/// branch that reads it as well as the branch that finds nothing to read. The name is the
/// SPI's, spelled out in `@objc` rather than in Swift, because that is the only part that
/// has to match.
private final class GestureStub: NSObject {
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
    @objc(_isUserInitiated) func gesture() -> Bool { answer }
}

// MARK: - Where the popup lands

extension TabStore {
    /// WebKit is asking this window for a page to put a popup in. It gets a real one, in a
    /// window this decides — and never nil, which is what "the popup was silently dropped"
    /// looks like from the page's side.
    ///
    /// The tab is built first and placed afterwards, because it is the *web view* WebKit
    /// wants back and the placement only decides which window ends up drawing it.
    ///
    /// Out of a Little Vane or a Peek every popup floats, whatever it asked for: there is no
    /// sidebar to put a tab beside, and a page that escaped from a floating window into the
    /// window behind it is not what the user clicked. It floats where the placement said it
    /// should go, though — `Popup.takesFocus` — so a ⌘-click or a gesture-less popup inside
    /// a Little Vane opens *behind* it rather than jumping in front of the page being read.
    func popup(_ cfg: WKWebViewConfiguration, placement: Popup.Placement,
               opener: Tab.ID?) -> WKWebView {
        let tab = Tab(popup: cfg, isPrivate: isPrivate, profileID: profileID)
        switch placement {
        case .tab(let focus) where !isLittle:
            adoptBeside(tab, opener: opener, focus: focus)
        default:
            LittleArc.open(popup: tab, isPrivate: isPrivate, profileID: profileID,
                           focus: Popup.takesFocus(placement))
        }
        return tab.web
    }

    /// A tab that already exists, put into the strip beside `opener`. `newTabBeside` next
    /// door does the same for a tab this window makes itself; a popup's is WebKit's, so it
    /// can only be adopted.
    func adoptBeside(_ tab: Tab, opener: Tab.ID?, focus: Bool) {
        wire(tab)
        tab.kind = .today
        Motion.list {
            let dest = TabStore.insertionIndexBeside(
                current: tabs.firstIndex { $0.id == opener }, kinds: tabs.map(\.kind))
            tabs.insert(tab, at: min(dest, tabs.count))
        }
        if focus {
            current = tab.id
        } else {
            axAnnounce("Opened in a background tab.")
        }
        extensions.sync()
    }

    /// The one page of a Little Vane opened around a popup. A floating store made with no
    /// url comes up empty with the search bar over it, the way ⌥⌘N does — but this one is
    /// not empty, it is about to be navigated by WebKit, so the bar goes.
    func adopt(popup tab: Tab) {
        wire(tab)
        tabs.append(tab)
        current = tab.id
        palette = nil
        extensions.sync()
    }

    /// A popup that called `window.close()` on itself — the last thing every OAuth flow on
    /// the web does. It goes without a trace: not archived, and not pushed for Reopen Closed
    /// Tab either, because a sign-in window nobody chose to open is not a page anyone wants
    /// back. Nothing archives it because nothing routes through `archive`; nothing remembers
    /// it because `byScript` tells `close` not to — see `TabStore.remembersClosed`.
    ///
    /// A Little Vane is its one page, so closing that page closes the window, exactly as
    /// ⌘W does — see `closeOrArchive`.
    func closedByScript(_ id: Tab.ID) {
        if isLittle, tabs.count <= 1, tabs.first?.id == id {
            window?.performClose(nil)
        } else {
            close(id, byScript: true)
        }
    }
}
