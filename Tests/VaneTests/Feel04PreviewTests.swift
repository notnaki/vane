import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

@MainActor private final class Feel04Loader: FavouritePreviewLoading {
    var contexts: [FavouritePreviewContext] = []
    var replies: [CheckedContinuation<FavouritePreviewResult, Never>] = []
    var completed = 0
    func load(_ context: FavouritePreviewContext) async -> FavouritePreviewResult {
        contexts.append(context)
        let result = await withCheckedContinuation { replies.append($0) }
        completed += 1
        return result
    }
    func cancel() {}
    func finish(_ result: FavouritePreviewResult = .ready(.init(account: "fixture", items: []))) {
        let pending = replies; replies = []
        pending.forEach { $0.resume(returning: result) }
    }
}

@MainActor final class Feel04PreviewTests: XCTestCase {
    private func context(_ profile: UUID = UUID()) -> FavouritePreviewContext {
        FavouritePreviewContext(profileID: profile, url: URL(string: "https://github.com/")!)!
    }
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testRepeatedRequestDoesNotCancelOrLoseInflightResultToCooldown() async throws {
        TestEnvironment.prepare()
        let loader = Feel04Loader()
        let coordinator = FavouritePreviews(loader: loader), target = context(), owner = UUID()
        defer { coordinator.dismiss(owner: owner); loader.finish() }
        coordinator.request(target, owner: owner, account: "fixture")
        try await settle { loader.contexts.count == 1 }
        coordinator.request(target, owner: owner, account: "fixture")
        loader.finish()
        try await settle { coordinator.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.contexts.count, 1)
    }

    func testCardKeepsReferenceGeometryAsContentArrives() throws {
        TestEnvironment.prepare()
        let target = context()
        let items = (1...5).map { FavouritePreviewItem(title: "Pull request \($0)", subtitle: "owner/repo", url: URL(string: "https://github.com/owner/repo/pull/\($0)")!) }
        let states: [FavouritePreviewState] = [.loading, .signedOut, .unavailable,
            .ready(.init(account: "fixture", items: items)), .stale(.init(account: "fixture", items: items))]
        let sizes = states.map { state in
            let host = NSHostingView(rootView: FavouritePreviewCard(context: target, state: state, open: { _ in }, dismiss: {}))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        for size in sizes { XCTAssertEqual(size, sizes[0]) }
        XCTAssertEqual(sizes[0].width, 240)
        XCTAssertEqual(sizes[0].height, 270)
    }
}

@MainActor final class Feel04PreparationTests: XCTestCase {
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testIntentSeparatesPreparationFromOpeningAndCancelsSweeps() async throws {
        let clock = Feel04DebounceFixture(), hover = FavouritePreviewHover(sleep: clock.sleep)
        defer { hover.dismiss(); clock.finish() }
        hover.setHovered(true, over: .tile)
        try await clock.waitUntil { clock.count == 1 }
        XCTAssertFalse(hover.preparing)
        hover.setHovered(false, over: .tile)
        clock.release(0)
        try await clock.waitUntil { clock.completed.contains(0) }
        XCTAssertFalse(hover.preparing)
        XCTAssertFalse(hover.visible)
        hover.setHovered(true, over: .tile)
        try await clock.waitUntil { clock.count == 2 }
        clock.release(1)
        try await clock.waitUntil { hover.preparing && clock.count == 3 }
        XCTAssertFalse(hover.visible)
        clock.release(2)
        try await clock.waitUntil { hover.visible }
        hover.openForKeyboard()
        hover.setHovered(false, over: .tile)
        XCTAssertTrue(hover.visible)
        hover.dismiss()
        XCTAssertFalse(hover.preparing)
    }
    func testPromotionAndQuickReturnReusePreparationWithoutRestart() async throws {
        TestEnvironment.prepare()
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader)
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com")!)!, owner = UUID()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { previews.dismiss(owner: owner); loader.finish(); BatterySaver.shared.setMode(mode) }
        previews.prepare(target, owner: owner)
        try await settle { loader.contexts.count == 1 }
        previews.request(target, owner: owner)
        loader.finish()
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.contexts.count, 1)
        previews.invalidate(profileID: target.profileID)
        previews.prepare(target, owner: owner)
        try await settle { loader.contexts.count == 2 }
        previews.dismiss(owner: owner)
        previews.prepare(target, owner: owner)
        XCTAssertEqual(loader.contexts.count, 2)
        previews.request(target, owner: owner)
        loader.finish()
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.contexts.count, 2)
    }
    func testPrivateDisabledAndBatterySavingPreparationNeverLoads() async throws {
        TestEnvironment.prepare()
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader)
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com")!)!, owner = UUID()
        let enabled = UserDefaults.vane.object(forKey: FavouritePreviews.enabledKey)
        let mode = BatterySaver.shared.mode
        defer {
            previews.dismiss(owner: owner); loader.finish(); BatterySaver.shared.setMode(mode)
            UserDefaults.vane.set(enabled, forKey: FavouritePreviews.enabledKey)
        }
        previews.prepare(target, owner: owner, privateSession: true)
        UserDefaults.vane.set(false, forKey: FavouritePreviews.enabledKey)
        previews.prepare(target, owner: owner)
        UserDefaults.vane.set(true, forKey: FavouritePreviews.enabledKey)
        BatterySaver.shared.setMode(.alwaysOn)
        previews.prepare(target, owner: owner)
        await Task.yield()
        XCTAssertEqual(loader.contexts.count, 0)
    }
}

