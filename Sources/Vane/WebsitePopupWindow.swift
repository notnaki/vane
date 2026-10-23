import AppKit
import WebKit
import SwiftUI

/// A website-owned dialog. It owns its page, never a sidebar, Space or saved session.
/// Retain the controller until native or scripted close tears down only this web view.
@MainActor final class WebsitePopupWindow: NSWindowController, NSWindowDelegate {
    private static var live: [WebsitePopupWindow] = []
    let tab: Tab
    private weak var origin: TabStore?
    private let opener: Tab.ID?
    private var observation: NSKeyValueObservation?
    private let location = NSTextField(labelWithString: "about:blank")

    static func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return tab(in: window) != nil
    }

    static func tab(in window: NSWindow?) -> Tab? {
        guard let window else { return nil }
        return live.first { $0.window === window }?.tab
    }

    @discardableResult
    static func open(_ tab: Tab, origin: TabStore?, opener: Tab.ID?,
                     features: WKWindowFeatures? = nil, focus: Bool = true) -> WebsitePopupWindow {
        let controller = WebsitePopupWindow(tab: tab, origin: origin, opener: opener, features: features)
        live.append(controller)
        if focus { controller.window?.makeKeyAndOrderFront(nil) }
        else { controller.window?.orderBack(nil) }
        return controller
    }

    private init(tab: Tab, origin: TabStore?, opener: Tab.ID?, features: WKWindowFeatures?) {
        self.tab = tab
        self.origin = origin
        self.opener = opener
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 800)
        let size = Self.contentSize(width: features?.width?.doubleValue,
                                    height: features?.height?.doubleValue, available: visible)
        let window = WebsiteDialogWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Website Popup"
        super.init(window: window)
        window.delegate = self
        window.contentMinSize = NSSize(width: min(320, size.width), height: min(240, size.height))

        let content = NSView()
        window.contentView = content
        location.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingTail
        location.isSelectable = true
        location.setAccessibilityLabel("Website address")
        let web = tab.web
        let page = NSHostingView(rootView: WebsitePopupPage(tab: tab).font(Look.text))
        for view in [location, page] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            location.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            location.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            location.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            location.heightAnchor.constraint(equalToConstant: 18),
            page.topAnchor.constraint(equalTo: location.bottomAnchor, constant: 7),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Keep profile-scoped link actions, but replace the tab-store close/popup owners.
        origin?.wire(tab)
        tab.onPopup = { [weak self] configuration, placement, features in
            guard let self else { return nil }
            if case .tab = placement, let origin = self.origin {
                return origin.popup(configuration, placement: placement, opener: self.opener, features: features)
            }
            let child = Tab(popup: configuration, isPrivate: self.tab.isPrivate, profileID: self.tab.profileID)
            Self.open(child, origin: self.origin, opener: self.opener,
                      features: features, focus: Popup.takesFocus(placement))
            return child.web
        }
        tab.onClose = { [weak self] in
            // Never free the page while WebKit is still in webViewDidClose.
            Task { @MainActor [weak self] in self?.window?.performClose(nil) }
        }
        observation = web.observe(\.url, options: [.initial, .new]) { [weak self] _, change in
            let url = change.newValue ?? nil
            Task { @MainActor [weak self] in self?.showLocation(url) }
        }
        window.center()
        content.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showLocation(_ url: URL?) {
        let address = url.flatMap(SiteBoosts.origin) ?? "about:blank"
        location.stringValue = address
        window?.title = address == "about:blank" ? "Website Popup" : address
    }

    /// Honor requested dimensions while keeping native close controls reachable.
    nonisolated static func contentSize(width: Double?, height: Double?, available: NSSize) -> NSSize {
        func dimension(_ requested: Double?, fallback: Double, maximum: Double) -> Double {
            let value = requested.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? fallback
            return min(max(240, value), max(240, maximum - 80))
        }
        return NSSize(width: dimension(width, fallback: 500, maximum: available.width),
                      height: dimension(height, fallback: 600, maximum: available.height))
    }

    func windowWillClose(_ notification: Notification) {
        observation = nil
        tab.onPopup = nil
        tab.onClose = nil
        tab.tearDown()
        window?.contentView = nil
        // NSWindow's delegate is weak; keep self alive through this callback as well.
        Task { @MainActor in Self.live.removeAll { $0 === self } }
    }
}


/// Keep authentication UI on the popup's own page without introducing a tab store.
private struct WebsitePopupPage: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            if let web = tab.existingWeb {
                WebView(web: web)
                    .overlay(alignment: .topLeading) { PasswordChooser(tab: tab) }
                    .overlay(alignment: .topTrailing) { PasswordOffer(tab: tab).padding(12) }
            }
        }
    }
}

private final class WebsiteDialogWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        MainActor.assumeIsolated { PasswordChooser.handlePointer(event) }
        if event.type == .keyDown, event.keyCode == 53,
           MainActor.assumeIsolated({ PasswordChooser.dismiss(in: self) }) { return }
        super.sendEvent(event)
    }
}
