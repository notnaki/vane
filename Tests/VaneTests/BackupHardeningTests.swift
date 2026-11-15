import XCTest
import SQLite3
@testable import vane

@MainActor final class BackupHardeningTests: XCTestCase {
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        _ = f.seed()
        return f
    }
    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    private func strings(_ sql: String, at url: URL) throws -> [String] {
        let db = try BackupSQLite.connection(url)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))))
        }
        return result
    }
    private func restore(_ source: BackupFixture, into target: BackupFixture) throws {
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
    }

    func testChangedProviderOrEndpointCannotReuseCredentialAccounts() throws {
        for changeProvider in [false, true] {
            let source = try fixture(), target = try fixture()
            var local = AIConnection(provider: .custom)
            local.baseURL = "https://trusted.example/v1"
            local.legacyCredentialAccount = "groq"
            var current = AIConnections(); current.connections = [local]; current.save(target.defaults)
            var incoming = local
            if changeProvider { incoming.provider = .groq }
            else { incoming.baseURL = "https://untrusted.example/v1" }
            incoming.credentialUsesEndpointScope = false
            incoming.legacyCredentialAccount = "groq"
            var state = AIConnections(); state.connections = [incoming]; state.route(.summaries, to: incoming.id)
            state.save(source.defaults)
            try restore(source, into: target)
            let restored = try XCTUnwrap(AIConnections.load(target.defaults).connection(for: .summaries))
            XCTAssertEqual(restored.baseURL, incoming.baseURL)
            XCTAssertNotEqual(restored.credentialAccount, local.credentialAccount)
            XCTAssertNotEqual(restored.credentialAccount, incoming.endpointCredentialAccount,
                              "A restored ID cannot select an orphaned endpoint-scoped credential either.")
            XCTAssertNil(restored.legacyCredentialAccount)
        }
    }
    func testMatchingDestinationRetainsOnlyDeviceLocalCredentialBinding() throws {
        let source = try fixture(), target = try fixture()
        var connection = AIConnection(provider: .custom)
        connection.baseURL = "https://trusted.example/v1"
        connection.legacyCredentialAccount = "approved-local-slot"
        var current = AIConnections(); current.connections = [connection]; current.save(target.defaults)
        connection.legacyCredentialAccount = "attacker-selected-slot"
        var incoming = AIConnections(); incoming.connections = [connection]; incoming.route(.summaries, to: connection.id)
        incoming.save(source.defaults)
        try restore(source, into: target)
        XCTAssertEqual(AIConnections.load(target.defaults).connection(for: .summaries)?.credentialAccount, "approved-local-slot")
    }
    func testLegacyAndChatGPTBackupsCannotSelectExistingCredentials() throws {
        let source = try fixture(), target = try fixture()
        source.defaults.set("groq", forKey: "aiProvider")
        try restore(source, into: target)
        let legacy = try XCTUnwrap(AIConnections.load(target.defaults).connection(for: .tabTitles))
        XCTAssertNotEqual(legacy.credentialAccount, "groq")

        var chat = AIConnection(provider: .chatGPT)
        chat.legacyCredentialAccount = "known-chatgpt-slot"
        chat.registration = ChatGPTRegistration(clientID: "imported", subject: "imported", email: nil)
        var incoming = AIConnections(); incoming.connections = [chat]; incoming.route(.summaries, to: chat.id)
        incoming.save(source.defaults)
        try restore(source, into: target)
        let restored = try XCTUnwrap(AIConnections.load(target.defaults).connection(for: .summaries))
        XCTAssertNotEqual(restored.credentialAccount, "known-chatgpt-slot")
        XCTAssertNil(restored.registration)
    }
    func testInterruptedRestoreKeepsOriginalCredentialBindingsAndSchemaOnRollback() throws {
        let source = try fixture(), target = try fixture()
        var local = AIConnection(provider: .groq)
        local.legacyCredentialAccount = "local-key"
        var state = AIConnections(); state.connections = [local]; state.route(.summaries, to: local.id)
        state.save(target.defaults)
        let original = target.defaults.data(forKey: AIConnections.preferenceKey)
        _ = target.database(ProfileManager.defaultID)
        let database = ProfileManager.dbURL(for: ProfileManager.defaultID, in: target.root)
        try execute("CREATE TABLE original_metadata(value TEXT); INSERT INTO original_metadata VALUES('original');", at: database)
        let originalDatabase = try BackupIO.read(database)
        let restore = BackupRestore(library: target.library, checkpoint: { name in
            if name == "preferences" { throw CocoaError(.userCancelled) }
        })
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertThrowsError(try restore.recoverAtLaunch())
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .rolledBack)
        XCTAssertEqual(target.defaults.data(forKey: AIConnections.preferenceKey), original)
        XCTAssertEqual(try BackupIO.read(database), originalDatabase)
    }
    func testRestoreRebuildsOnlyOwnedDatabaseSchemaAndKeepsLibraryRows() throws {
        let source = try fixture(), target = try fixture()
        let url = ProfileManager.dbURL(for: ProfileManager.defaultID, in: source.root)
        _ = source.database(ProfileManager.defaultID)
        try execute("""
            INSERT INTO bookmark_folders VALUES('folder', 'Saved', 3, 123);
            INSERT INTO bookmarks(id,url,title,at,folder_id) VALUES(7,'https://saved.example','Saved',124,'folder');
            INSERT INTO visits VALUES(9,'https://past.example','Past',125);
            CREATE TABLE retained_history(url TEXT);
            CREATE VIEW stolen_history AS SELECT url FROM retained_history;
            CREATE TRIGGER retain_visit AFTER INSERT ON visits BEGIN INSERT INTO retained_history VALUES(new.url); END;
            CREATE INDEX attacker_index ON visits(title);
            """, at: url)
        try restore(source, into: target)
        let restored = ProfileManager.dbURL(for: ProfileManager.defaultID, in: target.root)
        XCTAssertEqual(try strings("SELECT name FROM sqlite_master WHERE type IN ('table','view','trigger') ORDER BY name", at: restored),
                       ["bookmark_folders", "bookmarks", "visits"])
        XCTAssertFalse(try strings("SELECT name FROM sqlite_master WHERE type='index'", at: restored).contains("attacker_index"))
        XCTAssertEqual(try strings("SELECT id || ':' || url || ':' || folder_id FROM bookmarks", at: restored), ["7:https://saved.example:folder"])
        XCTAssertEqual(try strings("SELECT id || ':' || name || ':' || position FROM bookmark_folders", at: restored), ["folder:Saved:3"])
        try execute("INSERT INTO visits(url,title,at) VALUES('https://new.example','New',126); DELETE FROM visits;", at: restored)
        XCTAssertEqual(try strings("SELECT url FROM visits", at: restored), [])
    }
    func testRestoreKeepsICloudSyncIdentities() throws {
        let source = try fixture(), target = try fixture()
        let url = ProfileManager.dbURL(for: ProfileManager.defaultID, in: source.root)
        _ = source.database(ProfileManager.defaultID)
        try execute("""
            ALTER TABLE visits ADD COLUMN sync_id TEXT;
            ALTER TABLE bookmarks ADD COLUMN sync_id TEXT;
            INSERT INTO visits(id,url,title,at,sync_id) VALUES(9,'https://past.example','Past',125,'visit-identity');
            INSERT INTO bookmarks(id,url,title,at,sync_id) VALUES(7,'https://saved.example','Saved',124,'bookmark-identity');
            """, at: url)
        try restore(source, into: target)
        let restored = ProfileManager.dbURL(for: ProfileManager.defaultID, in: target.root)
        XCTAssertEqual(try strings("SELECT sync_id FROM visits WHERE id=9", at: restored), ["visit-identity"])
        XCTAssertEqual(try strings("SELECT sync_id FROM bookmarks WHERE id=7", at: restored), ["bookmark-identity"])
    }
    func testRestoreValidationRejectsOverflowingFolderPositionsAndBadSyncIdentities() throws {
        for sql in ["INSERT INTO bookmark_folders VALUES('f','Folder',9223372036854775807,1)",
                    "INSERT INTO bookmark_folders VALUES('f','Folder',-1,1)",
                    "INSERT INTO bookmark_folders VALUES('f','Folder','top',1)",
                    "ALTER TABLE visits ADD COLUMN sync_id TEXT; INSERT INTO visits(url,title,at,sync_id) VALUES('https://e.example','E',1,x'00')"] {
            let f = try fixture()
            _ = f.database(ProfileManager.defaultID)
            try execute(sql, at: ProfileManager.dbURL(for: ProfileManager.defaultID, in: f.root))
            var archive = try f.library.capture(reason: .manual, allowDamaged: true)
            archive.damage = nil
            XCTAssertThrowsError(try f.library.validate(archive), sql)
        }
    }
    func testRestoreValidationRejectsNonFiniteAndNonNumericTimestamps() throws {
        for (table, column) in [("visits", "at"), ("bookmarks", "at"), ("bookmark_folders", "created_at")] {
            for value in ["1e999", "-1e999", "'invalid'"] {
                let f = try fixture()
                _ = f.database(ProfileManager.defaultID)
                let url = ProfileManager.dbURL(for: ProfileManager.defaultID, in: f.root)
                if table == "bookmark_folders" {
                    try execute("INSERT INTO bookmark_folders VALUES('f','Folder',0,\(value))", at: url)
                } else {
                    try execute("INSERT INTO \(table)(url,title,at) VALUES('https://example.com','Title',\(value))", at: url)
                }
                var archive = try f.library.capture(reason: .manual, allowDamaged: true)
                archive.damage = nil
                XCTAssertThrowsError(try f.library.validate(archive), "\(table).\(column)=\(value)")
            }
        }
    }
    func testRestoreRejectsInvalidProfileColor() throws {
        for color in ["invalid", "#12345z", "", "#1234567", "#12345"] {
            let f = try fixture()
            var archive = try f.library.capture(reason: .manual)
            let index = try XCTUnwrap(archive.files.firstIndex { $0.name == "profiles.json" })
            var profiles = try JSONDecoder().decode(BackupLibrary.Profiles.self, from: archive.files[index].data)
            profiles.profiles[0].colorHex = color
            archive.files[index] = .init(name: "profiles.json", data: try JSONEncoder().encode(profiles))
            XCTAssertThrowsError(try f.library.validate(archive), color)
        }
    }
    func testCorruptSavedProfileColorUsesNeutralWash() {
        let profile = Profile(id: ProfileManager.defaultID, name: "Broken", colorHex: "invalid")
        let wash = ThemeWash.space(nil, fallback: profile, profiles: [profile], systemDark: false)
        XCTAssertTrue(wash.colors.allSatisfy { $0.isValid })
        XCTAssertTrue(wash.colors.allSatisfy { $0.red == $0.green && $0.green == $0.blue })
    }
    func testICloudCaptureRejectsAlreadyCorruptLocalTimestamps() async throws {
        let f = try fixture(), store = f.database(ProfileManager.defaultID)
        let db = try StoreSQLiteFixture.writer(store)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO visits(url,title,at) VALUES('https://example.com','Title',1e999)", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await store.captureICloud([.history], profile: ProfileManager.defaultID)
            XCTFail("Corrupt local timestamps must produce a recoverable capture error")
        } catch {}
    }
    func testICloudApplyRejectsAlreadyCorruptLocalTimestamp() async throws {
        let f = try fixture(), store = f.database(ProfileManager.defaultID)
        let db = try StoreSQLiteFixture.writer(store)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO bookmarks(url,title,at) VALUES('https://example.com','Title',123)", nil, nil, nil), SQLITE_OK)
        let items = try await store.captureICloud([.bookmarks], profile: ProfileManager.defaultID)
        var item = try XCTUnwrap(items.first)
        item.fields["title"] = try JSONEncoder().encode("Updated")
        XCTAssertEqual(sqlite3_exec(db, "UPDATE bookmarks SET at=1e999", nil, nil, nil), SQLITE_OK)
        do {
            try await store.applyICloud(item, deleting: false)
            XCTFail("Corrupt local timestamps must produce a recoverable apply error")
        } catch {}
    }
}