@MainActor final class Feel04LinkPreviewTests: XCTestCase {
    func testSameURLCannotReusePrivateSnapshotInAnotherTab() {
        TestEnvironment.prepare()
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        let previews = Previews(), first = Tab(isPrivate: true), second = Tab(isPrivate: true)
        defer { previews.cancel(); first.tearDown(); second.tearDown(); Previews.enabled = enabled; BatterySaver.shared.setMode(mode) }
        let url = URL(string: "https://example.test/preview")!
        previews.request(url, from: first)
        var snapshot = Previews.Preview(url: url, title: "Private account", image: NSImage())
        snapshot.loading = false
        previews.publish(snapshot, for: previews.begin())
        previews.request(url, from: second)
        XCTAssertNil(previews.current?.image)
        XCTAssertNotEqual(previews.current?.title, "Private account")
        XCTAssertEqual(previews.current?.url, url, "The new shell should publish synchronously")
    }
    func testDisablingPreviewsRetiresAnAlreadyVisibleShell() {
        TestEnvironment.prepare()
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        let previews = Previews(), tab = Tab(isPrivate: true)
        defer { previews.cancel(); tab.tearDown(); Previews.enabled = enabled; BatterySaver.shared.setMode(mode) }
        let url = URL(string: "https://example.test/preview")!
        previews.request(url, from: tab)
        XCTAssertNotNil(previews.current)
        Previews.enabled = false
        previews.request(url, from: tab)
        XCTAssertNil(previews.current)
    }
}

