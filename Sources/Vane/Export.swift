import AppKit
import Security
import SQLite3
import UniformTypeIdentifiers

/// Getting your data back out. Vane can import bookmarks, history and passwords; a browser
/// that can only take data in is a trap, so this is the other direction.
///
/// Formats are chosen for what *other* software already reads, not for what is convenient
/// here: Netscape bookmark HTML (Chrome, Safari, Firefox and Edge all import it), CSV in the
/// exact shape `PasswordImport` accepts, and JSON for anything that wants to script over it.
/// ponytail: string building and one NSSavePanel. No writer library, no template engine, no
/// SwiftUI — an export is a file, and a file is a String plus `write(to:)`.
///
/// Everything is per profile. `Store` holds no dates on the way out (`bookmarks()` drops
/// `at`), so the rows are read straight from the profile's SQLite file with a second
/// read-only connection. ponytail: that duplicates two SELECTs rather than widening Store's
/// API for one caller; if a third caller ever needs dated rows, move it into Store.
@MainActor enum Export {

    enum Kind {
        case bookmarks, historyJSON, historyCSV, passwords
    }

    /// A dated url. Bookmarks and history are the same three columns in this app.
    struct Row: Equatable {
        let url: String
        let title: String
        let at: Date
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    // MARK: Reading a profile

    /// Read-only second connection to the active profile's db. Store keeps its own handle
    /// open in WAL mode; WAL is built for exactly this — one writer, many readers — so
    /// nothing has to be copied the way BrowserImport copies another browser's locked file.
    private static func rows(_ sql: String, profileID: UUID) -> [Row] {
        let path = ProfileManager.dbURL(for: profileID, in: Store.directory).path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func text(_ c: Int32) -> String {
                sqlite3_column_text(st, c).map { String(cString: $0) } ?? ""
            }
            out.append(Row(url: text(0), title: text(1),
                           at: Date(timeIntervalSince1970: sqlite3_column_double(st, 2))))
        }
        return out
    }

    static func bookmarkRows(profileID: UUID = ProfileManager.activeProfileID) -> [Row] {
        rows("SELECT url, title, at FROM bookmarks ORDER BY at DESC", profileID: profileID)
    }

    /// One row per *visit*, not per url: that is what the table holds, and collapsing it
    /// would throw away the visit history the user asked to export.
    /// ponytail: the whole table, built into one String in memory. A heavy profile is a few
    /// hundred thousand rows — tens of MB, written once, on a user-initiated action. The
    /// ceiling is a machine where that matters; the fix then is streaming to a FileHandle,
    /// not a date range nobody asked for.
    static func historyRows(profileID: UUID = ProfileManager.activeProfileID) -> [Row] {
        rows("SELECT url, title, at FROM visits ORDER BY at DESC", profileID: profileID)
    }

    // MARK: Bookmarks → Netscape HTML

    /// The format every browser reads, defined by Netscape in 1996 and never changed since:
    /// a doctype nobody validates, then a `<DL>` of `<DT><A HREF ADD_DATE>` entries.
    /// ponytail: flat, no `<H3>` folders. Vane's bookmarks have no folders to preserve, and
    /// importers put a flat list wherever they put flat lists.
    ///
    /// ADD_DATE is whole seconds since the unix epoch. Chrome reads a float here as garbage
    /// and shows 1970, so it is truncated to an Int rather than printed as a Double.
    static func bookmarksHTML(_ rows: [Row]) -> String {
        var s = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for r in rows {
            // The url is escaped too: a query string with a bare `&` is legal in a url and
            // illegal in an attribute, and browsers that re-serialize the file will mangle it.
            s += "    <DT><A HREF=\"\(escape(r.url))\" ADD_DATE=\"\(Int(r.at.timeIntervalSince1970))\">"
                + escape(r.title) + "</A>\n"
        }
        s += "</DL><p>\n"
        return s
    }

