import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class MediaControlsWebKitTests: XCTestCase {
    // Two-second H.264 blue frame fixture; looped locally without a network service.
    private static let video = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQkbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAA050cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAoAAAAFoAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAIAAABAAAAAALGbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAUABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACcW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjFzdGJsAAAAwXN0c2QAAAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAoABaABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAW/+EAGmdkABas2UCgL/lwEQAAAwABAAADABQPFi2WAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABK0AAAAAAAAABhzdHRzAAAAAAAAAAEAAAAUAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAqGN0dHMAAAAAAAAAEwAAAAEAAAgAAAAAAQAAFAAAAAABAAAIAAAAAAEAAAAAAAAAAQAABAAAAAABAAAUAAAAAAEAAAgAAAAAAQAAAAAAAAABAAAEAAAAAAEAABQAAAAAAQAACAAAAAABAAAAAAAAAAEAAAQAAAAAAQAAFAAAAAABAAAIAAAAAAEAAAAAAAAAAQAABAAAAAABAAAQAAAAAAIAAAQAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAUAAAAAQAAAGRzdHN6AAAAAAAAAAAAAAAUAAADGAAAABUAAAATAAAAEwAAABMAAAAbAAAAFQAAABMAAAATAAAAHAAAABUAAAATAAAAEwAAABwAAAAVAAAAEwAAABMAAAAbAAAAFQAAABMAAAAUc3RjbwAAAAAAAAABAAAEVAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAyAAAACGZyZWUAAAS1bWRhdAAAAq8GBf//q9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xMSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAABhZYiEABH//ufj/AptfMRxOnYY+vfW13Ki6NeHVxiFPILozGR/X1AAAAMAAAMAABQlR7IzW8C6BqQAAAMBJgAn4NgIaGCFwGoHeKCOoUwgBAAAAwAAAwAAAwAAAwAAAwAFvQAAABFBmiRsQR/+tSqAAAADAAAdUAAAAA9BnkJ4h38AAAMAAAMAcsEAAAAPAZ5hdEN/AAADAAADAKSAAAAADwGeY2pDfwAAAwAAAwCkgQAAABdBmmhJqEFomUwII//+tSqAAAADAAAdUQAAABFBnoZFESw7/wAAAwAAAwBywQAAAA8BnqV0Q38AAAMAAAMApIEAAAAPAZ6nakN/AAADAAADAKSAAAAAGEGarEmoQWyZTAgh//6qVQAAAwAAAwA6oAAAABFBnspFFSw7/wAAAwAAAwBywQAAAA8Bnul0Q38AAAMAAAMApIAAAAAPAZ7rakN/AAADAAADAKSAAAAAGEGa8EmoQWyZTAh///6plgAAAwAAAwDlgQAAABFBnw5FFSw7/wAAAwAAAwBywQAAAA8Bny10Q38AAAMAAAMApIEAAAAPAZ8vakN/AAADAAADAKSAAAAAF0GbM0moQWyZTAhv//6nhAAAAwAAAwHHAAAAEUGfUUUVLDf/AAADAAADAKSBAAAADwGfcmpDfwAAAwAAAwCkgA=="

    private func wait(line: Int = #line, _ condition: () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while try await !condition() {
            if Date.now >= deadline { throw NSError(domain: "MediaFixtureTimeout at line \(line)", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func fixture(_ html: String) async throws -> (Tab, NSWindow) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://media.example.test/"))
        addTeardownBlock { @MainActor in
            tab.tearDown()
            window.close()
        }
        try await wait { !tab.web.isLoading }
        return (tab, window)
    }

    func testEmbeddedPlayerCanPauseAndResumeWithoutStartingMainFrameDecoy() async throws {
        let player = "<video id='player' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video>" +
            "<script>navigator.mediaSession.metadata=new MediaMetadata({title:'Embedded movie'});</script>"
        let quoted = player.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let (tab, _) = try await fixture("<video id='decoy'></video><iframe id='embedded' srcdoc=\"" + quoted + "\"></iframe>")
        let paused = "document.getElementById('embedded').contentDocument.getElementById('player').paused"
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        MediaState.shared.send(.playpause, to: tab)
        try await Task.sleep(for: .milliseconds(250))
        let isPaused = try await tab.web.evaluateJavaScript(paused) as? Bool
        XCTAssertEqual(isPaused, true,
                       "The sidebar pause must reach the iframe that is actually playing")
        XCTAssertEqual(MediaState.shared.info(for: tab.id)?.title, "Embedded movie")
        MediaState.shared.send(.playpause, to: tab)
        try await Task.sleep(for: .milliseconds(250))
        let isResumed = try await tab.web.evaluateJavaScript(paused) as? Bool
        XCTAssertEqual(isResumed, false)
        let decoyPaused = try await tab.web.evaluateJavaScript("document.getElementById('decoy').paused") as? Bool
        XCTAssertEqual(decoyPaused, true)
    }

    func testPausedTrayKeepsItsPlayerWhenAnotherFrameStartsPlaying() async throws {
        let player = "<video id='player' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video>"
        let quoted = player.replacingOccurrences(of: "\"", with: "&quot;")
        let (tab, _) = try await fixture("<video id='background' muted loop src='data:video/mp4;base64,\(Self.video)'></video><iframe id='embedded' srcdoc=\"" + quoted + "\"></iframe>")
        let paused = "document.getElementById('embedded').contentDocument.getElementById('player').paused"
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == true }
        MediaState.shared.send(.playpause, to: tab)
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == true }
        _ = try await tab.web.evaluateJavaScript("document.getElementById('background').play(); true;")
        try await Task.sleep(for: .milliseconds(100))
        MediaState.shared.send(.playpause, to: tab)
        try await Task.sleep(for: .milliseconds(150))
        let resumed = try await tab.web.evaluateJavaScript(paused) as? Bool
        XCTAssertEqual(resumed, false, "Resume stays with the paused player even while another frame plays")
        let backgroundPaused = try await tab.web.evaluateJavaScript("document.getElementById('background').paused") as? Bool
        XCTAssertEqual(backgroundPaused, false, "Resuming the tray must not pause unrelated background media")
    }

    func testInventingDocumentTokensDoesNotBypassMediaMessageThrottle() async throws {
        let (tab, _) = try await fixture("<p>Quiet fixture</p>")
        _ = try await tab.web.evaluateJavaScript("for(var i=0;i<100;i++) webkit.messageHandlers.vanemedia.postMessage({source:'invented'+i,hasMedia:true,playing:false,title:'Flood '+i}); webkit.messageHandlers.vanemedia.postMessage({source:'last',hasMedia:true,playing:false,title:'Throttle bypassed'}); true;")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(MediaState.shared.info(for: tab.id)?.title, "Throttle bypassed")
    }

    func testSessionOnlyPlayerReportsStateAndUsesItsPauseAndPlayHandlers() async throws {
        let (tab, _) = try await fixture("""
        <script>
        navigator.mediaSession.metadata=new MediaMetadata({title:'Session player'});
        navigator.mediaSession.setActionHandler('play', function() { navigator.mediaSession.playbackState='playing'; });
        navigator.mediaSession.setActionHandler('pause', function() { navigator.mediaSession.playbackState='paused'; });
        navigator.mediaSession.playbackState='playing';
        </script>
        """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(MediaState.shared.info(for: tab.id)?.playing, true)
        MediaState.shared.send(.playpause, to: tab)
        try await wait { try await tab.web.evaluateJavaScript("navigator.mediaSession.playbackState") as? String == "paused" }
        XCTAssertEqual(MediaState.shared.info(for: tab.id)?.playing, false)
        MediaState.shared.send(.playpause, to: tab)
        try await wait { try await tab.web.evaluateJavaScript("navigator.mediaSession.playbackState") as? String == "playing" }
    }

    func testDismissStopsPlaybackWithoutClosingTheTab() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        MediaState.shared.dismiss(tab)
        try await wait { !tab.pictureInPicture }
        try await Task.sleep(for: .milliseconds(200))
        let stopped = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(stopped, true)
        XCTAssertTrue(MediaState.shared.isDismissed(tab.id))
        XCTAssertNotNil(tab.web.url)
    }

    func testCollapsedPiPKeepsItsVideoInsteadOfAPlayingMainFrame() async throws {
        let player = "<video id='player' width='640' height='360' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video>"
        let quoted = player.replacingOccurrences(of: "\"", with: "&quot;")
        let (tab, _) = try await fixture("<video id='background' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video><iframe id='embedded' srcdoc=\"" + quoted + "\"></iframe>")
        let paused = "document.getElementById('embedded').contentDocument.getElementById('player').paused"
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        // The site opens its iframe player directly, as a real embedded-player button does.
        _ = try await tab.web.evaluateJavaScript("document.getElementById('embedded').contentDocument.getElementById('player').webkitSetPresentationMode('picture-in-picture'); true;")
        try await wait { tab.pictureInPicture }
        try await Task.sleep(for: .milliseconds(150))
        MediaState.shared.minimize(tab)
        try await wait { !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        MediaState.shared.send(.playpause, to: tab)
        try await Task.sleep(for: .milliseconds(200))
        let videoPaused = try await tab.web.evaluateJavaScript(paused) as? Bool
        let backgroundPaused = try await tab.web.evaluateJavaScript("document.getElementById('background').paused") as? Bool
        XCTAssertEqual(videoPaused, true, "Collapsed controls must continue targeting the former PiP video")
        XCTAssertEqual(backgroundPaused, false)
    }

    func testReturningReleasesCollapsedVideoSelectionForAnotherPlayer() async throws {
        let (tab, _) = try await fixture("<video id='old' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video><video id='new' muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('old').paused") as? Bool == false }
        _ = try await tab.web.evaluateJavaScript("document.getElementById('old').removeAttribute('autoplay')")
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        var collapsed = false
        MediaState.shared.minimize(tab) { collapsed = $0 }
        try await wait { collapsed && !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('old').paused") as? Bool == false }
        MediaState.shared.returned(to: tab)
        _ = try await tab.web.evaluateJavaScript("document.getElementById('old').pause(); document.getElementById('new').play(); true;")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('new').paused") as? Bool == false }
        try await Task.sleep(for: .milliseconds(100))
        MediaState.shared.send(.playpause, to: tab)
        try await Task.sleep(for: .milliseconds(150))
        let newPaused = try await tab.web.evaluateJavaScript("document.getElementById('new').paused") as? Bool
        let oldPaused = try await tab.web.evaluateJavaScript("document.getElementById('old').paused") as? Bool
        XCTAssertEqual(newPaused, true, "Returning to the tab releases the former PiP video selection")
        XCTAssertEqual(oldPaused, true, "The old video must not restart")
    }

    func testNativePiPMinimizeButtonKeepsVideoPlaying() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' loop autoplay muted src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { (try await tab.web.evaluateJavaScript("document.getElementById('player').readyState") as? Int ?? 0) >= 3 }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        _ = try await tab.web.evaluateJavaScript("document.getElementById('player').removeAttribute('autoplay')")
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        try await Task.sleep(for: .milliseconds(300))
        func minimize(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.minimize" { return button }
            return view.subviews.lazy.compactMap { minimize(in: $0) }.first
        }
        let button = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView }.compactMap { minimize(in: $0) }.first,
                                   "Minimize must be a real control inside the native PiP window")
        let content = try XCTUnwrap(button.window?.contentView)
        XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)), "The minimize button must be inside the visible video panel")
        XCTAssertGreaterThanOrEqual(content.bounds.maxX - button.frame.maxX, 50, "Minimize leaves space for native restore controls")
        let videoView = try XCTUnwrap(content.subviews.first { NSStringFromClass(type(of: $0)) == "WebVideoViewContainer" })
        let originalSize = content.frame.size
        content.setFrameSize(NSSize(width: originalSize.width * 0.8, height: originalSize.height * 0.8))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(videoView.frame.width, content.bounds.width, accuracy: 1, "Video width follows PiP resizing")
        XCTAssertEqual(videoView.frame.height, content.bounds.height, accuracy: 1, "Video height follows PiP resizing")
        content.setFrameSize(originalSize)
        // A later unrelated video must not steal the active PiP frame.
        _ = try await tab.web.evaluateJavaScript("var ad=document.createElement('iframe'); ad.id='ad'; ad.srcdoc=\"<video preload='auto' src='data:video/mp4;base64,\(Self.video)'></video>\"; document.body.appendChild(ad); true;")
        try await wait { (try await tab.web.evaluateJavaScript("document.getElementById('ad').contentDocument?.querySelector('video')?.readyState || 0") as? Int ?? 0) >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tab.pipFrame?.isMainFrame, true, "A new ad frame must not replace the active PiP frame")
        button.performClick(nil)
        try await wait { !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(paused, false, "Minimize must preserve playback")
        XCTAssertTrue(MediaState.shared.held.contains(tab.id), "Sidebar controls remain available after minimizing")
    }
}
