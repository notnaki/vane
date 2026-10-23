import AppKit
import XCTest
@testable import vane

@MainActor final class BootstrapIngressTests: XCTestCase {
    func testFileOpenReopenAndBothDockActionsWaitForRecoveryAndDrainInArrivalOrder() throws {
        TestEnvironment.prepare()
        var actions: [String] = []
        let lifecycle = AppLifecycle(openURLs: { urls in actions.append("file:" + urls[0].lastPathComponent) },
            reopenAction: { _ in actions.append("reopen") },
            openWindow: { actions.append($0 ? "private" : "window") })
        // The task models an unfinished disk recovery; explicit readiness owns the gate.
        lifecycle.bootstrapTask = Task {}
        lifecycle.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/synthetic.html")])
        XCTAssertFalse(lifecycle.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        let menu = try XCTUnwrap(lifecycle.applicationDockMenu(NSApplication.shared))
        for item in menu.items {
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        }
        XCTAssertTrue(actions.isEmpty, "external events must not initialize profiles/windows during disk recovery")
        lifecycle.completeBootstrap()
        XCTAssertEqual(actions, ["file:synthetic.html", "reopen", "window", "private"])
    }

    func testGetURLRoutingWaitsForRecoveryAndAlsoForRestoreExitGate() throws {
        TestEnvironment.prepare()
        let lifecycle = AppLifecycle.shared
        XCTAssertNil(lifecycle.bootstrapTask)
        var opened: [URL] = []
        lifecycle.bootstrapTask = Task {}
        let first = try XCTUnwrap(URLHandling.normalize("https://first.synthetic.invalid"))
        let second = try XCTUnwrap(URLHandling.normalize("https://second.synthetic.invalid"))
        URLHandling.open([first], onReady: { opened += $0 })
        XCTAssertTrue(opened.isEmpty)
        lifecycle.completeBootstrap()
        XCTAssertEqual(opened, [first])
        XCTAssertTrue(lifecycle.beginPersistenceExit())
        defer { lifecycle.endPersistenceExit() }
        URLHandling.open([second], onReady: { opened += $0 })
        XCTAssertEqual(opened, [first])
        lifecycle.endPersistenceExit()
        XCTAssertEqual(opened, [first, second])
    }

    func testFileReopenAndDockIngressRemainQueuedUntilFailedExitReleasesGate() throws {
        TestEnvironment.prepare()
        var actions: [String] = []
        let lifecycle = AppLifecycle(openURLs: { _ in actions.append("file") },
            reopenAction: { _ in actions.append("reopen") }, openWindow: { _ in actions.append("window") })
        XCTAssertTrue(lifecycle.beginPersistenceExit())
        defer { lifecycle.endPersistenceExit() }
        lifecycle.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/synthetic.html")])
        XCTAssertFalse(lifecycle.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        let item = try XCTUnwrap(lifecycle.applicationDockMenu(NSApplication.shared)?.items.first)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(actions.isEmpty)
        lifecycle.endPersistenceExit()
        XCTAssertEqual(actions, ["file", "reopen", "window"])
    }
}
