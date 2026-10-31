import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionNativeMessagingErrorTests: XCTestCase {
    private func until(_ description: String, seconds: Int = 5, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            await Task.yield()
        }
    }

    func testDenialWaitsForDefinedPolicyAndRetiresPendingWork() async throws {
        let gate = NativeErrorSleepGate()
        let denial = ExtensionNativeMessagingDenial { try await gate.sleep($0) }
        let context = NSObject()
        let completed = NativeErrorCompletion()
        let request = Task { try await denial.wait(contextID: ObjectIdentifier(context)); completed.value = true }
        defer { denial.cancelAll(); gate.releaseAll(); request.cancel() }
        try await until("denial reached controlled sleeper", seconds: 1) { gate.pending == 1 }
        XCTAssertEqual(gate.durations, [.milliseconds(100)])
        XCTAssertEqual(denial.pendingCount, 1)
        XCTAssertFalse(completed.value, "No error reply may escape before its backpressure boundary")
        gate.releaseAll()
        try await request.value
        XCTAssertTrue(completed.value)
        XCTAssertEqual(denial.pendingCount, 0)
    }

    func testCancellationIsScopedAndGlobalCancellationReleasesWork() async throws {
        let gate = NativeErrorSleepGate()
        let denial = ExtensionNativeMessagingDenial { try await gate.sleep($0) }
        let a = NSObject(), b = NSObject()
        let first = Task { try await denial.wait(contextID: ObjectIdentifier(a)) }
        let second = Task { try await denial.wait(contextID: ObjectIdentifier(b)) }
        defer { denial.cancelAll(); gate.releaseAll(); first.cancel(); second.cancel() }
        try await until("both contexts reached sleeper", seconds: 1) { gate.pending == 2 }
        denial.cancel(contextID: ObjectIdentifier(a))
        do { try await first.value; XCTFail("Cancelled context must not finish successfully") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(denial.pendingCount, 1)
        XCTAssertEqual(gate.pending, 1, "Context B must remain independent")
        denial.cancelAll()
        do { try await second.value; XCTFail("Global cancellation must release pending waits") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(denial.pendingCount, 0)
        XCTAssertEqual(gate.pending, 0)
    }

    func testPendingBudgetDoesNotRetainUnboundedNativeRequests() async throws {
        let gate = NativeErrorSleepGate()
        let denial = ExtensionNativeMessagingDenial { try await gate.sleep($0) }
        let context = NSObject(), other = NSObject()
        let requests = (0..<ExtensionNativeMessagingDenial.perContextLimit).map { _ in
            Task { try await denial.wait(contextID: ObjectIdentifier(context)) }
        }
        defer { denial.cancelAll(); gate.releaseAll(); requests.forEach { $0.cancel() } }
        try await until("context pending budget populated", seconds: 1) { gate.pending == requests.count }
        do { try await denial.wait(contextID: ObjectIdentifier(context)); XCTFail("Overflow must fail without retaining more work") }
        catch { XCTAssertEqual((error as NSError).localizedDescription, "Native messaging hosts are unavailable in Vane.") }
        XCTAssertEqual(denial.pendingCount, requests.count)
        let independent = Task { try await denial.wait(contextID: ObjectIdentifier(other)) }
        try await until("another context can enter", seconds: 1) { gate.pending == requests.count + 1 }
        gate.releaseAll()
        for request in requests { try await request.value }
        try await independent.value
        XCTAssertEqual(denial.pendingCount, 0)
    }

    func testBothPublicNativePathsExistWithoutEnablingAnyAPI() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let host = ExtensionHost.host(for: profile)
        XCTAssertTrue(host.responds(to: Self.messageSelector), "An absent delegate permits WebKit's automatic Safari native fallback")
        XCTAssertTrue(host.responds(to: Self.portSelector), "Ports require their own permanent denial boundary")
        ExtensionHost.forget(profile)
        try await NativeFixtureProfileCleanup.release([profile])
    }

    func testTotalPendingBudgetStaysBoundedAcrossContexts() async throws {
        let gate = NativeErrorSleepGate()
        let denial = ExtensionNativeMessagingDenial { try await gate.sleep($0) }
        let contexts = (0..<4).map { _ in NSObject() }, excess = NSObject()
        let requests = contexts.flatMap { context in
            (0..<ExtensionNativeMessagingDenial.perContextLimit).map { _ in
                Task { try await denial.wait(contextID: ObjectIdentifier(context)) }
            }
        }
        defer { denial.cancelAll(); gate.releaseAll(); requests.forEach { $0.cancel() } }
        try await until("global pending budget populated", seconds: 1) { gate.pending == ExtensionNativeMessagingDenial.totalLimit }
        do { try await denial.wait(contextID: ObjectIdentifier(excess)); XCTFail("Total overflow must not retain another request") }
        catch { XCTAssertEqual((error as NSError).localizedDescription, "Native messaging hosts are unavailable in Vane.") }
        XCTAssertEqual(denial.pendingCount, ExtensionNativeMessagingDenial.totalLimit)
        gate.releaseAll()
        for request in requests { try await request.value }
        XCTAssertEqual(denial.pendingCount, 0)
    }

    func testRealSDKCallbackPromiseAndPortReceiveOnlyUnavailableErrors() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let host = ExtensionHost.host(for: profile)
        let intercepted = host.responds(to: Self.messageSelector) && host.responds(to: Self.portSelector)
        XCTAssertTrue(intercepted)
        guard intercepted else {
            ExtensionHost.forget(profile)
            try await NativeFixtureProfileCleanup.release([profile])
            return
        }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let oldPolicy = NSApp.activationPolicy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-error-sdk-" + UUID().uuidString)
        var context: WKWebExtensionContext?
        var window: NSWindow?
        var failure: (any Error)?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Native Error SDK Fixture","version":"1","permissions":["nativeMessaging"]}"#.utf8)
                .write(to: folder.appendingPathComponent("manifest.json"))
            try Data("<title>Native error fixture</title><script src='native.js'></script>".utf8)
                .write(to: folder.appendingPathComponent("page.html"))
            try Data(Self.script.utf8).write(to: folder.appendingPathComponent("native.js"))
            let ext = try await WKWebExtension(resourceBaseURL: folder)
            let fixture = WKWebExtensionContext(for: ext)
            fixture.uniqueIdentifier = UUID().uuidString.lowercased()
            fixture.baseURL = URL(string: "webkit-extension://\(fixture.uniqueIdentifier)/")!
            // Explicit synthetic permission isolates delegate semantics. Managed
            // default-off and reviewed context creation have separate controls.
            fixture.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "nativeMessaging"))
            context = fixture
            try host.controller.load(fixture)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                configuration: try XCTUnwrap(fixture.webViewConfiguration))
            let owner = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.contentView = web
            window = owner
            NSApp.setActivationPolicy(.regular)
            owner.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await until("native error fixture foreground") { NSApp.isActive && owner.isKeyWindow && web.window === owner }
            web.load(URLRequest(url: fixture.baseURL.appendingPathComponent("page.html")))
            try await until("native error fixture document") { !web.isLoading && web.title == "Native error fixture" && web.window === owner && owner.isVisible }
            let result = NativeErrorJavaScriptResult()
            web.callAsyncJavaScript("return await window.exerciseNativeErrors();", arguments: [:], in: nil, in: .page) { result.value = $0 }
            try await until("native callback, Promise and port errors") { result.value != nil }
            let values = try XCTUnwrap(try result.value?.get() as? [String: Any])
            XCTAssertEqual(values["responseUndefined"] as? Bool, true)
            XCTAssertEqual(values["lastErrorCleared"] as? Bool, true,
                           "Outside-callback lastError: type=\(values["lastErrorType"] ?? "missing"), null=\(values["lastErrorNull"] ?? "missing"), message=\(values["lastErrorMessage"] ?? "missing")")
            XCTAssertEqual(values["messages"] as? Int, 0)
            XCTAssertEqual(values["disconnects"] as? Int, 1)
            for key in ["callbackError", "promiseError", "portError"] {
                let error = try XCTUnwrap(values[key] as? String)
                XCTAssertTrue(error.contains("Native messaging hosts are unavailable in Vane."), "\(key): \(error)")
                XCTAssertFalse(error.contains("must-not-be-echoed"))
            }
            #if DEBUG
            XCTAssertEqual(host.nativeMessagingDeniedRequestCount, 3, "Both message calls and the port must reach our denial handlers")
            #endif
        } catch { failure = error }
        window?.contentView = nil
        window?.close()
        if let context, context.isLoaded { try? host.controller.unload(context) }
        ExtensionHost.forget(profile)
        try? FileManager.default.removeItem(at: folder)
        do { try await NativeFixtureProfileCleanup.release([profile]) } catch { if failure == nil { failure = error } else { XCTFail("Native error fixture cleanup failed: \(error)") } }
        NSApp.setActivationPolicy(oldPolicy)
        do { try await loop.close() } catch { if failure == nil { failure = error } else { XCTFail("Native error loop cleanup failed: \(error)") } }
        if let failure { throw failure }
    }

    private static let messageSelector = NSSelectorFromString("webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:")
    private static let portSelector = NSSelectorFromString("webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:")
    private static let script = #"""
    window.exerciseNativeErrors = async () => {
      const callback = await new Promise(resolve => browser.runtime.sendNativeMessage('com.vane.test.native',
        {sentinel:'must-not-be-echoed'}, response => resolve({responseUndefined:response === undefined,
          error:browser.runtime.lastError?.message ?? ''})));
      // WebKit clears lastError after native callback dispatch returns. Its
      // Promise microtasks can still run inside that dispatch; cross the event
      // boundary before asserting the callback-scoped error has disappeared.
      await new Promise(resolve => setTimeout(resolve, 0));
      // The real Safari/WebKit API returns null for an absent lastError;
      // Chromium uses undefined. Neither may retain an error outside dispatch.
      const lastErrorCleared = browser.runtime.lastError == null;
      const lastErrorType = typeof browser.runtime.lastError;
      const lastErrorNull = browser.runtime.lastError === null;
      const lastErrorMessage = browser.runtime.lastError?.message ?? 'none';
      let promiseError = 'fulfilled';
      try { await browser.runtime.sendNativeMessage('com.vane.test.native', {sentinel:'must-not-be-echoed'}); }
      catch (error) { promiseError = error.message; }
      let messages = 0, disconnects = 0;
      const port = browser.runtime.connectNative('com.vane.test.native');
      const portError = await new Promise(resolve => {
        port.onMessage.addListener(() => messages++);
        port.onDisconnect.addListener(() => { disconnects++; resolve(browser.runtime.lastError?.message ?? port.error?.message ?? ''); });
        port.postMessage({sentinel:'must-not-be-echoed'});
      });
      return {responseUndefined:callback.responseUndefined,callbackError:callback.error,lastErrorCleared,lastErrorType,lastErrorNull,lastErrorMessage,
        promiseError,portError,messages,disconnects};
    };
    """#
}

@MainActor private final class NativeErrorCompletion { var value = false }
@MainActor private final class NativeErrorJavaScriptResult { var value: Result<Any, any Error>? }
@MainActor private final class NativeErrorSleepGate {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var durations: [Duration] = []
    var pending: Int { continuations.count }
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in continuations[id] = continuation }
        } onCancel: { Task { @MainActor in self.finish(id, error: CancellationError()) } }
    }
    private func finish(_ id: UUID, error: (any Error)? = nil) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func releaseAll() { for id in Array(continuations.keys) { finish(id) } }
}
