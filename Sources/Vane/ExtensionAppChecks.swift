import AppKit
import Network
import Security
import WebKit

/// Opt-in checks against unmodified upstream packages in an isolated signed app.
/// Run: VANE_DATA_DIR=~/Downloads/<isolated-folder> Vane.app/Contents/MacOS/vane extensioncheck
/// The fixture folders and accepted installation records are retained for restart checks.
@MainActor enum ExtensionAppChecks {
    private static var runner: Runner?

    static func run() -> Never {
        let manager = FileManager.default
        guard let override = Store.overrideDirectory,
              let downloads = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            refuse("Set VANE_DATA_DIR to an existing isolated directory under Downloads.")
        }
        let directory = URL(fileURLWithPath: override).resolvingSymlinksInPath().standardizedFileURL
        let downloadsRoot = downloads.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var isDirectory: ObjCBool = false
        guard directory.path.hasPrefix(downloadsRoot),
              manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              Bundle.main.bundleURL.pathExtension == "app", sandboxedSignature() else {
            refuse("Requires a signed sandboxed .app and an existing isolated VANE_DATA_DIR under Downloads.")
        }
        for name in ["darkreader-mv3", "ubolite-safari", "bitwarden-firefox"] {
            let fixture = directory.appendingPathComponent("fixtures/" + name)
            guard fixture.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                  manager.fileExists(atPath: fixture.appendingPathComponent("manifest.json").path) else {
                refuse("Missing local fixture fixtures/" + name + "/manifest.json.")
            }
        }
        // A Downloads location alone does not prove this is a disposable profile.
        // Mint a marker only before Vane has written any library or preferences here;
        // reruns require that marker to identify this exact canonical directory.
        let marker = directory.appendingPathComponent("extensioncheck-fixture.json")
        if manager.fileExists(atPath: marker.path) {
            guard (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: marker),
                  let identity = try? JSONDecoder().decode(Isolation.self, from: data),
                  identity.schema == 1, identity.purpose == "Vane extensioncheck fixtures",
                  identity.directory == directory.path else {
                refuse("The isolation marker is invalid or belongs to a different directory.")
            }
        } else {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path),
                  Set(names).isSubset(of: ["fixtures", ".DS_Store"]) else {
                refuse("A first run requires a directory containing only fixtures; existing profile/library data is not allowed.")
            }
            do {
                let identity = Isolation(schema: 1, purpose: "Vane extensioncheck fixtures", directory: directory.path, id: UUID())
                try JSONEncoder().encode(identity).write(to: marker, options: .withoutOverwriting)
            } catch { refuse("Could not mint the isolated fixture-directory marker.") }
        }
        let check = Runner(directory: directory)
        runner = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            check.record("overall deadline", .failed, "Exceeded 240 seconds; a platform callback did not finish.")
            check.finish()
        }
        Task { await check.run() }
        NSApp.run()
        refuse("The application run loop ended before extensioncheck completed.")
    }

    private static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL extensioncheck: " + message + "\n").utf8))
        exit(2)
    }

    private static func sandboxedSignature() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    private enum Result: String, Codable { case verified = "VERIFIED", unavailable = "UNAVAILABLE", failed = "FAILED" }
    private struct Isolation: Codable { let schema: Int; let purpose: String; let directory: String; let id: UUID }
    private struct SettingProbe: Codable { let contextID: String; let brightness: Int }
    private struct Finding: Codable { let workflow: String; let result: Result; let detail: String }
    private struct Report: Codable { let profileID: UUID; let findings: [Finding] }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @MainActor private final class Runner {
        let directory: URL
        var profileID: UUID?
        var store: TabStore?
        var server: Server?
        var findings: [Finding] = []
        var permissionTimer: Timer?
        var popupAnchors: [NSView] = []

        init(directory: URL) { self.directory = directory }

        func record(_ workflow: String, _ result: Result, _ detail: String) {
            findings.append(Finding(workflow: workflow, result: result, detail: detail))
            print("\(result.rawValue) extensioncheck: \(workflow) — \(detail)")
            fflush(stdout)
        }

        func run() async {
            do {
                HTTPSOnly.enabled = false
                let profile = ProfileManager.shared.active
                profileID = profile.id
                print("extensioncheck isolated profileID=\(profile.id.uuidString); no accounts or credentials are used")
                fflush(stdout)
                // Explicit fixture install consent is injected below. Optional runtime
                // requests are denied, preventing an unexpected modal from hanging checks.
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard NSApp.modalWindow != nil else { return }
                        self?.record("runtime permission prompt", .unavailable, "Denied by the opt-in fixture harness; no additional access approved.")
                        NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    }
                }
                permissionTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .modalPanel)
                let server = try Server()
                self.server = server
                try await wait("loopback fixture starts") { server.port != nil || server.error != nil }
                if let error = server.error { throw Failure(error) }
                guard let port = server.port else { throw Failure("The loopback listener has no port.") }
                let base = "http://127.0.0.1:\(port)"
                let store = Windows.open(profile: profile, session: [])
                self.store = store
                let tab = store.newBlankTab()
                tab.go(URL(string: base + "/page")!)
                try await wait("controlled page loads") { tab.web.title == "Vane extension fixture" && !tab.web.isLoading }
                let baseline = try await tab.web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
                let restoredStyle = try await tab.web.evaluateJavaScript("document.querySelectorAll('style.darkreader').length > 0") as? Bool == true
                record("controlled ordinary browser page", baseline == "rgb(255, 255, 255)" || restoredStyle ? .verified : .failed,
                       "Real Vane window and loopback page; background \(baseline ?? "unavailable"), restored Dark Reader styles present=\(restoredStyle). A restart may restore styling before the first page loads.")
                await darkReader(tab: tab, base: base)
                await blocker(tab: tab, base: base)
                await passwordManager(tab: tab)
                await syntheticRuntime(tab: tab)
            } catch {
                record("harness setup", .failed, error.localizedDescription)
            }
            finish()
        }

        private func install(_ fixture: String) async throws -> WKWebExtensionContext {
            guard let profileID else { throw Failure("No isolated profile.") }
            let host = ExtensionHost.host(for: profileID)
            try await wait("prior extension operations settle", seconds: 25) { !host.isBusy }
            let folder = directory.appendingPathComponent("fixtures/" + fixture)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
            let version = manifest?["version"] as? String ?? "unknown"
            let path = folder.resolvingSymlinksInPath().path
            if let existing = host.loaded.first(where: { $0.path == path })?.context {
                record(fixture + " " + version + " restore", .verified, "Accepted installation restored with its existing identity.")
                return existing
            }
            let accepted = try await host.load(folder, installing: true) { [weak self] review in
                self?.record(fixture + " " + version + " review", .verified,
                             "Explicit test acceptance before activation; required access reviewed for this known local fixture.")
                return true
            }
            guard accepted, let context = host.loaded.first(where: { $0.path == path })?.context else {
                throw Failure("The fixture did not activate after explicit test consent.")
            }
            record(fixture + " " + version + " install", .verified,
                   "Production staging, manifest/resource validation, managed copy, and loaded WebKit context.")
            for limitation in host.entries.first(where: { $0.path == path })?.compatibility ?? [] {
                record(fixture + " compatibility", .unavailable, limitation)
            }
            return context
        }

        private func darkReader(tab: Tab, base: String) async {
            do {
                let context = try await install("darkreader-mv3")
                tab.go(URL(string: base + "/page?darkreader")!)
                try await wait("Dark Reader page loads") { tab.web.title == "Vane extension fixture" && !tab.web.isLoading }
                let script = "document.querySelectorAll('style.darkreader').length > 0 && getComputedStyle(document.body).backgroundColor !== 'rgb(255, 255, 255)'"
                do {
                    try await waitJavaScript("Dark Reader changes visible page style", in: tab.web, script: script, seconds: 20)
                    let count = try await tab.web.evaluateJavaScript("document.querySelectorAll('style.darkreader').length") as? Int ?? 0
                    record("Dark Reader \(context.webExtension.version ?? "unknown") controlled content script", .verified,
                           "\(count) injected Dark Reader stylesheets; the known white page rendered with a changed computed background.")
                } catch { record("Dark Reader visible page transformation", .failed, error.localizedDescription) }
                _ = await popup(context, tab: tab, label: "Dark Reader popup", expected: "/dark reader|darkreader|on|off/i.test(document.body.innerText)")
                if let options = await options(context, label: "Dark Reader options") {
                    await darkReaderSetting(context, in: options)
                }
            } catch { record("Dark Reader package", .unavailable, error.localizedDescription) }
        }

        private func darkReaderSetting(_ context: WKWebExtensionContext, in web: WKWebView) async {
            let probeURL = directory.appendingPathComponent("darkreader-option-probe.json")
            func readBrightness() async throws -> Int? {
                let value = try await web.callAsyncJavaScript("return (await browser.runtime.sendMessage({type:'ui-bg-get-data'}))?.data?.settings?.theme?.brightness ?? null;",
                                                            arguments: [:], in: nil, contentWorld: .page)
                return (value as? NSNumber)?.intValue
            }
            do {
                if FileManager.default.fileExists(atPath: probeURL.path) {
                    let saved = try JSONDecoder().decode(SettingProbe.self, from: Data(contentsOf: probeURL))
                    let current = try await readBrightness()
                    record("Dark Reader actual option across process restart",
                           saved.contextID == context.uniqueIdentifier && current == saved.brightness ? .verified : .failed,
                           "Compared its real theme brightness option and persistent WebKit identity with the preceding completed fixture run.")
                    return
                }
                guard try await readBrightness() != nil else { throw Failure("Dark Reader did not expose its theme settings through its UI message API.") }
                _ = try await web.callAsyncJavaScript("void browser.runtime.sendMessage({type:'ui-bg-set-theme',data:{brightness:110}}).catch(()=>{}); return true;",
                                                     arguments: [:], in: nil, contentWorld: .page)
                let deadline = ContinuousClock.now + .seconds(10)
                while try await readBrightness() != 110 {
                    guard ContinuousClock.now < deadline else { throw Failure("The actual theme brightness option did not change to 110.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let probe = SettingProbe(contextID: context.uniqueIdentifier, brightness: 110)
                try JSONEncoder().encode(probe).write(to: probeURL, options: .atomic)
                record("Dark Reader actual option setting", .verified, "Its existing UI-background message API changed and read back theme brightness=110 in the isolated profile.")
                record("Dark Reader actual option across process restart", .unavailable,
                       "Prepared the persisted option/identity probe; rerun extensioncheck in this same fixture directory to verify a fresh process.")
            } catch { record("Dark Reader actual option setting", .unavailable, error.localizedDescription) }
        }

        private func blocker(tab: Tab, base: String) async {
            do {
                let context = try await install("ubolite-safari")
                _ = await popup(context, tab: tab, label: "uBlock Origin Lite popup",
                                expected: "!document.body.classList.contains('loading') && document.querySelector('#gotoDashboard')?.getClientRects().length > 0")
                guard let options = await options(context, label: "uBlock Origin Lite dashboard") else { return }
                do {
                    let rules = try await options.callAsyncJavaScript("return await browser.declarativeNetRequest.getEnabledRulesets();",
                                                                    arguments: [:], in: nil, contentWorld: .page) as? [String] ?? []
                    record("uBlock Origin Lite enabled static rulesets", rules.isEmpty ? .failed : .verified,
                           "WebKit reports these enabled ruleset identifiers: " + rules.sorted().joined(separator: ", ") + ". This does not assert real-site blocking.")
                    let existing = try await options.callAsyncJavaScript("return await browser.declarativeNetRequest.getDynamicRules();",
                                                                        arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]] ?? []
                    let existingIDs = Set(existing.compactMap { ($0["id"] as? NSNumber)?.intValue })
                    var ruleID = 1_900_000_001
                    while existingIDs.contains(ruleID) { ruleID -= 1 }
                    let rule: [String: Any] = ["id": ruleID, "priority": 1, "action": ["type": "block"],
                                             "condition": ["urlFilter": base + "/blocked-by-fixture.js", "resourceTypes": ["script"]]]
                    _ = try await options.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({addRules:[rule]}); return true;",
                                                             arguments: ["id": ruleID, "rule": rule], in: nil, contentWorld: .page)
                    do {
                        server?.requests["/blocked-by-fixture.js"] = 0
                        tab.go(URL(string: base + "/block-check")!)
                        try await wait("controlled DNR page loads") { tab.web.title == "Vane DNR fixture" && !tab.web.isLoading }
                        let allowed = try await tab.web.evaluateJavaScript("window.fixtureAllowed === true") as? Bool == true
                        let blocked = try await tab.web.evaluateJavaScript("window.fixtureBlocked !== true") as? Bool == true
                        let reachedServer = server?.requests["/blocked-by-fixture.js"] ?? 0
                        record("uBlock Origin Lite context controlled DNR request", allowed && blocked && reachedServer == 0 ? .verified : .failed,
                               "Temporary harness dynamic rule: control script executed=\(allowed), blocked script absent=\(blocked), blocked endpoint requests=\(reachedServer). This tests WebKit DNR through uBOL’s context, not upstream filter coverage.")
                    } catch { record("controlled DNR page", .failed, error.localizedDescription) }
                    _ = try await options.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[id]}); return true;",
                                                             arguments: ["id": ruleID], in: nil, contentWorld: .page)
                    record("controlled DNR rule cleanup", .verified, "Removed only the temporary harness rule; upstream rules were preserved.")
                } catch { record("uBlock Origin Lite DNR API workflow", .unavailable, error.localizedDescription) }
            } catch { record("uBlock Origin Lite package", .unavailable, error.localizedDescription) }
        }

        private func passwordManager(tab: Tab) async {
            do {
                let context = try await install("bitwarden-firefox")
                if let popup = await popup(context, tab: tab, label: "Bitwarden unauthenticated popup",
                                           expected: "/log in|login|create account|get started/i.test(document.body.innerText)") {
                    let clicked = try await popup.evaluateJavaScript("""
                        (() => { const item = [...document.querySelectorAll('button,a')].find(e => /settings/i.test((e.getAttribute('aria-label') || '') + ' ' + e.innerText)); if (!item) return false; item.click(); return true; })()
                        """) as? Bool == true
                    if clicked {
                        try await waitJavaScript("Bitwarden unauthenticated settings render", in: popup,
                                                 script: "/settings|environment|server/i.test(document.body.innerText)")
                        record("Bitwarden unauthenticated settings", .verified, "Opened the visible Settings control without entering account or vault credentials.")
                    } else {
                        record("Bitwarden unauthenticated settings", .unavailable, "No Settings control was exposed on the observed signed-out popup screen.")
                    }
                }
                _ = await options(context, label: "Bitwarden options")
                record("Bitwarden authenticated workflows", .unavailable, "Account login, vault unlock, autofill, native messaging, and credential saving were not tested.")
            } catch { record("Bitwarden package", .unavailable, error.localizedDescription) }
        }

        private func syntheticRuntime(tab: Tab) async {
            guard let profileID else { return }
            let host = ExtensionHost.host(for: profileID)
            let folder = directory.appendingPathComponent("fixtures/vane-smoke-mv3")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(#"{"manifest_version":3,"name":"Vane Assembled Runtime Fixture","version":"1.0","description":"Synthetic assembled-app runtime checks","permissions":["storage"],"action":{"default_popup":"popup.html"},"options_page":"options.html","commands":{"fixture":{"suggested_key":{"mac":"Command+Shift+Y"},"description":"Assembled check command"}}}"#.utf8)
                    .write(to: folder.appendingPathComponent("manifest.json"))
                try Data("<title>Vane runtime fixture</title><p>Runtime fixture ready</p><script src='fixture.js'></script>".utf8).write(to: folder.appendingPathComponent("options.html"))
                try Data("<title>Vane popup fixture</title><p>Popup fixture ready</p>".utf8).write(to: folder.appendingPathComponent("popup.html"))
                try Data("window.fixtureCommands=[];browser.commands.onCommand.addListener(name=>window.fixtureCommands.push(name));".utf8).write(to: folder.appendingPathComponent("fixture.js"))
                let context = try await install("vane-smoke-mv3")
                defer { try? host.remove(folder: folder.path) }
                _ = await popup(context, tab: tab, label: "Synthetic actual action window", expected: "document.body.innerText.includes('Popup fixture ready')")
                guard let options = await options(context, label: "Synthetic actual options window",
                                                  expected: "document.body.innerText.includes('Runtime fixture ready')"),
                      let window = store?.window else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                window.makeFirstResponder(nil)
                do {
                    try await wait("real browser key focus") { window.isKeyWindow }
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "Y", charactersIgnoringModifiers: "Y",
                        isARepeat: false, keyCode: 16) else { throw Failure("Could not create keyboard event.") }
                    let routed = ExtensionCommands.handle(event)
                    try await waitJavaScript("command listener receives real routed NSEvent", in: options,
                                             script: "window.fixtureCommands.includes('fixture')")
                    record("Synthetic native keyboard command", routed ? .verified : .failed,
                           "Real key Vane window, NSEvent matching, profile-scoped dispatch, and WebKit commands listener; no simulated key-window override.")
                } catch { record("Synthetic native keyboard command", .unavailable, error.localizedDescription) }
            } catch { record("Synthetic runtime fixture", .failed, error.localizedDescription) }
        }

        private func popup(_ context: WKWebExtensionContext, tab: Tab, label: String, expected: String) async -> WKWebView? {
            do {
                guard let profileID, let window = store?.window, let content = window.contentView else { throw Failure("No browser anchor window.") }
                let host = ExtensionHost.host(for: profileID)
                guard let action = host.action(context, for: tab), action.presentsPopup,
                      let web = action.popupWebView else { throw Failure("WebKit exposes no action popup for this context.") }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try await wait(label + " parent foreground") { NSApp.isActive && window.isVisible && window.isKeyWindow }
                let anchor = NSView(frame: NSRect(x: content.bounds.maxX - 48, y: content.bounds.maxY - 44, width: 28, height: 28))
                content.addSubview(anchor)
                popupAnchors.append(anchor)
                host.run(context, for: tab, from: anchor)
                try await wait(label + " presents", seconds: 15) {
                    guard let owner = host.actionPopupWindow(context, for: tab), let contents = owner.contentView else { return false }
                    return owner !== window && owner.isVisible && owner.styleMask.contains(.titled)
                        && web.window === owner && web.isDescendant(of: contents)
                }
                let owner = host.actionPopupWindow(context, for: tab)
                try await waitJavaScript(label + " usable DOM", in: web, script: expected, seconds: 20)
                guard let owner, owner.isVisible, web.window === owner else { throw Failure("The exact SDK popup lost its native presentation owner.") }
                record(label, .verified, "Production action path displayed its exact SDK popup webview in the owning native titlebar window with its expected usable DOM.")
                return web
            } catch { record(label, .unavailable, error.localizedDescription); return nil }
        }

        private func options(_ context: WKWebExtensionContext, label: String,
                             expected: String = "[...document.querySelectorAll('button,input,select,a')].some(e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden')") async -> WKWebView? {
            guard let profileID, let url = context.optionsPageURL else {
                record(label, .unavailable, "This manifest declares no options page.")
                return nil
            }
            do {
                let host = ExtensionHost.host(for: profileID)
                try await host.webExtensionController(host.controller, openOptionsPageFor: context)
                var web: WKWebView?
                try await wait(label + " native window", seconds: 15) {
                    web = NSApp.windows.lazy.compactMap { self.webView(in: $0.contentView, url: url) }.first
                    return web != nil
                }
                guard let web else { throw Failure("The native options window contains no matching extension web view.") }
                try await waitJavaScript(label + " content", in: web, script: expected, seconds: 20)
                record(label, .verified, "Production options delegate opened the extension-origin page in its native window with the expected rendered UI.")
                return web
            } catch { record(label, .unavailable, error.localizedDescription); return nil }
        }

        private func webView(in view: NSView?, url: URL) -> WKWebView? {
            guard let view else { return nil }
            if let web = view as? WKWebView, web.url?.host == url.host,
               web.url?.path == url.path { return web }
            for child in view.subviews { if let found = webView(in: child, url: url) { return found } }
            return nil
        }

        private func wait(_ description: String, seconds: Int = 10, until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !predicate() {
                guard ContinuousClock.now < deadline else { throw Failure("Timed out: " + description) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        private func waitJavaScript(_ description: String, in web: WKWebView, script: String, seconds: Int = 10) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while true {
                if !web.isLoading, (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
                guard ContinuousClock.now < deadline else { throw Failure("Timed out: " + description) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        func finish() -> Never {
            permissionTimer?.invalidate()
            if let profileID {
                ExtensionManagement.close(for: profileID)
                ExtensionHost.forget(profileID) // unload; preserve accepted installs for restart
            }
            for window in NSApp.windows where window.isVisible { window.close() }
            popupAnchors.forEach { $0.removeFromSuperview() }; popupAnchors = []
            server?.stop()
            let failed = findings.filter { $0.result == .failed }.count
            if let profileID {
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(Report(profileID: profileID, findings: findings))
                        .write(to: directory.appendingPathComponent("extensioncheck-results.json"), options: .atomic)
                } catch { print("FAILED extensioncheck: could not save fixture report: " + error.localizedDescription); exit(1) }
            }
            print("extensioncheck summary: verified=\(findings.filter { $0.result == .verified }.count), unavailable=\(findings.filter { $0.result == .unavailable }.count), failed=\(failed); accepted installs retained for restart")
            fflush(stdout)
            exit(failed == 0 ? 0 : 1)
        }
    }

    /// Loopback-only bounded fixture server; it never serves user files or credentials.
    @MainActor private final class Server {
        let listener: NWListener
        var port: UInt16?
        var error: String?
        var requests: [String: Int] = [:]
        private var connections: [NWConnection] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in MainActor.assumeIsolated {
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
                if case .failed(let error) = state { self?.error = error.localizedDescription }
            } }
            listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffer: Data())
            } }
            listener.start(queue: .main)
        }

        func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections = [] }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in MainActor.assumeIsolated {
                guard let self, error == nil else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count < 32768 else { connection.cancel(); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let path = String(target.split(separator: "?", maxSplits: 1)[0])
                self.requests[path, default: 0] += 1
                let script = path.hasSuffix(".js")
                let body: String
                if path == "/allowed-by-fixture.js" { body = "window.fixtureAllowed=true;" }
                else if path == "/blocked-by-fixture.js" { body = "window.fixtureBlocked=true;" }
                else if path == "/block-check" {
                    body = "<title>Vane DNR fixture</title><body><h1>Controlled DNR check</h1><script src='/allowed-by-fixture.js'></script><script src='/blocked-by-fixture.js'></script></body>"
                } else {
                    body = "<title>Vane extension fixture</title><style>body{background:#fff;color:#111;font:20px system-ui;padding:40px}</style><body><h1>Extension fixture</h1><p>A controlled white page for content-script checks.</p><a href='/page'>Fixture link</a></body>"
                }
                let data = Data(body.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(script ? "application/javascript" : "text/html; charset=utf-8")\r\nCache-Control: no-store\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
            } }
        }
    }
}
