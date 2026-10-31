import AppKit
import WebKit
import XCTest
@testable import vane

extension ExtensionNativeMessagingErrorTests {
    func testNativeModeReviewExplainsErrorOnlyPermissionAndBlockedDesktopApps() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let alert = ExtensionConsent.makeNativeMessagingErrorPrompt(.init(name: "Native Mode Fixture"))
        XCTAssertEqual(alert.messageText, "Enable error-only desktop compatibility for “Native Mode Fixture”?")
        XCTAssertEqual(alert.informativeText, "The extension can receive errors when it requests desktop integration. Vane will not connect to desktop apps. Desktop-dependent features remain unavailable.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Enable Error-Only Mode", "Cancel"])
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
    }

    func testOrdinaryApprovalAndRefusedNativeReviewKeepTheAcceptedContext() async throws {
        try await withNativeModeFixture { fixture in
            let host = fixture.host
            let original = try XCTUnwrap(host.installed.first)
            let record = try fixture.recordBytes()
            XCTAssertFalse(original.hasPermission(Self.nativePermission))
            XCTAssertTrue(original.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
            XCTAssertTrue(original.unsupportedAPIs.contains("browser.runtime.connectNative"))
            var reviews = 0
            let accepted = try await host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { review in
                reviews += 1
                XCTAssertEqual(review.name, "Native Mode Fixture")
                XCTAssertEqual(host.profileID, fixture.profile)
                XCTAssertTrue(host.installed.first === original)
                XCTAssertFalse(original.hasPermission(Self.nativePermission))
                return false
            }
            XCTAssertFalse(accepted)
            XCTAssertEqual(reviews, 1, "Ordinary installation approval cannot replace the separate review")
            XCTAssertTrue(host.installed.first === original)
            XCTAssertEqual(try fixture.recordBytes(), record)
        }
    }

    func testExplicitModeSurvivesRestoreAndRevocationDoesNotAddOtherGrants() async throws {
        try await withNativeModeFixture { fixture in
            let original = try XCTUnwrap(fixture.host.installed.first)
            let identity = original.uniqueIdentifier
            let origin = original.baseURL
            let required = Set(original.grantedPermissions.keys.map(\.rawValue))
            let sites = Set(original.grantedPermissionMatchPatterns.keys.map(\.string))
            let cookie = WKWebExtension.Permission(rawValue: "cookies")
            original.setPermissionStatus(.grantedExplicitly, for: cookie)
            let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            XCTAssertTrue(accepted)
            let enabled = try XCTUnwrap(fixture.host.installed.first)
            XCTAssertFalse(enabled === original)
            XCTAssertFalse(original.isLoaded)
            XCTAssertEqual(enabled.uniqueIdentifier, identity)
            XCTAssertEqual(enabled.baseURL, origin)
            XCTAssertTrue(enabled.hasPermission(Self.nativePermission))
            XCTAssertFalse(enabled.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
            XCTAssertFalse(enabled.unsupportedAPIs.contains("browser.runtime.connectNative"))
            XCTAssertEqual(Set(enabled.grantedPermissions.keys.map(\.rawValue)), required.union(["nativeMessaging"]))
            XCTAssertEqual(Set(enabled.grantedPermissionMatchPatterns.keys.map(\.string)), sites)
            XCTAssertFalse(enabled.hasPermission(cookie), "Optional runtime grants follow the existing context-reload rules")
            XCTAssertEqual(try fixture.record().nativeMessagingErrorCompatibilityVersion, 1)
            try await fixture.restart()
            XCTAssertTrue(try XCTUnwrap(fixture.host.installed.first).hasPermission(Self.nativePermission))
            let revoked = try await fixture.host.setNativeMessagingErrorCompatibility(false, for: fixture.folder.path) { _ in
                XCTFail("Revocation cannot require access-expanding approval"); return false
            }
            XCTAssertTrue(revoked)
            XCTAssertNil(try fixture.record().nativeMessagingErrorCompatibilityVersion)
            try await fixture.restart()
            let restored = try XCTUnwrap(fixture.host.installed.first)
            XCTAssertFalse(restored.hasPermission(Self.nativePermission))
            XCTAssertTrue(restored.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
            XCTAssertTrue(restored.unsupportedAPIs.contains("browser.runtime.connectNative"))
            XCTAssertEqual(restored.uniqueIdentifier, identity)
            XCTAssertEqual(Set(restored.grantedPermissions.keys.map(\.rawValue)), required)
        }
    }

    func testOptionalNativeDeclarationCanBeReviewedButUnrequestedNativeCannot() async throws {
        try await withNativeModeFixture(required: ["storage"], optional: ["nativeMessaging", "cookies"]) { fixture in
            let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            XCTAssertTrue(accepted)
            let context = try XCTUnwrap(fixture.host.installed.first)
            XCTAssertTrue(context.hasPermission(Self.nativePermission))
            XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "cookies")))
            fixture.host.revokeRuntimeAccess(context)
            XCTAssertTrue(context.hasPermission(Self.nativePermission),
                          "Separately reviewed error-only mode is revoked through its own control")
        }
        try await withNativeModeFixture(required: ["storage"], optional: ["cookies"]) { fixture in
            let original = try XCTUnwrap(fixture.host.installed.first)
            let before = try fixture.recordBytes()
            do {
                _ = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in
                    XCTFail("An undeclared capability cannot be offered for approval"); return true
                }
                XCTFail("Unrequested native access must fail closed")
            } catch { }
            XCTAssertTrue(fixture.host.installed.first === original)
            XCTAssertEqual(try fixture.recordBytes(), before)
            XCTAssertFalse(original.hasPermission(Self.nativePermission))
        }
    }

    func testDisabledModeChangesStayDisabledThroughRestore() async throws {
        try await withNativeModeFixture { fixture in
            try fixture.host.disable(fixture.folder.path)
            let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            XCTAssertTrue(accepted)
            XCTAssertTrue(fixture.host.installed.isEmpty)
            XCTAssertEqual(try fixture.record().nativeMessagingErrorCompatibilityVersion, 1)
            try await fixture.restart()
            XCTAssertTrue(fixture.host.installed.isEmpty)
            XCTAssertEqual(fixture.host.entries.first?.status, "Disabled")
            let revoked = try await fixture.host.setNativeMessagingErrorCompatibility(false, for: fixture.folder.path) { _ in
                XCTFail("Revoking a disabled extension cannot prompt"); return false
            }
            XCTAssertTrue(revoked)
            XCTAssertTrue(fixture.host.installed.isEmpty)
            XCTAssertNil(try fixture.record().nativeMessagingErrorCompatibilityVersion)
        }
    }

    func testFailedModeMetadataCommitRestoresBothPriorApprovalStates() async throws {
        for priorEnabled in [false, true] {
            try await withNativeModeFixture { fixture in
                if priorEnabled {
                    let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
                    XCTAssertTrue(accepted)
                }
                let old = try XCTUnwrap(fixture.host.installed.first)
                let original = try fixture.recordBytes()
                let index = fixture.store.root.appendingPathComponent("installations.json")
                let savedIndex = try Data(contentsOf: index)
                try FileManager.default.removeItem(at: index)
                try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
                defer {
                    try? FileManager.default.removeItem(at: index)
                    try? savedIndex.write(to: index)
                }
                do {
                    _ = try await fixture.host.setNativeMessagingErrorCompatibility(!priorEnabled, for: fixture.folder.path) { _ in true }
                    XCTFail("A failed accepted-record commit cannot adopt the candidate mode")
                } catch { }
                let recovered = try XCTUnwrap(fixture.host.installed.first)
                XCTAssertEqual(recovered.uniqueIdentifier, old.uniqueIdentifier)
                XCTAssertEqual(recovered.baseURL, old.baseURL)
                XCTAssertEqual(recovered.hasPermission(Self.nativePermission), priorEnabled)
                XCTAssertEqual(fixture.host.controller.extensionContexts.count, 1)
                try FileManager.default.removeItem(at: index)
                try savedIndex.write(to: index)
                XCTAssertEqual(try fixture.recordBytes(), original)
            }
        }
    }

    func testRemovingOrForgettingInstallationDuringReviewCannotAdoptApproval() async throws {
        for forgetProfile in [false, true] {
            try await withNativeModeFixture { fixture in
                let original = try XCTUnwrap(fixture.host.installed.first)
                do {
                    _ = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in
                        if forgetProfile { ExtensionHost.forget(fixture.profile) }
                        else { try! fixture.host.remove(folder: fixture.folder.path) }
                        return true
                    }
                    XCTFail("Approval delivered after invalidation must be rejected")
                } catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertFalse(original.isLoaded)
                XCTAssertFalse(fixture.host.installed.contains { $0.hasPermission(Self.nativePermission) })
                XCTAssertNil(try fixture.store.records()[fixture.folder.path]?.nativeMessagingErrorCompatibilityVersion)
            }
        }
    }

    func testCancellingNativeReviewCannotChangeTheAcceptedMode() async throws {
        try await withNativeModeFixture { fixture in
            let original = try XCTUnwrap(fixture.host.installed.first)
            let before = try fixture.recordBytes()
            let change = Task { @MainActor in
                try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            }
            do { _ = try await change.value; XCTFail("Cancelled review cannot adopt approval") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(fixture.host.installed.first === original)
            XCTAssertTrue(original.isLoaded)
            XCTAssertEqual(try fixture.recordBytes(), before)
        }
    }

    #if DEBUG
    func testCancellationDuringRealBackgroundActivationRecoversBothPriorModes() async throws {
        for priorEnabled in [false, true] {
            try await withNativeModeFixture(hasBackground: true) { fixture in
                let host = fixture.host
                if priorEnabled {
                    let accepted = try await host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
                    XCTAssertTrue(accepted)
                }
                let original = try XCTUnwrap(host.installed.first)
                let before = try fixture.recordBytes()
                let operation = NativeModeCancellationOperation()
                // Observe genuine SDK creation; cancel the caller once, without
                // changing the webview, callback, resources, or native result.
                host.backgroundCreationObserver = { _, context in
                    guard operation.enteredContext == nil else { return }
                    operation.enteredContext = context
                    operation.task?.cancel()
                }
                defer { host.backgroundCreationObserver = nil; operation.task = nil }
                let change = Task { @MainActor in
                    try await host.setNativeMessagingErrorCompatibility(!priorEnabled, for: fixture.folder.path) { _ in true }
                }
                operation.task = change
                do { _ = try await change.value; XCTFail("Cancelled background activation cannot commit the new mode") }
                catch { XCTAssertTrue(error is CancellationError) }
                let candidate = try XCTUnwrap(operation.enteredContext, "Cancellation must follow real SDK background creation")
                XCTAssertFalse(candidate === original)
                XCTAssertFalse(candidate.isLoaded)
                let recovered = try XCTUnwrap(host.installed.first)
                XCTAssertFalse(recovered === candidate)
                XCTAssertTrue(recovered.isLoaded)
                XCTAssertEqual(recovered.uniqueIdentifier, original.uniqueIdentifier)
                XCTAssertEqual(recovered.baseURL, original.baseURL)
                XCTAssertEqual(recovered.hasPermission(Self.nativePermission), priorEnabled)
                XCTAssertEqual(host.controller.extensionContexts.count, 1)
                XCTAssertEqual(try fixture.recordBytes(), before)
            }
        }
    }
    #endif

    func testUpdateRetainsApprovalOnlyWhileNativeRemainsDeclared() async throws {
        try await withNativeModeFixture { fixture in
            let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            XCTAssertTrue(accepted)
            try fixture.write(version: "2", required: ["storage", "nativeMessaging"], optional: ["cookies"])
            let updated = try await fixture.host.refresh(fixture.folder.path) { _ in true }
            XCTAssertTrue(updated)
            XCTAssertEqual(try fixture.record().nativeMessagingErrorCompatibilityVersion, 1)
            XCTAssertTrue(try XCTUnwrap(fixture.host.installed.first).hasPermission(Self.nativePermission))
            try fixture.write(version: "3", required: ["storage"], optional: ["cookies"])
            _ = try await fixture.host.refresh(fixture.folder.path) { _ in true }
            XCTAssertNil(try fixture.record().nativeMessagingErrorCompatibilityVersion)
            try fixture.write(version: "4", required: ["storage", "nativeMessaging"], optional: ["cookies"])
            _ = try await fixture.host.refresh(fixture.folder.path) { _ in true }
            XCTAssertNil(try fixture.record().nativeMessagingErrorCompatibilityVersion)
            XCTAssertFalse(try XCTUnwrap(fixture.host.installed.first).hasPermission(Self.nativePermission))
        }
    }

    func testNativeApprovalDoesNotCrossProfilesAndUnknownVersionsStayClosed() async throws {
        try await withNativeModeFixture { fixture in
            let accepted = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            XCTAssertTrue(accepted)
            let other = fixture.otherHost()
            let installed = try await other.load(fixture.folder, installing: true) { _ in true }
            XCTAssertTrue(installed)
            let context = try XCTUnwrap(other.installed.first)
            XCTAssertFalse(context.hasPermission(Self.nativePermission))
            XCTAssertTrue(context.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
            let otherStore = ExtensionCodeStore(profileID: other.profileID)
            XCTAssertNil(try otherStore.records()[fixture.folder.path]?.nativeMessagingErrorCompatibilityVersion)
            XCTAssertNotEqual(context.baseURL, fixture.host.installed.first?.baseURL)
            var record = try fixture.record()
            record.nativeMessagingErrorCompatibilityVersion = 2
            try fixture.store.save([fixture.folder.path: record])
            try await fixture.restart()
            let unknown = try XCTUnwrap(fixture.host.installed.first)
            XCTAssertFalse(unknown.hasPermission(Self.nativePermission))
            XCTAssertTrue(unknown.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
            XCTAssertTrue(unknown.unsupportedAPIs.contains("browser.runtime.connectNative"))
        }
    }

    func testNativeModeManagementEntriesFollowAcceptedProfileDeclarationAndMode() async throws {
        try await withNativeModeFixture { fixture in
            let off = try XCTUnwrap(fixture.host.entries.first)
            XCTAssertTrue(off.nativeMessagingErrorCompatibilityAvailable)
            XCTAssertFalse(off.nativeMessagingErrorCompatibilityEnabled)
            let other = fixture.otherHost()
            XCTAssertTrue(other.entries.isEmpty, "Another profile has no control for this installation")
            _ = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true }
            let on = try XCTUnwrap(fixture.host.entries.first)
            XCTAssertTrue(on.nativeMessagingErrorCompatibilityAvailable)
            XCTAssertTrue(on.nativeMessagingErrorCompatibilityEnabled)
            XCTAssertTrue(fixture.host.diagnostic(for: on).contains("Error-only mode enabled. Desktop apps remain blocked."))
            try fixture.host.disable(fixture.folder.path)
            XCTAssertTrue(try XCTUnwrap(fixture.host.entries.first).nativeMessagingErrorCompatibilityEnabled,
                          "A disabled installation retains its explicitly approved choice")
            _ = try await fixture.host.setNativeMessagingErrorCompatibility(false, for: fixture.folder.path) { _ in false }
            XCTAssertFalse(try XCTUnwrap(fixture.host.entries.first).nativeMessagingErrorCompatibilityEnabled)
            let privateHost = ExtensionHost.host(for: Profile.incognito.id)
            XCTAssertTrue(privateHost.entries.isEmpty)
        }
        try await withNativeModeFixture(required: ["storage"], optional: []) { fixture in
            let entry = try XCTUnwrap(fixture.host.entries.first)
            XCTAssertFalse(entry.nativeMessagingErrorCompatibilityAvailable)
            XCTAssertFalse(entry.nativeMessagingErrorCompatibilityEnabled)
        }
        let unmanaged = ExtensionHost.Entry(path: "unmanaged", name: "Unmanaged", context: nil,
                                            status: "Inactive", failure: nil, busy: false)
        XCTAssertFalse(unmanaged.nativeMessagingErrorCompatibilityAvailable)
        XCTAssertFalse(unmanaged.nativeMessagingErrorCompatibilityEnabled)
    }

    func testRetryFixtureAdmitsRegularPolicyAndRestoresOnlyAfterLoopJoin() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        enum DeliberateFailure: Error { case body }
        let previous = app.activationPolicy()
        defer { app.setActivationPolicy(previous) }
        for throwFromBody in [false, true] {
            let requestAccepted = app.setActivationPolicy(.accessory)
            print("Native retry fixture baseline: setterAccepted=\(requestAccepted), observed=\(app.activationPolicy().rawValue)")
            try await waitNativeModePage("observable nonregular policy baseline") { app.activationPolicy() == .accessory }
            do {
                try await withNativeModeFixture(retryPage: true) { fixture in
                    try fixture.verifyRunning()
                    XCTAssertEqual(app.activationPolicy(), .regular,
                                   "A retry window must be created inside a lease that already admits regular policy")
                    if throwFromBody { throw DeliberateFailure.body }
                }
                XCTAssertFalse(throwFromBody, "The deliberate body error must propagate after cleanup")
            } catch DeliberateFailure.body { XCTAssertTrue(throwFromBody) }
            XCTAssertFalse(app.isRunning, "The owned AppKit loop joins before restoring policy")
            try await waitNativeModePage("observed original policy after joined cleanup") { app.activationPolicy() == .accessory }
            XCTAssertEqual(app.activationPolicy(), .accessory,
                           "Success and body-error paths restore the observed baseline after teardown and join")
        }
    }

    func testReviewedSequentialRetriesYieldToTheExtensionPageTimer() async throws {
        try await exerciseSequentialRetries(approvedModes: [false, true], injectObservedHide: false)
    }

    func testRetryPageReadmitsObservedOwnedApplicationHideBeforeAction() async throws {
        try await exerciseSequentialRetries(approvedModes: [true], injectObservedHide: true)
    }

    private func exerciseSequentialRetries(approvedModes: [Bool], injectObservedHide: Bool) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let lifecycleTrace = NativeModePageTrace(window: nil)
        defer { lifecycleTrace.close() }
        for approved in approvedModes {
            lifecycleTrace.record("before fixture approved=\(approved)")
            try await withNativeModeFixture(retryPage: true, lifecycleTrace: lifecycleTrace) { fixture in
                if approved { _ = try await fixture.host.setNativeMessagingErrorCompatibility(true, for: fixture.folder.path) { _ in true } }
                try fixture.verifyRunning()
                let context = try XCTUnwrap(fixture.host.installed.first)
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 240),
                                    configuration: try XCTUnwrap(context.webViewConfiguration))
                let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let trace = NativeModePageTrace(window: window)
                let oldDelegate = web.navigationDelegate
                if oldDelegate == nil { web.navigationDelegate = trace }
                defer {
                    trace.close()
                    if web.navigationDelegate === trace { web.navigationDelegate = oldDelegate }
                    web.stopLoading(); window.contentView = nil; window.close()
                }
                window.contentView = web
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await waitNativeModePage("retry page foreground") { NSApp.isActive && window.isKeyWindow && web.window === window }
                web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
                var actionInvoked = false
                if injectObservedHide {
                    // Inject only after the original exact-owner foreground gate.
                    NSApp.hide(nil)
                    try await waitNativeModePage("observable injected application hide") {
                        NSApp.isHidden && !window.isVisible && web.window === window
                    }
                    try await waitNativeModePage("hidden control document loaded") {
                        !web.isLoading && web.title == "Sequential retry fixture" && web.window === window
                    }
                    let count = NativeModeRetryResult()
                    web.callAsyncJavaScript("return window.nativeRetryActionStarts;", arguments: [:], in: nil, in: .page) {
                        count.value = $0
                    }
                    try await waitNativeModePage("hidden control action count") { count.value != nil }
                    XCTAssertEqual(try count.value?.get() as? Int, 0)
                    print("NATIVE_MODE_HIDE_CONTROL observedHidden=\(NSApp.isHidden) visible=\(window.isVisible) owner=\(web.window === window) actionInvoked=\(actionInvoked) actionStarts=0")
                }
                try await waitNativeModePage("retry page loaded in exact owner", diagnostics: {
                    "approved=\(approved), hidden=\(NSApp.isHidden), actionInvoked=\(actionInvoked), policy=\(NSApp.activationPolicy().rawValue), background=\(context.webExtension.hasBackgroundContent), prepared=\(ExtensionWorkerIdentity.identity(of: context.webExtension) != nil), loading=\(web.isLoading), title=\(web.title ?? "nil"), url=\(web.url?.absoluteString ?? "nil"), owner=\(web.window === window), visible=\(window.isVisible), active=\(NSApp.isActive), key=\(window.isKeyWindow), keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1), frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), titleGate=\(web.title == "Sequential retry fixture"), trace=\(trace.events.joined(separator: " | "))"
                }) {
                    !web.isLoading && web.title == "Sequential retry fixture" && web.window === window && window.isVisible
                        && NSApp.isActive && window.isKeyWindow
                }
                #if DEBUG
                let before = fixture.host.nativeMessagingDeniedRequestCount
                #endif
                try fixture.verifyRunning()
                let result = NativeModeRetryResult()
                actionInvoked = true
                web.callAsyncJavaScript("return await window.exerciseNativeRetries();", arguments: [:], in: nil, in: .page) {
                    result.value = $0
                }
                try await waitNativeModePage("bounded retries and page timer") { result.value != nil }
                let values = try XCTUnwrap(try result.value?.get() as? [String: Any])
                if injectObservedHide { XCTAssertEqual(values["actionStarts"] as? Int, 1) }
                XCTAssertEqual(values["attempts"] as? Int, 3)
                XCTAssertEqual(values["errors"] as? Int, 3)
                XCTAssertEqual(values["replies"] as? Int, 0)
                XCTAssertEqual(values["microtasks"] as? Int, 3)
                XCTAssertGreaterThan(try XCTUnwrap(values["finalTicks"] as? Int), 0)
                if approved {
                    XCTAssertEqual(values["nativeType"] as? String, "function")
                    XCTAssertGreaterThan(try XCTUnwrap(values["ticksAtCompletion"] as? Int), 0,
                                         "Real SDK error replies must let the page's timer run during sequential retries")
                    XCTAssertEqual(values["unavailableErrors"] as? Int, 3)
                    #if DEBUG
                    XCTAssertEqual(fixture.host.nativeMessagingDeniedRequestCount - before, 3)
                    #endif
                } else {
                    XCTAssertEqual(values["nativeType"] as? String, "undefined")
                    XCTAssertEqual(values["ticksAtCompletion"] as? Int, 0,
                                   "The bounded hidden-API control must reproduce the microtask-before-timer ordering")
                    #if DEBUG
                    XCTAssertEqual(fixture.host.nativeMessagingDeniedRequestCount, before)
                    #endif
                }
            }
        }
    }

    @MainActor private final class NativeModePageTrace: NSObject, WKNavigationDelegate {
        private(set) var events: [String] = []
        private var observers: [NSObjectProtocol] = []
        private let start = ContinuousClock.now
        init(window: NSWindow?) {
            super.init()
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.willHideNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                let windowEvent = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].contains(name)
                if windowEvent && window == nil { continue }
                let owner: Any? = windowEvent ? window : nil
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] note in
                    let event = note.name.rawValue
                    let willHide = note.name == NSApplication.willHideNotification
                    MainActor.assumeIsolated {
                        self?.record(event)
                        if willHide {
                            self?.record("willHide stack=" + Thread.callStackSymbols.joined(separator: " | "))
                        }
                    }
                })
            }
        }
        func close() { observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll() }
        func record(_ text: String) {
            note(text)
            print("NATIVE_MODE_LIFECYCLE " + (events.last ?? text))
        }
        private func note(_ text: String) {
            let elapsed = start.duration(to: .now).components
            events.append("\(elapsed.seconds)s+\(elapsed.attoseconds / 1_000_000_000_000_000)ms hidden=\(NSApp.isHidden) policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) " + text)
            if events.count > 32 { events.removeFirst() }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { note("navigation start") }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { note("navigation commit") }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { note("navigation finish") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let error = error as NSError; note("provisional failure \(error.domain):\(error.code)")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let error = error as NSError; note("navigation failure \(error.domain):\(error.code)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { note("content process terminated") }
    }

    private func waitNativeModePage(_ description: String, diagnostics: () -> String = { "" }, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description + " " + diagnostics()) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let nativePermission = WKWebExtension.Permission(rawValue: "nativeMessaging")

    private func withNativeModeFixture(required: [String] = ["storage", "nativeMessaging"], optional: [String] = ["cookies"], hasBackground: Bool = false, retryPage: Bool = false, lifecycleTrace: NativeModePageTrace? = nil,
        _ body: @MainActor (NativeModeFixture) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        lifecycleTrace?.record("fixture capture originalPolicy=\(originalPolicy.rawValue)")
        defer {
            // Covers acquisition failures too; successful acquisitions are closed
            // and joined below before this caller-owned policy is restored.
            if application.activationPolicy() != originalPolicy {
                lifecycleTrace?.record("restore policy request=\(originalPolicy.rawValue)")
                application.setActivationPolicy(originalPolicy)
                lifecycleTrace?.record("restore policy returned")
            }
        }
        lifecycleTrace?.record("before acquire requestedPolicy=\(retryPage ? "regular" : "current")")
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: retryPage ? .regular : nil)
        lifecycleTrace?.record("after acquire")
        let fixture = NativeModeFixture(hasBackground: hasBackground, retryPage: retryPage,
                                        verifyRunning: { try loop.verifyRunning() })
        var failure: (any Error)?
        do {
            try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
            try fixture.write(version: "1", required: required, optional: optional)
            let accepted = try await fixture.host.load(fixture.folder, installing: true) { _ in true }
            XCTAssertTrue(accepted)
            try await body(fixture)
        } catch { failure = error }
        // Invalidation tests can have forgotten the first host. Retire any new
        // restoration before releasing the exact profile and its scoped backend.
        for profile in fixture.profiles {
            let cleanupHost = ExtensionHost.host(for: profile)
            for entry in cleanupHost.entries { try? cleanupHost.remove(folder: entry.path) }
            ExtensionHost.forget(profile)
            for key in [ExtensionHost.baseKey, ExtensionHost.identifiersKey, ExtensionHost.namesKey,
                        ExtensionHost.disabledKey, ExtensionHost.bookmarksKey, ExtensionConsent.baseKey, ExtensionPins.key] {
                UserDefaults.vane.removeObject(forKey: ProfileManager.defaultsKey(key, profile))
            }
        }
        try? FileManager.default.removeItem(at: fixture.folder)
        do { try await NativeFixtureProfileCleanup.release(fixture.profiles) }
        catch { if failure == nil { failure = error } else { XCTFail("Mode fixture profile cleanup: \(error)") } }
        lifecycleTrace?.record("before loop close")
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Mode fixture loop cleanup: \(error)") } }
        lifecycleTrace?.record("after loop join running=\(application.isRunning)")
        if let failure { throw failure }
    }
}

