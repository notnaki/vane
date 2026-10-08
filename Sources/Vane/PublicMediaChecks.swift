import AppKit
import WebKit

/// Opt-in public demos, never part of deterministic CI or account verification.
@MainActor enum PublicMediaChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() async -> Int32 {
        let tab = Tab(isPrivate: true)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
        defer { tab.tearDown(); window.close() }
        var failures = 0
        for (name, protected) in [
            ("Big Buck Bunny: the Dark Truths of a Video Dev Cartoon (HLS)", false),
            ("Tears of Steel (HLS AVC - FairPlay - SingleKey)", true),
        ] {
            print("START public-media asset=\(name)"); fflush(stdout)
            do {
                try await load(name, tab: tab)
                try await exercise(tab, protected: protected)
                print("PASS public-media asset=\(name)")
            } catch {
                failures += 1
                print("FAIL public-media asset=\(name) error=\(error)")
                if let state = try? await snapshot(tab) { print("STATE \(state)") }
            }
        }
        print("Public demos only: accounts, subscriptions, cross-network calls and system permission revocation UNVERIFIED")
        return failures == 0 ? 0 : 1
    }

    private static func js(_ tab: Tab, _ script: String) async throws -> Any? {
        try await tab.web.evaluateJavaScript(script)
    }

    private static func wait(_ label: String, tab: Tab, _ script: String) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        while try await js(tab, script) as? Bool != true {
            if ContinuousClock.now >= deadline { throw Failure(description: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func load(_ name: String, tab: Tab) async throws {
        tab.web.loadHTMLString("<title>Public media reset</title>", baseURL: nil)
        try await wait("old document replaced", tab: tab, "document.title==='Public media reset'")
        tab.web.load(URLRequest(url: URL(string: "https://shaka-project.github.io/shaka-player/demo/?build=uncompiled")!))
        try await wait("demo initialized", tab: tab,
                       "typeof shakaDemoMain !== 'undefined' && typeof shakaAssets !== 'undefined' && !!document.querySelector('video')?.ui")
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [name]), encoding: .utf8)!
        _ = try await js(tab, """
        window.probeError=''; window.probeLoaded=false;
        window.probeVideo=document.querySelector('video');
        window.probePlayer=probeVideo.ui.getControls().getPlayer();
        window.probeEvents=[];
        ['pause','waiting','stalled','ended','error'].forEach(type=>probeVideo.addEventListener(type,()=>probeEvents.push({type,time:probeVideo.currentTime,wall:Date.now()})));
        probePlayer.addEventListener('error', e=>probeError=JSON.stringify({code:e.detail.code,category:e.detail.category}));
        window.probeAsset=shakaAssets.testAssets.find(a=>a.name===\(quoted)[0]);
        if(!probeAsset) throw new Error('demo asset missing');
        shakaDemoMain.loadAsset(probeAsset).then(()=>probeLoaded=true).catch(e=>probeError=String(e)); true;
        """)
        try await wait("asset loaded", tab: tab, "probeLoaded && probeVideo.readyState>=2")
    }

    private static func snapshot(_ tab: Tab) async throws -> String {
        try await js(tab, """
        JSON.stringify({time:probeVideo.currentTime,ready:probeVideo.readyState,width:probeVideo.videoWidth,
          paused:probeVideo.paused,keys:!!probeVideo.mediaKeys,keySystem:probePlayer.keySystem(),
          error:probeVideo.error?.code||null,playerError:probeError,
          textTracks:probePlayer.getTextTracks().map(t=>({id:t.id,language:t.language,active:t.active})),
          textVisible:probePlayer.getTextDisplayer()?.isTextVisible()||false,events:probeEvents.slice(-5)})
        """) as? String ?? "unavailable"
    }

    private static func exercise(_ tab: Tab, protected: Bool) async throws {
        _ = try await js(tab, "probeVideo.muted=true; probeVideo.play().catch(e=>probeError=String(e)); true")
        try await wait("decoded progress", tab: tab, "probeVideo.currentTime>1 && probeVideo.videoWidth>0 && !probeVideo.paused")
        let encryption = protected ? "probeVideo.mediaKeys && probePlayer.keySystem()==='com.apple.fps'" : "!probeVideo.mediaKeys"
        guard try await js(tab, "!!(\(encryption))") as? Bool == true else {
            throw Failure(description: "unexpected encryption state")
        }
        // Pause, seek, resume and observe the control outcomes before the sustained run.
        _ = try await js(tab, "probeVideo.pause(); window.probePausedAt=probeVideo.currentTime; true")
        try await Task.sleep(for: .seconds(1))
        guard try await js(tab, "probeVideo.paused && Math.abs(probeVideo.currentTime-probePausedAt)<0.1") as? Bool == true else {
            throw Failure(description: "pause did not hold")
        }
        _ = try await js(tab, "probeVideo.currentTime=30; true")
        try await wait("seek", tab: tab, "!probeVideo.seeking && Math.abs(probeVideo.currentTime-30)<1")
        _ = try await js(tab, "probeVideo.play().catch(e=>probeError=String(e)); true")
        try await wait("resume", tab: tab, "!probeVideo.paused && probeVideo.currentTime>31")
        let captions = try await js(tab, "probePlayer.getTextTracks().length") as? Int ?? 0
        if captions > 0 {
            _ = try await js(tab, "probePlayer.selectTextTrack(probePlayer.getTextTracks()[0]); true")
            try await wait("caption selection", tab: tab, "probePlayer.getTextDisplayer()?.isTextVisible() && probePlayer.getTextTracks().some(t=>t.active)")
            print("PARTIAL public-media captions selected; rendered cue text is not independently verified")
        } else { print("UNVERIFIED public-media captions: asset exposes no text tracks") }
        var prior = try await js(tab, "probeVideo.currentTime") as? Double ?? 0
        _ = try await js(tab, "probeEvents=[]; true")
        for sample in 1...6 {
            try await Task.sleep(for: .seconds(15))
            let time = try await js(tab, "probeVideo.currentTime") as? Double ?? 0
            print("SAMPLE elapsed=\(sample * 15)s \(try await snapshot(tab))")
            fflush(stdout)
            guard time > prior + 10,
                  try await js(tab, "!probeVideo.paused && probeVideo.videoWidth>0 && !probeVideo.error && !probeError && !!(\(encryption))") as? Bool == true else {
                throw Failure(description: "sustained playback stopped or errored")
            }
            prior = time
        }
        // Detach/reload the same asset to exercise a player interruption and recovery.
        _ = try await js(tab, "window.probeRecovered=false; probePlayer.unload().then(()=>shakaDemoMain.loadAsset(shakaDemoMain.selectedAsset)).then(()=>{probeVideo.play().catch(e=>probeError=String(e)); probeRecovered=true}).catch(e=>probeError=String(e)); true")
        try await wait("reload recovery", tab: tab, "probeRecovered && probeVideo.currentTime>1 && probeVideo.videoWidth>0 && !probeVideo.paused && !probeVideo.error && !probeError && !!(\(encryption))")
        print("RECOVERED \(try await snapshot(tab))")
        _ = try await js(tab, "probeVideo.pause(); true")
    }
}
