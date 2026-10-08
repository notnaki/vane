import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SitePermissionTests: XCTestCase {
    private var profile = UUID()
    private var tabs: [UUID] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
    }

    override func tearDown() async throws {
        for id in tabs { SitePermissions.endDocument(tabID: id) }
        SitePermissions.resetAll(profileID: profile)
        for window in windows { window.close() }
        tabs = []; windows = []
    }

    private func tabID() -> UUID {
        let id = UUID(); tabs.append(id); return id
    }

    private func scope(privateTab: UUID? = nil, url: String = "https://permission.example:8443") -> SitePermissions.Scope {
        SitePermissions.Scope(url: URL(string: url), profileID: profile, privateTabID: privateTab)!
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.orderFront(nil)
        return window
    }

    private func waitForSheet(_ window: NSWindow) async throws -> NSWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while window.attachedSheet == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(window.attachedSheet)
    }

    private func answer(_ scope: SitePermissions.Scope, type: SitePermissions.Kind,
                        tabID: UUID, response: NSApplication.ModalResponse) async throws -> WKPermissionDecision {
        let host = window()
        let task = Task { await SitePermissions.request(scope: scope, type: type, tabID: tabID,
                                                       window: host, isCurrent: { true }) }
        let sheet = try await waitForSheet(host)
        host.endSheet(sheet, returnCode: response)
        return await task.value
    }

    func testWantsToUsePopupsNameExactOriginAndDevice() {
        for (type, phrase) in [(SitePermissions.Kind.camera, "camera"), (.microphone, "microphone"),
                               (.cameraAndMicrophone, "camera and microphone")] {
            let alert = SitePermissions.makePrompt(scope: scope(), type: type)
            XCTAssertEqual(alert.messageText, "“https://permission.example:8443” wants to use your \(phrase)")
            XCTAssertEqual(alert.buttons.map(\.title), ["Allow Once", "Always Allow", "Don’t Allow"])
            XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
        }
    }

    func testPrivatePopupMakesSessionLifetimeExplicit() {
        let alert = SitePermissions.makePrompt(scope: scope(privateTab: tabID()), type: .camera)
        XCTAssertEqual(alert.buttons[1].title, "Allow for This Private Tab")
        XCTAssertTrue(alert.informativeText.contains("never saved"))
    }

    func testAllowOnceIsTabAndOriginScopedAndNeverSaved() async throws {
        let id = tabID(), s = scope()
        let result = try await answer(s, type: .camera, tabID: id, response: .alertFirstButtonReturn)
        XCTAssertEqual(result, .grant)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .camera, tabID: id), true)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: tabID()))
        XCTAssertNil(SitePermissions.effective(scope: scope(url: "http://permission.example:8443"), type: .camera, tabID: id))
        XCTAssertNil(SitePermissions.effective(scope: scope(url: "https://permission.example"), type: .camera, tabID: id))
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
        XCTAssertTrue(SitePermissions.all(profileID: profile).isEmpty)
        SitePermissions.endDocument(tabID: id)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: id))
    }

    func testCombinedOnceCoversBothDevicesButPersistentBlockWins() async throws {
        let id = tabID(), s = scope()
        let result = try await answer(s, type: .cameraAndMicrophone, tabID: id, response: .alertFirstButtonReturn)
        XCTAssertEqual(result, .grant)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .microphone, tabID: id), true)
        SitePermissions.remember(scope: s, type: .microphone, allow: false)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .cameraAndMicrophone, tabID: id), false)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .camera, tabID: id), true)
    }

    func testAlwaysAllowPersistsWhilePrivateAlwaysAllowDoesNot() async throws {
        let id = tabID(), s = scope()
        let result = try await answer(s, type: .microphone, tabID: id, response: .alertSecondButtonReturn)
        XCTAssertEqual(result, .grant)
        SitePermissions.endDocument(tabID: id)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .microphone), true)
        let privateID = tabID(), privateScope = scope(privateTab: privateID)
        let privateResult = try await answer(privateScope, type: .camera, tabID: privateID, response: .alertSecondButtonReturn)
        XCTAssertEqual(privateResult, .grant)
        SitePermissions.endDocument(tabID: privateID)
        XCTAssertEqual(SitePermissions.remembered(scope: privateScope, type: .camera), true)
        XCTAssertFalse(SitePermissions.all(profileID: profile).contains { $0.what == "Camera" })
        SitePermissions.forgetPrivate(tabID: privateID)
        XCTAssertNil(SitePermissions.remembered(scope: privateScope, type: .camera))
    }

    func testDontAllowPersistsBlockButDismissalDoesNot() async throws {
        let id = tabID(), s = scope()
        let result = try await answer(s, type: .camera, tabID: id, response: .alertThirdButtonReturn)
        XCTAssertEqual(result, .deny)
        XCTAssertEqual(SitePermissions.remembered(scope: s, type: .camera), false)
        let dismissed = try await answer(s, type: .microphone, tabID: id, response: .abort)
        XCTAssertEqual(dismissed, .deny)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .microphone))
    }

    func testNavigationCancelsPopupWithoutSavingLateAnswer() async throws {
        let host = window(), id = tabID(), s = scope()
        let task = Task { await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                       window: host, isCurrent: { true }) }
        _ = try await waitForSheet(host)
        SitePermissions.endDocument(tabID: id)
        let result = await task.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(host.attachedSheet)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
    }

    func testStaleRequestAndMissingWindowNeverGrantOrSave() async throws {
        let host = window(), id = tabID(), s = scope()
        var current = true
        let task = Task { await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                       window: host, isCurrent: { current }) }
        let sheet = try await waitForSheet(host)
        current = false
        host.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let result = await task.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
        SitePermissions.remember(scope: s, type: .camera, allow: true)
        let detached = await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                     window: nil, isCurrent: { true })
        XCTAssertEqual(detached, .deny)
    }

    func testSiteControlAskClearsOnceAndPreservesOtherDevice() async throws {
        let id = tabID(), s = scope()
        _ = try await answer(s, type: .cameraAndMicrophone, tabID: id, response: .alertFirstButtonReturn)
        SitePermissions.set(scope: s, type: .camera, answer: nil, tabID: id)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: id))
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .microphone, tabID: id), true)
        SitePermissions.reset(scope: s)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .microphone, tabID: id))
    }

    func testOtherWindowRemainsAvailableAndBusyWindowDoesNotStackPopups() async throws {
        let host = window(), other = window(), id = tabID(), s = scope()
        let first = Task { await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                        window: host, isCurrent: { true }) }
        let firstSheet = try await waitForSheet(host)
        let blocked = await SitePermissions.request(scope: s, type: .microphone, tabID: tabID(),
                                                    window: host, isCurrent: { true })
        XCTAssertEqual(blocked, .deny)
        let secondID = tabID()
        let second = Task { await SitePermissions.request(scope: s, type: .microphone, tabID: secondID,
                                                         window: other, isCurrent: { true }) }
        let otherSheet = try await waitForSheet(other)
        host.endSheet(firstSheet, returnCode: .alertFirstButtonReturn)
        other.endSheet(otherSheet, returnCode: .alertFirstButtonReturn)
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertEqual(firstResult, .grant); XCTAssertEqual(secondResult, .grant)
    }

    func testClosingWindowCancelsPendingPopup() async throws {
        let host = window(), id = tabID(), s = scope()
        var result: WKPermissionDecision?
        let task = Task { result = await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                                 window: host, isCurrent: { true }) }
        _ = try await waitForSheet(host)
        host.close()
        let deadline = ContinuousClock.now + .seconds(2)
        while result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(result, .deny, "Closing the requester must finish the WebKit decision")
        SitePermissions.endDocument(tabID: id)
        await task.value
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
    }

    func testTaskCancellationDismissesPopup() async throws {
        let host = window(), id = tabID(), s = scope()
        let task = Task { await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                       window: host, isCurrent: { true }) }
        _ = try await waitForSheet(host)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(host.attachedSheet)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
    }

    func testProfileResetClearsOnceAndCancelsPendingRequests() async throws {
        let id = tabID(), s = scope()
        _ = try await answer(s, type: .camera, tabID: id, response: .alertFirstButtonReturn)
        let host = window(), otherID = tabID()
        let task = Task { await SitePermissions.request(scope: s, type: .microphone, tabID: otherID,
                                                       window: host, isCurrent: { true }) }
        _ = try await waitForSheet(host)
        SitePermissions.resetAll(profileID: profile)
        let result = await task.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: id))
    }

    func testBlockInOtherWindowInvalidatesOlderAllowPopup() async throws {
        let s = scope(), firstWindow = window(), secondWindow = window()
        let firstID = tabID(), secondID = tabID()
        let first = Task { await SitePermissions.request(scope: s, type: .camera, tabID: firstID,
                                                        window: firstWindow, isCurrent: { true }) }
        let firstSheet = try await waitForSheet(firstWindow)
        let second = Task { await SitePermissions.request(scope: s, type: .camera, tabID: secondID,
                                                         window: secondWindow, isCurrent: { true }) }
        let secondSheet = try await waitForSheet(secondWindow)
        secondWindow.endSheet(secondSheet, returnCode: .alertThirdButtonReturn)
        let blocked = await second.value
        XCTAssertEqual(blocked, .deny)
        if firstWindow.attachedSheet != nil { firstWindow.endSheet(firstSheet, returnCode: .alertSecondButtonReturn) }
        let older = await first.value
        XCTAssertEqual(older, .deny)
        XCTAssertEqual(SitePermissions.remembered(scope: s, type: .camera), false)
    }

    func testTabNavigationAndTeardownExpireOnceInProductionHooks() async throws {
        let tab = Tab(isPrivate: true, profileID: profile)
        defer { tab.tearDown() }
        tabs.append(tab.id)
        let s = scope(privateTab: tab.id)
        tab.web.navigationDelegate = nil
        let navigation = try XCTUnwrap(tab.web.loadHTMLString("fixture", baseURL: nil))
        _ = try await answer(s, type: .camera, tabID: tab.id, response: .alertFirstButtonReturn)
        tab.webView(tab.web, didStartProvisionalNavigation: navigation)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: tab.id))
        _ = try await answer(s, type: .camera, tabID: tab.id, response: .alertFirstButtonReturn)
        tab.tearDown()
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: tab.id))
    }

    func testSiteControlShowsOneTimeLifetime() {
        var model = SiteControlModel()
        model.host = "permission.example"
        model.camera = true; model.cameraOnce = true
        model.microphone = true; model.microphoneOnce = true
        for id in [SiteControlModel.RowID.camera, .microphone] {
            let row = model.rows.first { $0.id == id }
            XCTAssertEqual(row?.control, .permission(true))
            XCTAssertEqual(row?.note, "Allowed once, until this tab navigates or closes.")
        }
    }


    func testPrivateSiteResetPreservesOtherPrivateTabsOnceGrants() async throws {
        let firstID = tabID(), secondID = tabID()
        let firstScope = scope(privateTab: firstID), secondScope = scope(privateTab: secondID)
        _ = try await answer(firstScope, type: .camera, tabID: firstID, response: .alertFirstButtonReturn)
        _ = try await answer(secondScope, type: .camera, tabID: secondID, response: .alertFirstButtonReturn)
        SitePermissions.reset(scope: firstScope)
        XCTAssertNil(SitePermissions.effective(scope: firstScope, type: .camera, tabID: firstID))
        XCTAssertEqual(SitePermissions.effective(scope: secondScope, type: .camera, tabID: secondID), true)
        _ = try await answer(firstScope, type: .camera, tabID: firstID, response: .alertFirstButtonReturn)
        SitePermissions.set(scope: firstScope, type: .camera, answer: nil)
        XCTAssertNil(SitePermissions.effective(scope: firstScope, type: .camera, tabID: firstID))
        XCTAssertEqual(SitePermissions.effective(scope: secondScope, type: .camera, tabID: secondID), true)
    }

    func testInvalidOwnerCancelsPromptWithoutAUserResponse() async throws {
        let host = window(), id = tabID(), s = scope()
        var current = true
        var result: WKPermissionDecision?
        let task = Task { result = await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                                 window: host, isCurrent: { current }) }
        _ = try await waitForSheet(host)
        current = false
        let deadline = ContinuousClock.now + .seconds(2)
        while result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(result, .deny, "An invalid owner must cancel without waiting for a sheet response")
        SitePermissions.endDocument(tabID: id)
        await task.value
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
    }


    func testLocationDecisionDoesNotSplitCombinedMediaDecision() async throws {
        guard SitePermissions.supportsLocation else { throw XCTSkip("Requires macOS 27 SDK and runtime") }
        let id = tabID(), s = scope()
        SitePermissions.remember(scope: s, type: .cameraAndMicrophone, allow: true)
        let result = try await answer(s, type: .location, tabID: id, response: .alertFirstButtonReturn)
        XCTAssertEqual(result, .grant)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .location, tabID: id), true)
        SitePermissions.set(scope: s, type: .location, answer: false, tabID: id)
        XCTAssertEqual(SitePermissions.remembered(scope: s, type: .cameraAndMicrophone), true)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .location, tabID: id), false)
        SitePermissions.endDocument(tabID: id)
        XCTAssertEqual(SitePermissions.effective(scope: s, type: .location), false)
        SitePermissions.reset(scope: s)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .location))
    }

    func testPrivateLocationNeverPersistsAndExpiresWithPrivateTab() async throws {
        guard SitePermissions.supportsLocation else { throw XCTSkip("Requires macOS 27 SDK and runtime") }
        let id = tabID(), s = scope(privateTab: id)
        _ = try await answer(s, type: .location, tabID: id, response: .alertSecondButtonReturn)
        SitePermissions.endDocument(tabID: id)
        XCTAssertEqual(SitePermissions.remembered(scope: s, type: .location), true)
        XCTAssertTrue(SitePermissions.all(profileID: profile).isEmpty)
        SitePermissions.forgetPrivate(tabID: id)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .location))
    }

    func testRevocationDuringFinalDocumentValidationCannotSaveLateAllow() async throws {
        let host = window(), id = tabID(), s = scope()
        var validations = 0
        var hold = false
        let task = Task { await SitePermissions.request(scope: s, type: .camera, tabID: id,
                                                       window: host, isCurrent: { true }, validate: {
            validations += 1
            while hold { try? await Task.sleep(for: .milliseconds(10)) }
            return true
        }) }
        let sheet = try await waitForSheet(host)
        hold = true
        host.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let deadline = ContinuousClock.now + .seconds(2)
        while validations < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(validations, 2)
        SitePermissions.reset(scope: s)
        hold = false
        let result = await task.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(SitePermissions.remembered(scope: s, type: .camera))
    }

    func testAskRevokesOnceInEveryTabForThisOriginAndProfile() async throws {
        let first = tabID(), second = tabID(), s = scope()
        _ = try await answer(s, type: .camera, tabID: first, response: .alertFirstButtonReturn)
        _ = try await answer(s, type: .camera, tabID: second, response: .alertFirstButtonReturn)
        SitePermissions.set(scope: s, type: .camera, answer: nil, tabID: first)
        XCTAssertNil(SitePermissions.effective(scope: s, type: .camera, tabID: second))
    }


}
