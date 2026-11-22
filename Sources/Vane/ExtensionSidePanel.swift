import AppKit
import SwiftUI
import WebKit

/// `chrome.sidePanel` for system WebKit, which has no such API. A script defines the
/// namespace in the extension's worker and pages; the host docks the panel page beside
/// the browser page. Vendor resources remain unchanged.
@MainActor enum ExtensionSidePanelAPI {
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_side_panel__"
    nonisolated static let permission = "sidePanel"

    // ponytail: writes travel one way, as a `tabs.create` the host intercepts — the one
    // host callback every extension context (workers included) can reach. Reads answer
    // from this context's own mirror; a two-way bridge is the upgrade if an extension
    // needs another context's options, `runtime.getContexts` or `onOpened`/`onClosed`.
    nonisolated static let script = #"""
        ;(() => {
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!api?.tabs?.create || !api.runtime?.getManifest || api.sidePanel !== undefined) continue;
              const runtime = api.runtime, tabs = api.tabs, manifest = runtime.getManifest();
              if (!manifest.permissions?.includes('sidePanel')) continue;
              const options = new Map(), behavior = {openPanelOnActionClick: false};
              const send = (op, target, values = {}) => {
                const properties = {url: runtime.getURL('/__vane_side_panel__?' + new URLSearchParams({op, ...values})), active: false};
                if (Number.isInteger(target?.tabId)) properties.openerTabId = target.tabId;
                if (Number.isInteger(target?.windowId)) properties.windowId = target.windowId;
                return tabs.create(properties).then(() => {});
              };
              const reply = (promise, callback) => {
                if (typeof callback !== 'function') return promise;
                promise.then(callback, error => { console.error(error); callback(); });
              };
              const read = tabId => {
                const own = options.get(tabId) ?? {}, shared = options.get(undefined) ?? {};
                const result = {enabled: own.enabled ?? shared.enabled ?? true};
                const path = own.path ?? shared.path ?? manifest.side_panel?.default_path;
                if (path !== undefined) result.path = path;
                if (tabId !== undefined) result.tabId = tabId;
                return result;
              };
              Object.defineProperty(api, 'sidePanel', {configurable: true, value: Object.freeze({
                setOptions(details, callback) {
                  const {tabId, path, enabled} = details ?? {}, own = {...options.get(tabId)}, values = {};
                  if (typeof path === 'string') own.path = values.path = path;
                  if (typeof enabled === 'boolean') { own.enabled = enabled; values.enabled = String(enabled); }
                  options.set(tabId, own);
                  return reply(send('setOptions', {tabId}, values), callback);
                },
                getOptions(details, callback) { return reply(Promise.resolve(read(details?.tabId)), callback); },
                open(details, callback) {
                  // A click in this page counts as the user's gesture; a worker has none to report.
                  const gesture = globalThis.navigator?.userActivation?.isActive ? {gesture: 'true'} : {};
                  return reply(send('open', details, gesture), callback);
                },
                close(details, callback) { return reply(send('close', details), callback); },
                setPanelBehavior(details, callback) {
                  if (typeof details?.openPanelOnActionClick !== 'boolean') return reply(Promise.resolve(), callback);
                  behavior.openPanelOnActionClick = details.openPanelOnActionClick;
                  return reply(send('setPanelBehavior', null, {enabled: String(details.openPanelOnActionClick)}), callback);
                },
                getPanelBehavior(callback) { return reply(Promise.resolve({...behavior}), callback); },
                getLayout(callback) { return reply(Promise.resolve({side: 'right'}), callback); }
              })});
            } catch (error) { console.error(error); }
          }
        })();
        """#

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }

    static func declared(_ manifest: [String: Any]) -> Bool {
        (manifest["permissions"] as? [String])?.contains(permission) == true
    }

    /// `nil` means inherit: a tab from the extension, the extension from its manifest.
    struct Options: Equatable {
        var path: String?
        var enabled: Bool?
    }

    enum Operation: String { case setOptions, open, close, setPanelBehavior }

    struct Request: Equatable {
        let operation: Operation
        var options = Options()
        /// The calling page's own report of a user gesture; only `open` reads it.
        var gesture = false

        /// Only the owning extension's bridge URL is a request; anything else is a tab.
        nonisolated init?(_ url: URL?, base: URL) {
            guard let url, url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path == bridgePath,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard let operation = value("op").flatMap(Operation.init) else { return nil }
            self.operation = operation
            options = Options(path: value("path"), enabled: value("enabled").flatMap(Bool.init))
            gesture = value("gesture") == "true"
        }
    }

    /// The panel page: inside the owning extension, and never the bridge itself.
    nonisolated static func page(_ path: String, base: URL) -> URL? {
        guard let components = URLComponents(string: path), components.scheme == nil, components.host == nil,
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.path != bridgePath, url.path != "/" else { return nil }
        return url
    }

    nonisolated static let width: CGFloat = 360
    nonisolated static let minWidth: CGFloat = 280
    /// What the page keeps beside a panel: the Library's guarantee.
    nonisolated static let minPage: CGFloat = 420

    /// The panel's width in `available` points shared with the page: narrower before the
    /// page gives up its minimum, and `nil` (hidden, still open) when both cannot fit.
    nonisolated static func width(sharing available: CGFloat) -> CGFloat? {
        let room = min(width, available - minPage)
        return room >= minWidth ? room : nil
    }
}

/// One open panel: an extension page for one tab, or for a whole window when `tabID` is nil.
@MainActor final class ExtensionSidePanel: NSObject, WKUIDelegate {
    let context: WKWebExtensionContext
    let web: WKWebView
    let tabID: Tab.ID?
    private(set) weak var tab: Tab?
    /// A tab's panel follows it to another window.
    weak var store: TabStore?
    /// What the options last asked for, whatever the page has since made of its URL.
    var page: URL
    var didClose: ((ExtensionSidePanel) -> Void)?
    var openExternal: ((URL) -> Void)?

    init(context: WKWebExtensionContext, web: WKWebView, page: URL, tab: Tab?, store: TabStore) {
        self.context = context
        self.web = web
        self.page = page
        self.tab = tab
        tabID = tab?.id
        self.store = store
    }

    /// The page's own `window.close()` is how an extension dismisses its panel.
    func webViewDidClose(_ webView: WKWebView) { didClose?(self) }

    /// A panel has no tabs of its own; its new-window links belong in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" || url.scheme == "http" { openExternal?(url) }
        return nil
    }
}

/// The panel as a second card on the page's trailing side. The page gives up the width.
struct ExtensionSidePanelDock: ViewModifier {
    @ObservedObject var host: ExtensionHost
    let store: TabStore
    /// Read by the caller so a tab switch re-evaluates which panel this window shows.
    let current: Tab.ID?
    var radius: CGFloat = Look.pageRadius
    var edgeToEdge = false
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let panel = host.sidePanel(in: store)
            // Flush pages have no card gap to part them, so a split-view hairline does.
            let gap = edgeToEdge ? Look.splitDivider : Look.cardGap
            let width = panel == nil ? nil : ExtensionSidePanelAPI.width(sharing: geometry.size.width - gap)
            HStack(spacing: 0) {
                content
                // Only this slot animates: its width, which the page gives up frame by
                // frame, and the panel's fade. Nothing in the page's own content joins in.
                ZStack(alignment: .leading) {
                    if let panel, let width {
                        VStack(spacing: 0) {
                            ExtensionSidePanelHeader(host: host, panel: panel)
                            Color(nsColor: .separatorColor).frame(height: Look.splitDivider)
                            ExtensionSidePanelPage(web: panel.web)
                                .accessibilityLabel("\(panel.context.webExtension.displayName ?? "Extension") side panel")
                        }
                            // Behind the hairline, or the window's tint shows through it.
                            .background(Look.panelFill)
                            .id(ObjectIdentifier(panel))
                            .frame(width: width)
                            .modifier(BrowserPageSurface(radius: radius, edgeToEdge: edgeToEdge))
                            .padding(.leading, gap)
                            .background(alignment: .leading) {
                                if edgeToEdge { Look.pageRim.frame(width: gap) }
                            }
                            .transition(.opacity)
                    }
                }
                .frame(width: width.map { $0 + gap } ?? 0, alignment: .leading)
                .animation(reduceMotion || batterySaver.isActive ? nil : Look.appear,
                           value: width == nil ? nil : panel.map(ObjectIdentifier.init))
            }
        }
    }
}

/// Whose panel this is, and the one way out that never depends on the extension: Claude's
/// button cannot close its panel, and a window's panel would otherwise last as long as
/// the window.
private struct ExtensionSidePanelHeader: View {
    let host: ExtensionHost
    let panel: ExtensionSidePanel

    var body: some View {
        HStack(spacing: Look.pillGlyphGap) {
            if let icon = host.icon(panel.context, for: nil) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: Look.rowIcon, height: Look.rowIcon)
                    .accessibilityHidden(true)
            }
            Text(panel.context.webExtension.displayName ?? "Extension")
                .font(Look.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            // The dock's own animation fades the card out and returns the page its width.
            Button { host.closeSidePanel(panel) } label: { Image(systemName: "xmark") }
                .buttonStyle(CompactControlStyle()).font(Look.caption)
                .help("Close side panel").accessibilityLabel("Close side panel")
        }
        .padding(.leading, Look.rowInset).padding(.trailing, Look.tabRowTrailingInset)
        .frame(height: Look.rowHeight)
    }
}

private struct ExtensionSidePanelPage: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
