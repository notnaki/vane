import AppKit
import XCTest
@testable import vane

/// The prompt is always a stub here: nothing in this file can raise a system dialog, and
/// lock/sleep notifications go to private centers so no other process hears them.
@MainActor final class PasswordFillGateTests: XCTestCase {
    private final class Prompt {
        var reasons: [String] = []
        var answer = true
    }

    private func gate(_ prompt: Prompt, workspace: NotificationCenter = NotificationCenter(),
                      distributed: NotificationCenter = NotificationCenter()) -> PasswordFillGate {
        TestEnvironment.prepare()
        UserDefaults.vane.removeObject(forKey: PasswordFillGate.requiredKey)
        addTeardownBlock { UserDefaults.vane.removeObject(forKey: PasswordFillGate.requiredKey) }
        let gate = PasswordFillGate(workspace: workspace, distributed: distributed)
        gate.authenticate = { reason, done in prompt.reasons.append(reason); done(prompt.answer) }
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
}
