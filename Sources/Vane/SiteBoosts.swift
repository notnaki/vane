import Foundation
import WebKit

struct SiteBoost: Codable, Equatable, Sendable {
    var enabled = true
    var font = ""
    var textScale = 1.0
    var background = ""
    var textColor = ""
    var linkColor = ""
    var hidden: [String] = []
    var css = ""
    var script = ""
    var scriptEnabled = false

    static let fonts = ["", "Georgia", "Helvetica Neue", "Avenir Next", "Menlo", "Palatino", "Times New Roman"]

    var sanitized: Self {
        var copy = self
        if !Self.fonts.contains(font) { copy.font = "" }
        copy.textScale = textScale.isFinite ? min(2, max(0.75, textScale)) : 1
        for key in [\Self.background, \Self.textColor, \Self.linkColor] {
            if copy[keyPath: key].range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil {
                copy[keyPath: key] = ""
            }
        }
        var seen = Set<String>()
        copy.hidden = hidden.filter { !$0.isEmpty && $0.utf8.count <= 4096 && seen.insert($0).inserted }
        return copy
    }

    var style: String {
        guard enabled else { return "" }
        let value = sanitized
        var rules: [String] = []
        if !value.font.isEmpty {
            // Keep icon fonts and SVG glyphs intact.
            rules.append("body, body :is(p,h1,h2,h3,h4,h5,h6,a,span,li,td,th,button,input,textarea,label,blockquote) { font-family: '\(value.font)' !important; }")
        }
        if !value.background.isEmpty {
            rules.append("html, body { background-color: \(value.background) !important; } body :is(main,article,section,aside,header,footer,nav) { background-color: \(value.background) !important; }")
        }
        if !value.textColor.isEmpty { rules.append("body, body :is(p,h1,h2,h3,h4,h5,h6,span,li,td,th,label,blockquote) { color: \(value.textColor) !important; }") }
        if !value.linkColor.isEmpty { rules.append("body a, body a * { color: \(value.linkColor) !important; }") }
        // Each selector is its own rule: one stale selector must not discard the others.
        rules += value.hidden.map { "\($0) { display: none !important; }" }
        rules.append(value.css)
        return rules.joined(separator: "\n")
    }
}

@MainActor final class SiteBoostStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    static func key(_ profile: UUID) -> String { ProfileManager.defaultsKey("siteBoosts.v1", profile) }

    func records(profile: UUID) -> [String: SiteBoost] {
        guard let data = defaults.data(forKey: Self.key(profile)),
              let raw = try? JSONDecoder().decode([String: SiteBoost].self, from: data) else { return [:] }
        return raw.filter { URL(string: $0.key).flatMap(SiteBoosts.origin) == $0.key }.mapValues(\.sanitized)
    }
    func get(origin: String, profile: UUID) -> SiteBoost { records(profile: profile)[origin] ?? SiteBoost() }
    func set(_ value: SiteBoost, origin: String, profile: UUID) {
        guard URL(string: origin).flatMap(SiteBoosts.origin) == origin else { return }
        var table = records(profile: profile)
        let value = value.sanitized
        if value == SiteBoost() { table.removeValue(forKey: origin) } else { table[origin] = value }
        if table.isEmpty { defaults.removeObject(forKey: Self.key(profile)) }
        else if let data = try? JSONEncoder().encode(table) { defaults.set(data, forKey: Self.key(profile)) }
    }
    func forget(profile: UUID) { defaults.removeObject(forKey: Self.key(profile)) }
}

@MainActor enum SiteBoosts {
    final class Document {
        weak var tab: Tab?
        let origin: String
        let stamp: Double
        let token: String
        var scriptRan = false
        init(tab: Tab, origin: String, stamp: Double, token: String) { self.tab = tab; self.origin = origin; self.stamp = stamp; self.token = token }
    }
    private static let store = SiteBoostStore(defaults: .vane)
    private static var privateValues: [UUID: [String: SiteBoost]] = [:]
    private static var documents: [UUID: Document] = [:]

