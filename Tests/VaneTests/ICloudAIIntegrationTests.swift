import Foundation
import XCTest
@testable import vane

final class ICloudAIIntegrationTests: XCTestCase {
    func testSyncedEndpointChangeCannotReuseExistingLocalCredentialAccount() throws {
        var existing = AIConnection(provider: .custom); existing.baseURL = "https://old.example.test/v1"
        var incoming = existing; incoming.baseURL = "https://new.example.test/v1"
        var local = AIConnections(); local.connections = [existing]
        var remote = AIConnections(); remote.connections = [incoming]
        let merged = try ICloudAIConnections.merge(remote, into: local)
        let changed = try XCTUnwrap(merged.connections.first)
        XCTAssertEqual(changed.baseURL, incoming.baseURL)
        XCTAssertNotEqual(changed.credentialAccount, existing.credentialAccount,
            "An endpoint edit cannot forward a key saved for another destination")
        let oldVault = [existing.credentialAccount: "old-endpoint-key"]
        XCTAssertNil(oldVault[changed.credentialAccount])
        XCTAssertEqual(oldVault[existing.credentialAccount], "old-endpoint-key", "The local original is retained")
        let oldCloud = try ICloudAIConnections.cloudAccounts(in: local)
        let newCloud = try ICloudAIConnections.cloudAccounts(in: merged)
        XCTAssertTrue(Set(oldCloud.keys).isDisjoint(with: newCloud.keys),
            "Old-endpoint cloud credentials cannot be admitted to the new destination")
        XCTAssertEqual(Set(newCloud.values), [changed.credentialAccount])
    }

    func testNewImportedDefinitionIgnoresLegacyOrphanAndModelOnlyEditsKeepMatchingKey() throws {
        let existing = AIConnection(provider: .openAI)
        var remote = AIConnections(); remote.connections = [existing]
        let imported = try ICloudAIConnections.merge(remote, into: AIConnections())
        XCTAssertNotEqual(imported.connections.first?.credentialAccount, existing.credentialAccount)
        XCTAssertEqual(imported.connections.first?.credentialAccount, existing.endpointCredentialAccount)
        var local = AIConnections(); local.connections = [existing]
        remote.connections[0].model = "another-model"
        let modelOnly = try ICloudAIConnections.merge(remote, into: local)
        XCTAssertEqual(modelOnly.connections.first?.credentialAccount, existing.credentialAccount)
        XCTAssertEqual(Set(try ICloudAIConnections.cloudAccounts(in: modelOnly).keys),
                       Set(try ICloudAIConnections.cloudAccounts(in: local).keys))
        let bytes = try JSONEncoder().encode(ICloudAIConnections.portable(imported))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("credentialUsesEndpointScope"),
            "A remote definition cannot choose this Mac's credential storage slot")
    }

    @MainActor func testTypedPreferenceCaptureUsesCanonicalBytesAndBaselineApplyAcceptsRemoteEdit() async throws {
        let suite = "icloud-ai-canonical-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { UserDefaults.dropScratchSuite(suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var api = AIConnection(provider: .groq); api.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var state = AIConnections(); state.connections = [api]; state.route(.downloads, to: api.id); state.save(defaults)
        let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [] })
        let initial = try await adapter.capture([.portablePreferences])
        let baseline = try XCTUnwrap(initial.first(where: { $0.id == AIConnections.preferenceKey }))
        let canonical = Data(#"{"connections":[{"baseURL":"https:\/\/api.groq.com\/openai\/v1","id":"00000000-0000-0000-0000-000000000002","model":"openai\/gpt-oss-20b","name":"Groq","provider":"groq"}],"routes":{"downloads":"00000000-0000-0000-0000-000000000002"}}"#.utf8)
        let plist = try PropertyListSerialization.propertyList(from: XCTUnwrap(baseline.fields["value"]), format: nil)
        XCTAssertEqual(plist as? Data, canonical)
        for _ in 0..<8 {
            let captured = try await adapter.capture([.portablePreferences])
            XCTAssertEqual(captured.first(where: { $0.id == AIConnections.preferenceKey })?.fields, baseline.fields)
        }
        var edited = state; edited.connections[0].model = "remote-model"
        var incoming = baseline
        incoming.fields["value"] = try PropertyListSerialization.data(fromPropertyList: JSONEncoder().encode(edited), format: .binary, options: 0)
        try await ICloudApplyContext.$baseline.withValue([baseline.key: baseline]) {
            try await adapter.apply([incoming], deleted: [], enabled: [.portablePreferences])
        }
        XCTAssertEqual(AIConnections.load(defaults).connections.first?.model, "remote-model")
    }
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
