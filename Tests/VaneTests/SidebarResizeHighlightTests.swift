import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarResizeHighlightTests: XCTestCase {
    private func fixture() -> SidebarResizeHighlightView {
        TestEnvironment.prepare()
        let defaults = UserDefaults.vane, key = UIAnimation.feedback.key
        let previous = defaults.object(forKey: key)
        defaults.set(1, forKey: key)
        addTeardownBlock { defaults.set(previous, forKey: key) }
        return SidebarResizeHighlightView()
    }

    func testHighlightFadesInAndOutDuringUnanimatedResizeTransactions() throws {
        let view = fixture()
        var resize = Transaction(animation: nil)
        resize.disablesAnimations = true
        withTransaction(resize) { view.setActive(true, animated: true) }
        let entrance = try XCTUnwrap(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey)
            as? CABasicAnimation)
        XCTAssertEqual(entrance.fromValue as? Float, 0)
        XCTAssertEqual(entrance.toValue as? Float, 1)
        XCTAssertEqual(entrance.duration, 0.2, accuracy: 0.001)
        XCTAssertEqual(view.layer?.opacity, 1)

        withTransaction(resize) { view.setActive(false, animated: true) }
        let exit = try XCTUnwrap(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey)
            as? CABasicAnimation)
        XCTAssertEqual(exit.toValue as? Float, 0)
        XCTAssertEqual(view.layer?.opacity, 0)
    }

    func testReducedMotionRemovesAnInFlightFadeAndAppliesTheEndpoint() throws {
        let view = fixture()
        view.setActive(true, animated: true)
        XCTAssertNotNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
        view.setActive(false, animated: false)
        XCTAssertNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
        XCTAssertEqual(view.layer?.opacity, 0)
        view.setActive(true, animated: false)
        XCTAssertNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func testHoverWaitsBeforeRevealingAndLeavingCancelsIt() async throws {
        let view = fixture()
        view.setActive(true, animated: true, delay: 0.25)
        XCTAssertEqual(view.layer?.opacity, 0, "Passing over the seam must not reveal it immediately")
        XCTAssertNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
        view.setActive(false, animated: true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.layer?.opacity, 0, "An exited hover must never flash later")
    }

    func testHoverRevealsAfterDwell() async throws {
        let view = fixture()
        view.setActive(true, animated: true, delay: 0.25)
        XCTAssertEqual(view.layer?.opacity, 0)
        try await compatibilityWait { view.layer?.opacity == 1 }
    }

    func testDraggingAndReducedMotionBypassTheHoverDelay() {
        let view = fixture()
        view.setActive(true, animated: true, delay: 0.25)
        view.setActive(true, animated: true)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertNotNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
        view.setActive(false, animated: false)
        view.setActive(true, animated: false, delay: 0.25)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertNil(view.layer?.animation(forKey: SidebarResizeHighlightView.fadeKey))
    }
}
