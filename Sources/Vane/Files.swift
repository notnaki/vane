import AppKit
import UniformTypeIdentifiers
import WebKit

/// Local files as pages: Finder ▸ Open With ▸ Vane, and files dropped onto a window.
///
/// A browser is the right app for a PDF, an .html file and the handful of image formats the
/// web already renders — WebKit draws all of them with no code of ours. What was missing was
/// everything around the load: the Info.plist claim that makes Vane appear in Open With, a
/// load that survives the sandbox, and a strip row that says the file's name rather than
/// "New Tab" with no icon.
///
/// ponytail: one filter and a handful of tiny helpers, no document architecture. Vane opens
/// files, it does not own them — nothing here saves, watches or reopens anything, and a tab
/// holding a file is an ordinary tab in every other respect.
/// Ceiling: no "Open in Preview" yet. `Files.opens` is the list it would hang off, and the
/// url is right there on the tab, so it is a menu item away.
///
/// Where a file may be dropped is deliberately narrow: the sidebar, and the page card only
/// while it is empty. The page itself is the web app's — dragging a screenshot into Gmail or
/// GitHub has to keep working, and a view over the page that took every file would break
/// upload-by-drag everywhere, in both directions (AppKit does not re-offer a drag it has been
/// refused, so a .zip would reach nobody at all).
/// ponytail ceiling: a Little Vane has no sidebar, so once it is showing a page there is
/// nowhere in it to drop a file. Open With, ⌘O and a drop on the window it came out of all
/// still work. Upgrade path is `_WKUIDelegatePrivate`'s drag-destination action mask, which
/// is how Safari asks the page first.
@MainActor enum Files {

    /// What Vane will open from disk. The same list make-app.sh declares as
    /// `CFBundleDocumentTypes`, and the reason it is short: every one of these is something
    /// WebKit already renders, so claiming it costs nothing and claiming anything else would
    /// be a lie told to Launch Services.
    /// `public.xhtml` has no `UTType` constant, hence the one literal.
    nonisolated static let types: [UTType] = [.pdf, .html, .png, .jpeg, .gif, .svg, .webP]
        + [UTType("public.xhtml")].compactMap { $0 }

    /// The files out of a drop worth opening, in the order they were dropped.
    ///
    /// Decided from the *name*, which is what makes it assertable: every browser-openable
    /// type is declared by extension anyway. A folder is refused — Vane has nowhere to put
    /// one — and so is anything whose extension is not one of `types`.
    ///
    /// `hasDirectoryPath` is lexical (it is asking about a trailing slash), so a folder or a
    /// package dropped without one would pass it; `isDirectoryKey` is the file system's own
    /// answer and is asked second, only for a url that got that far. A url with no file
    /// behind it answers nothing, and is kept — the extension test already vouched for it.
    nonisolated static func opens(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL, !url.hasDirectoryPath,
                  let type = UTType(filenameExtension: url.pathExtension),
                  types.contains(where: { type.conforms(to: $0) })
            else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
    }

