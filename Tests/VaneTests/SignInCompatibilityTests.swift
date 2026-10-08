import AppKit
import WebKit
import XCTest
@testable import vane

/// Synthetic redirect/MFA-shaped pages, not Google, Microsoft or GitHub verification.
@MainActor final class SignInCompatibilityTests: XCTestCase {
    func testCrossOriginPopupReturnReloadAndLogout() async throws {
        try await exercise(cancel: false)
    }

    func testCancelledPopupLeavesOpenerSignedOutAndCanReopen() async throws {
        try await exercise(cancel: true)
    }

    private func exercise(cancel: Bool) async throws {
        TestEnvironment.prepare()
        let server = try CompatibilityServer()
        addTeardownBlock { @MainActor in server.stop() }
        try await compatibilityWait { server.port != nil }
        let app = try server.url("/app")
        let provider = try server.url("/challenge", host: "localhost")
        let approve = try server.url("/approve", host: "localhost")
        let callback = try server.url("/callback")
        server.redirects["/authorize"] = provider
        server.redirects["/approve"] = callback
        server.pages["/app"] = """
        <title>Fixture app</title><script>
        window.returned=false;
        window.addEventListener('message', e=>{if(e.origin===location.origin && e.data==='complete') returned=true});
        function logout(){localStorage.removeItem('session');document.cookie='session=; Max-Age=0; path=/'}
        </script><button onclick="window.child=window.open('/authorize','_blank')">Sign in</button>
        """
        server.pages["/challenge"] = """
        <title>Synthetic challenge</title><input id="code"><button id="approve" onclick="if(code.value==='123456') location.href='\(approve.absoluteString)'">Continue</button>
        """
        server.pages["/callback"] = """
        <title>Fixture callback</title><script>
        localStorage.setItem('session','synthetic');document.cookie='session=synthetic; path=/; SameSite=Lax';
        opener.postMessage('complete',location.origin);window.close();
        </script>
        """
        let tab = Tab(isPrivate: true)
        let window = host(tab)
        var child: Tab?
        var childWindow: NSWindow?
        var closed = false
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        tab.onPopup = { configuration, _ in
            let made = Tab(popup: configuration, isPrivate: true, profileID: tab.profileID)
            child = made
            childWindow = self.host(made)
            made.onClose = { closed = true }
            return made.web
        }
        addTeardownBlock { @MainActor in
            child?.tearDown(); childWindow?.close(); tab.tearDown(); window.close()
        }
        tab.web.load(URLRequest(url: app))
        try await compatibilityWait { tab.web.title == "Fixture app" }
        _ = try await tab.web.evaluateJavaScript("document.querySelector('button').click(); true")
        try await compatibilityWait { child?.web.title == "Synthetic challenge" }
        if cancel {
            _ = try await child!.web.evaluateJavaScript("window.close(); true")
            try await compatibilityWait { closed }
            let signedOut = try await tab.web.evaluateJavaScript("localStorage.getItem('session')===null && !document.cookie.includes('session=synthetic') && !returned") as? Bool
            XCTAssertEqual(signedOut, true)
            child?.tearDown(); childWindow?.close(); child = nil; closed = false
            _ = try await tab.web.evaluateJavaScript("document.querySelector('button').click(); true")
            try await compatibilityWait { child?.web.title == "Synthetic challenge" }
        }
        let popup = try XCTUnwrap(child)
        XCTAssertEqual(popup.web.url?.host, "localhost")
        _ = try await popup.web.evaluateJavaScript("code.value='123456'; document.getElementById('approve').click(); true")
        try await compatibilityWait { closed }
        try await compatibilityWait { try await tab.web.evaluateJavaScript("returned && localStorage.getItem('session')==='synthetic' && document.cookie.includes('session=synthetic')") as? Bool == true }
        XCTAssertEqual(tab.web.url, app, "The provider redirect must leave the opener on its app page")
        tab.web.reload()
        try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Fixture app" }
        let persisted = try await tab.web.evaluateJavaScript("localStorage.getItem('session')==='synthetic' && document.cookie.includes('session=synthetic')") as? Bool
        XCTAssertEqual(persisted, true)
        _ = try await tab.web.evaluateJavaScript("logout(); true")
        tab.web.reload()
        try await compatibilityWait { !tab.web.isLoading }
        let loggedOut = try await tab.web.evaluateJavaScript("localStorage.getItem('session')===null && !document.cookie.includes('session=synthetic')") as? Bool
        XCTAssertEqual(loggedOut, true)
    }

    private func host(_ tab: Tab) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        return window
    }
}
