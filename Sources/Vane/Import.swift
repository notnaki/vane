import AppKit

/// RFC 4180. Not hand-rolled splitting on commas: passwords legitimately contain commas,
/// quotes and newlines, and a naive split silently corrupts exactly the entries you would
/// least like corrupted.
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); i = next }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c.isNewline {          // Character folds CRLF into one grapheme
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        rows.append(row)
        return rows.filter { $0.contains { !$0.isEmpty } }
    }
}

/// Import saved logins from any browser's password export. Chrome, Edge, Brave, Opera,
/// Vivaldi, Arc, Firefox, Safari and the macOS Passwords app all export this shape, and so
/// do 1Password and Bitwarden — so the column names vary but the file does not.
/// ponytail: no reading Chrome's Login Data + Safe Storage key, no Firefox NSS. One parser,
/// no crypto, and it does not break the next time a vendor changes its at-rest format.
enum PasswordImport {
    struct Entry { let host: String, account: String, password: String }

    private static let urlNames      = ["url", "website url", "login_uri", "web site", "hostname"]
    private static let accountNames  = ["username", "user name", "login_username", "login", "email"]
    private static let passwordNames = ["password", "login_password"]

    /// Returns the usable entries plus the count of rows dropped (no password, or no host).
    static func parse(_ text: String) throws -> (entries: [Entry], skipped: Int) {
        let rows = CSV.rows(text)
        guard let header = rows.first else { throw Failure("the file is empty") }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(_ names: [String]) -> Int? { cols.firstIndex { names.contains($0) } }
        guard let u = index(urlNames), let p = index(passwordNames) else {
            throw Failure("no url/password columns found — header was: \(cols.joined(separator: ", "))")
        }
        let a = index(accountNames)

        var entries: [Entry] = [], skipped = 0
        for row in rows.dropFirst() {
            func field(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespaces)
            }
            let password = field(p)
            guard !password.isEmpty, let host = host(from: field(u)) else { skipped += 1; continue }
            entries.append(Entry(host: host, account: field(a), password: password))
        }
        return (entries, skipped)
    }

    /// Exports write anything from "https://site.com/login" to a bare "site.com".
    private static func host(from raw: String) -> String? {
        if let h = URLComponents(string: raw)?.host, !h.isEmpty { return h.lowercased() }
        let bare = raw.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
        let host = bare.split(separator: "/").first.map(String.init) ?? ""
        return host.contains(".") ? host.lowercased() : nil
    }

    @discardableResult
    static func importFile(_ url: URL) throws -> (imported: Int, skipped: Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (entries, skipped) = try parse(text)
        for e in entries { Passwords.save(host: e.host, account: e.account, password: e.password) }
        return (entries.count, skipped)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    // MARK: UI

    @MainActor static func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Passwords"
        panel.message = "Choose a password export (.csv) from Chrome, Safari, Firefox, "
            + "Edge, Brave, 1Password or Bitwarden."
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        do {
            let (imported, skipped) = try importFile(file)
            alert.messageText = "Imported \(imported) password\(imported == 1 ? "" : "s")."
            alert.informativeText = (skipped > 0 ? "\(skipped) row(s) had no password and were skipped.\n\n" : "")
                + "That export file is plain text. Delete it now that it has been imported."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not import that file."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
