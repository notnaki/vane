import AppKit
import XCTest
@testable import vane

/// The prompt is always a stub here: nothing in this file can raise a system dialog, and
/// lock/sleep notifications go to private centers so no other process hears them.
@MainActor final class PasswordFillGateTests: XCTestCase {
    private final class Prompt {
        var reasons: [String] = []
        /// Nil holds the reply, the way a system prompt waits for a finger.
        var answer: Bool? = true
        var held: [@MainActor (Bool) -> Void] = []
        var dismissed = 0
    }

    private func gate(_ prompt: Prompt, workspace: NotificationCenter = NotificationCenter(),
                      distributed: NotificationCenter = NotificationCenter()) -> PasswordFillGate {
        TestEnvironment.prepare()
        UserDefaults.vane.removeObject(forKey: PasswordFillGate.requiredKey)
        addTeardownBlock { UserDefaults.vane.removeObject(forKey: PasswordFillGate.requiredKey) }
        let gate = PasswordFillGate(workspace: workspace, distributed: distributed)
        gate.authenticate = { reason, done in
            prompt.reasons.append(reason)
            if let answer = prompt.answer { done(answer) } else { prompt.held.append(done) }
            return { prompt.dismissed += 1 }
        }
        return gate
    }

    func testOnePromptOpensFiveMinutesAndNoLonger() async {
        let prompt = Prompt(), gate = gate(prompt)
        var elapsed = Duration.zero
        let start = ContinuousClock.now
        gate.now = { start + elapsed }
        XCTAssertTrue(PasswordFillGate.isRequired, "The requirement defaults to on")
        XCTAssertTrue(gate.needsPrompt)
        let first = await gate.authorize("fill")
        XCTAssertTrue(first)
        XCTAssertEqual(prompt.reasons, ["fill"])
        elapsed = .seconds(299)
        let within = await gate.authorize("fill")
        XCTAssertTrue(within)
        XCTAssertEqual(prompt.reasons.count, 1, "A fill inside the window must not ask again")
        elapsed = .seconds(300)
        XCTAssertTrue(gate.needsPrompt)
        _ = await gate.authorize("fill")
        XCTAssertEqual(prompt.reasons.count, 2, "The window ends five minutes after the prompt that opened it")
    }

    func testRefusedPromptOpensNothing() async {
        let prompt = Prompt(), gate = gate(prompt)
        prompt.answer = false
        let refused = await gate.authorize("fill")
        XCTAssertFalse(refused)
        XCTAssertTrue(gate.needsPrompt)
        _ = await gate.authorize("fill")
        XCTAssertEqual(prompt.reasons.count, 2)
    }

    func testLockSleepAndUserSwitchEndTheWindow() async throws {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        let prompt = Prompt(), gate = gate(prompt, workspace: workspace, distributed: distributed)
        let events: [(NotificationCenter, Notification.Name)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked")),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
        ]
        for (center, name) in events {
            _ = await gate.authorize("fill")
            XCTAssertFalse(gate.needsPrompt)
            center.post(name: name, object: nil)
            let deadline = ContinuousClock.now + .seconds(2)
            while !gate.needsPrompt, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(gate.needsPrompt, "\(name.rawValue) must end the window")
        }
        XCTAssertEqual(prompt.reasons.count, events.count)
    }

    func testTurningTheRequirementOffAsksFirst() async {
        let prompt = Prompt(), gate = gate(prompt)
        prompt.answer = false
        gate.setRequired(false)
        XCTAssertEqual(prompt.reasons.count, 1)
        XCTAssertTrue(PasswordFillGate.isRequired, "A refused prompt must leave the requirement on")
        prompt.answer = true
        gate.setRequired(false)
        XCTAssertFalse(PasswordFillGate.isRequired)
        XCTAssertFalse(gate.needsPrompt)
        let allowed = await gate.authorize("fill")
        XCTAssertTrue(allowed)
        XCTAssertEqual(prompt.reasons.count, 2, "With the requirement off, fills ask nobody")
        gate.setRequired(true)
        XCTAssertEqual(prompt.reasons.count, 2, "Turning it back on needs no prompt")
        XCTAssertTrue(gate.needsPrompt)
    }

    func testFillsArrivingDuringAPromptShareIt() async throws {
        let prompt = Prompt(), gate = gate(prompt)
        prompt.answer = nil
        let fills = (0..<3).map { index in Task { await gate.authorize("fill \(index)") } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(prompt.reasons.count, 1, "Fills waiting on a prompt must not raise their own")
        // Every prompt raised, so a regression fails above instead of waiting here forever.
        for answer in prompt.held { answer(true) }
        for fill in fills {
            let allowed = await fill.value
            XCTAssertTrue(allowed, "One answer serves every fill that waited for it")
        }
        XCTAssertFalse(gate.needsPrompt)
        XCTAssertEqual(prompt.dismissed, 0)
    }

    func testPromptNobodyWaitsForIsDismissed() async throws {
        let prompt = Prompt(), gate = gate(prompt)
        prompt.answer = nil
        let first = Task { await gate.authorize("first") }, second = Task { await gate.authorize("second") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(prompt.reasons.count, 1)
        first.cancel()
        let abandoned = await first.value
        XCTAssertFalse(abandoned, "A cancelled fill is not authorized")
        XCTAssertEqual(prompt.dismissed, 0, "The prompt stays while another fill waits on it")
        second.cancel()
        _ = await second.value
        XCTAssertEqual(prompt.dismissed, 1, "The prompt nobody is waiting for must leave the screen")
        // Even if the system still delivered an approval for it, it opens nothing.
        prompt.held.removeFirst()(true)
        XCTAssertTrue(gate.needsPrompt, "A stale prompt must not open the window")
        prompt.answer = true
        let fresh = await gate.authorize("third")
        XCTAssertTrue(fresh)
        XCTAssertEqual(prompt.reasons, ["first", "third"])
    }
}
