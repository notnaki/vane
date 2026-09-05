import Foundation
import WebKit

/// Arc's "Tidy Downloads": `887494876.pdf` lands in ~/Downloads and a moment later becomes
/// `Navan Itinerary.pdf`, with an undo.
///
/// The whole design falls out of one number: the on-device model takes 3–10 seconds, and a
/// download that waits for it is a download that hangs. So nothing here is in the download's
/// path. WebKit saves the file under the name the server sent, `downloadDidFinish` runs, and
/// only then is the file **renamed on disk**. That is also what Arc does — the toast says
/// "Download renamed to: …" *after* the fact, with an arrow to put it back.
///
/// ponytail: rename-after-the-fact means a user who double-clicks the row inside those few
/// seconds opens a file that is about to change name underneath them. Arc has the same race.
/// The alternative is blocking every download on a language model, which is worse.
@MainActor enum TidyDownloads {

    // MARK: - The switch

    /// **Default OFF.** Renaming files a user did not ask us to touch is not a default: the
    /// name a server sent is at least the name the user saw in the download bar, and a
    /// browser silently rewriting filenames in ~/Downloads is a support ticket, not a
    /// feature. Arc ships this one off too. `AppleAI.enabled` defaults on because it only
    /// ever *adds* text to a UI; this one edits the filesystem, so it asks first.
    static var enabled: Bool {
        get { UserDefaults.vane.bool(forKey: "tidyDownloads") }   // absent == false
        set { UserDefaults.vane.set(newValue, forKey: "tidyDownloads") }
    }

    // MARK: - Naming, the deterministic half
    //
    // Most junk filenames need no model at all, and a model call costs seconds. So: a pure
    // classifier decides whether the server's name is junk, and a pure builder makes a
    // better one out of the page title or the URL. The model is the fallback, not the plan.

    /// Splits a server-suggested name into the part we may rewrite and the part we may not.
    ///
    /// `suffix` is the extension taken **verbatim** — not sanitised, not chosen, not
    /// re-derived. It is what decides how the file opens, so the only safe thing to do with
    /// it is put back exactly what was already there. A query string is cut off first,
    /// because `download.php?id=887494876` is a filename a real CDN will hand you.
    static func parts(of suggested: String) -> (stem: String, suffix: String) {
        var name = suggested
        if let cut = name.firstIndex(where: { $0 == "?" || $0 == "#" }) { name = String(name[..<cut]) }
        name = (name as NSString).lastPathComponent
        return ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
    }

    /// Names that mean "the server had nothing to say". `AppleAI.isOpaque` already covers
    /// all-digits, no-vowels, hex blobs and the common placeholders; this is the extra
    /// vocabulary a browser sees that a filename generator does not.
    private static let placeholders: Set<String> = [
        "download", "downloads", "downloadfile", "getfile", "get", "file", "files",
        "attachment", "attachments", "document", "doc", "untitled", "unnamed", "unknown",
        "index", "tmp", "temp", "output", "out", "data", "export", "blob", "content",
        "view", "open", "viewer", "print", "generatepdf", "report",
    ]

