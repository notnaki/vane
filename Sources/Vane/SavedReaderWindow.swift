import AppKit
import SwiftUI
import WebKit
import Combine

@MainActor enum SavedReaderDocument {
    static func html(article: ReadingArticle) -> String {
        func nodes(_ input: [ReadingArticle.Node]) -> [Reader.Node] {
            input.map { .init(x: $0.x, e: $0.e, a: $0.a, c: $0.c.map(nodes)) }
        }
        let mapping = Dictionary(uniqueKeysWithValues: article.resources.map { ("images/" + $0.name, "images/" + $0.name) })
        let extraction = Reader.Extraction(title: article.title, byline: article.byline, nodes: nodes(article.nodes))
        let html = Reader.html(for: extraction, url: URL(string: article.sourceURL), localImages: mapping)
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; connect-src 'none'\">"
        let notice = "<p class=\"by\">Saved copy · \(Reader.esc(article.capturedAt.formatted(date: .abbreviated, time: .shortened)))\(article.missingImages > 0 ? " · Some images were unavailable" : "")</p>"
        return "<!doctype html><html>" + html.replacingOccurrences(of: "<head>", with: "<head>" + csp)
            .replacingOccurrences(of: "<header>", with: "<header>" + notice) + "</html>"
    }
}

enum SavedReaderNavigation {
    static func allowed(url: URL, articleDirectory: URL, userInitiated: Bool) -> Bool {
        guard url.isFileURL else { return false }
        let root = articleDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }
}

@MainActor enum SavedReaderWindow {
    private struct Key: Hashable { var profile: UUID; var article: UUID }
    private static var sessions: [Key: SavedReaderSession] = [:]
    static func show(articleID: UUID, repository: ReadingQueueStore, origin: TabStore) {
        guard !origin.isPrivate, origin.profileID == repository.profileID, !repository.invalidated else { return }
        let key = Key(profile: repository.profileID, article: articleID)
        if let session = sessions[key] { session.window.makeKeyAndOrderFront(nil); return }
        do {
            let session = try SavedReaderSession(articleID: articleID, repository: repository, origin: origin)
            sessions[key] = session
            session.onClose = { sessions[key] = nil }
            session.window.makeKeyAndOrderFront(nil)
        } catch { Toasts.show(error.localizedDescription, in: origin) }
    }
    static func forget(profileID: UUID) {
        for key in Array(sessions.keys) where key.profile == profileID { sessions[key]?.window.close() }
    }
    static func close(articleID: UUID, profileID: UUID) {
        sessions[Key(profile: profileID, article: articleID)]?.window.close()
    }
}

