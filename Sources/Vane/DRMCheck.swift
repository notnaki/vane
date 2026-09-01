import AppKit
import WebKit

/// `vane drmcheck` — the one runnable check behind the DRM claim. Asks the engine, in a
/// real https origin, which key systems it will actually hand out. Netflix/Disney+ need a
/// YES from a FairPlay (com.apple.fps) or Widevine (com.widevine.alpha) line; clearkey
/// alone means EME is wired up but no premium content will ever decrypt.
@MainActor enum DRMCheck {
    private static var web: WKWebView?
    private static var holder: NSWindow?
    private static var poller: Timer?
    // Actor state, not locals: a local captured by the MainActor closure below is
    // task-isolated, and newer Swift rejects mutating it from inside.
    private static var tick = 0
    private static var best = 0.0

    /// With a URL: load a real page and report whether a <video> actually advances —
    /// end-to-end proof that a DRM licence was fetched and frames are decrypting.
    static func run(url: String?) -> Never {
        if let url, let u = URL(string: url) { play(u) }
        probeOnly()
    }

    private static func probeOnly() -> Never {
        let cfg = Tab.configuration()
        let bridge = Bridge()
        cfg.userContentController.add(bridge, name: "vane")
        let w = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 600), configuration: cfg)
        w.customUserAgent = safariUA
        web = w
        // WebKit will not run a page for a view that was never hosted; a real (offscreen)
        // window is the cheapest way to give it one.
        let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = w
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.orderFront(nil)
        holder = win
        // Simulated response so the probe runs in a real https origin — EME refuses to
        // answer in a non-secure context, and about:blank would give a false negative.
        w.loadSimulatedRequest(URLRequest(url: URL(string: "https://vane.test/drmcheck")!),
                               responseHTML: probe)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("drmcheck: timed out\n".utf8))
            exit(2)
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    private static func play(_ url: URL) -> Never {
        let w = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800),
                          configuration: Tab.configuration())
        w.customUserAgent = safariUA
        web = w
        let win = NSWindow(contentRect: w.frame, styleMask: [.titled, .resizable],
                           backing: .buffered, defer: false)
        win.contentView = w
        win.title = "vane playtest"
        win.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        w.load(URLRequest(url: url))
        print("loading \(url.absoluteString) — polling for a playing <video>...")

        poller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                w.evaluateJavaScript(videoProbe) { result, _ in
                    let line = (result as? String) ?? "no result"
                    print("  t+\(tick * 3)s  \(line)")
                    if let t = Double(line.split(separator: " ").first(where: { $0.hasPrefix("time=") })?
                        .dropFirst(5) ?? "") { best = max(best, t) }
                    if tick >= 15 || best > 1.0 {
                        poller?.invalidate()
                        print("")
                        print(best > 1.0
                            ? "=> PLAYING (reached \(best)s of protected video)"
                            : "=> no playback (video never advanced past 1s)")
                        exit(best > 1.0 ? 0 : 1)
                    }
                }
            }
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    /// Finds the biggest <video> on the page, nudges it into playing, and reports its state.
    private static let videoProbe = """
    (function () {
      var vs = Array.prototype.slice.call(document.querySelectorAll('video'));
      if (!vs.length) {
        return 'no <video> yet | ' + document.title + ' | '
          + (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 160);
      }
      vs.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
      var v = vs[0];
      if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); }
      var keys = v.mediaKeys ? 'keys=yes' : 'keys=no';
      var err = v.error ? ' error=' + v.error.code : '';
      return 'time=' + v.currentTime.toFixed(2) + ' ready=' + v.readyState + ' ' + keys + err;
    })()
    """

    private final class Bridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            let lines = (m.body as? [String]) ?? ["unexpected payload: \(m.body)"]
            print("engine:     WKWebView (WebKit) — macOS system engine")
            print("user agent: \(safariUA)")
            print("")
            lines.forEach { print($0) }
            print("")
            let ok = lines.contains { $0.contains("com.apple.fps") && $0.contains("YES") }
            print(ok ? "=> FairPlay available: premium streaming has a decrypt path."
                     : "=> No FairPlay: Netflix/Disney+ will not play in this engine.")
            exit(ok ? 0 : 1)
        }
    }

    private static let probe = """
    <!doctype html><meta charset=utf-8><body><script>
    window.onerror = function (m) { webkit.messageHandlers.vane.postMessage(['js error: ' + m]); };
    var systems = [
      ['com.apple.fps',        'FairPlay (modern)'],
      ['com.apple.fps.1_0',    'FairPlay (legacy)'],
      ['com.widevine.alpha',   'Widevine'],
      ['com.microsoft.playready', 'PlayReady'],
      ['org.w3.clearkey',      'Clear Key (no premium content)']
    ];
    var config = [{
      initDataTypes: ['sinf', 'cenc', 'keyids'],
      videoCapabilities: [
        { contentType: 'video/mp4; codecs="avc1.42E01E"' },
        { contentType: 'video/mp4; codecs="hvc1.1.6.L93.B0"' }
      ],
      audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }]
    }];
    function pad(s) { while (s.length < 34) s += ' '; return s; }
    function probe(entry) {
      var id = entry[0], label = entry[1];
      if (!navigator.requestMediaKeySystemAccess) {
        return Promise.resolve(pad(label) + 'no  (EME missing entirely)');
      }
      return navigator.requestMediaKeySystemAccess(id, config)
        // Access alone only says the engine knows the name. Instantiating the CDM is what
        // proves a real decrypt path exists.
        .then(function (access) { return access.createMediaKeys(); })
        .then(function () { return pad(label) + 'YES (' + id + ', CDM loads)'; })
        .catch(function (e) { return pad(label) + 'no  (' + (e && e.name ? e.name : e) + ')'; });
    }
    Promise.all(systems.map(probe)).then(function (rows) {
      webkit.messageHandlers.vane.postMessage(rows);
    });
    </script></body>
    """
}
