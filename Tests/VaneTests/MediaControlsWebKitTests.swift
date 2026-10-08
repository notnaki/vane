import AppKit
import class SwiftUI.NSHostingView
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
            // PiPAgent completes dismissal asynchronously. The next fixture must not
            // open a new presentation while the preceding one is still closing.
            try await Task.sleep(for: .milliseconds(400))
        }
        try await wait { !tab.web.isLoading }
        return (tab, window)
    }

    func testDecodedPlaybackPauseSeekResumeAndEndUpdateTray() async throws {
        let (tab, _) = try await fixture("<video id='player' muted autoplay src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("player.currentTime > 0.15 && player.videoWidth === 640 && player.error === null") as? Bool == true }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == true }
        MediaState.shared.send(.playpause, to: tab)
        try await wait { try await tab.web.evaluateJavaScript("player.paused") as? Bool == true }
        _ = try await tab.web.evaluateJavaScript("player.currentTime=0.5; true")
        try await wait { try await tab.web.evaluateJavaScript("!player.seeking && Math.abs(player.currentTime-0.5)<0.05") as? Bool == true }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == false }
        MediaState.shared.send(.playpause, to: tab)
        try await wait { try await tab.web.evaluateJavaScript("!player.paused && player.currentTime>0.8 && player.error===null") as? Bool == true }
        try await wait { try await tab.web.evaluateJavaScript("player.ended") as? Bool == true }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == false }
    }

    func testDRMProbeInvalidatesSamplesOnSeek() async throws {
        let (tab, _) = try await fixture("<video id='player' muted autoplay src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("player.currentTime>0.15 && player.videoWidth===640") as? Bool == true }
        let firstValue = try await tab.web.evaluateJavaScript(DRMCheck.videoProbe)
        let first = try XCTUnwrap(firstValue as? [String: Any])
        XCTAssertEqual(first["paused"] as? Bool, false)
        _ = try await tab.web.evaluateJavaScript("player.pause(); player.currentTime=0.5; true")
        try await wait {
            let id = try await tab.web.evaluateJavaScript("window.__vaneDrmcheckSample.id") as? String
            return id != first["id"] as? String
        }
        // Hidden WebKit surfaces can defer a paused seek's final frame. Resume to
        // finish the seek, then sample after completion as the CLI would.
        _ = try await tab.web.evaluateJavaScript("player.play(); true")
        try await wait { try await tab.web.evaluateJavaScript("!player.seeking && player.currentTime>0.5") as? Bool == true }
        let seekValue = try await tab.web.evaluateJavaScript(DRMCheck.videoProbe)
        let afterSeek = try XCTUnwrap(seekValue as? [String: Any])
        XCTAssertNotEqual(first["id"] as? String, afterSeek["id"] as? String,
                          "A completed seek must invalidate continuity between native polling ticks")
        XCTAssertNotNil(afterSeek["frames"] as? Int)
        // Hidden XCTest surfaces may suppress compositor frame callbacks. Actual
        // delivered-frame progress is checked separately by the signed CLI probe.
    }

    func testNavigationClearsPlayingMediaAndFreshDocumentCanPlay() async throws {
        let html = "<video id='player' muted autoplay loop src='data:video/mp4;base64,\(Self.video)'></video>"
        let (tab, _) = try await fixture(html)
        try await wait { MediaState.shared.info(for: tab.id)?.playing == true }
        tab.web.loadHTMLString("<title>Quiet replacement</title>", baseURL: nil)
        try await wait { !tab.web.isLoading && tab.web.title == "Quiet replacement" }
        XCTAssertNil(MediaState.shared.info(for: tab.id))
        tab.web.loadHTMLString(html, baseURL: nil)
        try await wait { try await tab.web.evaluateJavaScript("!!document.getElementById('player') && player.currentTime>0.1 && player.error===null") as? Bool == true }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == true }
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
        // The mode event arrives before minimize's playback restoration finishes.
        // Drive collapsed controls after the actual minimize acknowledgement.
        let minimized = await withCheckedContinuation { continuation in
            MediaState.shared.minimize(tab) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(minimized)
        try await wait { !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        let controlled = await withCheckedContinuation { continuation in
            MediaState.shared.send(.playpause, to: tab) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(controlled)
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

    func testPiPUsesAVisibleCustomHostInsteadOfVisibleNativeChrome() async throws {
        let priorShells = Self.visibleSystemPiPWindows()
        var entryShells: Set<Int> = []
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait {
            try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false
        }
        PictureInPicture.toggle(tab)
        try await wait {
            entryShells.formUnion(Self.visibleSystemPiPWindows().subtracting(priorShells))
            return tab.pictureInPicture
        }
        try await wait {
            entryShells.formUnion(Self.visibleSystemPiPWindows().subtracting(priorShells))
            return NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }
        }
        XCTAssertTrue(entryShells.isEmpty, "Entry must bypass the native flying window as well as hide its final shell")
        XCTAssertFalse(NSApp.windows.contains {
            NSStringFromClass(type(of: $0)) == "PIPPanel" && $0.isVisible
        })
        let custom = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible
        })
        custom.setFrame(NSRect(x: 350, y: 260, width: 480, height: 270), display: true)
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(Self.visibleSystemPiPWindows().subtracting(priorShells).isEmpty,
                      "The system PiPAgent shell must disappear, not only Vane's local PIPPanel")
        XCTAssertEqual(custom.frame.origin, NSPoint(x: 350, y: 260))
        XCTAssertTrue(tab.pictureInPicture)
        var minimized = false
        PictureInPicture.minimize(tab) { minimized = $0 }
        try await wait { minimized && !tab.pictureInPicture }
        XCTAssertFalse(custom.isVisible)
        let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(paused, false)
    }

    func testEntryOriginMatchesInlineVideoInAFlippedBrowserHost() async throws {
        let (tab, window) = try await fixture("<video id='player' style='position:absolute;left:123px;top:40px;width:480px;height:270px' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let root = FlippedPiPFixtureView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = root
        tab.web.frame = NSRect(x: 50, y: 20, width: 700, height: 400)
        root.addSubview(tab.web)
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let box = try await tab.web.evaluateJavaScript("var r=document.getElementById('player').getBoundingClientRect(); ({x:r.x,y:r.y,w:r.width,h:r.height})") as? [String: Double]
        let rect = try XCTUnwrap(box)
        let webRect = NSRect(x: rect["x"]!, y: rect["y"]!, width: rect["w"]!, height: rect["h"]!)
        let inline = window.convertToScreen(tab.web.convert(webRect, to: nil))
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let destination = NSRect(x: 350, y: 350, width: 640, height: 360)
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        PictureInPicture.toggle(tab)
        try await wait { NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } }
        let custom = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
        let x = (custom.frame.minX - inline.minX) / (destination.minX - inline.minX)
        let y = (custom.frame.minY - inline.minY) / (destination.minY - inline.minY)
        if TestEnvironment.supportsPiPMotion(in: [inline, destination]) {
            XCTAssertLessThan(x, 0.8, "Observe the flight before it finishes")
            XCTAssertEqual(x, y, accuracy: 0.03, "Entry must follow the line from the media's real on-page position")
        } else {
            XCTAssertEqual(custom.frame, destination, "No-motion entry opens directly at the saved placement")
        }
    }

    func testCustomPiPUsesNaturalAspectRatherThanInlineCSSBox() async throws {
        let (tab, _) = try await fixture("<video id='player' width='320' height='320' style='object-fit:cover' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } }
        let custom = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
        let measured = try await tab.web.evaluateJavaScript("document.getElementById('player').videoWidth / document.getElementById('player').videoHeight")
        let natural = try XCTUnwrap(measured as? Double)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(custom.frame.width / custom.frame.height, natural, accuracy: 0.01)
    }

    func testCollapsedInlineVideoStillGetsAVisiblePiPHost() async throws {
        let (tab, _) = try await fixture("<video id='player' width='0' height='0' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        try await wait {
            NSApp.windows.contains {
                $0.isVisible && ($0.identifier?.rawValue == "vane.pip.window" || NSStringFromClass(type(of: $0)) == "PIPPanel")
            }
        }
        var returned = false
        PictureInPicture.minimize(tab) { returned = $0 }
        try await wait { returned && !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
    }

    private static func visibleSystemPiPWindows() -> Set<Int> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(windows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.PIPAgent",
                  (row[kCGWindowAlpha as String] as? Double ?? 0) > 0 else { return nil }
            return row[kCGWindowNumber as String] as? Int
        })
    }

    func testImmediateKeyboardExitAndRepeatedCustomEntryKeepPlayback() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        for _ in 0..<3 {
            PictureInPicture.toggle(tab)
            try await wait { tab.pictureInPicture }
            try await wait { NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } }
            PictureInPicture.toggle(tab)
            try await wait { !tab.pictureInPicture }
            try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
            XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func testPendingEntryDoesNotReopenAfterPageReturnsInline() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360'></video>")
        let reopened = try await pipJS("""
            const video = document.getElementById('player');
            let mode = 'inline', entries = 0;
            // Model native entry/exit events arriving within the helper's retry delay.
            Object.defineProperty(video, 'webkitPresentationMode', { get: () => mode });
            video.webkitSetPresentationMode = function(next) {
                if (next !== 'picture-in-picture') { return; }
                entries++;
                if (entries > 1) { return; }
                setTimeout(() => {
                    mode = 'picture-in-picture';
                    video.dispatchEvent(new Event('webkitpresentationmodechanged', { bubbles: true }));
                    mode = 'inline';
                    video.dispatchEvent(new Event('webkitpresentationmodechanged', { bubbles: true }));
                }, 10);
            };
            await window.__vanePiP();
            return entries > 1;
            """, tab: tab)
        XCTAssertEqual(reopened, false)
    }

    func testContentProcessTerminationRemovesOnlyItsCustomHost() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        try await wait { NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } }
        tab.webViewWebContentProcessDidTerminate(WKWebView())
        XCTAssertTrue(tab.pictureInPicture)
        tab.webViewWebContentProcessDidTerminate(tab.web)
        XCTAssertFalse(tab.pictureInPicture)
        XCTAssertNil(tab.pipFrame)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
    }

    func testPageInlineExitRemovesCustomHostWithoutPausing() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        try await wait { NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } }
        _ = try await tab.web.evaluateJavaScript("document.getElementById('player').webkitSetPresentationMode('inline')")
        try await wait { !tab.pictureInPicture }
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
        let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(paused, false)
    }

    func testLandingOnSourceTabKeepsTheMinimizedPlayerUntilExplicitlyOpened() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let store = TabStore(isPrivate: true)
        let trayWindow = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 250, height: 150),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        trayWindow.isReleasedWhenClosed = false
        store.tabs = [tab]
        store.current = tab.id
        trayWindow.contentView = NSHostingView(rootView: MediaTrayView().environmentObject(store))
        trayWindow.orderFront(nil)
        defer {
            trayWindow.close()
            TabStore.all.removeAll { $0 === store }
        }
        try await wait { MediaState.shared.info(for: tab.id)?.playing == true }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        var collapsed = false
        MediaState.shared.minimize(tab) { collapsed = $0 }
        try await wait { collapsed && !tab.pictureInPicture }
        store.current = nil
        try await Task.sleep(for: .milliseconds(100))
        store.current = tab.id
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(MediaState.shared.minimized.contains(tab.id),
                      "Landing in the source Space must not dismiss its minimized player")
        XCTAssertTrue(MediaState.shared.held.contains(tab.id))
        let departure: String? = try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(PictureInPicture.autoCommand(enter: true),
                                       in: tab.pipFrame, in: PictureInPicture.world) { result in
                continuation.resume(with: result.map { $0 as? String })
            }
        }
        XCTAssertEqual(departure, "minimized",
                       "Leaving the source tab again must not reopen PiP and replace the tray")
        MediaState.shared.returned(to: tab)
        XCTAssertFalse(MediaState.shared.minimized.contains(tab.id),
                       "Explicitly opening the playing tab still releases the player")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let reopened: String? = try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(PictureInPicture.autoCommand(enter: true),
                                       in: tab.pipFrame, in: PictureInPicture.world) { result in
                continuation.resume(with: result.map { $0 as? String })
            }
        }
        XCTAssertEqual(reopened, "pip", "Explicit opening restores ordinary automatic PiP behavior")
        PictureInPicture.exitIfAuto(tab)
    }

    func testPiPControlsHideOutsideVideoAndFollowItsFrame() async throws {
        let (tab, window) = try await fixture("<p>Hover geometry</p>")
        let controls = PiPMinimizeControls.Attachment(window: window, tab: tab)
        defer { controls.remove() }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        controls.update(pointer: center)
        XCTAssertTrue(controls.panel.isVisible)
        XCTAssertTrue(window.frame.contains(controls.panel.frame))
        window.setFrame(NSRect(x: 400, y: 200, width: 500, height: 300), display: false)
        controls.update(pointer: NSPoint(x: 650, y: 350))
        XCTAssertEqual(controls.panel.frame.maxX, 892)
        XCTAssertEqual(controls.panel.frame.maxY, 494)
        controls.update(pointer: NSPoint(x: 0, y: 0))
        XCTAssertFalse(controls.panel.isVisible, "Minimize must disappear when the pointer leaves the video")
        controls.update(pointer: NSPoint(x: 650, y: 350))
        window.orderOut(nil)
        controls.update(pointer: NSPoint(x: 650, y: 350))
        XCTAssertFalse(controls.panel.isVisible, "A closed or hidden video cannot leave floating controls behind")
    }

    func testPiPRestoreAnimatesToTheCurrentVideoPositionWithoutPausing() async throws {
        let (tab, window) = try await fixture("<style>body { margin: 0 } video { position: absolute; left: 90px; top: 80px; width: 480px; height: 270px }</style><video id='player' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let store = TabStore(isPrivate: true)
        defer { TabStore.all.removeAll { $0 === store } }
        store.tabs = [tab]
        store.current = tab.id
        store.window = window
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        store.current = store.newBlankTab(focus: false).id
        func restore(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap { restore(in: $0) }.first
        }
        var control: NSButton?
        try await wait {
            control = NSApp.windows.compactMap(\.contentView).compactMap { restore(in: $0) }.first
            return control != nil
        }
        let panel = try XCTUnwrap(control?.window)
        try await Task.sleep(for: .milliseconds(350))
        let placement = NSRect(x: 50, y: 50, width: 640, height: 360)
        panel.setFrame(placement, display: true)
        // Neither the entry rectangle nor its window position is still current.
        window.setFrameOrigin(NSPoint(x: 180, y: 170))
        _ = try await tab.web.evaluateJavaScript("player.style.left='140px'; player.style.top='100px'; player.style.width='128px'; player.style.height='72px'; true")
        try await Task.sleep(for: .milliseconds(100))
        let destination = window.convertToScreen(tab.web.convert(NSRect(x: 140, y: 100, width: 128, height: 72), to: nil))
        control?.performClick(nil)
        var moved = false
        for _ in 0..<25 {
            if panel.isVisible {
                let progress = (panel.frame.minX - placement.minX) / (destination.minX - placement.minX)
                if progress > 0.01 && progress < 0.99 { moved = true }
                XCTAssertEqual(progress, (panel.frame.minY - placement.minY) / (destination.minY - placement.minY), accuracy: 0.03)
                XCTAssertEqual(progress, (panel.frame.width - placement.width) / (destination.width - placement.width), accuracy: 0.03)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if TestEnvironment.supportsPiPMotion(in: [placement, destination]) {
            XCTAssertTrue(moved, "Back to Tab must move the live video into the page, rather than only fading")
            XCTAssertEqual(panel.frame.minX, destination.minX, accuracy: 1)
            XCTAssertEqual(panel.frame.minY, destination.minY, accuracy: 1)
            XCTAssertEqual(panel.frame.width, destination.width, accuracy: 1)
            XCTAssertEqual(panel.frame.height, destination.height, accuracy: 1)
        } else {
            XCTAssertFalse(moved)
            XCTAssertEqual(panel.frame, placement, "No-motion return fades at the existing placement")
        }
        let remembered = UserDefaults.vane.string(forKey: CustomPiPWindow.placementKey).map(NSRectFromString)
        XCTAssertEqual(remembered, placement, "Returning must preserve the user's floating placement")
        try await wait { !tab.pictureInPicture }
        try await wait { !panel.isVisible && store.current == tab.id }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(paused, false)
        XCTAssertEqual(store.current, tab.id)
        XCTAssertFalse(MediaState.shared.minimized.contains(tab.id))
    }

    func testEmbeddedPiPReturnsToItsScrolledFrame() async throws {
        let player = "<style>body {margin:0} video {position:absolute;left:20px;top:30px;width:320px;height:180px}</style><video autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>"
        let quoted = player.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let (tab, window) = try await fixture("<style>body{margin:0;height:1500px} iframe{position:absolute;left:100px;top:70px;width:500px;height:300px;border:0}</style><iframe id='embedded' sandbox='allow-scripts' srcdoc=\"" + quoted + "\"></iframe>")
        try await wait { tab.pipFrame?.isMainFrame == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        var panel: CustomPiPWindow?
        try await wait {
            panel = NSApp.windows.first { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } as? CustomPiPWindow
            return panel != nil
        }
        let custom = try XCTUnwrap(panel)
        try await Task.sleep(for: .milliseconds(350))
        let placement = NSRect(x: 50, y: 50, width: 640, height: 360)
        custom.setFrame(placement, display: true)
        _ = try await tab.web.evaluateJavaScript("embedded.style.top='600px'; window.scrollTo(0,400); true")
        try await Task.sleep(for: .milliseconds(100))
        let destination = window.convertToScreen(tab.web.convert(NSRect(x: 120, y: 230, width: 320, height: 180), to: nil))
        func restore(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap(restore).first
        }
        try XCTUnwrap(restore(custom.controlsView)).performClick(nil)
        var moved = false
        for _ in 0..<25 {
            if custom.isVisible && custom.frame != placement { moved = true }
            try await Task.sleep(for: .milliseconds(20))
        }
        if TestEnvironment.supportsPiPMotion(in: [placement, destination]) {
            XCTAssertTrue(moved, "An opaque-origin iframe must receive the same return motion")
            XCTAssertEqual(custom.frame.minX, destination.minX, accuracy: 1)
            XCTAssertEqual(custom.frame.minY, destination.minY, accuracy: 1)
            XCTAssertEqual(custom.frame.size, destination.size)
        } else {
            XCTAssertFalse(moved)
            XCTAssertEqual(custom.frame, placement, "No-motion return fades at the existing placement")
        }
        try await wait { !tab.pictureInPicture && !custom.isVisible }
    }

    func testRestoringSelectedTabKeepsAutomaticPiPEnabled() async throws {
        let (tab, window) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let store = TabStore(isPrivate: true)
        defer { TabStore.all.removeAll { $0 === store } }
        store.tabs = [tab]
        store.current = tab.id
        store.window = window
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        window.orderOut(nil)
        func restore(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap { restore(in: $0) }.first
        }
        var control: NSButton?
        try await wait {
            control = NSApp.windows.compactMap(\.contentView).compactMap { restore(in: $0) }.first
            return control != nil
        }
        control?.performClick(nil)
        try await wait { !tab.pictureInPicture && window.isVisible && !PiPMinimizeControls.isReturningToTab(tab) }
        // The native inline transition can finish before playback resumes. An idle
        // response would test that timing rather than whether minimize suppression cleared.
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let reply: String? = try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(PictureInPicture.autoCommand(enter: true),
                                       in: tab.pipFrame, in: PictureInPicture.world) { result in
                continuation.resume(with: result.map { $0 as? String })
            }
        }
        XCTAssertEqual(reply, "pip", "Restoring the already selected tab must release minimize suppression")
        // Reopening during the native close animation can be ignored. The helper's
        // decision verifies suppression was cleared without testing that OS animation.
        PictureInPicture.exitIfAuto(tab)
    }

    func testCustomPiPMinimizeButtonKeepsVideoPlaying() async throws {
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
                                   "Minimize must be a real control in the custom PiP window")
        let videoWindow = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible
        })
        let controlWindow = try XCTUnwrap(button.window)
        XCTAssertTrue(controlWindow === videoWindow, "Controls and live video share the custom window")
        XCTAssertGreaterThan(controlWindow.level.rawValue, NSWindow.Level.normal.rawValue)
        let content = try XCTUnwrap(videoWindow.contentView)
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

    func testClosingTabRemovesCustomPiPWindow() async throws {
        let (tab, _) = try await fixture("<video width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        PictureInPicture.toggle(tab)
        try await wait {
            NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }
        }
        tab.tearDown()
        try await wait {
            !NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }
        }
    }

    private func pipJS(_ code: String, tab: Tab) async throws -> Bool? {
        try await withCheckedThrowingContinuation { continuation in
            tab.web.callAsyncJavaScript(code, arguments: [:], in: tab.pipFrame, in: PictureInPicture.world) {
                continuation.resume(with: $0.map { $0 as? Bool })
            }
        }
    }

    func testPiPCommandsControlSelectedVideoAndRejectInvalidSeek() async throws {
        let (tab, _) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video><video id='decoy' muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.toggle(tab)
        try await wait { tab.pictureInPicture }
        let paused = try await pipJS("return await (window.__vanePiPControl && window.__vanePiPControl('playpause', 0));", tab: tab)
        XCTAssertEqual(paused, true)
        let playing = try await pipJS("return window.__vanePiPPlayback && window.__vanePiPPlayback().playing;", tab: tab)
        XCTAssertEqual(playing, false)
        let sought = try await pipJS("return await (window.__vanePiPControl && window.__vanePiPControl('seek', 0.75));", tab: tab)
        XCTAssertEqual(sought, true)
        let position = try await tab.web.evaluateJavaScript("document.getElementById('player').currentTime") as? Double
        XCTAssertEqual(try XCTUnwrap(position), 0.75, accuracy: 0.1)
        let invalid = try await pipJS("return await (window.__vanePiPControl && window.__vanePiPControl('seek', NaN));", tab: tab)
        XCTAssertEqual(invalid, false)
        let decoy = try await tab.web.evaluateJavaScript("document.getElementById('decoy').paused") as? Bool
        XCTAssertEqual(decoy, true)
        _ = try await tab.web.evaluateJavaScript("document.getElementById('player').remove()")
        let removed = try await pipJS("return await (window.__vanePiPControl && window.__vanePiPControl('playpause', 0));", tab: tab)
        XCTAssertEqual(removed, false)
    }

    func testSwiftPiPControlsKeepEmbeddedSourceAndRejectRemovedFrame() async throws {
        let player = "<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>"
        let quoted = player.replacingOccurrences(of: "\"", with: "&quot;")
        let (tab, _) = try await fixture("<video id='decoy'></video><iframe id='embedded' srcdoc=\"\(quoted)\"></iframe>")
        let paused = "document.getElementById('embedded').contentDocument.getElementById('player').paused"
        try await wait { try await tab.web.evaluateJavaScript(paused) as? Bool == false }
        _ = try await tab.web.evaluateJavaScript("document.getElementById('embedded').contentDocument.getElementById('player').webkitSetPresentationMode('picture-in-picture'); true;")
        try await wait { tab.pictureInPicture }
        var answer: Bool?
        PictureInPicture.control(.playpause, tab: tab) { answer = $0 }
        try await wait { answer != nil }
        XCTAssertEqual(answer, true)
        let nowPaused = try await tab.web.evaluateJavaScript(paused) as? Bool
        XCTAssertEqual(nowPaused, true)
        var playing: Bool?
        PictureInPicture.playback(tab) { playing = $0?.playing }
        try await wait { playing != nil }
        XCTAssertEqual(playing, false)
        answer = nil
        PictureInPicture.control(.seek(.nan), tab: tab) { answer = $0 }
        XCTAssertEqual(answer, false)
        _ = try await tab.web.evaluateJavaScript("document.getElementById('embedded').remove()")
        answer = nil
        PictureInPicture.control(.playpause, tab: tab) { answer = $0 }
        try await wait { answer != nil }
        XCTAssertEqual(answer, false)
        let decoy = try await tab.web.evaluateJavaScript("document.getElementById('decoy').paused") as? Bool
        XCTAssertEqual(decoy, true)
    }

    func testAutomaticCustomPiPReturnsInlineWithoutPausing() async throws {
        let (tab, window) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        window.makeKeyAndOrderFront(nil)
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        PictureInPicture.enterIfPlaying(tab)
        try await wait { tab.pictureInPicture }
        try await wait {
            NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }
        }
        XCTAssertFalse(NSApp.windows.first { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }?.isKeyWindow == true,
                       "Automatic PiP must not steal keyboard focus")
        PictureInPicture.exitIfAuto(tab)
        try await wait { !tab.pictureInPicture }
        try await wait { try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool == false }
        let paused = try await tab.web.evaluateJavaScript("document.getElementById('player').paused") as? Bool
        XCTAssertEqual(paused, false)
    }

    func testImmediateReentryDuringReturnDoesNotLeaveAnEmptyPanel() async throws {
        let (tab, window) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        func restore(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap(restore).first
        }
        PictureInPicture.toggle(tab)
        var old: CustomPiPWindow?
        try await wait {
            old = NSApp.windows.first { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible } as? CustomPiPWindow
            return old != nil
        }
        let original = try XCTUnwrap(old)
        try await Task.sleep(for: .milliseconds(350))
        let placement = NSRect(x: 50, y: 50, width: 640, height: 360)
        original.setFrame(placement, display: true)
        try XCTUnwrap(restore(original.controlsView)).performClick(nil)
        // Supersede the page's pending 50ms inline confirmation.
        try await wait { !tab.pictureInPicture }
        // A stale failed async request may arrive after native exit has started.
        if TestEnvironment.supportsPiPMotion(in: [placement, window.frame]) {
            try await wait { original.frame != placement }
        }
        PiPMinimizeControls.resumeAfterFailedExit(tab)
        if original.isVisible {
            XCTAssertTrue(original.videoView.superview === original.contentView, "A stale failure cannot reopen an empty live host")
        }
        PictureInPicture.toggle(tab)
        try await wait { !original.isVisible }
        try await wait { tab.pictureInPicture && NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible && $0 !== original } }
        let visible = NSApp.windows.filter { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible }
        XCTAssertEqual(visible.count, 1, "The newer entry must survive the old native return")
        XCTAssertFalse(original.isVisible, "A failed old request must not resurrect its closed panel")
        for case let custom as CustomPiPWindow in visible {
            XCTAssertTrue(custom.videoView.superview === custom.contentView, "Any reopened PiP must contain its live WebKit host")
        }
        try await wait { try await tab.web.evaluateJavaScript("player.paused") as? Bool == false }
    }

    func testTabSelectionDuringPiPReturnIsNotOverridden() async throws {
        let (tab, window) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let store = TabStore(isPrivate: true)
        store.tabs = [tab]
        store.current = tab.id
        store.window = window
        defer { TabStore.all.removeAll { $0 === store } }
        PictureInPicture.toggle(tab)
        func restore(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap { restore(in: $0) }.first
        }
        var button: NSButton?
        try await wait {
            button = NSApp.windows.filter { $0.identifier?.rawValue == "vane.pip.window" }
                .compactMap(\.contentView).compactMap { restore(in: $0) }.first
            return button != nil
        }
        let other = store.newBlankTab(focus: false)
        store.current = other.id
        button?.performClick(nil)
        // Return reveals the source first; the user then selects a different tab.
        store.current = other.id
        try await wait { !tab.pictureInPicture }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.current, other.id)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
    }

    func testNavigationDuringPiPReturnDoesNotRevealReplacementPage() async throws {
        let (tab, window) = try await fixture("<video id='player' width='640' height='360' autoplay muted loop src='data:video/mp4;base64,\(Self.video)'></video>")
        let store = TabStore(isPrivate: true)
        store.tabs = [tab]
        store.current = tab.id
        store.window = window
        defer { TabStore.all.removeAll { $0 === store } }
        PictureInPicture.toggle(tab)
        func restore(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "vane.pip.restore" { return button }
            return view.subviews.lazy.compactMap { restore(in: $0) }.first
        }
        var button: NSButton?
        try await wait {
            button = NSApp.windows.filter { $0.identifier?.rawValue == "vane.pip.window" }
                .compactMap(\.contentView).compactMap { restore(in: $0) }.first
            return button != nil
        }
        let other = store.newBlankTab(focus: false)
        store.current = other.id
        button?.performClick(nil)
        // Return reveals the source first; the user then selects a different tab.
        store.current = other.id
        tab.web.loadHTMLString("<p>Replacement page</p>", baseURL: URL(string: "https://replacement.example.test/"))
        try await wait { !tab.web.isLoading && tab.pipFrame == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.current, other.id)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "vane.pip.window" && $0.isVisible })
    }
}

@MainActor private final class FlippedPiPFixtureView: NSView {
    override var isFlipped: Bool { true }
}
