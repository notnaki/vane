// Compile the real BrowserAI dispatcher with deterministic substitutes only at framework,
// network and credential boundaries. No Keychain, UI, Neural Engine or real HTTP is used.
import Foundation
import SwiftUI
import Security

@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor enum Boundary {
    static var gate: Gate?
    static var requests = 0
    static var cancelledCredentials = 0
}
enum Store {
    static let overrideDirectory: String? = FileManager.default.temporaryDirectory.appendingPathComponent("vane-ai-routing-" + UUID().uuidString).path
    static var directory: URL { URL(fileURLWithPath: overrideDirectory!) }
}
extension UserDefaults {
    static let fixtureSuite = "routing-" + UUID().uuidString
    @MainActor static let vane = UserDefaults(suiteName: fixtureSuite)!
    static func suiteName(forDataDir: String) -> String { "offline-routing-fixture" }
}
@MainActor enum TidyTitles { static func invalidateGeneratedNames() {} }
@MainActor enum AIKeys {
    static var values: [String: String] = [:]
    static func read(account: String, namespace: String?) -> String? { values[account] }
    static func save(_ key: String, account: String, namespace: String?) -> OSStatus { values[account] = key; return errSecSuccess }
    static func remove(account: String, namespace: String?) -> OSStatus { values[account] = nil; return errSecSuccess }
}
@MainActor final class ChatGPTSession {
    let registration: ChatGPTRegistration
    var signedOut = false
    let read: () -> ChatGPTOAuth.Credentials?
    init(registration: ChatGPTRegistration, lockURL: URL, read: @escaping () -> ChatGPTOAuth.Credentials?, write: @escaping (ChatGPTOAuth.Credentials?) -> Bool) { self.registration = registration; self.read = read }
    func credentials() async throws -> ChatGPTOAuth.Credentials {
        await Boundary.gate?.wait()
        if Task.isCancelled { Boundary.cancelledCredentials += 1 }
        return read()!
    }
    func invalidate() {}
    func signOut() async throws -> Bool { signedOut = true; return true }
}
@MainActor enum ChatGPTResponses {
    struct Model { let slug: String }
    static func catalog(token: String) async throws -> [Model] { [] }
    static func complete(_ config: CloudAI.Configuration, token: String, prompt: String, isPrivate: Bool) async throws -> String { Boundary.requests += 1; return #"{"stem":"returned-file","text":"Returned title","groups":[{"name":"Group","tabs":[1,2]}]}"# }
}
@MainActor enum AppleAI {
    static var ready: Bool { true }
    static var unavailableReason: String? { nil }
    static func shortTitle(for: String, url: URL) async -> String? { await Boundary.gate?.wait(); return "Local title" }
    static func filename(for: String, pageTitle: String?, sourceURL: URL) async -> String? { await Boundary.gate?.wait(); return "local-file.txt" }
    static func group(_ tabs: [(id: String, title: String, host: String)]) async -> [(name: String, ids: [String])]? { await Boundary.gate?.wait(); return [("Local group", tabs.map(\.id))] }
    static func prompt(_ text: String, ask: String, limit: Int = 1000) -> String { text + ask }
    static func safeFilename(_ stem: String, extension: String) -> String? { stem }
    static func worthGrouping(_ count: Int) -> Bool { count >= 2 }
    static func listing(_ tabs: [(id: String, title: String, host: String)]) -> String { "fixture" }
    static func tidyGroups(_ groups: [(String, [Int])], ids: [String]) -> [(name: String, ids: [String])]? { [("Group", ids)] }
    static func summarizeStream(_ text: String, sentences: Int) -> AsyncStream<String> { AsyncStream { $0.yield("Local summary"); $0.finish() } }
    static func payload(_ text: String) -> String? { text }
    static func plausibleSummary(_ s: String, sentences: Int, of: String) -> Bool { true }
}

@main struct BrowserAIRoutingHarness {
    @MainActor static func main() async {
        defer { UserDefaults.vane.removePersistentDomain(forName: UserDefaults.fixtureSuite) }
        var checks: [(String, Bool)] = []
        func setup(_ feature: AIFeature, cloud: Bool) -> AIConnection {
            var connection = AIConnection(provider: .chatGPT); connection.model = "fixture"
            connection.registration = .init(clientID: "oaiapp_fixture", subject: "fixture", email: nil)
            var state = AIConnections(); state.connections = [connection]
            if cloud { state.route(feature, to: connection.id) }
            UserDefaults.vane.set(true, forKey: "appleAI"); BrowserAI.save(state)
            let grant = ChatGPTOAuth.Credentials(accessToken: "fixture", refreshToken: "fixture", idToken: "fixture", scopes: ["chatgpt.tokens.use.direct"], expiresAt: .distantFuture)
            AIKeys.values[connection.credentialAccount] = grant.stored
            Boundary.requests = 0; Boundary.cancelledCredentials = 0; Boundary.gate = nil
            return connection
        }
        func waitForGate(_ gate: Gate) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
            return gate.entered
        }
        let url = URL(string: "https://fixture.example/article")!
        _ = setup(.summaries, cloud: true)
        let refresh = Gate(); Boundary.gate = refresh
        let summary = Task { @MainActor in
            var values: [String] = []
            for await value in BrowserAI.summarizeStream("Private article content", sentences: 2) { values.append(value) }
            return values
        }
        let entered = await waitForGate(refresh)
        var state = BrowserAI.state; state.route(.summaries, to: nil); BrowserAI.save(state)
        refresh.release()
        let result = await summary.value
        checks.append(("route changes during refresh prevent page-text upload", entered && Boundary.requests == 0 && result.isEmpty))
        _ = setup(.summaries, cloud: true)
        let masterRefresh = Gate(); Boundary.gate = masterRefresh
        let masterSummary = Task { @MainActor in
            var values: [String] = []
            for await value in BrowserAI.summarizeStream("Page text from before disabling AI", sentences: 2) { values.append(value) }
            return values
        }
        let masterEntered = await waitForGate(masterRefresh)
        let beforeMaster = BrowserAI.revision
        // Exercise the same production Binding used by Settings → Max.
        let masterEnabled = BrowserAI.enabledBinding
        masterEnabled.wrappedValue = false
        let disabledRevision = BrowserAI.revision
        let offPersisted = !BrowserAI.enabled && !UserDefaults.vane.bool(forKey: "appleAI")
        masterEnabled.wrappedValue = true
        let afterMaster = BrowserAI.revision
        masterRefresh.release()
        let masterResult = await masterSummary.value
        print("EVIDENCE master off/on: entered=\(masterEntered) enabled=\(BrowserAI.enabled) revision=\(beforeMaster)->\(afterMaster) uploads=\(Boundary.requests) results=\(masterResult.count)")
        checks.append(("master off/on during refresh prevents stale page-text upload", masterEntered && Boundary.requests == 0 && masterResult.isEmpty))
        checks.append(("master transition synchronously persists and invalidates each edge", offPersisted && BrowserAI.enabled && disabledRevision == beforeMaster + 1 && afterMaster == disabledRevision + 1))
        checks.append(("master switch cancels the suspended request before refresh resumes", Boundary.cancelledCredentials == 1))
        // New work after re-enabling must remain admissible. A no-op UI write must
        // neither invalidate it nor advance the generation.
        let freshRefresh = Gate(); Boundary.gate = freshRefresh
        let freshSummary = Task { @MainActor in
            var values: [String] = []
            for await value in BrowserAI.summarizeStream("New page text after re-enabling AI", sentences: 2) { values.append(value) }
            return values
        }
        let freshEntered = await waitForGate(freshRefresh)
        let freshRevision = BrowserAI.revision
        masterEnabled.wrappedValue = true
        let noOpRevision = BrowserAI.revision
        freshRefresh.release()
        let freshResult = await freshSummary.value
        checks.append(("re-enabled AI admits only fresh work and ignores same-value writes", freshEntered && freshRevision == noOpRevision && Boundary.requests == 1 && freshResult.count == 1))
        _ = setup(.tabTitles, cloud: true)
        let privateResult = await BrowserAI.shortTitle(for: "private", url: url, isPrivate: true)
        checks.append(("private browser calls never reach cloud dispatcher", privateResult == nil && Boundary.requests == 0))
        let cloud = setup(.downloads, cloud: false)
        let local = Gate(); Boundary.gate = local
        let filename = Task { @MainActor in await BrowserAI.filename(for: "opaque.txt", pageTitle: "Page", sourceURL: url) }
        let localEntered = await waitForGate(local)
        state = BrowserAI.state; state.route(.downloads, to: cloud.id); BrowserAI.save(state)
        local.release()
        let staleFilename = await filename.value
        checks.append(("route changes discard old Apple filenames", localEntered && staleFilename == nil))
        _ = setup(.tabGroups, cloud: false)
        let grouping = Gate(); Boundary.gate = grouping
        let groups = Task { @MainActor in await BrowserAI.group([(id: "1", title: "One", host: "fixture"), (id: "2", title: "Two", host: "fixture")]) }
        let groupingEntered = await waitForGate(grouping)
        BrowserAI.enabledBinding.wrappedValue = false
        BrowserAI.enabledBinding.wrappedValue = true
        grouping.release()
        let staleGroups = await groups.value
        checks.append(("master off/on discards old Apple groups", groupingEntered && BrowserAI.enabled && staleGroups == nil))
        for (name, passed) in checks { print("\(passed ? "ok" : "FAIL") \(name)") }
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
}
