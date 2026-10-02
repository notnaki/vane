import AppKit
import XCTest
@testable import vane

final class LinkInteractionTests: XCTestCase {
    private let page = URL(string: "https://example.com/page")!
    private let other = URL(string: "https://other.test/article")!

    private func route(_ modifiers: NSEvent.ModifierFlags, kind: TabKind = .today,
                       target: LinkInteraction.Target = .main,
                       floating: Bool = false, split: Bool = true,
                       preferences: LinkInteraction.Preferences = .init(),
                       button: Int = 1) -> LinkInteraction.Action {
        LinkInteraction.route(to: other,
            context: .init(kind: kind, source: page, target: target,
                           canPeek: !floating, canSplit: split && !floating, floating: floating),
            modifiers: modifiers, button: button, preferences: preferences)
    }

    func testCommandPreservesBackgroundAndShiftCommandFocuses() {
        XCTAssertEqual(route(.command), .tab(focus: false))
        XCTAssertEqual(route([.command, .shift]), .tab(focus: true))
        XCTAssertEqual(route(.command, kind: .pinned), .tab(focus: false))
    }

    func testOptionSplitsWebpageLinksAndWinsOverShift() {
        XCTAssertEqual(route(.option), .split)
        XCTAssertEqual(route([.option, .shift]), .split)
        XCTAssertEqual(route(.option, target: .newWindow), .split)
        XCTAssertEqual(route(.option, target: .subframe), .navigate)
    }

    func testLittleWindowPreferenceAndCombinationPrecedence() {
        XCTAssertEqual(route([.option, .command]), .little)
        XCTAssertEqual(route([.option, .command, .shift]), .little)
        XCTAssertEqual(route([.option, .command], preferences: .init(littleLinks: false)), .tab(focus: false))
        XCTAssertEqual(route([.option, .command, .shift], preferences: .init(littleLinks: false)), .tab(focus: true))
        XCTAssertEqual(route([.option, .command], target: .newWindow), .little)
    }

    func testShiftPeeksFromEveryTabKindAndCanBeDisabled() {
        for kind in [TabKind.today, .pinned, .favourite] {
            XCTAssertEqual(route(.shift, kind: kind), .peek)
        }
        XCTAssertEqual(route(.shift, preferences: .init(shiftPeek: false)), .navigate)
        XCTAssertEqual(route(.shift, kind: .pinned, preferences: .init(shiftPeek: false)), .peek)
        XCTAssertEqual(route([], kind: .pinned, preferences: .init(automaticPeek: false)), .tab(focus: true))
    }

    func testKeyboardActivationKeepsModifierAndPinnedLinkRouting() {
        XCTAssertEqual(route(.command, button: 0), .tab(focus: false))
        XCTAssertEqual(route(.shift, button: 0), .peek)
        XCTAssertEqual(route([], kind: .pinned, button: 0), .peek)
    }

    func testOrdinaryFloatingPopupIsDelegatedToWebKit() {
        XCTAssertEqual(route([], target: .newWindow, floating: true), .popup(floating: true),
                          "Ordinary popups need WebKit's configuration, opener and scripted close")
    }

    func testTargetsAndFloatingWindowsKeepTheirOwnNavigation() {
        XCTAssertEqual(route([], target: .newWindow), .popup(floating: false))
        XCTAssertEqual(route(.shift, target: .newWindow), .peek)
        XCTAssertEqual(route([], kind: .pinned, target: .subframe), .navigate)
        XCTAssertEqual(route(.shift, floating: true), .navigate)
        XCTAssertEqual(route(.option, floating: true), .navigate)
        XCTAssertEqual(route(.command, floating: true), .little)
    }

    func testMiddleClickIgnoresModifiersAndControlOpensTheContextMenu() {
        XCTAssertEqual(route([.command, .option, .shift, .control], button: TabActions.middleButton), .tab(focus: false))
        XCTAssertEqual(route([.control, .command, .option]), .navigate)
    }

    func testExternalAndScriptLinksNeverPromiseBrowserTabs() {
        for raw in ["mailto:me@example.com", "javascript:alert(1)", "vane://oauth/github"] {
            XCTAssertEqual(LinkInteraction.route(to: URL(string: raw)!,
                context: .init(kind: .pinned, source: page),
                modifiers: [.command, .option, .shift]), .navigate)
        }
    }

    func testHintUsesActualRouteAndOrdinaryHoverHasNoActionSentence() {
        let context = LinkInteraction.Context(kind: .today, source: page)
        XCTAssertNil(LinkInteraction.hint(to: other, context: context, modifiers: []))
        XCTAssertEqual(LinkInteraction.hint(to: other, context: context, modifiers: .command), " in a new tab")
        XCTAssertEqual(LinkInteraction.hint(to: other, context: context, modifiers: [.command, .shift]), " in a new tab and focus it")
        XCTAssertEqual(LinkInteraction.hint(to: other, context: context, modifiers: .option), " in Split View")
        XCTAssertEqual(LinkInteraction.hint(to: other, context: context, modifiers: .shift), " in Peek")
        XCTAssertNil(LinkInteraction.hint(to: other, context: context, modifiers: .control))
    }
    func testHoverPayloadPreservesTargetsAndRejectsMalformedMessages() {
        let hover = StatusBar.hover(from: ["url": other.absoluteString, "target": "newWindow"])
        XCTAssertEqual(hover?.url, other.absoluteString)
        XCTAssertEqual(hover?.target, .newWindow)
        XCTAssertEqual(StatusBar.hover(from: page.absoluteString)?.target, .main)
        XCTAssertNil(StatusBar.hover(from: ["url": "", "target": "main"]))
        XCTAssertNil(StatusBar.hover(from: ["url": 17, "target": "main"]))
        XCTAssertNil(StatusBar.hover(from: ["url": other.absoluteString, "target": "unknown"]))
    }

}

@MainActor final class LinkSplitTests: XCTestCase {
    func testOpeningAWebpageLinkSplitsBesideItsSourceAndFullSplitCreatesNoTab() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID(), session: [])
        let source = store.newBlankTab()
        let destination = URL(string: "about:blank")!
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        store.openLinkInSplit(destination, beside: source.id)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeSplit?.tabs.first, source.id)
        XCTAssertEqual(store.activeSplit?.activeTab, store.current)
        XCTAssertTrue(store.tabs.allSatisfy { $0.isPrivate && $0.profileID == store.profileID })
        store.openLinkInSplit(destination, beside: source.id)
        store.openLinkInSplit(destination, beside: source.id)
        let selected = store.current
        XCTAssertEqual(store.tabs.count, 4)
        store.openLinkInSplit(destination, beside: source.id)
        XCTAssertEqual(store.tabs.count, 4)
        XCTAssertEqual(store.current, selected)
        XCTAssertEqual(store.activeSplit?.tabs.count, 4)
    }
}