@MainActor final class Feel04PanelTests: XCTestCase {
    func testDismissalIsNoninteractiveAndOldCompletionCannotCloseReopenedPanel() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor; owner.makeKeyAndOrderFront(nil)
        let content = AnyView(Text("Preview fixture").frame(width: 370, height: 180))
        defer { anchor.hide(); owner.contentView = nil; owner.close() }
        anchor.configure(visible: true, keyboard: true, content: content, dismiss: {})
        let old = try XCTUnwrap(owner.childWindows?.first)
        anchor.configure(visible: false, keyboard: false, content: content, dismiss: {})
        if old.isVisible {
            XCTAssertTrue(old.ignoresMouseEvents)
            XCTAssertFalse(old.canBecomeKey)
            XCTAssertFalse(old.isKeyWindow)
        }
        anchor.configure(visible: true, keyboard: false, content: content, dismiss: {})
        let reopened = try XCTUnwrap(owner.childWindows?.first)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(reopened.isVisible)
        XCTAssertEqual(reopened.alphaValue, 1)
        XCTAssertFalse(reopened.ignoresMouseEvents)
        XCTAssertEqual(owner.childWindows?.count, 1)
        anchor.hide()
        XCTAssertTrue(owner.childWindows?.isEmpty ?? true)
        XCTAssertNil(old.contentView)
    }

    func testReducedMotionUsesImmediateFramesAndDismissal() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor; owner.makeKeyAndOrderFront(nil)
        defer { anchor.hide(); owner.contentView = nil; owner.close(); BatterySaver.shared.setMode(mode) }
        let content = AnyView(Text("Preview fixture").frame(width: 370, height: 180))
        anchor.configure(visible: true, keyboard: false, content: content, dismiss: {})
        let panel = try XCTUnwrap(owner.childWindows?.first)
        XCTAssertEqual(panel.alphaValue, 1)
        anchor.configure(visible: false, keyboard: false, content: content, dismiss: {})
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(owner.childWindows?.isEmpty ?? true)
    }
}

@MainActor final class Feel04SessionTests: XCTestCase {
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testPreparationCannotSurviveSessionInvalidationOrReplaceAnotherOwnersReply() async throws {
        TestEnvironment.prepare()
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader)
        let a = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com")!)!
        let b = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com")!)!
        let first = UUID(), second = UUID(), mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { previews.dismiss(owner: second); loader.finish(); BatterySaver.shared.setMode(mode) }
        previews.prepare(a, owner: first)
        try await settle { loader.contexts.count == 1 }
        previews.sessionChanged(profileID: a.profileID)
        loader.finish()
        await Task.yield()
        XCTAssertEqual(previews.state, .unavailable)
        XCTAssertEqual(loader.contexts.count, 1, "Session changes must not restart speculative preparation")
        previews.prepare(a, owner: first)
        try await settle { loader.contexts.count == 2 }
        previews.prepare(b, owner: second)
        try await settle { loader.contexts.count == 3 }
        previews.dismiss(owner: first)
        XCTAssertEqual(previews.owner, second)
        previews.request(b, owner: second)
        loader.finish()
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(previews.owner, second)
    }
}

/// Execute the real identity script, mutate the same real DOM after its read, then
/// promote before delivering that earlier reply. Only this source owns the gate.
@MainActor private final class Feel04AccountProofSource: WKWebView {
    var gateNextIdentity = false
    var changesAccount = true
    var captured: ((String?, String?, Duration) -> Void)?
    private(set) var gated = false
    private(set) var identityReplies: [String] = []

    override func __evaluateJavaScript(_ script: String, inFrame frame: WKFrameInfo?, in world: WKContentWorld,
                                      completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        guard gateNextIdentity, script == DOMFavouritePreviewAdapter(service: .github).identityScript else {
            super.__evaluateJavaScript(script, inFrame: frame, in: world) { [weak self] value, error in
                if script == DOMFavouritePreviewAdapter(service: .github).identityScript {
                    self?.identityReplies.append(value as? String ?? "<missing>")
                }
                completionHandler?(value, error)
            }
            return
        }
        gateNextIdentity = false
        let started = ContinuousClock.now
        let mutation = """
        (() => {
          const proof = (\(script));
          const meta = document.querySelector('meta[name="user-login"]');
          \(changesAccount ? "meta.content = 'other';" : "")
          return {proof, current: meta.content};
        })()
        """
        super.__evaluateJavaScript(mutation, inFrame: frame, in: world) { [weak self] value, error in
            guard let self else { completionHandler?(nil, error); return }
            let values = value as? [String: String]
            self.gated = true
            self.identityReplies.append(values?["proof"] ?? "<missing>")
            self.captured?(values?["proof"], values?["current"], ContinuousClock.now - started)
            completionHandler?(values?["proof"], error)
        }
    }
}

