import AppKit
import WebKit

/// `vane drmcheck` — the one runnable check behind the DRM claim. Asks the engine, in a
/// real https origin, which key systems can initialize. This is capability evidence,
/// not subscription-service or license-exchange verification.
@MainActor enum DRMCheck {
    private static var web: WKWebView?
    private static var holder: NSWindow?
    private static var poller: Timer?
    // Actor state, not locals: a local captured by the MainActor closure below is
    // task-isolated, and newer Swift rejects mutating it from inside.
    private static var tick = 0
    private static var previousTime: Double?
    private static var previousVideoID: String?
    private static var previousFrames: Int?
    enum PlaybackResult { case unverified, withoutKeys, keysAttached }

    static func playbackResult(time: Double, previousTime: Double? = nil, width: Int, hasKeys: Bool, error: Int?,
                               paused: Bool = false, seeking: Bool = false,
                               frames: Int? = nil, previousFrames: Int? = nil) -> PlaybackResult {
        guard let previousTime, previousTime.isFinite, time.isFinite,
              time > 1, time > previousTime + 0.05, width > 0, error == nil,
              !paused, !seeking, let frames, let previousFrames, frames > previousFrames else { return .unverified }
        return hasKeys ? .keysAttached : .withoutKeys
    }

    /// With a URL: report decoded progress and modern media-key attachment separately.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
            FileHandle.standardError.write(Data("drmcheck: playback probe timed out\n".utf8))
            exit(2)
        }

        poller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                w.evaluateJavaScript(videoProbe) { result, _ in
                    let state = result as? [String: Any] ?? [:]
                    print("  t+\(tick * 3)s  \(state)")
                    let videoID = state["id"] as? String
                    let time = state["time"] as? Double ?? 0
                    let frames = state["frames"] as? Int
                    let evidence = playbackResult(time: state["time"] as? Double ?? 0,
                                                  previousTime: videoID != nil && videoID == previousVideoID ? previousTime : nil,
                                                  width: state["width"] as? Int ?? 0,
                                                  hasKeys: state["keys"] as? Bool ?? false,
                                                  error: state["error"] as? Int,
                                                  paused: state["paused"] as? Bool ?? true,
                                                  seeking: state["seeking"] as? Bool ?? true,
                                                  frames: frames,
                                                  previousFrames: videoID != nil && videoID == previousVideoID ? previousFrames : nil)
                    previousVideoID = videoID
                    previousTime = time
                    previousFrames = frames
                    if tick >= 15 || evidence != .unverified {
                        poller?.invalidate()
                        print("")
                        switch evidence {
                        case .withoutKeys: print("=> PLAYING (decoded progress; no modern media keys attached)")
                        case .keysAttached: print("=> PLAYING (decoded progress; modern media keys attached)")
                        case .unverified: print("=> playback unverified (requires progress, decoded width and no media error)")
                        }
                        print("Asset encryption, license exchange and subscription compatibility require separate verification.")
                        exit(evidence == .unverified ? 1 : 0)
                    }
                }
            }
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    /// Finds the biggest <video> on the page, nudges it into playing, and reports its state.
    static let videoProbe = """
    (function () {
      var vs = Array.prototype.slice.call(document.querySelectorAll('video'));
      if (!vs.length) {
        return {status:'no video'};
      }
      vs.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
      var v = vs[0];
      var sample = window.__vaneDrmcheckSample;
      if (!sample || sample.video !== v) {
        sample = window.__vaneDrmcheckSample = {video:v,id:Math.random().toString(36),frames:0};
        if (v.requestVideoFrameCallback) {
          var delivered = function() {
            if (window.__vaneDrmcheckSample !== sample || !v.isConnected) return;
            sample.frames++;
            v.requestVideoFrameCallback(delivered);
          };
          v.requestVideoFrameCallback(delivered);
        }
        // Invalidate continuity even if a seek completes between native polling ticks.
        ['seeking','emptied'].forEach(function(type){v.addEventListener(type,function(){sample.id=Math.random().toString(36);});});
      }
      if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); }
      var quality = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
      // Native HLS can expose zero quality counters while delivering frame callbacks.
      var frames = v.requestVideoFrameCallback ? sample.frames :
        (quality ? quality.totalVideoFrames - quality.droppedVideoFrames : v.webkitDecodedFrameCount);
      return {id:sample.id,time:v.currentTime,ready:v.readyState,width:v.videoWidth,keys:!!v.mediaKeys,error:v.error ? v.error.code : null,
        paused:v.paused,seeking:v.seeking,frames:typeof frames==='number'?frames:null};
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
            print(ok ? "=> FairPlay CDM initialized; service compatibility remains unverified."
                     : "=> FairPlay unavailable in this probe; service compatibility remains unverified.")
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