    /// The same, for a SwiftUI drop: `NSItemProvider` only ever answers asynchronously, so
    /// every drop that wants a file has to come back for it.
    /// ponytail: one provider at a time rather than a barrier over the batch — each file is
    /// its own tab, so the only thing a barrier would buy is the order of a multi-file drop.
    static func openDropped(_ providers: [NSItemProvider], in store: TabStore) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in Files.open([url], in: store) }
            }
        }
    }

    /// Open dropped or Finder-handed files in this window. A Little Vane is one page, so the
    /// file lands in the page that is there — the same thing a link clicked inside one does.
    static func open(_ urls: [URL], in store: TabStore) {
        let files = opens(urls)
        guard !files.isEmpty else { return }
        if store.isLittle {
            // A Little Vane opened empty (⌥⌘N) has no page yet; one dropped on it is its page.
            (store.active ?? store.newBlankTab()).go(files[0])
            // `isPrivate` passed, never defaulted: a Little Vane floated off a Private Window
            // would otherwise quietly take the persistent store and write the file into
            // history — the one thing that window exists not to do. See `LittleArc.open`.
            files.dropFirst().forEach { LittleArc.open($0, isPrivate: store.isPrivate) }
        } else {
            for url in files { store.newBlankTab().go(url) }
        }
        axAnnounce(files.count == 1
                   ? "Opened \(files[0].lastPathComponent)."
                   : "Opened \(files.count) files.")
    }

    /// Finder's own icon for the document. A local file has no favicon and no host to fetch
    /// one from, and the icon Finder draws is what the file is recognised by everywhere else
    /// on the Mac. `FileIcons` is the Downloads list's cache — `icon(forFile:)` reads the
    /// file, and a strip row asks for its icon on every render.
    static func icon(for url: URL) -> NSImage {
        FileIcons.icon(path: url.path, name: url.lastPathComponent)
    }

    /// What the strip calls a page. A PDF has no `<title>` for WebKit to report, so a file
    /// opened from Finder would sit there as "New Tab": the name Finder gave it is the one
    /// the user went looking for.
    nonisolated static func title(page: String?, url: URL?) -> String {
        if let page, !page.isEmpty { return page }
        if let url, url.isFileURL { return url.lastPathComponent }
        return "New Tab"
    }

    /// What the address pill says: a local file's own name, or the host with `www.` dropped
    /// the way Arc shows it — the scheme is noise the user has never needed to read. Nil
    /// when there is no page, which is the pill's "Search or Enter URL".
    nonisolated static func pillLabel(_ url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - check

    nonisolated static func check() -> [(String, Bool)] {
        let pdf = URL(fileURLWithPath: "/tmp/report.pdf")
        let folder = URL(fileURLWithPath: "/tmp/papers", isDirectory: true)
        let zip = URL(fileURLWithPath: "/tmp/archive.zip")
        let page = URL(fileURLWithPath: "/tmp/index.html")
        let shot = URL(fileURLWithPath: "/tmp/shot.PNG")
        let remote = URL(string: "https://example.com/a.pdf")!
        return [
            ("a pdf is opened", opens([pdf]) == [pdf]),
            ("html, png, jpeg, gif, svg and webp are opened",
             opens(["a.html", "b.png", "c.jpeg", "d.gif", "e.svg", "f.webp"]
                .map { URL(fileURLWithPath: "/tmp/\($0)") }).count == 6),
            ("a folder is refused", opens([folder]).isEmpty),
            ("an unsupported type is refused", opens([zip]).isEmpty),
            ("an extensionless file is refused", opens([URL(fileURLWithPath: "/tmp/README")]).isEmpty),
            ("an http url is refused — this is the *file* filter", opens([remote]).isEmpty),
            ("the extension is matched case-insensitively", opens([shot]) == [shot]),
            ("a mixed drop keeps only the openable files, in order",
             opens([zip, pdf, folder, page]) == [pdf, page]),
            ("an empty drop opens nothing", opens([]).isEmpty),

            ("a page's own title wins", title(page: "Hello", url: pdf) == "Hello"),
            ("a file with no page title falls back to its name",
             title(page: "", url: pdf) == "report.pdf"),
            ("a titleless remote page is still New Tab",
             title(page: nil, url: remote) == "New Tab"),
            ("no page at all is New Tab", title(page: nil, url: nil) == "New Tab"),

            ("the pill shows a file by name", pillLabel(pdf) == "report.pdf"),
            ("the pill shows a site by host", pillLabel(remote) == "example.com"),
            ("the pill drops www.",
             pillLabel(URL(string: "https://www.example.com/a")!) == "example.com"),
            ("the pill keeps a host that merely starts with www",
             pillLabel(URL(string: "https://wwwx.example.com")!) == "wwwx.example.com"),
            ("the pill has nothing to say about about:blank",
             pillLabel(URL(string: "about:blank")!) == nil),
            ("the pill has nothing to say with no page", pillLabel(nil) == nil),
        ]
    }
}

extension Tab {
    /// Go to a url, wherever it came from. `loadFileURL` is the only load a WKWebView will
    /// accept for a `file:` url — a plain `URLRequest` is refused outright — and under the
    /// sandbox the read access has to be spelled out.
    ///
    /// The root is the *file*, not its folder: Finder hands a file opened or dropped on Vane
    /// with an implicit sandbox extension for that one file, and asking WebKit for the whole
    /// folder is asking for something the app sandbox never granted — measured, WebKit then
    /// refuses the load outright with "outside the sandbox".
    /// ponytail ceiling: an .html file's siblings — its stylesheet, its images — are outside
    /// that root and do not load. Upgrade path is `NSOpenPanel` on the folder, which is the
    /// only way the sandbox hands one over.
    func go(_ url: URL) {
        guard url.isFileURL else { web.load(URLRequest(url: url)); return }
        // Set before the load, not on didFinish: a PDF never reports a title, and the row
        // must not sit there as "New Tab" for as long as the file takes to render.
        title = url.lastPathComponent
        favicon = Files.icon(for: url)
        // A nil navigation is WebKit refusing before there is anything to fail — a file the
        // sandbox never extended to us. Nothing would call `didFail`, so the tab would sit
        // there blank under a name and an icon that say it loaded.
        guard web.loadFileURL(url, allowingReadAccessTo: url) == nil else { return }
        show(URLError(.noPermissionsToReadFile,
                      userInfo: [NSURLErrorFailingURLErrorKey: url]), in: web)
    }
}
