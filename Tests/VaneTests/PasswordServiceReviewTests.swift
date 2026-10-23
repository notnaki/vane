import Foundation
import XCTest
@testable import vane

private final class ReviewedCredentialFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "original"
    private var stamp = 1.0
    var revision: Passwords.Revision {
        lock.withLock { .init(reference: Data([1]), modified: Date(timeIntervalSince1970: stamp)) }
    }
    var password: String { lock.withLock { value } }
    func set(_ password: String) { lock.withLock { value = password; stamp += 1 } }
}

@MainActor final class PasswordServiceReviewTests: XCTestCase {
    func testSettingsEditCannotInterleaveReviewedCheckAndWrite() async throws {
        let fixture = ReviewedCredentialFixture(), origin = PasswordOrigin(host: "serialized.invalid"), profile = UUID()
        let checked = expectation(description: "review read old revision")
        let release = DispatchSemaphore(value: 0)
        let offer = PendingSave(revision: fixture.revision, host: origin.host, account: "ada", password: "offer", update: true)
        var review = Passwords.ReviewOperations()
        review.snapshot = { _, _, _ in
            let saved = (fixture.password as String?, fixture.revision as Passwords.Revision?)
            checked.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return saved
        }
        review.update = { _, _, _, password, _ in fixture.set(password) }
        let operations = review
        var reader = Passwords.Reader()
        reader.commit = { try Passwords.reviewedSave($0, origin: $1, account: $2, password: $3, profileID: $4, operations: operations) }
        let save = Task { try await reader.save(offer, origin: origin, account: "ada", password: "offer", profileID: profile) }
        await fulfillment(of: [checked], timeout: 2)
        var edits = Passwords.MutationOperations()
        edits.edit = { _, _, _, password, _ in fixture.set(password) }
        let settingsOperations = edits
        let settings = Task {
            try await Passwords.editAsync(.init(origin: origin, account: "ada"), origin: origin, account: "ada",
                password: "settings edit", profileID: profile, operations: settingsOperations)
        }
        // A blocked service leaves UI progress available; Settings joins the same lane.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.password, "original")
        release.signal()
        _ = try await save.value
        try await settings.value
        XCTAssertEqual(fixture.password, "settings edit")
    }

    func testSettingsEditBeforeReviewRequiresRereview() async throws {
        let fixture = ReviewedCredentialFixture(), origin = PasswordOrigin(host: "serialized.invalid"), profile = UUID()
        let offer = PendingSave(revision: fixture.revision, host: origin.host, account: "ada", password: "offer", update: true)
        var edits = Passwords.MutationOperations()
        edits.edit = { _, _, _, password, _ in fixture.set(password) }
        try await Passwords.editAsync(.init(origin: origin, account: "ada"), origin: origin, account: "ada",
            password: "newer settings edit", profileID: profile, operations: edits)
        var review = Passwords.ReviewOperations()
        review.snapshot = { _, _, _ in (fixture.password, fixture.revision) }
        review.update = { _, _, _, password, _ in fixture.set(password) }
        let operations = review
        let outcome = try await Passwords.perform {
            try Passwords.reviewedSave(offer, origin: origin, account: "ada", password: "offer", profileID: profile, operations: operations)
        }
        guard case .review(let updated) = outcome else { return XCTFail("Changed revision did not require a new review") }
        XCTAssertEqual(updated.revision, fixture.revision)
        XCTAssertEqual(fixture.password, "newer settings edit")
    }
}
