import AppKit
import WebKit

// Deliberately standalone: no Vane code, injected scripts, private APIs or file grants.
@MainActor final class Probe: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        web = WKWebView(frame: .zero)
        web.uiDelegate = self; web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Standalone directory upload probe"
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: URL(string: CommandLine.arguments[1])!))
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        print("picker directories=\(parameters.allowsDirectories) multiple=\(parameters.allowsMultipleSelection)")
        let panel = NSOpenPanel()
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.treatsFilePackagesAsDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            print("picker response=\(response.rawValue) urls=\(panel.urls)")
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        print("policy method=\(action.request.httpMethod ?? "") type=\(action.navigationType.rawValue)")
        decisionHandler(.allow)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { print("content process terminated") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
guard CommandLine.arguments.count == 2,
      let url = URL(string: CommandLine.arguments[1]),
      url.host == "127.0.0.1", url.scheme == "http" else {
    print("Usage: probe http://127.0.0.1:PORT/directory (or /files)")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Probe()
app.delegate = delegate
app.run()
