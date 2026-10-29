#if DEBUG
import AppKit
import CryptoKit
import ObjectiveC
import Security
import WebKit

/// Diagnostic capability A only. No host policy changes, private callback, or
/// worker API interception. Eligibility is not an initial origin-UA lookup.
@MainActor enum ExtensionWorkerClientCapability {
    private static var runner: Runner?
    private static let purpose = "Vane MV3 eligible-client capability"

    static func run(cleanup: Bool) -> Never {
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
                  claim["schema"] as? Int == 1, claim["purpose"] as? String == purpose,
                  claim["dataDirectory"] as? String == root.path,
                  let profile = UUID(uuidString: claim["profileID"] as? String ?? ""),
                  let store = UUID(uuidString: claim["storeID"] as? String ?? ""),
                  profile != ProfileManager.defaultID, profile != Profile.incognito.id,
                  ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: root.path) == store else {
                throw Failure("Invalid isolated capability claim")
            }
            let probe = Runner(root: root, claim: claim, storeID: store)
            runner = probe
            NSApp.delegate = probe
            probe.cleanupOnly = cleanup
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

    private final class Runner: NSObject, NSApplicationDelegate, WKWebExtensionControllerDelegate {
        let root: URL
        let claim: [String: Any]
        let storeID: UUID
        var cleanupOnly = false
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
            report = claim.filter { ["schema", "namespace", "profileID", "storeID", "contextID", "sourceFingerprint", "scriptSHA256"].contains($0.key) }
        }
        func applicationDidFinishLaunching(_ notification: Notification) {
            guard !began else { return }
            began = true
            Task { if self.cleanupOnly { await self.cleanup() } else { await self.perform() } }
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
            if let context, context.isLoaded {
                do { try controller?.unload(context) }
                catch { report["cleanupFailure"] = String(describing: error); report["result"] = "failed"; code = 1 }
            }
            window?.contentView = nil; window?.close(); window = nil
            context = nil; controller = nil
            do { try write(report, cleanupOnly ? "cleanup-failure.json" : "capability-report.json") }
            catch { FileHandle.standardError.write(Data("Cannot save report: \(error)\n".utf8)); code = 1 }
            print("CAPABILITY result=\(report["result"] ?? "failed") eligible-client observation only; no initial-UA-map claim")
            fflush(stdout)
            exit(code)
        }
        private func cleanup() async {
            let deadline = ContinuousClock.now + .seconds(15)
            var lastError: (any Error)?
            while ContinuousClock.now < deadline {
                let identifiers: [UUID] = await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
                }
                if !identifiers.contains(storeID) {
                    do { try write(["namespace":claim["namespace"]!, "storeID":storeID.uuidString.lowercased(), "retired":true], "cleanup-report.json") }
                    catch { abort("Cannot save exact retirement proof") }
                    print("CAPABILITY cleanup: exact owned named store absent"); exit(0)
                }
                lastError = await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.remove(forIdentifier: storeID) { continuation.resume(returning: $0) }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            abort("Exact owned store retirement failed: \(String(describing: lastError))")
        }
    }
}
#endif