    nonisolated static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = url.port
        let suffix = port != nil && port != (scheme == "https" ? 443 : 80) ? ":\(port!)" : ""
        return "\(scheme)://\(host)\(suffix)"
    }

    static func document(for tab: Tab) -> Document? { documents[tab.id] }
    static func value(origin: String, tab: Tab) -> SiteBoost {
        tab.isPrivate ? privateValues[tab.id]?[origin] ?? SiteBoost() : store.get(origin: origin, profile: tab.profileID)
    }
    static func set(_ boost: SiteBoost, origin: String, tab: Tab) {
        guard URL(string: origin).flatMap(Self.origin) == origin else { return }
        let boost = boost.sanitized
        if tab.isPrivate {
            if boost == SiteBoost() { privateValues[tab.id]?.removeValue(forKey: origin) }
            else { privateValues[tab.id, default: [:]][origin] = boost }
        } else { store.set(boost, origin: origin, profile: tab.profileID) }
        for doc in documents.values {
            guard let other = doc.tab, doc.origin == origin,
                  tab.isPrivate ? other === tab : (!other.isPrivate && other.profileID == tab.profileID) else { continue }
            apply(to: other, document: doc)
        }
        SiteChanges.shared.bump()
    }

    static func receive(_ message: WKScriptMessage, tab: Tab) {
        guard message.webView === tab.existingWeb, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let origin = body["origin"] as? String,
              let stamp = body["stamp"] as? Double, stamp.isFinite,
              let token = body["token"] as? String, token.utf8.count == 32,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let frameURL = message.frameInfo.request.url, Self.origin(frameURL) == origin,
              let url = tab.currentURL, Self.origin(url) == origin else { return }
        switch body["kind"] as? String {
        case "ready", "restored":
            let doc = Document(tab: tab, origin: origin, stamp: stamp, token: token)
            documents[tab.id] = doc
            apply(to: tab, document: doc)
        case "loaded":
            guard let doc = documents[tab.id], doc.token == token, !doc.scriptRan else { return }
            doc.scriptRan = true
            apply(to: tab, document: doc)
            Task {
                guard documents[tab.id] === doc else { return }
                let result = await runScript(tab: tab)
                if documents[tab.id] === doc { SiteBoostEditor.report(result, tab: tab) }
            }
        case "pick":
            guard let doc = documents[tab.id], doc.token == token,
                  let selector = body["selector"] as? String, !selector.isEmpty,
                  selector.utf8.count <= 4096, SiteBoostEditor.acceptsPick(tab: tab) else { return }
            SiteBoostEditor.pick(selector, tab: tab)
        case "done":
            guard documents[tab.id]?.token == token else { return }
            SiteBoostEditor.stopZap(tab: tab)
        default: break
        }
    }

    private static func apply(to tab: Tab, document: Document) {
        guard let web = tab.existingWeb else { return }
        web.callAsyncJavaScript("if (window.__vaneBoost && window.__vaneBoost.documentToken === token && location.origin === origin) window.__vaneBoost.apply(css, scale);",
            arguments: ["token": document.token, "origin": document.origin, "css": value(origin: document.origin, tab: tab).style, "scale": value(origin: document.origin, tab: tab).enabled ? value(origin: document.origin, tab: tab).sanitized.textScale : 1],
            in: nil, in: SiteBoostScripts.world) { _ in }
    }

    static func zap(_ on: Bool, tab: Tab) {
        guard let doc = documents[tab.id], let web = tab.existingWeb else { return }
        web.callAsyncJavaScript("if (window.__vaneBoost && window.__vaneBoost.documentToken === token && location.origin === origin) window.__vaneBoost.zap(on);",
            arguments: ["token": doc.token, "origin": doc.origin, "on": on], in: nil, in: SiteBoostScripts.world) { _ in }
    }

    static func runScript(tab: Tab) async -> String {
        guard let doc = documents[tab.id], let web = tab.existingWeb else { return "Load a page first." }
        let boost = value(origin: doc.origin, tab: tab)
        guard boost.enabled, boost.scriptEnabled else { return "Enable JavaScript to run this script." }
        guard !boost.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "The script is empty." }
        // Compile user code directly through WebKit: page CSP can block JavaScript eval().
        let source = """
        if (location.origin !== __vaneOrigin || performance.timeOrigin !== __vaneStamp) return 'Page changed. Reload and try again.';
        \(boost.script)
        ;return 'Script applied.';
        """
        let result: String = await withCheckedContinuation { continuation in
            web.callAsyncJavaScript(source, arguments: ["__vaneOrigin": doc.origin, "__vaneStamp": doc.stamp], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "Script applied.")
                case .failure(let error):
                    let details = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    continuation.resume(returning: String(details.prefix(500)))
                }
            }
        }
        guard documents[tab.id] === doc else { return "Page changed. Reload and try again." }
        return result
    }

    /// A provisional load can be cancelled or turn into a download; its old document survives.
    static func beginNavigation(tab: Tab) { SiteBoostEditor.close(tab: tab) }

    static func navigation(tab: Tab) {
        SiteBoostEditor.close(tab: tab)
        documents.removeValue(forKey: tab.id)
    }
    static func forget(tab: Tab) {
        navigation(tab: tab)
        privateValues.removeValue(forKey: tab.id)
    }
    static func forget(host: String, tab: Tab) {
        let records = tab.isPrivate ? privateValues[tab.id] ?? [:] : store.records(profile: tab.profileID)
        let matching = records.keys.filter { URL(string: $0)?.host()?.lowercased() == host.lowercased() }
        for origin in matching { set(SiteBoost(), origin: origin, tab: tab) }
    }

    static func forget(profile: UUID) {
        store.forget(profile: profile)
        for doc in documents.values where doc.tab?.profileID == profile {
            if let tab = doc.tab { apply(to: tab, document: doc) }
        }
        SiteChanges.shared.bump()
    }
}
