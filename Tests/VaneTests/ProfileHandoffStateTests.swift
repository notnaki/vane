import AppKit
import XCTest
@testable import vane

@MainActor final class ProfileHandoffStateTests: XCTestCase {
    func testLittleVaneHandoffDropsOnlyCrossProfileInteractionState() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let source = TabStore(isPrivate: true, profileID: UUID(), isLittle: true, session: [])
        let target = TabStore(isPrivate: true, profileID: UUID(), session: [])
        let same = TabStore(isPrivate: true, profileID: source.profileID, session: [])
        defer {
            for store in [source, target, same] {
                store.tabs.forEach { $0.tearDown() }
                TabStore.all.removeAll { $0 === store }
            }
        }
        let url = URL(string: "https://transfer.example.test/")!
        // Recovery holds the page parked, so the assertion observes exactly what
        // handoff admitted without asking WebKit to decode synthetic opaque data.
        let snapshot = Parked(title: "Saved title", state: Data([1, 2, 3]), needsRecovery: true)
        let crossed = target.newBlankTab(), retained = same.newBlankTab()
        LittleArc.hand((url, snapshot), into: crossed, of: target, from: source, saying: "Moved")
        LittleArc.hand((url, snapshot), into: retained, of: same, from: source, saying: "Moved")
        XCTAssertEqual(crossed.currentURL, url)
        XCTAssertEqual(crossed.snapshot.title, "Saved title")
        XCTAssertNil(crossed.snapshot.state)
        XCTAssertEqual(retained.snapshot.state, Data([1, 2, 3]))
    }
}