@MainActor private final class SavedReaderSession: NSObject, ObservableObject, NSWindowDelegate, WKNavigationDelegate {
    let window: NSWindow
    let web: WKWebView
    let repository: ReadingQueueStore
    let articleID: UUID
    let presentation: URL
    weak var origin: TabStore?
    var onClose: (() -> Void)?
    @Published var message: String?
    private var observation: AnyCancellable?
    init(articleID: UUID, repository: ReadingQueueStore, origin: TabStore) throws {
        let candidate = try repository.candidate(articleID)
        self.articleID = articleID; self.repository = repository; self.origin = origin
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-saved-reader-\(UUID().uuidString)")
        try ReadingQueueFiles.ensureDirectory(directory)
        do {
            if !candidate.images.isEmpty {
                let images = directory.appendingPathComponent("images"); try ReadingQueueFiles.ensureDirectory(images)
                for (name, bytes) in candidate.images { try bytes.write(to: images.appendingPathComponent(name), options: .atomic) }
            }
            try Data(SavedReaderDocument.html(article: candidate.article).utf8).write(to: directory.appendingPathComponent("article.html"), options: .atomic)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        presentation = directory
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Saved copy — \(candidate.article.title)"
        window.minSize = .init(width: 520, height: 360); window.isReleasedWhenClosed = false
        window.delegate = self; web.navigationDelegate = self
        window.contentView = NSHostingView(rootView: SavedReaderView(session: self, repository: repository))
        window.center()
        web.loadFileURL(directory.appendingPathComponent("article.html"), allowingReadAccessTo: directory)
        observation = repository.$revision.sink { [weak self] _ in
            guard let self else { return }
            if self.repository.invalidated || !self.repository.articles.contains(where: { $0.id == articleID }) { self.window.close() }
        }
    }
    var article: ReadingArticle? { repository.articles.first { $0.id == articleID } }
    func open(_ url: URL) {
        guard let origin, !origin.isPrivate, origin.profileID == repository.profileID, article != nil else { return }
        if ReadingArticleCodec.webURL(url.absoluteString) != nil { origin.newTab(url); origin.window?.makeKeyAndOrderFront(nil) }
        else if url.scheme?.lowercased() == "mailto" { NSWorkspace.shared.open(url) }
    }
    func changeSize(_ delta: Int) { Reader.adjustFontSize(delta, in: nil); applyPreferences() }
    func changeTypeface() { Reader.setSerif(!Reader.serif, in: nil); applyPreferences() }
    func applyPreferences() {
        guard let article else { return }
        // Reuse Reader's style values without reloading or changing the saved payload/scroll.
        let html = SavedReaderDocument.html(article: article)
        guard let start = html.range(of: "<style>"), let end = html.range(of: "</style>") else { return }
        let css = String(html[start.upperBound..<end.lowerBound])
        web.evaluateJavaScript("document.body.style.transition = '\(Motion.reduced ? "none" : "font-size 120ms ease-out, line-height 120ms ease-out, max-width 120ms ease-out")'; document.querySelector('style').textContent = \(Reader.jsString(css));")
        objectWillChange.send()
    }
    func windowWillClose(_ notification: Notification) {
        observation = nil; web.stopLoading(); web.navigationDelegate = nil
        web.removeFromSuperview(); window.contentView = nil
        try? FileManager.default.removeItem(at: presentation)
        onClose?(); onClose = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if SavedReaderNavigation.allowed(url: url, articleDirectory: presentation, userInitiated: false) { return .allow }
        if action.navigationType == .linkActivated { open(url) }
        return .cancel
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = "Could not open the saved copy. \(error.localizedDescription)" }
}

private struct SavedReaderView: View {
    @ObservedObject var session: SavedReaderSession
    @ObservedObject var repository: ReadingQueueStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved copy").font(.headline)
                    if let article = session.article {
                        Text("\(URL(string: article.sourceURL)?.host ?? "") · \(article.capturedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let article = session.article {
                    Button(article.isRead ? "Mark Unread" : "Mark Read") {
                        do { try repository.setRead(!article.isRead, id: article.id) } catch { session.message = error.localizedDescription }
                    }
                    Menu("Reading Preferences") {
                        Button("Larger Text (\(Reader.fontSize) pt)") { session.changeSize(1) }.disabled(Reader.fontSize >= 32)
                        Button("Smaller Text") { session.changeSize(-1) }.disabled(Reader.fontSize <= 13)
                        Button(Reader.serif ? "Use Sans Serif" : "Use Serif") { session.changeTypeface() }
                    }
                    Button("Open Live Page") { if let url = URL(string: article.sourceURL) { session.open(url) } }
                }
            }.padding(14)
            if let message = session.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(8).accessibilityLabel(message) }
            if (session.article?.missingImages ?? 0) > 0 { Text("Some images were unavailable when this article was saved.").font(.caption).foregroundStyle(.secondary).padding(6) }
            Divider()
            SavedReaderWeb(web: session.web)
        }.accessibilityLabel("Saved article Reader")
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.vane).receive(on: RunLoop.main)) { _ in session.applyPreferences() }
    }
}

private struct SavedReaderWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
