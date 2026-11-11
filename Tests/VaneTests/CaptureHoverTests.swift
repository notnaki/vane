import AppKit
import XCTest
@testable import vane

@MainActor final class CaptureHoverTests: XCTestCase {
    func testHoverStartsImmediatelyAndCoalescesMovesWhileWebKitIsBusy() async throws {
        var requests: [CGPoint] = []
        var pending: [CheckedContinuation<CGRect?, Never>] = []
        var displayed: [CGRect?] = []
        let hover = CaptureElementHover(query: { point in
            requests.append(point)
            return await withCheckedContinuation { pending.append($0) }
        }, update: { displayed.append($0) })
        hover.move(to: CGPoint(x: 10, y: 10))
        try await compatibilityWait { requests.count == 1 }
        hover.move(to: CGPoint(x: 100, y: 10))
        hover.move(to: CGPoint(x: 200, y: 10))
        XCTAssertEqual(requests.count, 1, "Only one WebKit lookup should be in flight")
        pending.removeFirst().resume(returning: CGRect(x: 0, y: 0, width: 20, height: 20))
        try await compatibilityWait { requests.count == 2 }
        XCTAssertEqual(requests[1], CGPoint(x: 200, y: 10))
        XCTAssertTrue(displayed.isEmpty, "A stale result must not flash behind the moving pointer")
        let latest = CGRect(x: 190, y: 0, width: 20, height: 20)
        pending.removeFirst().resume(returning: latest)
        try await compatibilityWait { displayed.count == 1 }
        XCTAssertEqual(displayed[0], latest)
        hover.cancel()
    }
    func testCancelledLookupCannotReplaceAHighlightFromANewerSession() async throws {
        var pending: [CheckedContinuation<CGRect?, Never>] = []
        var displayed: [CGRect?] = []
        let hover = CaptureElementHover(query: { _ in
            await withCheckedContinuation { pending.append($0) }
        }, update: { displayed.append($0) })
        hover.move(to: .zero)
        try await compatibilityWait { pending.count == 1 }
        hover.cancel()
        hover.move(to: CGPoint(x: 40, y: 40))
        try await compatibilityWait { pending.count == 2 }
        pending.removeFirst().resume(returning: CGRect(x: 0, y: 0, width: 20, height: 20))
        let latest = CGRect(x: 30, y: 30, width: 30, height: 30)
        pending.removeFirst().resume(returning: latest)
        try await compatibilityWait { displayed.count == 1 }
        XCTAssertEqual(displayed[0], latest)
        hover.cancel()
    }
}
