import AppKit
import SwiftUI
import WebKit

/// Arc's Developer Mode. On by itself for anything served from this machine, and a switch
/// per site for everything else (Site Control Center, the command bar, ⌥⌘D). A tab in it
/// gets a bar above the page with the full url and the tools a developer keeps reaching
/// for, a striped toolbar joined to the page, and the Web Inspector — whatever the
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

    /// Keep the port visible so two local servers are distinguishable in the sidebar.
    nonisolated static func endpoint(_ url: URL?) -> String? {
        guard let url, let host = url.host(), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
        let label = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(label):\($0)" } ?? label
    }

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

/// Black fills the gaps between yellow dashes even on a light or tinted sidebar.
struct DeveloperTabBorder: View {
    var body: some View {
        let outline = RoundedRectangle(cornerRadius: Look.pillRadius)
        outline.strokeBorder(.black, lineWidth: 1.5)
            .overlay {
                outline.strokeBorder(Look.developerYellow,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The bar

/// The toolbar and page share the card's outer edges and clip. `WebCard` (or a split pane)
/// owns their rounding and window inset; adding padding here would inset both a second time.
struct DeveloperFrame<Content: View>: View {
    @ObservedObject var tab: Tab
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if tab.developer { DeveloperBar(tab: tab) }
            content()
        }
        .accessibilityElement(children: .contain)
    }
}

/// Arc's dev toolbar: the lock, the whole url, then copy, capture, console, inspector, reload.
private struct DeveloperBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: tab.currentURL?.scheme == "https" ? "lock.fill" : "lock.open")
            Text(tab.currentURL?.absoluteString ?? tab.address)
                .font(Look.small.monospaced().weight(.medium))
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
        .font(Look.caption.weight(.medium)).foregroundStyle(Color(white: 0.86))
        .buttonStyle(FindControlStyle())
        .padding(.horizontal, Look.rowTrailingInset).frame(height: Look.rowHeight)
        .background {
            Color(white: 0.18)
                .overlay {
                    Canvas { context, size in
                        let stripe: CGFloat = 24
                        for x in stride(from: -size.height, to: size.width, by: stripe * 2) {
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x + stripe, y: 0))
                            path.addLine(to: CGPoint(x: x + stripe + size.height, y: size.height))
                            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            path.closeSubpath()
                            context.fill(path, with: .color(.black.opacity(0.08)))
                        }
                    }
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Developer Mode")
    }

    private var divider: some View { Divider().frame(height: 14).opacity(0.5) }

    private func tool(_ glyph: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: glyph) }
            .help(name).accessibilityLabel(name)
    }
}
