import JavaScriptCore
import XCTest
@testable import vane

@MainActor final class SiteBoostTrustedInputTests: XCTestCase {
    func testZapRejectsSyntheticClicksHoverAndEscapeBeforeAnySideEffect() throws {
        let context = try XCTUnwrap(JSContext())
        // A minimal DOM supplies geometry and message observation; execute the actual
        // production runtime so removing a trusted-event guard changes its behavior.
        context.evaluateScript(#"""
            var location = {protocol:'https:', origin:'https://boost.invalid'};
            var performance = {timeOrigin:1};
            var crypto = {getRandomValues: value => value.fill(1)};
            var CSS = {escape: value => value};
            class CSSStyleSheet { replaceSync() {} }
            var window = globalThis, listeners = {}, messages = [], prevented = 0, measured = 0;
            window.webkit = {messageHandlers:{vaneBoost:{postMessage: message => messages.push(message)}}};
            window.addEventListener = (type, callback) => listeners[type] = callback;
            window.removeEventListener = type => delete listeners[type];
            var document = {body:{contains:() => true}, documentElement:{append:() => {}},
                createElement:() => ({dataset:{}, style:{setProperty:() => {}}, remove:() => {}}),
                querySelectorAll:() => [target]};
            var target = {id:'ad', parentElement:{}, getRootNode:() => document,
                hasAttribute:() => false, getBoundingClientRect:() => {measured++; return {x:0,y:0,width:10,height:10}}};
            function event(trusted) {return {isTrusted:trusted, target, key:'Escape',
                preventDefault:() => prevented++, stopImmediatePropagation:() => {}};}
            """#)
        context.evaluateScript(SiteBoostScripts.runtime)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        context.evaluateScript("window.__vaneBoost.zap(true); messages = []; listeners.pointermove(event(false)); listeners.click(event(false)); listeners.pointerdown(event(false)); listeners.keydown(event(false));")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("prevented")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("measured")?.toInt32(), 0)
        XCTAssertTrue(context.evaluateScript("window.__vaneBoost.zapping")?.toBool() == true)
        // The positive path proves the target and active session are selectable.
        context.evaluateScript("listeners.pointermove(event(true)); listeners.click(event(true));")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        XCTAssertEqual(context.evaluateScript("messages[0].kind")?.toString(), "pick")
        XCTAssertEqual(context.evaluateScript("messages[0].selector")?.toString(), "#ad")
        XCTAssertEqual(context.evaluateScript("measured")?.toInt32(), 1)
        context.evaluateScript("listeners.keydown(event(true));")
        XCTAssertFalse(context.evaluateScript("window.__vaneBoost.zapping")?.toBool() ?? true)
        XCTAssertEqual(context.evaluateScript("messages[1].kind")?.toString(), "done")
    }
}
