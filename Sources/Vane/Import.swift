import AppKit
import UniformTypeIdentifiers

/// RFC 4180. Not hand-rolled splitting on commas: passwords legitimately contain commas,
/// quotes and newlines, and a naive split silently corrupts exactly the entries you would
/// least like corrupted.
enum CSV {
    static func rows(_ text: String) -> [[String]] { (try? parse(text)) ?? [] }

    /// Validate the whole document before a caller saves any credentials. Errors identify
    /// structure only, never field contents (even a malformed header may contain a secret).
    static func parse(_ input: String) throws -> [[String]] {
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        var i = text.startIndex
        func finishField() { row.append(field); field = ""; closed = false }
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); i = next }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," {
                finishField()
            } else if c.isNewline {
                finishField(); rows.append(row); row = []
            } else if c == "\"", field.isEmpty, !closed {
                quoted = true
            } else {
                guard !closed, c != "\"" else {
                    throw PasswordImport.Failure("Malformed CSV quoting.")
                }
                field.append(c)
            }
            i = text.index(after: i)
        }
        guard !quoted else { throw PasswordImport.Failure("The CSV has an unfinished quoted field.") }
        finishField(); rows.append(row)
        return rows.filter { $0.contains { !$0.isEmpty } }
    }
}

/// Import saved logins from any browser's password export. Chrome, Edge, Brave, Opera,
/// Vivaldi, Arc, Firefox, Safari and the macOS Passwords app all export this shape, and so
/// do 1Password and Bitwarden — so the column names vary but the file does not.
/// ponytail: no reading Chrome's Login Data + Safe Storage key, no Firefox NSS. One parser,
/// no crypto, and it does not break the next time a vendor changes its at-rest format.
enum PasswordImport {
    struct Entry {
        let origin: PasswordOrigin
        let account: String, password: String
        var host: String { origin.host }
        init(host: String, account: String, password: String) {
            self.init(origin: PasswordOrigin(host: host), account: account, password: password)
        }
        init(origin: PasswordOrigin, account: String, password: String) {
            self.origin = origin; self.account = account; self.password = password
        }
    }

    private static let urlNames      = ["url", "website url", "login_uri", "web site", "hostname"]
    private static let accountNames  = ["username", "user name", "login_username", "login", "email"]
    private static let passwordNames = ["password", "login_password"]

    /// Returns the usable entries plus the count of rows dropped (no password, or no host).
    static func parse(_ text: String) throws -> (entries: [Entry], skipped: Int) {
        let rows = try CSV.parse(text)
        guard let header = rows.first else { throw Failure("the file is empty") }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(_ names: [String]) -> Int? { cols.firstIndex { names.contains($0) } }
        guard let u = index(urlNames), let p = index(passwordNames) else {
            throw Failure("no url/password columns found")
        }
        let a = index(accountNames)

        var entries: [Entry] = [], skipped = 0
        for row in rows.dropFirst() {
            func field(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i]
            }
            let password = field(p)
            guard !password.isEmpty, let origin = origin(from: field(u)) else { skipped += 1; continue }
            entries.append(Entry(origin: origin, account: field(a), password: password))
        }
        return (entries, skipped)
    }

    /// Exports write anything from "https://site.com/login" to a bare "site.com".
    private static func origin(from raw: String) -> PasswordOrigin? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: raw.contains("://") ? raw : "https://" + raw)
        return url.flatMap(PasswordOrigin.init(url:))
    }

    @discardableResult
    static func importFile(_ url: URL, existing: Set<String> = [],
                           save: (Entry) -> Bool = {
                               Passwords.save(origin: $0.origin, account: $0.account,
                                              password: $0.password, replacingExisting: false)
                           }) throws -> (imported: Int, skipped: Int, failed: Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try parse(text)
        var imported = 0, skipped = parsed.skipped, failed = 0
        var saved = existing
        for entry in parsed.entries {
            let key = entry.origin.key(account: entry.account)
            guard !saved.contains(key) else { skipped += 1; continue }
            if save(entry) { imported += 1; saved.insert(key) }
            else { failed += 1 }
        }
        return (imported, skipped, failed)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    // MARK: UI

    @MainActor static func chooseAndImport(profileID: UUID = ProfileManager.activeProfileID) {
        let panel = NSOpenPanel()
        panel.title = "Import Passwords"
        panel.message = "Choose a password export (.csv) from Chrome, Safari, Firefox, "
            + "Edge, Brave, 1Password or Bitwarden."
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        do {
            let existing = Set(Passwords.all(profileID: profileID).map(\.id))
            let result = try importFile(file, existing: existing, save: {
                return Passwords.save(origin: $0.origin, account: $0.account, password: $0.password,
                                      profileID: profileID, replacingExisting: false)
            })
            let imported = result.imported
            alert.messageText = result.failed == 0
                ? "Imported \(imported) password\(imported == 1 ? "" : "s")."
                : "Some passwords could not be imported."
            if result.failed > 0 { alert.alertStyle = .warning }
            alert.informativeText = (result.failed > 0
                ? "\(imported) saved; \(result.failed) failed. Existing passwords were kept. Check Keychain access and try importing again.\n\n"
                : "")
                + (result.skipped > 0 ? "\(result.skipped) invalid, duplicate or existing row(s) were skipped. Existing passwords were kept.\n\n" : "")
                + "That export file is plain text. Delete it when you no longer need it."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not import that file."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

/// Netscape bookmark HTML from Vane or another browser. Folder names are retained; nested
/// paths are displayed as a single readable folder because the native manager is one level.
@MainActor enum BookmarkImport {
    @discardableResult
    static func importFile(_ url: URL, profileID: UUID = ProfileManager.activeProfileID) throws
        -> BookmarkImportResult {
        let entries = try Export.checkedNetscapeEntries(String(contentsOf: url, encoding: .utf8))
        guard !entries.isEmpty else { throw PasswordImport.Failure("no bookmarks were found") }
        let items = entries.compactMap { entry -> BookmarkImportItem? in
            guard let url = URL(string: entry.row.url), url.scheme == "http" || url.scheme == "https"
            else { return nil }
            return BookmarkImportItem(url: url, title: entry.row.title,
                                      folder: entry.folder, at: entry.importedAt)
        }
        guard !items.isEmpty else { throw PasswordImport.Failure("no usable web bookmarks were found") }
        guard let result = Store.store(for: profileID).importBookmarks(items) else {
            throw PasswordImport.Failure("the bookmarks could not be saved")
        }
        return result
    }

    static func chooseAndImport(profileID: UUID = ProfileManager.activeProfileID) {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Choose a bookmark HTML export from Vane, Safari, Chrome, Firefox or Edge."
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let alert = NSAlert()
        do {
            let result = try importFile(file, profileID: profileID)
            alert.messageText = "Imported \(result.imported) bookmark\(result.imported == 1 ? "" : "s")."
            alert.informativeText = result.folders == 0 ? "" : "Created \(result.folders) folder\(result.folders == 1 ? "" : "s")."
            rebuild()
            BookmarkManager.refresh(profileID: profileID)
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not import that bookmark file."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
