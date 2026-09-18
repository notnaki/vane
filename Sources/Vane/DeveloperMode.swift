import AppKit
import SwiftUI
import WebKit

/// Arc's Developer Mode. On by itself for anything served from this machine, and a switch
/// per site for everything else (Site Control Center, the command bar, ⌥⌘D). A tab in it
/// gets a bar above the page with the full url and the tools a developer keeps reaching
/// for, a yellow-and-black outline round the page, and the Web Inspector — whatever the
/// browser-wide "Allow Web Inspector" says.
///
/// ponytail: one `[host: Bool]` per profile, stored only where the answer differs from the
/// automatic one, so turning it off for localhost:3000 is a row and turning it on for
/// staging.example.com is a row, and the table stays empty for everyone else.
@MainActor enum DeveloperMode {
    /// Served from this machine: `localhost`, anything under it, and the loopback addresses.
    /// Deliberately narrower than `HTTPSOnly.isLocal` — a router at 192.168.1.1 is on the
    /// LAN, but it is not something you are developing.
    nonisolated static func isLocal(_ url: URL?) -> Bool {
        guard let h = url?.host()?.lowercased(), !h.isEmpty else { return false }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.") { return true }
        return false
    }

    private static let base = "developerSites"
    private static func key(_ profile: UUID) -> String { ProfileManager.defaultsKey(base, profile) }
    private static var defaults: UserDefaults { .vane }

    private static func table(_ profile: UUID) -> [String: Bool] {
        (defaults.dictionary(forKey: key(profile)) ?? [:]).compactMapValues { $0 as? Bool }
    }

    /// The answer for a url: what the user said about its host, else whether it is local.
    nonisolated static func wants(_ url: URL?, said: [String: Bool]) -> Bool {
        guard let url, let h = url.host()?.lowercased() else { return false }
        return said[h] ?? isLocal(url)
    }

    static func wants(_ url: URL?, profile: UUID) -> Bool { wants(url, said: table(profile)) }

    /// Remember the answer for this host; forget it when it is what the automatic one would
    /// have said anyway.
    nonisolated static func set(_ on: Bool, for url: URL, in table: inout [String: Bool]) {
        guard let h = url.host()?.lowercased() else { return }
        if on == isLocal(url) { table.removeValue(forKey: h) } else { table[h] = on }
    }

    static func set(_ on: Bool, for url: URL, profile: UUID) {
        var t = table(profile)
        set(on, for: url, in: &t)
        if t.isEmpty { defaults.removeObject(forKey: key(profile)) } else { defaults.set(t, forKey: key(profile)) }
    }

    /// Read the answer for where the tab is and put it on the web view. Runs on attach, on
    /// every commit and when the switch is flipped, so a suspended tab that comes back or a
    /// page that navigates from localhost to a deployed site lands in the right mode.
    static func apply(to tab: Tab) {
        let on = wants(tab.currentURL, profile: tab.profileID)
        if tab.developer != on { tab.developer = on }
        let inspect = on || Settings.inspectorEnabled
        tab.web.isInspectable = inspect
        // "Inspect Element" and the in-app inspector are gated on this preference, not on
        // `isInspectable` — see Tab.configuration.
        tab.web.configuration.preferences.setValue(inspect, forKey: "developerExtrasEnabled")
    }

    static func set(_ on: Bool, on tab: Tab) {
        if let url = tab.currentURL { set(on, for: url, profile: tab.profileID) }
        apply(to: tab)
    }

    static func toggle(_ tab: Tab) { set(!tab.developer, on: tab) }

    /// The page, to the clipboard — Arc's "Capture" from the same bar.
    static func capture(_ tab: Tab) {
        Task {
            guard let image = try? await tab.web.takeSnapshot(configuration: nil) else {
                Toasts.show("Nothing to capture yet"); return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            Toasts.show("Page copied as an image")
        }
    }

    static func check() -> [(String, Bool)] {
        func u(_ s: String) -> URL { URL(string: s)! }
        var t: [String: Bool] = [:]
        var out: [(String, Bool)] = [
            ("localhost is local", isLocal(u("http://localhost:3000/"))),
            ("a .localhost subdomain is local", isLocal(u("http://api.localhost/"))),
            ("loopback is local", isLocal(u("http://127.0.0.1:8080/")) && isLocal(u("http://[::1]/"))),
            ("the LAN is not", !isLocal(u("http://192.168.1.1/"))),
            ("a real site is not", !isLocal(u("https://example.com/"))),
            ("local sites are on with nothing said", wants(u("http://localhost:3000/"), said: [:])),
            ("others are off with nothing said", !wants(u("https://example.com/"), said: [:])),
        ]
        set(false, for: u("http://localhost:3000/"), in: &t)
        out.append(("saying no to localhost is a row", t["localhost"] == false))
        out.append(("…and is honoured", !wants(u("http://localhost:3000/a"), said: t)))
        set(true, for: u("http://localhost:3000/"), in: &t)
        out.append(("saying the automatic answer removes the row", t.isEmpty))
        set(true, for: u("https://staging.example.com/x"), in: &t)
        out.append(("saying yes to a real site is a row", t == ["staging.example.com": true]))
        out.append(("…keyed by host, not page", wants(u("https://staging.example.com/y"), said: t)))
        return out
    }
}

// MARK: - The bar

/// A tab's page with Developer Mode's bar above it, in the gap Arc leaves: the pill wears
/// the Space's colour and the page's top corners round off under it. Nothing at all when
/// the mode is off, so the page sits exactly where it always did.
struct DeveloperFrame<Content: View>: View {
    @ObservedObject var tab: Tab
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: Look.inset) {
            if tab.developer { DeveloperBar(tab: tab) }
            content()
                .clipShape(.rect(cornerRadius: tab.developer ? Look.paneRadius : 0))
        }
        .padding(tab.developer ? Look.inset : 0)
        .accessibilityElement(children: .contain)
    }
}

/// Arc's dev toolbar: the lock, the whole url, then copy, capture, console, inspector, reload.
private struct DeveloperBar: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: tab.currentURL?.scheme == "https" ? "lock.fill" : "lock.open")
            Text(tab.currentURL?.absoluteString ?? tab.address)
                .font(.system(size: Look.findFontSize, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            tool("link", "Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.currentURL?.absoluteString ?? "", forType: .string)
                Toasts.show("URL copied")
            }
            divider
            tool("camera", "Capture Page") { DeveloperMode.capture(tab) }
            divider
            if Inspector.available {
                tool("terminal", "Console") { Inspector.showConsole(tab.web) }
                tool("scope", "Web Inspector") { Inspector.show(tab.web) }
            }
            tool("arrow.clockwise", "Reload Ignoring Cache") { tab.web.reloadFromOrigin() }
        }
        .font(Look.caption.weight(.medium)).foregroundStyle(.white)
        .buttonStyle(FindControlStyle())
        .padding(.horizontal, Look.rowTrailingInset).frame(height: Look.rowHeight)
        .background(tint, in: .rect(cornerRadius: Look.pillRadius))
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Developer Mode")
    }

    /// The Space's own colour, the way Arc paints the bar in the Space's accent.
    private var tint: Color {
        let hex = store.currentSpace.map(Spaces.themeColors(of:))?.first ?? store.profile.colorHex
        return Color(hex: hex) ?? .accentColor
    }

    private var divider: some View { Divider().frame(height: 14).opacity(0.5) }

    private func tool(_ glyph: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: glyph) }
            .help(name).accessibilityLabel(name)
    }
}
