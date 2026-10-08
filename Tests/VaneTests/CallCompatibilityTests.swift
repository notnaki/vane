import AppKit
import WebKit
import XCTest
@testable import vane

/// Synthetic video and two in-page peers: no camera, microphone or remote participant.
@MainActor final class CallCompatibilityTests: XCTestCase {
    func testSyntheticCallInterruptionReconnectAndSourceStop() async throws {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            _ = try? await tab.web.evaluateJavaScript("cleanup(); true")
            tab.tearDown()
            window.close()
        }
        tab.web.loadHTMLString(Self.page, baseURL: URL(string: "https://call.example.test/"))
        try await compatibilityWait { try await tab.web.evaluateJavaScript("typeof connect === 'function'") as? Bool == true }
        _ = try await tab.web.evaluateJavaScript("connect().catch(e => failure=String(e)); true")
        try await connected(tab)
        let first = try await decoded(tab)
        try await compatibilityWait { try await self.decoded(tab) > first + 3 }

        _ = try await tab.web.evaluateJavaScript("sender.replaceTrack(null).then(()=>interrupted=true).catch(e=>failure=String(e)); true")
        try await compatibilityWait { try await tab.web.evaluateJavaScript("interrupted") as? Bool == true }
        // Drain frames already in flight, then prove the interruption stopped delivery.
        try await Task.sleep(for: .milliseconds(500))
        let stopped = try await decoded(tab)
        try await Task.sleep(for: .milliseconds(400))
        let duringInterruption = try await decoded(tab)
        XCTAssertEqual(duringInterruption, stopped)
        _ = try await tab.web.evaluateJavaScript("sender.replaceTrack(source.getVideoTracks()[0]).catch(e=>failure=String(e)); true")
        try await compatibilityWait { try await self.decoded(tab) > stopped + 3 }

        _ = try await tab.web.evaluateJavaScript("left.close(); right.close(); oldClosed=left.connectionState==='closed' && right.connectionState==='closed'; connect().catch(e=>failure=String(e)); true")
        let oldClosed = try await tab.web.evaluateJavaScript("oldClosed") as? Bool
        XCTAssertEqual(oldClosed, true)
        try await connected(tab)
        let reconnected = try await decoded(tab)
        try await compatibilityWait { try await self.decoded(tab) > reconnected + 3 }

        _ = try await tab.web.evaluateJavaScript("cleanup(); true")
        let ended = try await tab.web.evaluateJavaScript("source.getTracks().every(t=>t.readyState==='ended') && left.connectionState==='closed' && right.connectionState==='closed' && remote.srcObject===null") as? Bool
        XCTAssertEqual(ended, true)
        let failure = try await tab.web.evaluateJavaScript("failure") as? String
        XCTAssertEqual(failure, "")
    }

    private func connected(_ tab: Tab) async throws {
        try await compatibilityWait {
            try await tab.web.evaluateJavaScript("failure || (left.connectionState==='connected' && right.connectionState==='connected' && remote.videoWidth===320)") as? Bool == true
        }
    }

    private func decoded(_ tab: Tab) async throws -> Int {
        let value = try await tab.web.callAsyncJavaScript("const stats=await right.getStats(); let frames=0; stats.forEach(s=>{if(s.type==='inbound-rtp' && s.kind==='video') frames+=s.framesDecoded||0}); return frames;",
                                                        arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? Int)
    }

    private static let page = """
    <canvas id="canvas" width="320" height="180"></canvas><video id="remote" autoplay muted playsinline></video>
    <script>
    let failure='', left, right, sender, interrupted=false, oldClosed=false;
    let frame=0; const context=canvas.getContext('2d');
    const timer=setInterval(()=>{context.fillStyle=frame++%2?'blue':'green'; context.fillRect(0,0,320,180)},50);
    const source=canvas.captureStream(20);
    async function connect() {
      left=new RTCPeerConnection(); right=new RTCPeerConnection();
      const a=left,b=right;
      a.onicecandidate=e=>{if(e.candidate)b.addIceCandidate(e.candidate).catch(e=>failure=String(e))};
      b.onicecandidate=e=>{if(e.candidate)a.addIceCandidate(e.candidate).catch(e=>failure=String(e))};
      b.ontrack=e=>remote.srcObject=new MediaStream([e.track]);
      sender=a.addTrack(source.getVideoTracks()[0],source);
      await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
      await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
    }
    function cleanup(){clearInterval(timer);source.getTracks().forEach(t=>t.stop());if(left)left.close();if(right)right.close();remote.srcObject=null}
    </script>
    """
}
