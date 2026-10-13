import XCTest

/// Releases debounce waits explicitly, even after cancellation, so tests exercise
/// the consumer's cancellation guard without racing a real clock.
@MainActor final class Feel04DebounceFixture {
    private var waits: [CheckedContinuation<Void, Never>] = []
    private var released: Set<Int> = []
    private(set) var completed: Set<Int> = []
    private var stopped = false
    var count: Int { waits.count }

    func sleep(_ duration: Duration) async throws {
        guard !stopped else { return }
        let index = waits.count
        await withCheckedContinuation { waits.append($0) }
        completed.insert(index)
    }

    func release(_ index: Int) {
        if released.insert(index).inserted { waits[index].resume() }
    }

    func finish() {
        stopped = true
        for index in waits.indices { release(index) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else { throw WaitError.timedOut }
    }

    private enum WaitError: Error { case timedOut }
}
