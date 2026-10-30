#if DEBUG
import AppKit
import CryptoKit
import ObjectiveC
import Security
import WebKit

/// Separate DEBUG diagnostics for capability A and cold named-store retirement.
/// Namespace mode creates no page/extension/worker. Neither mode changes policy.
@MainActor enum ExtensionWorkerClientCapability {
    private static var runner: Runner?
    private static let purpose = "Vane MV3 eligible-client capability"
    private static let namespacePurpose = "Vane cold named-store cleanup regression"

    static func run(cleanup: Bool, namespaceOnly: Bool = false) -> Never {
        do {
            guard let directory = Store.overrideDirectory else { throw Failure("VANE_DATA_DIR is required") }
            let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.resolvingSymlinksInPath()
            guard root.path.hasPrefix(downloads.path + "/"), Bundle.main.bundleURL.pathExtension == "app" else {
                throw Failure("Requires a signed normal app and isolated Downloads directory")
            }
            try verifySignature()
            let data = try Data(contentsOf: root.appendingPathComponent("capability-claim.json"))
            guard data.count <= 65536, let claim = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  claim["schema"] as? Int == 1, claim["purpose"] as? String == (namespaceOnly ? namespacePurpose : purpose),
                  claim["dataDirectory"] as? String == root.path,
                  let profile = UUID(uuidString: claim["profileID"] as? String ?? ""),
                  let store = UUID(uuidString: claim["storeID"] as? String ?? ""),
                  profile != ProfileManager.defaultID, profile != Profile.incognito.id,
                  ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: root.path) == store else {
                throw Failure("Invalid isolated capability claim")
            }
            if namespaceOnly, claim["appBundleID"] as? String != Bundle.main.bundleIdentifier { throw Failure("Wrong namespace app/container") }
            let probe = Runner(root: root, claim: claim, storeID: store)
            runner = probe
            NSApp.delegate = probe
            probe.cleanupOnly = cleanup
            probe.namespaceOnly = namespaceOnly
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { probe.abort("Overall capability deadline exceeded") }
            NSApp.run()
            throw Failure("Normal AppKit loop returned unexpectedly")
        } catch {
            FileHandle.standardError.write(Data("Capability admission failed: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func verifySignature() throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw Failure("App signature is invalid")
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              entitlements["com.apple.security.cs.disable-library-validation"] as? Bool != true,
              entitlements["com.apple.security.get-task-allow"] as? Bool != true,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0 else { throw Failure("Requires sandbox and Hardened Runtime without debug/security exceptions") }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private final class Reply {
        let deadline: ContinuousClock.Instant
        init(seconds: Int) { deadline = .now + .seconds(seconds) }
        var continuation: CheckedContinuation<String, any Error>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<String, any Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            timer?.cancel(); timer = nil
            if case .success = result, ContinuousClock.now >= deadline {
                pending.resume(throwing: Failure("Bounded JavaScript reply expired"))
            } else { pending.resume(with: result) }
        }
    }

    @MainActor private final class SDKReply<Value: Sendable> {
        let deadline: ContinuousClock.Instant
        let received: (Value) -> Void
        var continuation: CheckedContinuation<Value, any Error>?
        var timer: Task<Void, Never>?
        init(deadline: ContinuousClock.Instant, received: @escaping (Value) -> Void) {
            self.deadline = deadline; self.received = received
        }
        func finish(_ result: Result<Value, any Error>) {
            // Retain every delivered removal error, including duplicate/late
            // callbacks; only the continuation is single-resume.
            if case .success(let value) = result { received(value) }
            guard let pending = continuation else { return }
            continuation = nil; timer?.cancel(); timer = nil
            if case .success = result, ContinuousClock.now >= deadline {
                pending.resume(throwing: Failure("SDK callback exceeded the absolute deadline"))
            } else { pending.resume(with: result) }
        }
    }

    private final class Runner: NSObject, NSApplicationDelegate, WKWebExtensionControllerDelegate {
        let root: URL
        let claim: [String: Any]
        let storeID: UUID
        var cleanupOnly = false
        var namespaceOnly = false
        private var operationDeadline: ContinuousClock.Instant?
        private var began = false
        private var done = false
        private var badgeCompleted = false
        private var badgeBirthNonce: String?
        private var controller: WKWebExtensionController?
        private var context: WKWebExtensionContext?
        private var window: NSWindow?
        private var report: [String: Any]
        init(root: URL, claim: [String: Any], storeID: UUID) {
            self.root = root; self.claim = claim; self.storeID = storeID
            report = claim.filter { ["schema", "purpose", "namespace", "profileID", "storeID", "contextID", "sourceFingerprint", "scriptSHA256", "appBundleID"].contains($0.key) }
        }
        func applicationDidFinishLaunching(_ notification: Notification) {
            guard !began else { return }
            began = true
            Task {
                if self.cleanupOnly { await self.cleanup() }
                else if self.namespaceOnly { await self.createNamespace() }
                else { await self.perform() }
            }
        }
        private func wait(_ description: String, seconds: Int = 5, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while true {
                guard ContinuousClock.now < deadline else { throw Failure("Timed out: " + description) }
                let admitted = ready()
                guard ContinuousClock.now < deadline else { throw Failure("Timed out: " + description) }
                if admitted { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        private func write(_ value: [String: Any], _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent(name), options: .atomic)
        }
        private func sdk<Value: Sendable>(deadline: ContinuousClock.Instant,
            received: @escaping (Value) -> Void = { _ in },
            _ begin: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
            guard ContinuousClock.now < deadline else { throw Failure("SDK operation deadline expired") }
            let reply = SDKReply<Value>(deadline: deadline, received: received)
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                reply.continuation = continuation
                reply.timer = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    reply.finish(.failure(Failure("SDK callback did not arrive before the absolute deadline")))
                }
                begin { result in Task { @MainActor in reply.finish(result) } }
            }
            guard ContinuousClock.now < deadline else { throw Failure("SDK result consumed after the absolute deadline") }
            return value
        }
        private func identifiers(deadline: ContinuousClock.Instant) async throws -> [UUID] {
            try await sdk(deadline: deadline, received: { _ in
                self.report["registryCallbackCount"] = (self.report["registryCallbackCount"] as? Int ?? 0) + 1
            }) { completion in
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { completion(.success($0)) }
            }
        }
        private func qualifyRuntime() throws -> [String: Any] {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { throw Failure("Requires macOS26+") }
            let image = class_getImageName(WKWebView.self).map { String(cString: $0) } ?? ""
            guard image.hasPrefix("/System/Library/Frameworks/WebKit.framework/"), !image.contains("StagedFrameworks") else { throw Failure("Not system WebKit") }
            return ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                "osMajor": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                "webkit": Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "Unavailable",
                "frameworkPath": "/System/Library/Frameworks/WebKit.framework", "classImagePath": image]
        }
        private func admitNamespacePhase(_ phase: String, deadline: ContinuousClock.Instant) async throws {
            operationDeadline = deadline
            try await wait("normal namespace AppKit launch") { NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching }
            guard ContinuousClock.now < deadline else { throw Failure("Namespace admission exceeded original deadline") }
            report["phase"] = phase; report["pid"] = ProcessInfo.processInfo.processIdentifier
            report["noExtensionWorkerOrPage"] = true
            report["registryCallbackCount"] = 0
            // First WebKit object in this process. No page/controller is needed.
            WebKitStartup.prepare()
            report["runtime"] = try qualifyRuntime()
        }
        private func createNamespace() async {
            let deadline = ContinuousClock.now + .seconds(15)
            do {
                try await admitNamespacePhase("namespace-create", deadline: deadline)
                let before = try await identifiers(deadline: deadline)
                report["admission"] = ["beforeAbsent": !before.contains(storeID), "cookieVerified": false, "afterPresent": false]
                guard !before.contains(storeID) else { throw Failure("Fresh namespace already exists") }
                let store = WKWebsiteDataStore(forIdentifier: storeID)
                guard store.identifier == storeID && store.isPersistent else { throw Failure("Wrong actual namespace store") }
                let name = "owned-" + (claim["namespace"] as! String), value = claim["namespace"] as! String
                guard let cookie = HTTPCookie(properties: [.domain: "vane-cleanup.invalid", .path: "/", .name: name, .value: value, .expires: Date.now.addingTimeInterval(3600)]) else { throw Failure("Invalid owned sentinel cookie") }
                let _: Bool = try await sdk(deadline: deadline, received: { _ in
                    self.report["cookieWriteCallbackCount"] = (self.report["cookieWriteCallbackCount"] as? Int ?? 0) + 1
                }) { completion in store.httpCookieStore.setCookie(cookie) { completion(.success(true)) } }
                let verified: Bool = try await sdk(deadline: deadline, received: { _ in
                    self.report["cookieReadCallbackCount"] = (self.report["cookieReadCallbackCount"] as? Int ?? 0) + 1
                }) { completion in
                    store.httpCookieStore.getAllCookies { cookies in
                        completion(.success(cookies.contains { $0.name == name && $0.value == value && $0.domain == "vane-cleanup.invalid" }))
                    }
                }
                let after = try await identifiers(deadline: deadline)
                report["admission"] = ["beforeAbsent": true, "cookieVerified": verified, "afterPresent": after.contains(storeID)]
                guard verified && after.contains(storeID), report["registryCallbackCount"] as? Int == 2,
                      report["cookieWriteCallbackCount"] as? Int == 1, report["cookieReadCallbackCount"] as? Int == 1 else { throw Failure("Namespace creation admission failed") }
                report["result"] = "created"; finish(code: 0)
            } catch { abort(String(describing: error)) }
        }
        private func js(_ web: WKWebView, _ source: String, arguments: [String: Any] = [:], seconds: Int = 1) async throws -> Any? {
            let reply = Reply(seconds: seconds)
            let raw: String = try await withCheckedThrowingContinuation { continuation in
                reply.continuation = continuation
                reply.timer = Task {
                    do { try await ContinuousClock().sleep(until: reply.deadline) } catch { return }
                    reply.finish(.failure(Failure("Bounded JavaScript reply expired")))
                }
                web.callAsyncJavaScript("return JSON.stringify(await (async () => {" + source + "})());", arguments: arguments, in: nil, in: .page) { result in
                    reply.finish(result.map { $0 as? String ?? "null" })
                }
            }
            return try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        }
        private var origin: String { "webkit-extension://" + (claim["contextID"] as! String) }
        private func checkIdentity(_ value: [String: Any], request: String) throws {
            guard value["namespace"] as? String == claim["namespace"] as? String,
                  value["requestNonce"] as? String == claim[request] as? String,
                  value["runtimeID"] as? String == claim["contextID"] as? String,
                  value["origin"] as? String == origin,
                  value["scriptURL"] as? String == origin + "/worker.js",
                  value["manifestVersion"] as? Int == 3, value["version"] as? String == "1.0",
                  let birth = UUID(uuidString: value["birthNonce"] as? String ?? ""),
                  !["namespace", "contextID", "identityRequestNonce", "resultRequestNonce"].contains(where: {
                      UUID(uuidString: claim[$0] as? String ?? "") == birth
                  }) else { throw Failure("Stale/wrong worker identity or reused birth/request nonce") }
        }
        private func perform() async {
            do {
                try await wait("normal application launch") { NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching }
                guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { throw Failure("Requires macOS26+") }
                let image = class_getImageName(WKWebView.self).map { String(cString: $0) } ?? ""
                guard image.hasPrefix("/System/Library/Frameworks/WebKit.framework/"), !image.contains("StagedFrameworks") else {
                    throw Failure("Runtime is not system WebKit: " + image)
                }
                let bundle = Bundle(for: WKWebView.self)
                report["runtime"] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "osMajor": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    "webkit": bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unavailable",
                    "frameworkPath": "/System/Library/Frameworks/WebKit.framework", "classImagePath": image]
                let fixture = root.appendingPathComponent("fixture")
                let script = try Data(contentsOf: fixture.appendingPathComponent("worker.js"))
                let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
                guard hash == claim["scriptSHA256"] as? String else { throw Failure("Fixture script fingerprint mismatch") }
                let configuration = WKWebExtensionController.Configuration(identifier: storeID)
                let store = WKWebsiteDataStore(forIdentifier: storeID)
                configuration.defaultWebsiteDataStore = store
                guard let seed = configuration.webViewConfiguration else { throw Failure("Missing public controller page configuration") }
                seed.websiteDataStore = store
                seed.processPool = WebKitStartup.extensionProcessPool
                seed.applicationNameForUserAgent = safariUA.components(separatedBy: "(KHTML, like Gecko) ").last
                configuration.webViewConfiguration = seed
                let owner = WKWebExtensionController(configuration: configuration)
                owner.delegate = self
                controller = owner
                let ext = try await WKWebExtension(resourceBaseURL: fixture)
                let candidate = WKWebExtensionContext(for: ext)
                candidate.uniqueIdentifier = claim["contextID"] as! String
                candidate.baseURL = URL(string: origin + "/")!
                candidate.unsupportedAPIs = ["browser.runtime.sendNativeMessage", "browser.runtime.connectNative"]
                candidate.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "nativeMessaging"))
                candidate.setPermissionStatus(.grantedExplicitly, for: .init(rawValue: "storage"))
                context = candidate
                // This is the sole startup trigger. No background load or extension
                // UI/document exists before the public badge completion callback.
                try owner.load(candidate)
                try await wait("automatic SDK worker and public action badge") { self.badgeCompleted }
                report["lifecycle"] = ["finishedLaunching": NSRunningApplication.current.isFinishedLaunching,
                    "appRunning": NSApp.isRunning, "autoStartBadge": badgeCompleted,
                    "noExplicitBackgroundLoad": true, "publicOnly": true]
                guard let action = candidate.action(for: nil), let web = action.popupWebView else { throw Failure("No actual SDK popup") }
                let native = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                native.isReleasedWhenClosed = false; native.title = "MV3 eligible-client capability"
                native.contentView = web; window = native
                native.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await wait("exact visible foreground SDK popup document", seconds: 10) {
                    native.isVisible && native.isKeyWindow && NSApp.isActive && web.window === native
                        && !web.isLoading && web.title == "Eligible client capability"
                }
                report["bindings"] = ["pool": web.configuration.processPool === WebKitStartup.extensionProcessPool,
                    "store": web.configuration.websiteDataStore.identifier == storeID && web.configuration.websiteDataStore.isPersistent
                        && owner.configuration.defaultWebsiteDataStore?.identifier == storeID,
                    "controller": web.configuration.webExtensionController === owner && candidate.webExtensionController === owner,
                    "visibleOwner": native.contentView === web && web.window === native && native.isVisible,
                    "unsupportedNative": !candidate.hasPermission(.init(rawValue: "nativeMessaging"))
                        && candidate.unsupportedAPIs == Set(["browser.runtime.sendNativeMessage", "browser.runtime.connectNative"]),
                    "grantedPermissions": candidate.grantedPermissions.keys.map(\.rawValue).sorted(),
                    "grantedSites": candidate.grantedPermissionMatchPatterns.keys.map(\.string).sorted()]
                let query = "return await browser.runtime.sendMessage({kind, namespace, requestNonce});"
                guard let identity = try await js(web, query, arguments: ["kind":"identity", "namespace":claim["namespace"]!, "requestNonce":claim["identityRequestNonce"]!], seconds: 10) as? [String: Any] else { throw Failure("No original identity reply") }
                try checkIdentity(identity, request: "identityRequestNonce")
                guard identity["birthNonce"] as? String == badgeBirthNonce else { throw Failure("Identity did not come from the worker that completed the badge") }
                let popupUA = try await js(web, "return navigator.userAgent;") as? String ?? "Unavailable"
                let uaPassed = identity["startupUA"] as? String == safariUA && identity["currentUA"] as? String == safariUA && popupUA == safariUA
                report["expectedUA"] = safariUA; report["popupUA"] = popupUA
                report["badgeBirthNonce"] = badgeBirthNonce
                report["identity"] = identity; report["uaVerdict"] = uaPassed ? "passed" : "failed"
                // Persist the original UA verdict BEFORE reading the client result.
                try write(["identity": identity, "uaVerdict": uaPassed ? "passed" : "failed"], "identity-verdict.json")
                guard let result = try await js(web, query, arguments: ["kind":"eligible-result", "namespace":claim["namespace"]!, "requestNonce":claim["resultRequestNonce"]!]) as? [String: Any] else { throw Failure("No bound eligible result reply") }
                try checkIdentity(result, request: "resultRequestNonce")
                guard result["birthNonce"] as? String == identity["birthNonce"] as? String else { throw Failure("Worker birth changed between replies") }
                report["eligible"] = result
                let snapshot = result["snapshot"] as? [String: Any] ?? [:]
                let clients = snapshot["clients"] as? [[String: Any]] ?? []
                let hosts = clients.filter { client in
                    guard let url = URLComponents(string: client["url"] as? String ?? "") else { return false }
                    return client["type"] as? String == "window" && client["frameType"] as? String == "top-level"
                        && url.scheme == "webkit-extension" && url.host == claim["contextID"] as? String
                        && url.port == nil && url.user == nil && url.password == nil
                        && ["", "/"].contains(url.path) && url.query == nil && url.fragment == nil
                }
                let observable = snapshot["status"] as? String == "observed" && hosts.count == 1
                report["result"] = !uaPassed ? "failed" : observable ? "observed" : "unavailable"
                finish(code: !uaPassed ? 1 : observable ? 0 : 3)
            } catch { abort(String(describing: error)) }
        }
        func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                    forExtensionContext context: WKWebExtensionContext) {
            let value = action.badgeText
            guard controller === self.controller, context === self.context,
                  let birth = UUID(uuidString: value),
                  birth.uuidString.lowercased() == value else { return }
            badgeBirthNonce = value
            badgeCompleted = true
        }
        func abort(_ message: String) {
            guard !done else { return }
            report["failure"] = message; report["result"] = "failed"
            finish(code: 1)
        }
        private func finish(code initialCode: Int32) -> Never {
            done = true
            var code = initialCode
            func expireVerdict() {
                if let operationDeadline, ContinuousClock.now >= operationDeadline {
                    report["failure"] = "Final verdict exceeded the original absolute deadline"
                    report["result"] = "failed"; code = 1
                }
            }
            expireVerdict()
            if let context, context.isLoaded {
                do { try controller?.unload(context) }
                catch { report["cleanupFailure"] = String(describing: error); report["result"] = "failed"; code = 1 }
            }
            window?.contentView = nil; window?.close(); window = nil
            context = nil; controller = nil
            let name = namespaceOnly ? (cleanupOnly ? "namespace-cleanup-report.json" : "namespace-create-report.json")
                : (cleanupOnly ? "cleanup-failure.json" : "capability-report.json")
            do {
                try write(report, name)
                expireVerdict()
                if code != initialCode { try write(report, name) }
            }
            catch { FileHandle.standardError.write(Data("Cannot save report: \(error)\n".utf8)); code = 1 }
            print("CAPABILITY result=\(report["result"] ?? "failed") eligible-client observation only; no initial-UA-map claim")
            fflush(stdout)
            exit(code)
        }
        private func cleanup() async {
            let deadline = ContinuousClock.now + .seconds(15)
            // Match ProfileManager's cold-registry prerequisite. An AppKit loop
            // alone does not initialize WebKit's WTF main run loop.
            operationDeadline = deadline
            report["removalErrors"] = [String](); report["removalCallbackCount"] = 0
            report["registryCallbackCount"] = 0
            do {
                if namespaceOnly { try await admitNamespacePhase("namespace-cleanup", deadline: deadline) }
                else {
                    try await wait("normal cleanup AppKit launch") { NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching }
                    WebKitStartup.prepare()
                }
                let before = try await identifiers(deadline: deadline)
                let present = before.contains(storeID)
                var creatorVerified = false
                if namespaceOnly {
                    let data = try? Data(contentsOf: root.appendingPathComponent("namespace-create-report.json"))
                    let creator = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let admission = creator?["admission"] as? [String: Any]
                    creatorVerified = creator?["result"] as? String == "created"
                        && creator?["schema"] as? Int == 1
                        && creator?["noExtensionWorkerOrPage"] as? Bool == true
                        && creator?["phase"] as? String == "namespace-create"
                        && creator?["purpose"] as? String == claim["purpose"] as? String
                        && creator?["profileID"] as? String == claim["profileID"] as? String
                        && creator?["namespace"] as? String == claim["namespace"] as? String
                        && creator?["storeID"] as? String == claim["storeID"] as? String
                        && creator?["sourceFingerprint"] as? String == claim["sourceFingerprint"] as? String
                        && creator?["appBundleID"] as? String == Bundle.main.bundleIdentifier
                        && admission?["beforeAbsent"] as? Bool == true
                        && admission?["cookieVerified"] as? Bool == true
                        && admission?["afterPresent"] as? Bool == true
                        && (creator?["pid"] as? Int ?? 0) > 0
                        && creator?["pid"] as? Int != Int(ProcessInfo.processInfo.processIdentifier)
                    report["creatorPID"] = creator?["pid"]
                    report["admission"] = ["creatorVerified": creatorVerified, "beforePresent": present]
                }
                report["retirement"] = ["removalAttempted": present, "afterAbsent": false]
                if present {
                    let _: String? = try await sdk(deadline: deadline, received: { error in
                        self.report["removalCallbackCount"] = (self.report["removalCallbackCount"] as? Int ?? 0) + 1
                        if let error {
                            var errors = self.report["removalErrors"] as? [String] ?? []
                            errors.append(error); self.report["removalErrors"] = errors
                        }
                    }) { completion in
                        WKWebsiteDataStore.remove(forIdentifier: self.storeID) { error in completion(.success(error.map { String(describing: $0) })) }
                    }
                }
                let after = try await identifiers(deadline: deadline)
                let absent = !after.contains(storeID)
                report["retirement"] = ["removalAttempted": present, "afterAbsent": absent]
                let errors = report["removalErrors"] as? [String] ?? []
                let callbacks = report["registryCallbackCount"] as? Int == 2
                    && report["removalCallbackCount"] as? Int == (present ? 1 : 0)
                let qualified = absent && errors.isEmpty && callbacks && (!namespaceOnly || (present && creatorVerified))
                if namespaceOnly {
                    report["result"] = qualified ? "retired" : "failed"
                    finish(code: qualified ? 0 : 1)
                }
                guard qualified, ContinuousClock.now < deadline else { throw Failure("Exact named-store retirement failed") }
                try write(["namespace":claim["namespace"]!, "storeID":storeID.uuidString.lowercased(), "retired":true], "cleanup-report.json")
                guard ContinuousClock.now < deadline else { throw Failure("Retirement report exceeded absolute deadline") }
                print("CAPABILITY cleanup: exact owned named store absent"); exit(0)
            } catch { abort(String(describing: error)) }
        }
    }
}
#endif
