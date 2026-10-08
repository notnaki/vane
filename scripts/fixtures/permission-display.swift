import AppKit
import WebKit

/// Standalone app host: getDisplayMedia requires an active document, which XCTest's
/// command-line host cannot reliably provide. Only WebKit's fake display is used.
@MainActor final class DisplayFixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let result = URL(fileURLWithPath: CommandLine.arguments[1])

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.setValue(true, forKey: "mockCaptureDevicesEnabled")
        cfg.preferences.setValue(false, forKey: "mockCaptureDevicesPromptEnabled")
        cfg.preferences.setValue(true, forKey: "screenCaptureEnabled")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: cfg)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Vane synthetic display fixture"
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
        let child = """
        <body style='margin:0'><button style='position:absolute;left:40px;top:40px;width:240px;height:70px' onclick='share()'>Share fake screen</button>
        <script>
        function share() {
          parent.displayResult = 'pending';
          navigator.mediaDevices.getDisplayMedia({video:true}).then(s => {
            parent.displayStream = s; parent.displayResult = 'granted';
          }).catch(e => { parent.displayResult = e.name + ': ' + e.message; });
        }
        </script>
        """.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        web.loadHTMLString("<body style='margin:0'><iframe style='width:700px;height:500px;border:0' allow='display-capture' srcdoc=\"\(child)\"></iframe>",
                           baseURL: URL(string: "http://localhost"))
        Task { @MainActor in
            do {
                guard web.configuration.preferences.value(forKey: "mockCaptureDevicesEnabled") as? Bool == true,
                      web.configuration.preferences.value(forKey: "mockCaptureDevicesPromptEnabled") as? Bool == false else {
                    throw failure("Fake display preferences unavailable; refusing to request capture")
                }
                try await wait("active app and document") {
                    NSApp.isActive && self.window.isKeyWindow && !self.web.isLoading
                }
                try await waitJS("document.querySelector('iframe').contentDocument.readyState", equals: "complete")
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 425),
                                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, clickCount: 1, pressure: 1) else { throw failure("No click event") }
                    window.sendEvent(event)
                }
                try await wait("fake display grant") {
                    let state = try await self.js("window.displayResult")
                    if let state, state != "pending", state != "granted" { throw self.failure(state) }
                    return state == "granted"
                }
                guard try await js("displayStream.getVideoTracks()[0].readyState") == "live" else { throw failure("No live fake display") }
                _ = try await js("document.querySelector('iframe').remove(); 'removed'")
                try await waitJS("displayStream.getVideoTracks()[0].readyState", equals: "ended")
                finish(["passed": true, "source": "WebKit fake display", "liveBeforeRemoval": true, "endedAfterRemoval": true])
            } catch { finish(["passed": false, "error": error.localizedDescription]) }
        }
    }

    func js(_ code: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(code) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String) }
            }
        }
    }
    func failure(_ text: String) -> NSError { NSError(domain: "DisplayFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func wait(_ name: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw failure("Timed out: \(name)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func waitJS(_ code: String, equals expected: String) async throws {
        try await wait(code) { try await self.js(code) == expected }
    }
    func finish(_ value: [String: Any]) {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: result)
        window.close()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let fixture = DisplayFixture()
app.setActivationPolicy(.regular)
app.delegate = fixture
app.run()
