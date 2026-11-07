import AppKit
import XCTest
@testable import vane

@MainActor final class NativeSidebarAccessibilityTests: XCTestCase {
    /// SwiftUI can expose public Objective-C AX methods without declaring the
    /// corresponding formal protocol. In particular NSRect/BOOL are not objects.
    private final class InformalElement: NSObject {
        var exposed = true
        var allowed = true
        var presses = 0
        var children: [NSObject] = []
        @objc func accessibilityFrame() -> NSRect { NSRect(x: 17, y: 29, width: 101, height: 31) }
        @objc func accessibilityChildren() -> [NSObject] { children }
        @objc func isAccessibilityElement() -> Bool { exposed }
        @objc func accessibilityRole() -> String { NSAccessibility.Role.group.rawValue }
        @objc func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool { allowed }
        @objc func accessibilityPerformPress() -> Bool { presses += 1; return true }
    }
    private final class MinimalElement: NSObject, NSAccessibilityElementProtocol {
        func accessibilityFrame() -> NSRect { NSRect(x: 3, y: 5, width: 7, height: 11) }
        func accessibilityParent() -> Any? { nil }
        // Preserve the existing element-only fallback even if this informal
        // getter disagrees; these nodes do not adopt the full AX protocol.
        @objc func isAccessibilityElement() -> Bool { false }
    }
    private final class ContentsElement: NSObject {
        let child = MinimalElement()
        @objc func accessibilityContents() -> [NSObject] { [child] }
    }
    private final class ActionView: NSView {
        var presses = 0
        override func accessibilityPerformPress() -> Bool { presses += 1; return true }
    }

    func testInformalPublicMethodsPreserveGeometryExposureAndReadOnlyActionDiscovery() {
        let node = InformalElement(), child = MinimalElement()
        node.children = [child]
        XCTAssertFalse(node is any NSAccessibilityElementProtocol)
        XCTAssertEqual(NativeSidebarAccessibility.frame(node), NSRect(x: 17, y: 29, width: 101, height: 31))
        XCTAssertTrue(NativeSidebarAccessibility.children(node).first === child)
        XCTAssertTrue(NativeSidebarAccessibility.isExposed(node))
        XCTAssertTrue(NativeSidebarAccessibility.isActionable(node))
        XCTAssertEqual(node.presses, 0, "Discovering AX controls must never perform their actions")
        node.exposed = false
        node.allowed = false
        XCTAssertFalse(NativeSidebarAccessibility.isExposed(node))
        XCTAssertFalse(NativeSidebarAccessibility.isActionable(node), "A present but disallowed action is not advertised")
        XCTAssertEqual(node.presses, 0)
    }

    func testElementOnlyLeavesKeepTheirPublicFrameAndExposure() {
        let node = MinimalElement()
        XCTAssertEqual(NativeSidebarAccessibility.frame(node), NSRect(x: 3, y: 5, width: 7, height: 11))
        XCTAssertTrue(NativeSidebarAccessibility.isExposed(node))
        XCTAssertFalse(NativeSidebarAccessibility.isActionable(node))
        XCTAssertFalse(NativeSidebarAccessibility.isExposed(NSObject()))
    }

    func testPublicContentsFallbackPreservesVirtualChildren() {
        let node = ContentsElement()
        XCTAssertTrue(NativeSidebarAccessibility.children(node).first === node.child)
    }

    func testOverriddenAppKitActionIsDetectedWithoutPerformingIt() {
        let view = ActionView(frame: .zero)
        XCTAssertTrue(NativeSidebarAccessibility.isActionable(view))
        XCTAssertEqual(view.presses, 0)
    }

    func testAppKitDefaultsDoNotMakeEveryViewActionable() {
        let view = NSView(frame: .zero)
        XCTAssertFalse(NativeSidebarAccessibility.isActionable(view))
        XCTAssertFalse(NativeSidebarAccessibility.isActionable(NSAccessibilityElement()))
        XCTAssertFalse(NativeSidebarAccessibility.isActionable(NSCell()))
        let button = NSButton(title: "AX control", target: nil, action: nil)
        XCTAssertTrue(NativeSidebarAccessibility.isActionable(button))
    }
}