    /// "download (1)", "invoice copy 2", "file-1" — the same opaque name wearing Finder's
    /// duplicate suffix. Stripped before classifying, never before naming: if we do rename,
    /// `Downloads.uniqueDestination` puts a fresh " 2" on for us.
    private static func withoutDuplicateMarker(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        // " (1)", " copy", " copy 3"
        while let r = t.range(of: #"[ _-]*(\(\d{1,3}\)|copy( \d{1,3})?)$"#,
                             options: [.regularExpression, .caseInsensitive]), !r.isEmpty {
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // A bare trailing counter, but only when there is a word in front of it, so that
        // "887494876" is still all-digits and "v2" is still a version.
        if let r = t.range(of: #"[ _-]\d{1,3}$"#, options: .regularExpression),
           t[..<r.lowerBound].contains(where: \.isLetter) {
            t = String(t[..<r.lowerBound])
        }
        return t
    }

    /// A cache-buster or content hash bolted onto an otherwise fine name:
    /// `quarterly-report-8f3a1c2e9b4d.pdf`. Twelve characters is the floor deliberately —
    /// eight would eat `statement-20260901`, and losing a date is worse than keeping a hash.
    private static func withoutTrailingHash(_ s: String) -> String {
        guard let r = s.range(of: #"[ _.-][0-9a-fA-F]{12,}$"#, options: .regularExpression),
              s[..<r.lowerBound].contains(where: \.isLetter) else { return s }
        return String(s[..<r.lowerBound])
    }

    /// Is this stem junk — worth replacing — or does it already read like something a person
    /// wrote? The centre of the whole feature: a false "junk" renames a file the user named,
    /// which is the only way this feature can actually hurt someone.
    static func isJunk(_ stem: String) -> Bool {
        let s = withoutDuplicateMarker(stem.trimmingCharacters(in: .whitespaces))
        if s.isEmpty { return true }
        if placeholders.contains(s.lowercased()) { return true }
        // Query-string leftovers: "id=887494876", "attachment;filename".
        if s.contains("=") || s.contains(";") || s.contains("&") { return true }
        // Everything else — all digits, vowel-less, uuid, sha1, "untitled" — AppleAI already
        // decides, and two files disagreeing about what "opaque" means would be a bug.
        return AppleAI.isOpaque(s)
    }

    /// `%20` and friends. A server that sends `Navan%20Itinerary.pdf` has given us a perfectly
    /// good name wearing a URL costume.
    private static func decoded(_ s: String) -> String { s.removingPercentEncoding ?? s }

    /// "quarterly_report-v2" → "Quarterly Report-v2". Only for names we build out of URL path
    /// components; a name the user can already read is never re-cased.
    private static func humanised(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "+" || $0.isWhitespace })
            .map { w -> String in
                // Uppercase only an all-lowercase word, so "iPhone" and "macOS" survive.
                w.allSatisfy { !$0.isUppercase } ? w.prefix(1).uppercased() + w.dropFirst() : String(w)
            }
            .joined(separator: " ")
    }

    /// The page title, minus the site name. "Navan Itinerary | Navan" → "Navan Itinerary".
    /// ponytail: " - " is deliberately *not* a separator here. Half the titles on the web use
    /// it as punctuation ("Trip - Itinerary") and cutting there loses the informative half.
    private static func fromTitle(_ title: String?) -> String? {
        guard var t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for sep in [" | ", " · ", " — ", " – ", " :: "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]); break }
        }
        t = t.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        guard t.count >= 3, !isJunk(t) else { return nil }
        return t
    }

    /// The last path component that says something: `/trips/itinerary/887494876.pdf` →
    /// "Itinerary". Walks backwards, skipping the junk component we are trying to replace.
    private static func fromURL(_ url: URL) -> String? {
        for raw in url.pathComponents.reversed() where raw != "/" {
            let stem = decoded((raw as NSString).deletingPathExtension)
            guard stem.count >= 3, !isJunk(stem) else { continue }
            return humanised(stem)
        }
        return nil
    }

    /// The whole deterministic path. Returns a complete filename, or nil meaning either
    /// "this name is already fine" or "I have nothing better" — the caller tells them apart
    /// by whether the stem was junk.
    ///
    /// Pure. No filesystem, no model, no clock. This is the function the tests are about.
    static func clean(suggested: String, pageTitle: String?, sourceURL: URL?) -> String? {
        let (stem, suffix) = parts(of: suggested)
        let tidied = withoutTrailingHash(decoded(stem))

        if !isJunk(tidied) {
            // Already descriptive. Leave it exactly as the server sent it — unless decoding
            // or a stripped cache-buster genuinely improved it.
            guard tidied != stem else { return nil }
            return safeName(stem: tidied, extension: suffix)
        }
        guard let better = fromTitle(pageTitle) ?? sourceURL.flatMap(fromURL),
              let out = safeName(stem: better, extension: suffix),
              // The page title can perfectly well be the name the server already sent.
              out.compare(suggested, options: .caseInsensitive) != .orderedSame else { return nil }
        return out
    }

    /// A better filename, or nil to keep what the server sent.
    ///
    /// Deterministic first because it is instant and handles the common shapes; the model
    /// only sees the leftovers — a junk name on a page with no usable title and no usable
    /// URL. Its answer is re-validated here rather than trusted, because it has just read a
    /// page that wanted it to say something else.
    static func suggest(suggested: String, pageTitle: String?, sourceURL: URL) async -> String? {
        if let deterministic = clean(suggested: suggested, pageTitle: pageTitle, sourceURL: sourceURL) {
            return deterministic
        }
        let (stem, suffix) = parts(of: suggested)
        guard isJunk(withoutTrailingHash(decoded(stem))) else { return nil }  // fine as-is: do not spend 8s
        guard let answer = await AppleAI.filename(for: suggested, pageTitle: pageTitle,
                                                  sourceURL: sourceURL) else { return nil }
        // AppleAI.safeFilename already ran. It is not the thing to rely on: it re-derives the
        // extension from a string *it* was handed, and it allows an interior dot. Take only
        // the stem out of its answer and put our own extension back.
        let model = (answer as NSString).deletingPathExtension
        // Measured: given only a url the 3B model answers "download" for "download" and
        // "attachment" for "attachment.pdf". Junk in, junk out — and a rename to the name it
        // already had is a toast the user gets nothing from.
        guard !isJunk(model), let out = safeName(stem: model, extension: suffix),
              out.compare(suggested, options: .caseInsensitive) != .orderedSame else { return nil }
        return out
    }

    // MARK: - Safety
    //
    // Every name below came, eventually, from a web page: a <title>, a URL path, or a model
    // that just read both. So it is attacker-influenced text on its way to a filesystem call.
    // This function is the only door, and it is deliberately blunt.

    /// Longest name we will write. APFS allows 255 UTF-8 bytes for one component; the slack
    /// is for `Downloads.uniqueDestination` appending " 12".
    static let nameLimit = 200

    /// Turns page-controlled text into a filename, or nil if nothing safe is left.
    ///
    /// Guarantees, each of which is asserted in `check()`:
    /// * no path separator (`/`, `\`, `:`) and no NUL — cannot escape the directory,
    /// * no `.` **anywhere** in the stem — so no leading dot (hidden file), no `..`
    ///   (traversal), and no second extension: a page cannot turn `invoice.pdf` into
    ///   `invoice.pdf.command`, because the only dot in the result is the one we put back,
    /// * the extension is the caller's, verbatim, so how the file opens never changes,
    /// * bounded in *bytes*, not characters, because that is what the filesystem counts,
    /// * never empty, never a bare "." or "..", never starting with "-".
    static func safeName(stem: String, extension suffix: String) -> String? {
        // Control characters, zero-width joiners and the model's fence markers.
        var s = AppleAI.sanitize(stem)
        for bad in ["/", "\\", ":", "\u{0}"] { s = s.replacingOccurrences(of: bad, with: " ") }
        s = s.replacingOccurrences(of: ".", with: " ")
        s = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let edges = CharacterSet(charactersIn: " -_")
        s = s.trimmingCharacters(in: edges)
        guard !s.isEmpty else { return nil }

        // An "extension" this long is not an extension, it is the name. Refuse rather than
        // guess, which leaves the file alone.
        guard suffix.count <= 24 else { return nil }
        let ext = suffix.isEmpty ? "" : "." + suffix
        let budget = nameLimit - ext.utf8.count
        guard budget > 0 else { return nil }
        while s.utf8.count > budget { s.removeLast() }
        s = s.trimmingCharacters(in: edges)
        guard !s.isEmpty else { return nil }
        return s + ext
    }

    // MARK: - Renaming on disk

    /// Where a file was before we touched it, keyed by the row that owns it.
    ///
    /// ponytail: in memory only. Undo is the toast's arrow, a thing you press within seconds;
    /// persisting it would mean a second JSON file and a stale-path problem for an affordance
    /// nobody uses on Tuesday for a file renamed on Monday.
    private static var undoLog: [UUID: (now: URL, was: URL)] = [:]

    /// Page titles, parked between "this navigation became a download" (the only place the
    /// title exists) and the download finishing.
    private static var pageTitles: [ObjectIdentifier: String] = [:]
    private static var itemTitles: [UUID: String] = [:]

    static func canUndo(_ item: Downloads.Item) -> Bool {
        guard let log = undoLog[item.id] else { return false }
        return item.url == log.now && FileManager.default.fileExists(atPath: log.now.path)
    }

    /// Rename the finished file. Returns false — and changes nothing — whenever it is not
    /// obviously safe: the file moved, the file is gone, there is no better name, or the
    /// better name is the one it already has.
    ///
    /// `downloads` only exists so the index is written immediately. Nil is fine; the row is
    /// still correct in memory and `Downloads` saves on its next state change. `pageTitle` is
    /// the seam a caller with a title in hand uses; the automatic path leaves it nil and the
    /// title comes from whatever `remember` parked.
    @discardableResult
    static func rename(_ item: Downloads.Item, pageTitle: String? = nil,
                       in downloads: Downloads? = nil) async -> Bool {
        guard let from = item.url, FileManager.default.fileExists(atPath: from.path) else { return false }
        let title = pageTitle ?? itemTitles.removeValue(forKey: item.id)
        // Deliberately the name **on disk**, not the name the server suggested: between the
        // two, Downloads may already have uniquified it, and the file we are about to move is
        // the truth.
        guard let better = await suggest(suggested: from.lastPathComponent, pageTitle: title,
                                         sourceURL: item.source ?? from) else { return false }
        return apply(better, to: item, in: downloads)
    }

    /// The disk half, synchronous, so the checks below can prove it without a model.
    ///
    /// Re-reads the filesystem rather than trusting anything from before the await: the model
    /// took up to ten seconds, and the user may have moved, renamed or deleted the file in
    /// them. A rename that cannot find its own file is a no-op, not an error.
    @discardableResult
    static func apply(_ newName: String, to item: Downloads.Item, in downloads: Downloads? = nil) -> Bool {
        let fm = FileManager.default
        guard let from = item.url, fm.fileExists(atPath: from.path) else { return false }
        let current = from.lastPathComponent
        // Case-insensitively equal means the volume considers them the same file; moving is
        // either a no-op or a self-collision, and neither is worth doing.
        guard newName.compare(current, options: .caseInsensitive) != .orderedSame else { return false }
        // Belt and braces: whatever produced newName, it does not get to be a path.
        guard let safe = safeName(stem: (newName as NSString).deletingPathExtension,
                                  extension: (newName as NSString).pathExtension),
              safe == newName else { return false }

        let to = Downloads.uniqueDestination(in: from.deletingLastPathComponent(), suggested: safe)
        guard (try? fm.moveItem(at: from, to: to)) != nil else { return false }
        undoLog[item.id] = (now: to, was: from)
        item.url = to
        item.name = to.lastPathComponent
        downloads?.save()
        return true
    }

    /// Put it back. Same never-overwrite policy as everything else: if something has taken
    /// the old name in the meantime, the file comes back as "report 2.pdf" rather than
    /// landing on top of a stranger.
    @discardableResult
    static func undo(_ item: Downloads.Item, in downloads: Downloads? = nil) -> Bool {
        let fm = FileManager.default
        guard let log = undoLog[item.id], item.url == log.now,
              fm.fileExists(atPath: log.now.path) else { return false }
        let back = Downloads.uniqueDestination(in: log.was.deletingLastPathComponent(),
                                               suggested: log.was.lastPathComponent)
        guard (try? fm.moveItem(at: log.now, to: back)) != nil else { return false }
        undoLog[item.id] = nil
        item.url = back
        item.name = back.lastPathComponent
        downloads?.save()
        return true
    }

    // MARK: - Wiring seams
    //
    // Two calls, in two files I do not own. See the report.

    /// Engine, in both `didBecome download:` methods. The page title only exists on the
    /// WKWebView that started the download, and only at that moment.
    static func remember(_ download: WKDownload, pageTitle: String?) {
        guard enabled, let t = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return }
        // A download that never finishes never collects its title. Rather than a reaper, an
        // occasional forget: the cost of losing one is a nil we already handle everywhere.
        if pageTitles.count > 32 { pageTitles.removeAll() }
        pageTitles[ObjectIdentifier(download)] = t
    }

    /// Downloads, as the **first** line of `downloadDidFinish` — before `unwatch()`, which is
    /// what makes `item.download` nil and loses the key the title is filed under.
    ///
    /// Fire and forget. The Task runs after the current synchronous body, so by the time the
    /// rename happens the row is already `.done`, already sized, already saved.
    static func tidy(_ download: WKDownload, in downloads: Downloads) {
        guard enabled,
              let item = downloads.items.first(where: { $0.download === download }) else { return }
        if let t = pageTitles.removeValue(forKey: ObjectIdentifier(download)) {
            if itemTitles.count > 32 { itemTitles.removeAll() }
            itemTitles[item.id] = t
        }
        Task { @MainActor in
            guard await rename(item, in: downloads) else { return }
            // The toast's arrow, as promised above `undoLog`: the only way back, and only now.
            Toasts.show("Renamed to \(item.name)",
                        action: ("Undo", { [weak downloads] in undo(item, in: downloads) }))
        }
    }

    // MARK: - Offline check

    /// Everything here is pure or runs against a throwaway temp directory. Nothing reaches
    /// the model, the network, or the real ~/Downloads.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let navan = URL(string: "https://app.navan.com/trips/itinerary/887494876.pdf")!
        let bare = URL(string: "https://cdn.example.com/d/887494876.pdf")!
        let title = "Navan Itinerary | Navan"

        // --- The classifier: junk on the left, names a person wrote on the right ---
        assert("a name that is nothing but digits is junk", isJunk("887494876"))
        assert("a uuid is junk", isJunk("550e8400-e29b-41d4-a716-446655440000"))
        assert("a sha1 is junk", isJunk("da39a3ee5e6b4b0d3255bfef95601890afd80709"))
        assert("a short hex blob is junk", isJunk("8f3a1c2e9b"))
        assert("the word download is junk", isJunk("download") && isJunk("Download"))
        assert("Finder's duplicate suffix does not rescue a junk name",
               isJunk("download (1)") && isJunk("download-2") && isJunk("file copy"))
        assert("an empty stem is junk", isJunk("") && isJunk("   "))
        assert("a query-string leftover is junk", isJunk("id=887494876") && isJunk("attachment;filename"))
        assert("a vowel-less blob is junk", isJunk("xkcdzzbmp"))
        assert("a timestamp is junk", isJunk("1698765432"))
        assert("report-final-v2 is a name a person wrote", !isJunk("report-final-v2"))
        assert("Quarterly Report 2026 is a name a person wrote", !isJunk("Quarterly Report 2026"))
        assert("a double extension is not junk on account of its dots", !isJunk("archive.tar"))
        assert("a decoded name is judged decoded, not encoded",
               !isJunk(decoded("Navan%20Itinerary")))
        assert("a name with no extension can still be descriptive", !isJunk("release notes"))
        assert("invoice-2026 keeps its year rather than reading as a counter", !isJunk("invoice-2026"))

        // --- What clean() does with each ---
        assert("a junk name takes the page title",
               clean(suggested: "887494876.pdf", pageTitle: title, sourceURL: navan) == "Navan Itinerary.pdf")
        assert("the site name is dropped from the page title",
               clean(suggested: "887494876.pdf", pageTitle: "Navan Itinerary | Navan", sourceURL: navan)
                   == clean(suggested: "887494876.pdf", pageTitle: "Navan Itinerary", sourceURL: navan))
        assert("with no title the url's last meaningful component is used",
               clean(suggested: "887494876.pdf", pageTitle: nil, sourceURL: navan) == "Itinerary.pdf")
        assert("with neither a title nor a usable url there is nothing deterministic to say",
               clean(suggested: "887494876.pdf", pageTitle: nil, sourceURL: bare) == nil)
        assert("a descriptive name is left completely alone",
               clean(suggested: "report-final-v2.docx", pageTitle: title, sourceURL: navan) == nil)
        assert("a double extension is left completely alone",
               clean(suggested: "archive.tar.gz", pageTitle: title, sourceURL: navan) == nil)
        assert("a percent-encoded name is decoded, not replaced",
               clean(suggested: "Navan%20Itinerary.pdf", pageTitle: "Something Else", sourceURL: navan)
                   == "Navan Itinerary.pdf")
        assert("a cache-buster is stripped off an otherwise fine name",
               clean(suggested: "quarterly-report-8f3a1c2e9b4d.pdf", pageTitle: title, sourceURL: navan)
                   == "quarterly-report.pdf")
        assert("a junk name with no extension stays without one",
               clean(suggested: "887494876", pageTitle: title, sourceURL: navan) == "Navan Itinerary")
        assert("a query string on the suggested name is cut before naming",
               clean(suggested: "download.php?id=887494876", pageTitle: title, sourceURL: navan)
                   == "Navan Itinerary.php")
        assert("a title that is itself junk is refused, and the url used instead",
               clean(suggested: "887494876.pdf", pageTitle: "404", sourceURL: navan) == "Itinerary.pdf")
        assert("a title that is already the name the server sent is not a rename",
               clean(suggested: "Itinerary.pdf", pageTitle: "Itinerary", sourceURL: navan) == nil)
        assert("url components are humanised without re-casing real words",
               clean(suggested: "download.pdf", pageTitle: nil,
                     sourceURL: URL(string: "https://x.test/docs/iPhone_setup_guide/download.pdf")!)
                   == "iPhone Setup Guide.pdf")

        // --- The extension is never ours to choose ---
        assert("the server's extension is preserved exactly",
               safeName(stem: "Navan Itinerary", extension: "pdf") == "Navan Itinerary.pdf")
        assert("an extensionless download stays extensionless",
               safeName(stem: "Navan Itinerary", extension: "") == "Navan Itinerary")
        assert("the extension is not laundered into a tidier one",
               safeName(stem: "notes", extension: "PDF") == "notes.PDF")
        assert("something absurd in the extension slot is refused, not written",
               safeName(stem: "notes", extension: String(repeating: "x", count: 40)) == nil)

        // --- Dangerous names. A page wrote every one of these. ---
        let traversal = safeName(stem: "../../etc/passwd", extension: "pdf")
        let appBundle = safeName(stem: "invoice.pdf", extension: "pdf")
        let command = safeName(stem: "payload.command", extension: "txt")
        let long = safeName(stem: String(repeating: "é", count: 400), extension: "pdf")
        let emoji = safeName(stem: String(repeating: "🙂", count: 200), extension: "pdf")

        assert("a path separator cannot survive",
               traversal != nil && !traversal!.contains("/") && !traversal!.contains("\\")
                   && !traversal!.contains(":"))
        assert("traversal cannot survive", traversal != nil && !traversal!.contains(".."))
        assert("a windows separator and a colon cannot survive",
               safeName(stem: "a\\b:c", extension: "txt") == "a b c.txt")
        assert("a leading dot cannot make a hidden file",
               safeName(stem: ".hidden", extension: "txt") == "hidden.txt")
        assert("a bare dot or double dot is refused outright",
               safeName(stem: ".", extension: "") == nil && safeName(stem: "..", extension: "") == nil)
        assert("a page cannot append a second extension",
               appBundle == "invoice pdf.pdf")
        assert("a page cannot turn a text file into a .command",
               command == "payload command.txt" && !command!.hasSuffix(".command"))
        assert("a page cannot turn a pdf into an .app",
               safeName(stem: "invoice.pdf", extension: "app")?
                   .components(separatedBy: ".").count == 2)
        assert("exactly one dot ever reaches the filesystem",
               safeName(stem: "a.b.c.d", extension: "zip")!.filter { $0 == "." }.count == 1)
        assert("a leading dash cannot make the name look like a flag",
               safeName(stem: "--force", extension: "txt") == "force.txt")
        assert("a NUL cannot survive", !(safeName(stem: "a\u{0}b", extension: "txt")?.contains("\u{0}") ?? true))
        assert("control and zero-width characters cannot survive",
               safeName(stem: "in\u{200B}voi\u{7}ce", extension: "txt") == "invoice.txt")
        assert("a newline collapses instead of splitting the name",
               safeName(stem: "two\nlines", extension: "zip") == "two lines.zip")
        assert("the name is bounded in bytes, not characters",
               long != nil && long!.utf8.count <= nameLimit
                   && emoji != nil && emoji!.utf8.count <= nameLimit)
        assert("truncation never leaves a broken scalar",
               emoji != nil && String(emoji!.dropLast(4)).allSatisfy { $0 == "🙂" })
        assert("an empty or all-punctuation name is refused, never written",
               safeName(stem: "   ", extension: "pdf") == nil
                   && safeName(stem: "...", extension: "pdf") == nil
                   && safeName(stem: "-_-", extension: "pdf") == nil)
        assert("nothing safeName produces starts with a dot or a dash",
               [traversal, appBundle, command, long, emoji].allSatisfy {
                   guard let n = $0 else { return false }
                   return !n.hasPrefix(".") && !n.hasPrefix("-")
               })
        // The end-to-end version of the same claim: a hostile <title> reaching disk.
        let hostileTitle = clean(suggested: "887494876.pdf",
                                 pageTitle: "../../../../Library/LaunchAgents/evil.command",
                                 sourceURL: navan)
        assert("a hostile page title still yields one harmless component",
               hostileTitle != nil && !hostileTitle!.contains("/")
                   && hostileTitle!.hasSuffix(".pdf")
                   && hostileTitle!.filter { $0 == "." }.count == 1)

        // --- On disk: collisions, undo, and files that are not there ---
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-tidy-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("dl", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let downloads = Downloads(profileID: ProfileManager.defaultID, directory: root, sandboxed: true)
        func row(_ name: String, _ body: String) -> Downloads.Item {
            let at = dir.appendingPathComponent(name)
            try? Data(body.utf8).write(to: at)
            return downloads.add(Downloads.Record(name: name, destination: at, source: navan,
                                                  state: "done", completed: .now))
        }

        let first = row("887494876.pdf", "itinerary")
        assert("a rename moves the file and updates the row",
               apply("Navan Itinerary.pdf", to: first, in: downloads)
                   && first.url?.lastPathComponent == "Navan Itinerary.pdf"
                   && first.name == "Navan Itinerary.pdf")
        assert("the old name is gone from disk",
               !fm.fileExists(atPath: dir.appendingPathComponent("887494876.pdf").path))
        assert("the bytes are the same bytes",
               (try? String(contentsOf: first.url!, encoding: .utf8)) == "itinerary")

        // A second download of the same thing must not land on the first.
        let second = row("887494877.pdf", "second itinerary")
        assert("a colliding rename uniquifies instead of overwriting",
               apply("Navan Itinerary.pdf", to: second, in: downloads)
                   && second.url?.lastPathComponent == "Navan Itinerary 2.pdf")
        assert("the file that was already there is untouched",
               (try? String(contentsOf: first.url!, encoding: .utf8)) == "itinerary")

        // Undo.
        assert("undo is offered after a rename", canUndo(first))
        assert("undo puts the name back",
               undo(first, in: downloads) && first.url?.lastPathComponent == "887494876.pdf"
                   && first.name == "887494876.pdf")
        assert("undo keeps the bytes",
               (try? String(contentsOf: first.url!, encoding: .utf8)) == "itinerary")
        assert("undo is offered exactly once", !canUndo(first) && !undo(first, in: downloads))
        assert("the renamed name is free again after an undo",
               !fm.fileExists(atPath: dir.appendingPathComponent("Navan Itinerary.pdf").path))
        assert("undo survives someone else taking the old name",
               { let x = row("taken.pdf", "x")
                 guard apply("taken-renamed.pdf", to: x, in: downloads) else { return false }
                 try? Data("squatter".utf8).write(to: dir.appendingPathComponent("taken.pdf"))
                 guard undo(x, in: downloads) else { return false }
                 return x.url?.lastPathComponent == "taken 2.pdf"
                     && (try? String(contentsOf: dir.appendingPathComponent("taken.pdf"),
                                     encoding: .utf8)) == "squatter" }())

        // Files that are not where the row says they are.
        let moved = row("moved.pdf", "m")
        try? fm.removeItem(at: moved.url!)
        assert("a rename is a no-op when the file has gone",
               !apply("Better Name.pdf", to: moved, in: downloads)
                   && moved.name == "moved.pdf")
        let ghost = downloads.add(Downloads.Record(name: "ghost.pdf", destination: nil, state: "done"))
        assert("a row with no destination is a no-op", !apply("x.pdf", to: ghost, in: downloads))
        let same = row("Keep This.pdf", "k")
        assert("renaming to the name it already has does nothing",
               !apply("Keep This.pdf", to: same, in: downloads)
                   && !apply("keep this.pdf", to: same, in: downloads))
        assert("apply refuses a name that is not already safe",
               !apply("../escape.pdf", to: same, in: downloads)
                   && !apply(".hidden.pdf", to: same, in: downloads)
                   && same.name == "Keep This.pdf")
        assert("a refused rename leaves nothing to undo", !canUndo(same))

        // --- The switch ---
        let stored = UserDefaults.vane.object(forKey: "tidyDownloads")
        defer { UserDefaults.vane.set(stored, forKey: "tidyDownloads") }
        UserDefaults.vane.removeObject(forKey: "tidyDownloads")
        let byDefault = enabled
        enabled = true
        let on = enabled
        enabled = false
        assert("tidying is off until asked for", byDefault == false)
        assert("the switch round-trips", on == true && enabled == false)

        return out
    }
}
