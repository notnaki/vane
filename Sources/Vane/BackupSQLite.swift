import Foundation
import SQLite3
import CryptoKit

enum BackupSQLite {
    static func connection(_ url: URL) throws -> OpaquePointer {
        try BackupIO.checkFile(url)
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw BackupError.invalid("The bookmarks and history database cannot be opened.")
        }
        sqlite3_busy_timeout(db, 1000)
        // Schema supplied by a backup must not enable SQL functions in schema objects.
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        return db
    }
    static func snapshot(at url: URL) throws -> Data {
        let source = try connection(url)
        defer { sqlite3_close(source) }
        return try withTemporaryDatabase { destination in
            var db: OpaquePointer?
            guard sqlite3_open(destination.path, &db) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                throw BackupError.storage("Could not create a database snapshot.")
            }
            var closed = false
            defer { if !closed { sqlite3_close(db) } }
            guard let backup = sqlite3_backup_init(db, "main", source, "main") else {
                throw BackupError.storage("Could not snapshot bookmarks and history.")
            }
            var status = sqlite3_backup_step(backup, -1), attempts = 0
            while [SQLITE_BUSY, SQLITE_LOCKED].contains(status), attempts < 20 {
                Thread.sleep(forTimeInterval: 0.05); attempts += 1
                status = sqlite3_backup_step(backup, -1)
            }
            let finish = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE, finish == SQLITE_OK else { throw BackupError.storage("Could not finish the database snapshot. Try again.") }
            // The backup inherits WAL mode. Export a closed, single-file snapshot.
            guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                throw BackupError.storage("Could not complete the database snapshot.")
            }
            try verify(db)
            guard sqlite3_close(db) == SQLITE_OK else { throw BackupError.storage("Could not close the database snapshot.") }
            closed = true
            return try BackupIO.read(destination)
        }
    }
    static func counts(_ data: Data) throws -> (bookmarks: Int, history: Int) {
        try withData(data) { db in
            try verify(db)
            return (try count(db, "bookmarks"), try count(db, "visits"))
        }
    }
    static func contentDigest(_ data: Data) throws -> String {
        try withData(data) { db in
            try verify(db)
            var hash = SHA256()
            // Hash ordered typed values, rather than SQLite's volatile page/header bytes.
            for table in ["bookmarks", "bookmark_folders", "visits"] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY id", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw BackupError.invalid("Invalid database schema.") }
                defer { sqlite3_finalize(statement) }
                hash.update(data: Data(table.utf8))
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    for column in 0..<sqlite3_column_count(statement) {
                        let type = sqlite3_column_type(statement, column)
                        let value: Data
                        if type == SQLITE_NULL { value = Data() }
                        else if let bytes = sqlite3_column_blob(statement, column) {
                            value = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                        } else { value = Data() }
                        hash.update(data: Data("\(type):\(value.count):".utf8)); hash.update(data: value)
                    }
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw BackupError.invalid("Could not read database contents.") }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    private static func count(_ db: OpaquePointer, _ table: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BackupError.invalid("Missing bookmark/history tables.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BackupError.invalid("Could not count saved data.") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private static func verify(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BackupError.invalid("Invalid database.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE else {
            throw BackupError.invalid("The bookmarks/history database is damaged.")
        }
        for (table, columns) in [("bookmarks", ["id", "url", "title", "at", "folder_id"]),
                                 ("bookmark_folders", ["id", "name", "position", "created_at"]),
                                 ("visits", ["id", "url", "title", "at"])] {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT \(columns.joined(separator: ",")) FROM \(table) LIMIT 0", -1, &st, nil) == SQLITE_OK,
                  let st else { throw BackupError.invalid("Unsupported bookmark/history schema.") }
            sqlite3_finalize(st)
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT type FROM sqlite_master WHERE name=?", -1, &schema, nil) == SQLITE_OK,
                  let schema else { throw BackupError.invalid("Invalid database schema.") }
            defer { sqlite3_finalize(schema) }
            sqlite3_bind_text(schema, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(schema) == SQLITE_ROW, let kind = sqlite3_column_text(schema, 0),
                  String(cString: kind) == "table" else { throw BackupError.invalid("Invalid database tables.") }
        }
    }
    private static func withData<T>(_ data: Data, _ body: (OpaquePointer) throws -> T) throws -> T {
        try withTemporaryDatabase { url in
            try BackupIO.write(data, url)
            let db = try connection(url); defer { sqlite3_close(db) }
            return try body(db)
        }
    }
    private static func withTemporaryDatabase<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-backup-sqlite-\(UUID())")
        try BackupIO.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root.appendingPathComponent("snapshot.db"))
    }
}