@MainActor final class Feel04AccountProofTests: XCTestCase {
    private func settle(_ condition: () -> Bool, diagnostics: () -> String = { "" },
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), diagnostics(), file: file, line: line)
    }
    private func diagnostics(_ previews: FavouritePreviews, source: WKWebView, loader: Feel04Loader) -> String {
        let fields = Set(["generation", "loading", "loadingOwner", "preparing", "preparedState", "accountHint"])
        let internals = Mirror(reflecting: previews).children.compactMap { child -> String? in
            guard let label = child.label, fields.contains(label) else { return nil }
            return "\(label)=\(String(describing: child.value))"
        }.joined(separator: ", ")
        return "state=\(previews.state), owner=\(String(describing: previews.owner)), \(internals), "
            + "loader=\(loader.contexts.count)/\(loader.completed), source=\(String(describing: source.url)), "
            + "loading=\(source.isLoading), mounted=\(source.window != nil), appRunning=\(NSApp.isRunning)"
    }
    func testPreparedSnapshotRechecksLiveAccountBeforePresentation() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader), source = WKWebView()
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!, owner = UUID()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { previews.dismiss(owner: owner); loader.finish(); source.stopLoading(); BatterySaver.shared.setMode(mode) }
        source.loadHTMLString("<meta name='user-login' content='fixture'><body>Fixture</body>", baseURL: target.siteURL)
        try await settle { source.url == target.siteURL && !source.isLoading }
        previews.prepare(target, owner: owner, source: source)
        try await settle { loader.contexts.count == 1 }
        loader.finish()
        try await settle { loader.completed == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(previews.state, .loading, "Preparation must not expose account content before the card opens")
        let changedAccount = try await source.evaluateJavaScript("document.querySelector('meta').content = 'other'") as? String
        print("ACCOUNT PROOF before promotion: changed=\(String(describing: changedAccount)), \(diagnostics(previews, source: source, loader: loader))")
        previews.request(target, owner: owner, source: source)
        try await settle({ previews.state == .unavailable }, diagnostics: {
            "changed=\(String(describing: changedAccount)), \(self.diagnostics(previews, source: source, loader: loader))"
        })
        print("ACCOUNT PROOF after promotion: \(diagnostics(previews, source: source, loader: loader))")
        XCTAssertEqual(loader.contexts.count, 1)
    }

    func testPromotionDuringAccountVerificationRechecksBeforePublishing() async throws {
        try await exercisePromotionDuringAccountVerification(changingAccount: true)
    }

    func testPromotionDuringAccountVerificationStillPublishesTheSameLiveAccount() async throws {
        try await exercisePromotionDuringAccountVerification(changingAccount: false)
    }

    private func exercisePromotionDuringAccountVerification(changingAccount: Bool) async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy(), mode = BatterySaver.shared.mode
        defer { NSApp.setActivationPolicy(policy); BatterySaver.shared.setMode(mode) }
        BatterySaver.shared.setMode(.off)
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let source = Feel04AccountProofSource(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        source.changesAccount = changingAccount
        let window = NSWindow(contentRect: source.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = source
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader)
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!, owner = UUID()
        var failure: (any Error)?
        do {
            try await settle {
                NSApp.isRunning && NSApp.isActive && NSRunningApplication.current.isFinishedLaunching
                    && window.isKeyWindow && NSApp.keyWindow === window
                    && NativeFixtureMountAdmission.surfaceReady(source, in: window)
            }
            source.loadHTMLString("<meta name='user-login' content='fixture'><body>Fixture</body>", baseURL: target.siteURL)
            try await settle { source.url == target.siteURL && !source.isLoading }
            let document = try await source.evaluateJavaScript("({ready: document.readyState, account: document.querySelector('meta').content})") as? [String: String]
            XCTAssertEqual(document?["ready"], "complete")
            XCTAssertEqual(document?["account"], "fixture")
            previews.prepare(target, owner: owner, source: source)
            try await settle { loader.contexts.count == 1 }
            source.captured = { old, current, elapsed in
                XCTAssertEqual(old, "fixture", "The gated proof must come from the actual earlier identity read")
                XCTAssertEqual(current, changingAccount ? "other" : "fixture", "The actual document supplies the current account")
                XCTAssertLessThan(elapsed, .milliseconds(400), "Admit this reply before the unchanged identity-probe deadline")
                XCTAssertEqual(previews.state, .loading, "Prepared account content must remain hidden")
                print("ACCOUNT PROOF captured before delivery: old=\(String(describing: old)), current=\(String(describing: current)), elapsed=\(elapsed), \(self.diagnostics(previews, source: source, loader: loader))")
                previews.request(target, owner: owner, source: source)
            }
            source.gateNextIdentity = true
            loader.finish()
            try await settle { source.gated }
            let expected: FavouritePreviewState = changingAccount ? .unavailable : .ready(.init(account: "fixture", items: []))
            try await settle({ previews.state == expected }, diagnostics: {
                self.diagnostics(previews, source: source, loader: loader)
            })
            print("ACCOUNT PROOF gated final: changing=\(changingAccount), reads=\(source.identityReplies), \(diagnostics(previews, source: source, loader: loader))")
            XCTAssertEqual(loader.contexts.count, 1, "Promotion must recheck proof without restarting the loader")
            XCTAssertEqual(previews.owner, owner)
        } catch { failure = error }
        previews.dismiss(owner: owner)
        loader.finish()
        source.captured = nil
        source.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Account proof fixture loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testInflightAccountChangeFailsClosed() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader), source = WKWebView()
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!, owner = UUID()
        defer { previews.dismiss(owner: owner); loader.finish(); source.stopLoading() }
        source.loadHTMLString("<meta name='user-login' content='fixture'><body>Fixture</body>", baseURL: target.siteURL)
        try await settle { source.url == target.siteURL && !source.isLoading }
        previews.request(target, owner: owner, source: source)
        try await settle { loader.contexts.count == 1 }
        _ = try await source.evaluateJavaScript("document.querySelector('meta').content = 'other'")
        loader.finish()
        try await settle { previews.state == .unavailable }
    }
}

