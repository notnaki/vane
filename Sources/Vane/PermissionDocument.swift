import AppKit
import WebKit

/// WKFrameInfo identifies a frame, which can outlive many same-origin documents.
/// An isolated-world token distinguishes those documents without trusting page code.
@MainActor final class SitePermissionDocument {
    static let world = WKContentWorld.world(name: "vane-site-permissions")
    static let script = """
    (() => {
      const fresh = () => Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
      const state = { token: fresh(), alive: true };
      globalThis.__vanePermissionDocument = state;
      addEventListener('pagehide', () => { state.alive = false; });
      addEventListener('pageshow', e => { if (e.persisted) { state.token = fresh(); state.alive = true; } });
    })();
    """

    private weak var tab: Tab?
    private weak var web: WKWebView?
    private weak var window: NSWindow?
    private let frame: WKFrameInfo
    private let generation: UInt
    private let token: String
    let scope: SitePermissions.Scope

    private init(tab: Tab, web: WKWebView, window: NSWindow, frame: WKFrameInfo,
                 scope: SitePermissions.Scope, generation: UInt, token: String) {
        self.tab = tab; self.web = web; self.window = window; self.frame = frame
        self.scope = scope; self.generation = generation; self.token = token
    }

    static func capture(tab: Tab, web: WKWebView, topOrigin: WKSecurityOrigin,
                        frame: WKFrameInfo, generation: UInt, window: NSWindow) async -> SitePermissionDocument? {
        guard frame.isMainFrame, frame.webView === web, tab.existingWeb === web,
              tab.permissionGeneration == generation, web.window === window, window.isVisible, !web.isHiddenOrHasHiddenAncestor,
              let top = scope(topOrigin, tab: tab), top == SitePermissions.scope(for: tab),
              let requesting = scope(frame.securityOrigin, tab: tab), requesting == top,
              let snapshot = await snapshot(web, frame: frame), snapshot.alive,
              URL(string: snapshot.href) == frame.request.url else { return nil }
        let document = SitePermissionDocument(tab: tab, web: web, window: window, frame: frame,
                                              scope: requesting, generation: generation, token: snapshot.token)
        return document.ownerIsCurrent ? document : nil
    }

    private static func scope(_ origin: WKSecurityOrigin, tab: Tab) -> SitePermissions.Scope? {
        SitePermissions.Scope(scheme: origin.protocol, host: origin.host, port: origin.port,
                              profileID: tab.profileID, privateTabID: tab.isPrivate ? tab.id : nil)
    }

    var ownerIsCurrent: Bool {
        guard let tab, let web, let window else { return false }
        return tab.existingWeb === web && tab.permissionGeneration == generation
            && web.window === window && window.isVisible && !web.isHiddenOrHasHiddenAncestor
    }

    func isCurrent() async -> Bool {
        guard ownerIsCurrent, let web, let value = await Self.snapshot(web, frame: frame) else { return false }
        return ownerIsCurrent && value.alive && value.token == token
    }

    private struct Snapshot: Decodable { let token: String; let href: String; let alive: Bool }
    private static func snapshot(_ web: WKWebView, frame: WKFrameInfo) async -> Snapshot? {
        let value: String? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript("JSON.stringify({...globalThis.__vanePermissionDocument, href: location.href})",
                                   in: frame, in: world) { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
        }
        return value.flatMap { try? JSONDecoder().decode(Snapshot.self, from: Data($0.utf8)) }
    }
}

extension Tab {
    /// Stop both devices through supported WebKit APIs even if another owner retains
    /// the view during teardown. Location/display tracks end with WebKit's document.
    func endPermissionDocument(navigationStarted: Bool = false) {
        permissionGeneration &+= 1
        SitePermissions.endDocument(tabID: id, preservingLocation: navigationStarted)
        existingWeb?.setCameraCaptureState(.none, completionHandler: nil)
        existingWeb?.setMicrophoneCaptureState(.none, completionHandler: nil)
    }
}