@MainActor private final class NativeModeFixture {
    let profile = UUID()
    private var otherProfiles = Set<UUID>()
    var profiles: Set<UUID> { otherProfiles.union([profile]) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-mode-" + UUID().uuidString).resolvingSymlinksInPath()
    lazy var host = ExtensionHost.host(for: profile)
    private let hasBackground: Bool
    private let retryPage: Bool
    let verifyRunning: @MainActor () throws -> Void
    init(hasBackground: Bool, retryPage: Bool, verifyRunning: @escaping @MainActor () throws -> Void) {
        self.hasBackground = hasBackground; self.retryPage = retryPage; self.verifyRunning = verifyRunning
    }
    var store: ExtensionCodeStore { ExtensionCodeStore(profileID: profile) }
    func otherHost() -> ExtensionHost {
        let other = UUID()
        otherProfiles.insert(other)
        return ExtensionHost.host(for: other)
    }
    func record() throws -> ExtensionCodeStore.Record { try XCTUnwrap(store.records()[folder.path]) }
    func recordBytes() throws -> Data {
        // Preserve the actual accepted commit bytes. Re-encoding Codable Sets
        // can reorder their arrays even when every accepted value is identical.
        try Data(contentsOf: store.root.appendingPathComponent("installations.json"))
    }
    func write(version: String, required: [String], optional: [String]) throws {
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Native Mode Fixture", "version": version,
            "permissions": required, "optional_permissions": optional, "host_permissions": ["https://mode.example/*"]]
        if retryPage {
            manifest["options_ui"] = ["page": "retry.html"]
            try Data("<title>Sequential retry fixture</title><script src='retry.js'></script>".utf8)
                .write(to: folder.appendingPathComponent("retry.html"))
            try Data(Self.retryScript.utf8).write(to: folder.appendingPathComponent("retry.js"))
        }
        if hasBackground {
            manifest["manifest_version"] = 2
            manifest["permissions"] = required + ["https://mode.example/*"]
            manifest.removeValue(forKey: "host_permissions")
            manifest["background"] = ["scripts": ["background.js"], "persistent": true]
            try Data("globalThis.nativeModeFixtureStarted = true;".utf8).write(to: folder.appendingPathComponent("background.js"))
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }
    private static let retryScript = #"""
    window.nativeRetryActionStarts = 0;
    window.exerciseNativeRetries = async () => {
      window.nativeRetryActionStarts++;
      let ticks = 0, attempts = 0, errors = 0, replies = 0, unavailableErrors = 0, microtasks = 0;
      const nativeType = typeof browser.runtime.sendNativeMessage;
      const timer = setInterval(() => ticks++, 0);
      // Match an extension's async wrapper: an absent API becomes a rejected
      // Promise, so the caller retries through microtasks rather than a plain loop.
      const send = async () => browser.runtime.sendNativeMessage('com.vane.sequential-fixture', {kind:'bounded-test'});
      for (let index = 0; index < 3; index++) {
        attempts++;
        queueMicrotask(() => microtasks++);
        try { await send(); replies++; }
        catch (error) {
          errors++;
          if (String(error.message).includes('Native messaging hosts are unavailable in Vane.')) unavailableErrors++;
        }
      }
      const ticksAtCompletion = ticks;
      await new Promise(resolve => setTimeout(resolve, 0));
      clearInterval(timer);
      return {nativeType,attempts,errors,replies,unavailableErrors,microtasks,ticksAtCompletion,finalTicks:ticks,actionStarts:window.nativeRetryActionStarts};
    };
    """#
    func restart() async throws {
        ExtensionHost.forget(profile)
        host = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(5)
        while host.isBusy {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Mode fixture restore did not complete") }
            await Task.yield()
        }
    }
}

#if DEBUG
@MainActor private final class NativeModeCancellationOperation {
    var task: Task<Bool, any Error>?
    var enteredContext: WKWebExtensionContext?
}
#endif

@MainActor private final class NativeModeRetryResult { var value: Result<Any, any Error>? }
