import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class PageTranslationTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    /// A foreign page is offered once; Not now holds through a reload on the same site.
    /// With `VANE_TRANSLATE_CAPTURE` set to a directory, also writes the offer card and the
    /// Site Controls popover (with "Offer to Translate" off) as PNGs for visual sign-off.
    func testOfferOnceNotNowHoldsAndCaptures() async throws {
        let target = PageTranslation.preferredLanguage()
        try XCTSkipIf(target.languageCode?.identifier == "de", "The fixture page is German")
        let profile = UUID()
        let store = TabStore(isPrivate: false, profileID: profile, session: [])
        let tab = Tab(isPrivate: false, profileID: profile)
        addTeardownBlock { @MainActor in
            PageTranslation.setOffers(true, host: "zeitung.example", tab: tab)
            tab.tearDown()
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile)
        }
        tab.web.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let html = "<html><body><p>" + String(repeating: "Die Katze sitzt auf der Matte und schläft den ganzen Tag. ", count: 4)
            + "</p></body></html>"
        func load() async throws {
            tab.web.loadHTMLString(html, baseURL: URL(string: "https://www.zeitung.example/"))
            try await compatibilityWait { !tab.web.isLoading && tab.web.url?.host() == "www.zeitung.example" }
        }
        try await load()
        try await compatibilityWait { PageTranslation.shared.offers[tab.id] != nil }
        let offer = try XCTUnwrap(PageTranslation.shared.offers[tab.id])
        XCTAssertEqual(offer.host, "www.zeitung.example")

        let directory = ProcessInfo.processInfo.environment["VANE_TRANSLATE_CAPTURE"]
        for dark in [false, true] {
            try capture(TranslateOffer(tab: tab, store: store).padding(20).frame(width: 440),
                        dark: dark, name: "offer", in: directory)
        }

        PageTranslation.answer(offer, .notNow, tab: tab, in: store)
        XCTAssertNil(PageTranslation.shared.offers[tab.id])
        try await load()
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(PageTranslation.shared.offers[tab.id], "Not now must hold on the same site in this tab")

        PageTranslation.setOffers(false, host: offer.host, tab: tab)
        let row = SiteControlModel(tab).rows.first { $0.id == .translateOffers }
        XCTAssertEqual(row?.note, "Never translate this site is on.")
        for dark in [false, true] {
            try capture(SiteControlPopover(tab: tab).environmentObject(store), dark: dark,
                        name: "site-controls", in: directory)
        }
    }

    private func capture(_ view: some View, dark: Bool, name: String, in directory: String?) throws {
        let host = NSHostingView(rootView: view.background(Look.panelFill))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 40, "\(name) rendered empty")
        guard let directory else { return }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
