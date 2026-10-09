#!/usr/bin/env swift
import AppKit
import WebKit

// Run on a logged-in Mac. Unlike the Node scene tests, this compiles and links
// the real shaders in system WebKit. Timing is diagnostic, not a CI budget.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let features = NSSelectorFromString("_features")
let key = NSSelectorFromString("key")
let setter = NSSelectorFromString("_setEnabled:forFeature:")
if WKPreferences.responds(to: features), configuration.preferences.responds(to: setter),
   let all = WKPreferences.perform(features)?.takeUnretainedValue() as? [NSObject],
   let feature = all.first(where: {
       $0.responds(to: key) &&
       $0.perform(key)?.takeUnretainedValue() as? String == "PreferPageRenderingUpdatesNear60FPSEnabled"
   }) {
    typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    unsafeBitCast(configuration.preferences.method(for: setter), to: Setter.self)(
        configuration.preferences, setter, false, feature)
}
let instrumentation = """
window.siteProbe = {errors: [], draws: [], recording: false, passes: 0};
const originalLink = WebGLRenderingContext.prototype.linkProgram;
WebGLRenderingContext.prototype.linkProgram = function(program) {
  originalLink.call(this, program);
  if (!this.getProgramParameter(program, this.LINK_STATUS))
    siteProbe.errors.push(this.getProgramInfoLog(program));
};
const originalDraw = WebGLRenderingContext.prototype.drawArrays;
WebGLRenderingContext.prototype.drawArrays = function(...args) {
  if (siteProbe.recording && siteProbe.passes++ % 2 === 0)
    siteProbe.draws.push(performance.now());
  return originalDraw.apply(this, args);
};
"""
configuration.userContentController.addUserScript(WKUserScript(
    source: instrumentation, injectionTime: .atDocumentStart, forMainFrameOnly: true))
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Vane website rendering check"
window.contentView = web
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

func finish(_ code: Int32) {
    window.close()
    exit(code)
}

class Navigation: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            web.callAsyncJavaScript("""
            const canvas = document.querySelector('[data-galaxy="hero"]');
            if (canvas.dataset.renderer !== 'webgl')
              throw Error('GPU renderer unavailable: ' + siteProbe.errors.join('; '));
            // Explicitly resume on Macs whose system motion preference starts paused.
            const toggle = document.querySelector('.galaxy-toggle');
            if (toggle.getAttribute('aria-pressed') === 'true') toggle.click();
            siteProbe.recording = true;
            const callbacks = [];
            await new Promise(resolve => {
              const start = performance.now();
              function sample(t) {
                callbacks.push(t);
                if (t - start < 8000) requestAnimationFrame(sample); else resolve();
              }
              requestAnimationFrame(sample);
            });
            siteProbe.recording = false;
            if (siteProbe.draws.length < 2) throw Error('Galaxy did not animate');
            const rate = times => (times.length - 1) * 1000 / (times.at(-1) - times[0]);
            const gaps = siteProbe.draws.slice(1).map((v, i) => v - siteProbe.draws[i]).sort((a,b) => a-b);
            return {renderer: canvas.dataset.renderer, callbackFPS: rate(callbacks),
                    galaxyFPS: rate(siteProbe.draws), p95DrawIntervalMS: gaps[Math.floor(gaps.length * .95)]};
            """, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let metrics):
                    print("PASS: real WebKit GPU scene", metrics ?? "")
                    finish(0)
                case .failure(let error):
                    print("FAIL:", error)
                    finish(1)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("FAIL: page load", error)
        finish(1)
    }
}
let delegate = Navigation()
web.navigationDelegate = delegate
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent("docs")
web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: timed out"); finish(1) }
app.run()