@MainActor final class Feel04RetryProofTests: XCTestCase {
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testSessionRetryPreservesLiveSourceAccountProof() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader), source = WKWebView()
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!, owner = UUID()
        defer { previews.dismiss(owner: owner); loader.finish(); source.stopLoading() }
        source.loadHTMLString("<meta name='user-login' content='fixture'><body>Fixture</body>", baseURL: target.siteURL)
        try await settle { source.url == target.siteURL && !source.isLoading }
        previews.request(target, owner: owner, source: source)
        try await settle { loader.contexts.count == 1 }
        previews.sessionChanged(profileID: target.profileID)
        try await settle { loader.contexts.count == 2 }
        loader.finish(.ready(.init(account: "other", items: [])))
        try await settle { loader.completed == 2 && previews.state != .loading }
        XCTAssertEqual(previews.state, .unavailable, "The retry must not publish another account over the live favourite")
    }
    func testSessionRetryPreservesExplicitAccountProof() async throws {
        TestEnvironment.prepare()
        let loader = Feel04Loader(), previews = FavouritePreviews(loader: loader)
        let target = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!, owner = UUID()
        defer { previews.dismiss(owner: owner); loader.finish() }
        previews.request(target, owner: owner, account: "fixture")
        try await settle { loader.contexts.count == 1 }
        previews.sessionChanged(profileID: target.profileID)
        try await settle { loader.contexts.count == 2 }
        loader.finish(.ready(.init(account: "other", items: [])))
        try await settle { loader.completed == 2 && previews.state != .loading }
        XCTAssertEqual(previews.state, .unavailable)
    }
}
