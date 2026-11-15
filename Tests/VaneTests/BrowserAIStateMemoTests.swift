import XCTest
@testable import vane

@MainActor final class BrowserAIStateMemoTests: XCTestCase {
    func testStateFollowsStoredBytesAfterMemoisation() {
        TestEnvironment.prepare()
        let key = AIConnections.preferenceKey
        let previous = UserDefaults.vane.data(forKey: key)
        defer {
            if let previous { UserDefaults.vane.set(previous, forKey: key) } else { UserDefaults.vane.removeObject(forKey: key) }
        }
        var first = AIConnections(); first.connections = [AIConnection(provider: .groq)]
        first.save(UserDefaults.vane)
        XCTAssertEqual(BrowserAI.state, first)
        XCTAssertEqual(BrowserAI.state, first, "A repeated read returns the same decoded value")
        var second = AIConnections(); second.connections = [AIConnection(provider: .custom), AIConnection(provider: .groq)]
        second.save(UserDefaults.vane)
        XCTAssertEqual(BrowserAI.state, second, "New bytes must replace the memoised state")
        UserDefaults.vane.set(Data("not json".utf8), forKey: key)
        XCTAssertEqual(BrowserAI.state, AIConnections(), "Damaged bytes decode to empty, not the stale memo")
    }
}
