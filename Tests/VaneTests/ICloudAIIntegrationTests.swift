import Foundation
import XCTest
@testable import vane

final class ICloudAIIntegrationTests: XCTestCase {
    func testDamagedMetadataCannotBecomeAnEmptyCredentialInventory() throws {
        let suite = "icloud-ai-corrupt-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.dropScratchSuite(suite) }
        defaults.set(Data("damaged metadata".utf8), forKey: AIConnections.preferenceKey)
        XCTAssertThrowsError(try ICloudAIConnections.local(defaults))
    }

    func testPortableAPIIdentityCannotReplaceDeviceLocalChatGPTConnection() throws {
        let chat = AIConnection(provider: .chatGPT)
        var api = AIConnection(provider: .openAI); api.id = chat.id
        var local = AIConnections(); local.connections = [chat]
        var incoming = AIConnections(); incoming.connections = [api]
        XCTAssertThrowsError(try ICloudAIConnections.merge(incoming, into: local))
        XCTAssertEqual(local.connections, [chat])
    }
    func testPortableConnectionsStripChatGPTRegistrationAndPreserveLocalChatGPTRoutes() throws {
        var api = AIConnection(provider: .openAI)
        api.registration = .init(clientID: "must-not-export", subject: "private-account", email: "private@example.test")
        var chat = AIConnection(provider: .chatGPT)
        chat.registration = api.registration
        var source = AIConnections(); source.connections = [api, chat]
        source.route(.tabTitles, to: api.id); source.route(.summaries, to: chat.id)
        let portable = try ICloudAIConnections.portable(source)
        XCTAssertEqual(portable.connections.map(\.id), [api.id])
        XCTAssertNil(portable.connections.first?.registration)
        XCTAssertNil(portable.connection(for: .summaries))
        XCTAssertEqual(portable.connection(for: .tabTitles)?.id, api.id)
        let bytes = try JSONEncoder().encode(portable)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-account"))

        var destination = AIConnections(); destination.connections = [chat]
        destination.route(.summaries, to: chat.id)
        let merged = try ICloudAIConnections.merge(portable, into: destination)
        XCTAssertEqual(merged.connection(for: .summaries), chat)
        XCTAssertEqual(merged.connection(for: .tabTitles)?.id, api.id)
        XCTAssertEqual(merged.connections.first(where: { $0.id == chat.id })?.registration, chat.registration)
    }

    func testAPIKeySnapshotNeverReadsChatGPTOrForeignCredentialAccounts() throws {
        let api = AIConnection(provider: .openAI), chat = AIConnection(provider: .chatGPT)
        var state = AIConnections(); state.connections = [api, chat]
        let eligible = try ICloudAIConnections.accounts(in: state)
        var reads: [String] = []
        let values = try AIKeys.iCloudSnapshot(accounts: eligible, read: { account in
            reads.append(account); return "synthetic-api-key"
        })
        XCTAssertEqual(reads, [api.credentialAccount])
        XCTAssertEqual(Set(values.keys), [.aiKey(account: api.credentialAccount)])
        XCTAssertFalse(reads.contains(chat.credentialAccount))
        var poisoned = api; poisoned.legacyCredentialAccount = chat.credentialAccount
        state.connections = [poisoned, chat]
        XCTAssertThrowsError(try ICloudAIConnections.accounts(in: state))
    }

    @MainActor func testPreferenceRoundTripKeepsAPIConnectionsAndDeviceLocalChatGPTSeparate() async throws {
        let suite = "icloud-ai-integration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { UserDefaults.dropScratchSuite(suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = AIConnection(provider: .groq), chat = AIConnection(provider: .chatGPT)
        var source = AIConnections(); source.connections = [api]; source.route(.downloads, to: api.id); source.save(defaults)
        let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [] })
        let rows = try await adapter.capture([.portablePreferences])
        XCTAssertTrue(rows.contains(where: { $0.id == AIConnections.preferenceKey }))
        XCTAssertNil(defaults.object(forKey: "appleAI"), "Sync capture cannot invent an enabled AI master")
        var local = AIConnections(); local.connections = [chat]; local.route(.summaries, to: chat.id); local.save(defaults)
        try await adapter.apply(rows, deleted: [], enabled: [.portablePreferences])
        let merged = AIConnections.load(defaults)
        XCTAssertEqual(merged.connection(for: .downloads)?.id, api.id)
        XCTAssertEqual(merged.connection(for: .summaries)?.id, chat.id)
        XCTAssertNil(defaults.object(forKey: "appleAI"))
    }
}