    /// `&` first, or every entity written after it gets double-escaped. Quotes are escaped
    /// because the same helper writes attribute values; apostrophes are left alone, which is
    /// safe inside double-quoted attributes and is what Chrome's own export does.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")   // last, or "&amp;lt;" decodes twice
    }

    /// Reads back what `bookmarksHTML` writes — and, being written against the format rather
    /// than against our writer, also reads Chrome's, Safari's and Firefox's exports, which is
    /// what makes the round-trip assertion worth anything.
    /// ponytail: a regex over `<DT><A …>`, not an HTML parser. This file has no nesting worth
    /// walking; the ceiling is that folder structure (`<H3>`) is ignored, which is exactly
    /// what Vane would do with it anyway.
    static func parseNetscape(_ html: String) -> [Row] {
        // Two passes: grab the anchor, then pull attributes out of it by name. One combined
        // pattern with an optional ADD_DATE group looks tidier and is wrong — the optional
        // group matches empty and `[^>]*` eats the date, so every bookmark imports as 1970.
        guard let anchors = try? NSRegularExpression(pattern: "<DT><A\\s([^>]*)>(.*?)</A>",
                                                     options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return anchors.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let attributes = ns.substring(with: m.range(at: 1))
            guard let href = attribute("HREF", in: attributes) else { return nil }
            return Row(url: unescape(href),
                       title: unescape(ns.substring(with: m.range(at: 2))),
                       at: Date(timeIntervalSince1970: Double(attribute("ADD_DATE", in: attributes) ?? "") ?? 0))
        }
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\"",
                                                options: [.caseInsensitive]) else { return nil }
        let ns = attributes as NSString
        guard let m = re.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: CSV

    /// RFC 4180, the writing half of `CSV.rows`. A field is quoted when it holds a comma, a
    /// quote, a newline or edge whitespace; embedded quotes double. Anything less than this
    /// corrupts precisely the passwords you would least like corrupted.
    static func field(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// CRLF because RFC 4180 says so and Excel cares; `CSV.rows` folds it into one grapheme.
    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: History

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Two date columns on purpose: `visited_at` is for the human reading the file, `epoch`
    /// is the one that survives a round trip — Swift prints a Double in its shortest
    /// round-trippable form, so `Double(epoch)!` is bit-for-bit the date that went in, which
    /// ISO-8601 (whole seconds) is not.
    static func historyCSVRows(_ rows: [Row]) -> [[String]] {
        [["url", "title", "visited_at", "epoch"]] + rows.map {
            [$0.url, $0.title, iso.string(from: $0.at), String($0.at.timeIntervalSince1970)]
        }
    }

    static func historyCSV(_ rows: [Row]) -> String { csv(historyCSVRows(rows)) }

    /// The inverse of `historyCSV`, over the existing RFC 4180 reader. Used by `check()` to
    /// prove a Vane export reads back as a Vane import.
    static func parseHistoryCSV(_ text: String) -> [Row] {
        CSV.rows(text).dropFirst().compactMap { row in
            guard row.count >= 4, let epoch = Double(row[3]) else { return nil }
            return Row(url: row[0], title: row[1], at: Date(timeIntervalSince1970: epoch))
        }
    }

    /// ponytail: JSONSerialization, not Codable — the shape is three keys and writing an
    /// Encodable struct to get the same bytes is more code, not less.
    static func historyJSON(_ rows: [Row]) -> String {
        let objects = rows.map {
            ["url": $0.url, "title": $0.title,
             "visited_at": iso.string(from: $0.at), "epoch": $0.at.timeIntervalSince1970] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text + "\n"
    }

    // MARK: Passwords

    /// 'Vane' as an OSType, and the per-profile security domain rule.
    /// ponytail: both are duplicated from Passwords.swift, which keeps them private. That is
    /// a real hazard — change the creator code there and this exports nothing — but the
    /// alternative is widening that file's API, and the constant is fixed forever by the
    /// items already sitting in users' keychains. Move both here → there when you next touch
    /// Passwords.swift.

    /// Every credential *Vane* saved for one profile. The creator code is what keeps this
    /// from sweeping up Safari's, `gh`'s or a password manager's items for the same host;
    /// the default profile carries no security domain, so its enumeration additionally drops
    /// anything stamped with another profile's domain — same rule as `Passwords.deleteAll`.
    ///
    /// Returns `PasswordImport.Entry` so the round-trip check compares like with like.
    static func savedPasswords(profileID: UUID = ProfileManager.activeProfileID) -> [PasswordImport.Entry] {
        // Passwords owns the definition of "a credential Vane created"; duplicating its
        // creator code and security-domain rule here would break silently if either moved.
        Passwords.all(profileID: profileID).map {
            PasswordImport.Entry(host: $0.host, account: $0.account, password: $0.password)
        }
    }

    /// Chrome's column names, because that is the header `PasswordImport` matches on and the
    /// one every other password manager also accepts. The url is written with a scheme —
    /// `PasswordImport` copes with a bare host, but 1Password and Bitwarden want the scheme.
    static func passwordsCSV(_ entries: [PasswordImport.Entry]) -> String {
        csv([["name", "url", "username", "password", "note"]] + entries.map {
            [$0.host, "https://" + $0.host, $0.account, $0.password, ""]
        })
    }

    // MARK: Writing

    static func text(for kind: Kind, profileID: UUID = ProfileManager.activeProfileID) -> String {
        switch kind {
        case .bookmarks:   bookmarksHTML(bookmarkRows(profileID: profileID))
        case .historyJSON: historyJSON(historyRows(profileID: profileID))
        case .historyCSV:  historyCSV(historyRows(profileID: profileID))
        case .passwords:   passwordsCSV(savedPasswords(profileID: profileID))
        }
    }

    /// UTF-8 with no BOM: `Data(string.utf8)` never writes one, where
    /// `String.write(to:atomically:encoding:)` is free to. Chrome's bookmark importer chokes
    /// on a BOM before the doctype, so this is not academic.
    static func write(_ text: String, to url: URL, secret: Bool = false) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        // A plaintext credential file has no business being group- or world-readable.
        if secret {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: UI

    private static func defaultName(_ kind: Kind, on day: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // never yyyy-MM-dd in a Buddhist calendar
        f.dateFormat = "yyyy-MM-dd"
        let stamp = f.string(from: day)
        switch kind {
        case .bookmarks:   return "vane-bookmarks-\(stamp).html"
        case .historyJSON: return "vane-history-\(stamp).json"
        case .historyCSV:  return "vane-history-\(stamp).csv"
        case .passwords:   return "vane-passwords-PLAINTEXT-\(stamp).csv"
        }
    }

    private static func contentType(_ kind: Kind) -> UTType {
        switch kind {
        case .bookmarks:   .html
        case .historyJSON: .json
        case .historyCSV, .passwords: .commaSeparatedText
        }
    }

    /// The password export writes every credential in the clear. One button is not enough
    /// friction for that, so the word has to be typed: no muscle-memory Return, no
    /// mis-click, and the alert says the dangerous thing out loud instead of hinting at it.
    private static func confirmPlaintext() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Export every saved password in plain text?"
        alert.informativeText = "The file Vane writes contains your passwords as readable "
            + "text. Anyone who opens it — or any app, backup or sync service that reads the "
            + "folder you save it in — can read all of them.\n\n"
            + "Type EXPORT below if that is what you want."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "EXPORT"
        alert.accessoryView = field
        // Cancel first, so it is the default button and Return does nothing dangerous.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Export Passwords")
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        return field.stringValue.trimmingCharacters(in: .whitespaces).uppercased() == "EXPORT"
    }

    static func chooseAndExport(_ kind: Kind) {
        if kind == .passwords, !confirmPlaintext() { return }

        let panel = NSSavePanel()
        panel.title = "Export"
        panel.nameFieldStringValue = defaultName(kind)
        panel.allowedContentTypes = [contentType(kind)]
        panel.message = kind == .passwords
            ? "This file will contain your passwords in plain text. Delete it when you are done."
            : "Exporting from the profile “\(ProfileManager.shared.active.name)”."
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        do {
            let body = text(for: kind)
            try write(body, to: file, secret: kind == .passwords)
            alert.messageText = "Exported \(count(kind, body)) to \(file.lastPathComponent)."
            alert.informativeText = kind == .passwords
                ? "That file is plain text. Delete it as soon as you have imported it elsewhere."
                : (kind == .bookmarks
                   ? "Chrome, Safari, Firefox and Edge can all import this file."
                   : "")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not write that file."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    /// "3 bookmarks" / "12 history entries" — counted from what was actually written, not
    /// from a second query that could disagree with it.
    private static func count(_ kind: Kind, _ body: String) -> String {
        switch kind {
        case .bookmarks:
            let n = parseNetscape(body).count
            return "\(n) bookmark\(n == 1 ? "" : "s")"
        case .historyJSON, .historyCSV:
            let n = kind == .historyCSV ? parseHistoryCSV(body).count
                : (((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [Any])?.count ?? 0)
            return "\(n) history entr\(n == 1 ? "y" : "ies")"
        case .passwords:
            let n = (try? PasswordImport.parse(body).entries.count) ?? 0
            return "\(n) password\(n == 1 ? "" : "s")"
        }
    }

    // MARK: Offline checks

    /// Pure-logic assertions: escaping, the Netscape structure, RFC 4180 quoting, and the
    /// round trips that are the whole point — a Vane export has to read back through Vane's
    /// own importers. No keychain, no sqlite, no window server; the file-writing half is
    /// covered by writing real files into a temp directory below.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // MARK: escaping

        let nasty = Row(url: "https://example.com/?a=1&b=2&c=\"x\"",
                        title: "Tom & Jerry <script>alert(\"hi\")</script>",
                        at: Date(timeIntervalSince1970: 1_700_000_000))
        let unicode = Row(url: "https://example.com/café",
                          title: "Café — 日本語 — ünïcøde 🎧",
                          at: Date(timeIntervalSince1970: 1_600_000_000))
        let plain = Row(url: "https://apple.com", title: "Apple",
                        at: Date(timeIntervalSince1970: 1_500_000_000))
        let html = bookmarksHTML([nasty, unicode, plain])

        assert("bookmark html: a title's < and > are escaped, not written raw",
               !html.contains("<script>") && html.contains("&lt;script&gt;"))
        assert("bookmark html: a bare & in a title becomes &amp;",
               html.contains("Tom &amp; Jerry"))
        assert("bookmark html: a quote in a title cannot close the attribute",
               html.contains("&quot;hi&quot;"))
        assert("bookmark html: & inside a url is escaped too",
               html.contains("?a=1&amp;b=2") && !html.contains("?a=1&b=2"))
        assert("bookmark html: escaping is not applied twice",
               !html.contains("&amp;amp;") && !html.contains("&amp;lt;"))
        assert("bookmark html: non-ascii titles are written as themselves, not entities",
               html.contains("Café — 日本語 — ünïcøde 🎧"))

        // MARK: netscape structure — what other browsers' importers key off

        let lines = html.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        assert("netscape: the doctype is the first line, byte for byte",
               lines.first == "<!DOCTYPE NETSCAPE-Bookmark-file-1>")
        assert("netscape: the charset meta is present and says UTF-8",
               html.contains("<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">"))
        assert("netscape: there is an <H1> heading before the list",
               html.range(of: "<H1>")! .lowerBound < html.range(of: "<DL><p>")!.lowerBound)
        assert("netscape: the list opens with <DL><p> and closes with </DL><p>",
               html.contains("<DL><p>") && html.hasSuffix("</DL><p>\n"))
        assert("netscape: one <DT><A HREF= entry per bookmark",
               html.components(separatedBy: "<DT><A HREF=").count - 1 == 3)
        assert("netscape: ADD_DATE is whole epoch seconds, not a float or a date string",
               html.contains("ADD_DATE=\"1700000000\"") && !html.contains("ADD_DATE=\"1700000000.0"))
        assert("netscape: the file is valid UTF-8 with no BOM",
               !Data(html.utf8).starts(with: [0xEF, 0xBB, 0xBF]) && !html.hasPrefix("\u{FEFF}"))

        // MARK: bookmark round trip

        let back = parseNetscape(html)
        assert("bookmark round trip: every entry comes back", back.count == 3)
        assert("bookmark round trip: urls survive escaping unchanged",
               back.map(\.url) == [nasty.url, unicode.url, plain.url])
        assert("bookmark round trip: titles survive escaping unchanged",
               back.map(\.title) == [nasty.title, unicode.title, plain.title])
        assert("bookmark round trip: ADD_DATE comes back as the same second",
               back.map { Int($0.at.timeIntervalSince1970) } == [1_700_000_000, 1_600_000_000, 1_500_000_000])
        // The reader is written against the format, not against our writer: Chrome's own
        // export puts extra attributes on the anchor and indents differently.
        let chrome = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1601301295" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://news.ycombinator.com/" ADD_DATE="1601301300" ICON="data:image/png;base64,AA">Hacker &amp; News</A>
            </DL><p>
        </DL><p>
        """
        let fromChrome = parseNetscape(chrome)
        assert("bookmark reader: a real Chrome export parses (folders, ICON, nesting)",
               fromChrome.count == 1 && fromChrome[0].url == "https://news.ycombinator.com/"
                   && fromChrome[0].title == "Hacker & News")

        // MARK: csv quoting

        assert("csv: a plain value is not quoted", field("hello") == "hello")
        assert("csv: a value with a comma is quoted", field("a,b") == "\"a,b\"")
        assert("csv: a quote is doubled inside quotes", field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        assert("csv: a newline forces quoting", field("two\nlines") == "\"two\nlines\"")
        assert("csv: edge whitespace is preserved by quoting", field(" pad ") == "\" pad \"")
        assert("csv: rows are CRLF terminated", csv([["a"], ["b"]]) == "a\r\nb\r\n")

        // MARK: history round trip — export, then read back with the existing reader

        let historyIn = [
            Row(url: "https://example.com/a?x=1,2", title: "Comma, in the title",
                at: Date(timeIntervalSince1970: 1_700_000_000.5)),
            Row(url: "https://example.com/b", title: "He said \"hello\"",
                at: Date(timeIntervalSince1970: 1_699_999_999.25)),
            Row(url: "https://example.com/c", title: "two\nlines",
                at: Date(timeIntervalSince1970: 1_690_000_000)),
            Row(url: "https://example.com/d", title: "",
                at: Date(timeIntervalSince1970: 1_680_000_000)),
            Row(url: "https://example.com/e", title: "Café 日本語 🎧",
                at: Date(timeIntervalSince1970: 1_670_000_000)),
        ]
        let historyText = historyCSV(historyIn)
        let parsed = CSV.rows(historyText)
        assert("history csv: the header is the four documented columns",
               parsed.first == ["url", "title", "visited_at", "epoch"])
        assert("history csv: the existing RFC 4180 reader sees every row",
               parsed.count == historyIn.count + 1)
        assert("history csv: a row with an empty title is not dropped as blank",
               parsed.contains { $0.first == "https://example.com/d" })
        let historyOut = parseHistoryCSV(historyText)
        assert("history csv round trip: same number of rows", historyOut.count == historyIn.count)
        assert("history csv round trip: identical rows, dates included", historyOut == historyIn)
        assert("history csv round trip: the ISO column agrees with the epoch column",
               parsed.dropFirst().allSatisfy {
                   iso.date(from: $0[2])?.timeIntervalSince1970 == (Double($0[3]) ?? -1).rounded(.down)
               })

        let json = (try? JSONSerialization.jsonObject(with: Data(historyJSON(historyIn).utf8))) as? [[String: Any]]
        assert("history json: parses as an array of objects, one per visit",
               json?.count == historyIn.count)
        assert("history json: a title with a quote and a newline survives",
               json?[1]["title"] as? String == "He said \"hello\"" && json?[2]["title"] as? String == "two\nlines")
        assert("history json: the epoch is a number, not a string",
               json?.first?["epoch"] as? Double == 1_700_000_000.5)

        // MARK: password round trip — through the importer that will actually read it

        let credentials = [
            PasswordImport.Entry(host: "github.com", account: "ada", password: "pa,ss\"word"),
            PasswordImport.Entry(host: "bank.example.com", account: "ada@example.com", password: "two\nlines"),
            PasswordImport.Entry(host: "unicode.example", account: "ünïcøde", password: "hünter2 🎧"),
        ]
        let pwText = passwordsCSV(credentials)
        if let round = try? PasswordImport.parse(pwText) {
            assert("password csv round trip: every credential comes back", round.entries.count == 3)
            assert("password csv round trip: nothing was skipped", round.skipped == 0)
            assert("password csv round trip: hosts match",
                   round.entries.map(\.host) == credentials.map(\.host))
            assert("password csv round trip: accounts match",
                   round.entries.map(\.account) == credentials.map(\.account))
            assert("password csv round trip: commas, quotes, newlines and unicode survive",
                   round.entries.map(\.password) == credentials.map(\.password))
        } else {
            assert("password csv round trip: PasswordImport accepts our own export", false)
        }
        assert("password csv: the header is the one PasswordImport matches on",
               pwText.hasPrefix("name,url,username,password,note\r\n"))
        assert("password csv: urls carry a scheme for 1Password and Bitwarden",
               pwText.contains("https://github.com"))

        // MARK: empty collections

        let emptyHTML = bookmarksHTML([])
        assert("empty bookmarks: still a valid, importable Netscape file",
               emptyHTML.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>") && emptyHTML.hasSuffix("</DL><p>\n"))
        assert("empty bookmarks: parses back to nothing, no crash", parseNetscape(emptyHTML).isEmpty)
        assert("empty history csv: header only, and it round-trips to nothing",
               CSV.rows(historyCSV([])).count == 1 && parseHistoryCSV(historyCSV([])).isEmpty)
        assert("empty history json: an empty array, not null or nothing",
               ((try? JSONSerialization.jsonObject(with: Data(historyJSON([]).utf8))) as? [Any])?.isEmpty == true)
        assert("empty passwords: header only, and PasswordImport reads it as zero entries",
               (try? PasswordImport.parse(passwordsCSV([])).entries.count) == 0)
        assert("a truncated file parses to nothing rather than crashing",
               parseNetscape("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n    <DT><A HREF=").isEmpty)

        // MARK: writing real files

        // The one thing the string assertions cannot cover: bytes actually landing on disk,
        // with the encoding and permissions claimed above.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-export-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The stamp is the user's local date, not UTC — a file saved on the evening of the
        // 14th in Istanbul is dated the 14th — so the assertion is on the shape, not on a
        // fixed string that would only pass in one time zone.
        let file = dir.appendingPathComponent(defaultName(.bookmarks, on: Date(timeIntervalSince1970: 1_700_000_000)))
        assert("save panel: the default filename carries the date and the extension",
               file.lastPathComponent.range(of: "^vane-bookmarks-2023-11-1[45]\\.html$",
                                            options: .regularExpression) != nil)
        assert("save panel: the password export's filename says PLAINTEXT out loud",
               defaultName(.passwords).contains("PLAINTEXT") && defaultName(.passwords).hasSuffix(".csv"))
        let wrote = (try? write(html, to: file)) != nil
        let readBack = try? String(contentsOf: file, encoding: .utf8)
        assert("written file: reads back as UTF-8, byte-identical", wrote && readBack == html)
        assert("written file: the bytes on disk start with the doctype, no BOM",
               (try? Data(contentsOf: file))?.starts(with: Array("<!DOCTYPE".utf8)) == true)
        assert("written file: parses back out of the file itself",
               parseNetscape(readBack ?? "").count == 3)

        let secret = dir.appendingPathComponent("passwords.csv")
        let wroteSecret = (try? write(pwText, to: secret, secret: true)) != nil
        let mode = (try? FileManager.default.attributesOfItem(atPath: secret.path))?[.posixPermissions] as? NSNumber
        assert("written file: a password export is owner-read/write only (0600)",
               wroteSecret && mode?.int16Value == 0o600)

        return out
    }
}
