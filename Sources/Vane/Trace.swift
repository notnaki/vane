import OSLog

/// Where a page load's time goes, as signposts.
///
/// Always on, in every build, and invisible unless something is listening: an `OSSignposter`
/// with no recorder attached costs a load and a branch. That is the whole reason there is no
/// `#if DEBUG` anywhere in here — the only timings worth having are a release build's, and a
/// measurement you have to rebuild to take is a measurement nobody takes.
///
///     xcrun xctrace record --template 'os_signpost' --attach vane --output page.trace
///
/// The navigation interval is the spine: it opens at `didStartProvisionalNavigation`, is
/// marked at `didCommit`, and closes at `didFinish`. The point signposts inside it —
/// certificate trust, the reader probe, the history row, the favicon — say which of those
/// landed where, so a load that is slow in one of them is slow visibly rather than by guess.
enum Trace {
    nonisolated static let posts = OSSignposter(subsystem: "app.vane", category: "page")

    /// A navigation begins in one delegate method and ends in another, so its interval state
    /// has to be parked somewhere in between. Keyed by tab: a tab has one navigation at a
    /// time, and a navigation replaced before it finished closes the old interval on the way
    /// past rather than leaving it open for the length of the trace.
    @MainActor private static var live: [UUID: OSSignpostIntervalState] = [:]

    @MainActor static func begin(_ tab: UUID) {
        end(tab)
        live[tab] = posts.beginInterval("navigation", id: posts.makeSignpostID())
    }

    @MainActor static func end(_ tab: UUID) {
        guard let state = live.removeValue(forKey: tab) else { return }
        posts.endInterval("navigation", state)
    }

    /// A moment inside a load, named.
    nonisolated static func note(_ name: StaticString) { posts.emitEvent(name) }

    /// For the one span that is neither a navigation nor a moment: a tab waking up.
    @MainActor static func span<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = posts.beginInterval(name, id: posts.makeSignpostID())
        defer { posts.endInterval(name, state) }
        return body()
    }
}
