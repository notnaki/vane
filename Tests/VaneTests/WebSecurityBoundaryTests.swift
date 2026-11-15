import Foundation
import JavaScriptCore
import XCTest
@testable import vane

@MainActor final class WebSecurityBoundaryTests: XCTestCase {
    func testDeveloperModeRequiresAParsedLoopbackAddress() {
        for host in ["127.attacker.example", "127.0.0.1.attacker.example", "127.999.1.1", "128.0.0.1"] {
            XCTAssertFalse(DeveloperMode.isLocal(URL(string: "https://\(host)/")), host)
        }
        for host in ["127.0.0.1", "127.255.2.3", "[::1]", "[0:0:0:0:0:0:0:1]", "localhost", "api.localhost"] {
            XCTAssertTrue(DeveloperMode.isLocal(URL(string: "http://\(host)/")), host)
        }
    }
    func testPlayingInlineTransitionDoesNotRequestTabActivation() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var window = this, messages = [], listeners = {};
            var document = {
                querySelectorAll: function () { return []; },
                addEventListener: function (name, listener) { listeners[name] = listener; }
            };
            var webkit = {messageHandlers: {vanepip: {postMessage: function (value) { messages.push(value); }}}};
            """)
        context.evaluateScript(PictureInPicture.script)
        XCTAssertNil(context.exception)
        context.evaluateScript("""
            var video = {webkitPresentationMode: 'picture-in-picture', paused: false,
                         getAttribute: function () { return null; }};
            listeners.webkitpresentationmodechanged({target: video});
            video.webkitPresentationMode = 'inline';
            listeners.webkitpresentationmodechanged({target: video});
            """)
        XCTAssertNil(context.exception)
        let messages = try XCTUnwrap(context.evaluateScript("messages")?.toArray())
        XCTAssertEqual(messages.count, 2, "A page-controlled mode transition may only report playback state")
        XCTAssertFalse(messages.contains { ($0 as? String) == "return" })
    }

}
