import XCTest
@testable import vane

@MainActor final class Feel09FeedbackTests: XCTestCase {
    private func toasts() -> Toasts {
        TestEnvironment.prepare()
        let toasts = Toasts.shared
        toasts.showing.forEach { toasts.dismiss($0) }
        addTeardownBlock { @MainActor in
            toasts.showing.forEach { toasts.dismiss($0) }
        }
        return toasts
    }

    func testReplacedToastCannotRunItsOldActionOrHoldHover() throws {
        let toasts = toasts()
        var oldActions = 0
        Toasts.show("First", action: ("Undo", { oldActions += 1 }), in: nil)
        let old = try XCTUnwrap(toasts.current)
        toasts.hover(old, true)
        Toasts.show("Second", in: nil)
        let current = try XCTUnwrap(toasts.current)
        // SwiftUI can deliver departure hover and activation callbacks after replacement.
        toasts.hover(old, true)
        toasts.hover(old, false)
        toasts.hover(old, true)
        toasts.act(old)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(toasts.current?.id, current.id)
        XCTAssertTrue(toasts.hovering.isEmpty)
    }

    func testToastActionRunsOnlyOnceAndMayShowItsSuccessor() throws {
        let toasts = toasts()
        var actions = 0
        Toasts.show("First", action: ("Undo", {
            actions += 1
            Toasts.show("Undone", in: nil)
        }), in: nil)
        let first = try XCTUnwrap(toasts.current)
        toasts.act(first)
        toasts.act(first)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(toasts.current?.text, "Undone")
    }

    func testReplacingOrRemovingStickyToastReleasesHover() throws {
        let toasts = toasts()
        let first = UUID(), second = UUID()
        Toasts.stick("Update", id: first)
        toasts.hover(try XCTUnwrap(toasts.current), true)
        Toasts.stick("New update", id: second)
        XCTAssertTrue(toasts.hovering.isEmpty)
        toasts.hover(try XCTUnwrap(toasts.current), true)
        Toasts.unstick(first)
        XCTAssertEqual(toasts.current?.id, second)
        Toasts.unstick(second)
        XCTAssertTrue(toasts.hovering.isEmpty)
    }

    func testRewrittenStickyActionRejectsStaleActivation() throws {
        let toasts = toasts()
        let id = UUID()
        var oldActions = 0, newActions = 0
        Toasts.stick("Available", id: id, action: ("Download", { oldActions += 1 }))
        let old = try XCTUnwrap(toasts.current)
        Toasts.stick("Ready", id: id, action: ("Restart", { newActions += 1 }))
        toasts.act(old)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(newActions, 0, "A press begun on Download must not become Restart")
        toasts.act(try XCTUnwrap(toasts.current))
        XCTAssertEqual(newActions, 1)
        XCTAssertNil(toasts.current)
    }

    func testSameTitleStickyReplacementRejectsPredecessorAction() throws {
        let toasts = toasts(), id = UUID()
        var oldRuns = 0, newRuns = 0
        Toasts.stick("Version one", id: id, action: ("Update", { oldRuns += 1 }))
        let old = try XCTUnwrap(toasts.current)
        Toasts.stick("Version two", id: id, action: ("Update", { newRuns += 1 }))
        toasts.act(old)
        XCTAssertEqual(oldRuns, 0)
        XCTAssertEqual(newRuns, 0)
        XCTAssertEqual(toasts.current?.text, "Version two")
        toasts.act(try XCTUnwrap(toasts.current))
        XCTAssertEqual(newRuns, 1)
    }

    func testRapidArrivalRetargetsAndSuppressedDragClearsHighlight() async throws {
        TestEnvironment.prepare()
        let feedback = InteractionFeedback()
        let first = UUID(), second = UUID()
        feedback.arrived(first)
        let stamp = feedback.arrivalStamp
        feedback.arrived(second)
        XCTAssertEqual(feedback.arrivingTab, second)
        XCTAssertNotEqual(feedback.arrivalStamp, stamp)
        feedback.withoutArrivalHighlight {
            feedback.withoutArrivalHighlight { feedback.arrived(first) }
            XCTAssertNil(feedback.arrivingTab)
        }
        feedback.arrived(second)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(feedback.arrivingTab)
    }

    func testCopyReplacementAndTidyCancellationStayCorrectAfterExpiry() async throws {
        TestEnvironment.prepare()
        let feedback = InteractionFeedback()
        let first = URL(string: "https://first.example")!
        let second = URL(string: "https://second.example")!
        feedback.copied(first)
        feedback.copied(second)
        XCTAssertEqual(feedback.copiedURL, second.absoluteString)
        feedback.tidied(["a", "b", "a"])
        XCTAssertEqual(feedback.tidyRanks, ["a": 0, "b": 1])
        feedback.cancelTidy()
        feedback.tidied(["c"])
        XCTAssertEqual(feedback.tidyRanks, ["c": 0])
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(feedback.copiedURL)
        XCTAssertTrue(feedback.tidyRanks.isEmpty)
    }
}
