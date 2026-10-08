import Foundation
import Combine
import WebKit

@MainActor final class ReadingQueueCapture: ObservableObject {
    static let shared = ReadingQueueCapture()
    @Published private(set) var capturing: Set<UUID> = []
    @Published private(set) var messages: [UUID: String] = [:]
    private var sources = Set<String>()
    static func canSave(tab: Tab?, in store: TabStore?) -> Bool {
        guard let tab, let store, !store.isPrivate, !store.isParked, !tab.isPrivate, !tab.loading,
              tab.easelID == nil, tab.profileID == store.profileID,
              let url = tab.existingWeb?.url else { return false }
        return ReadingArticleCodec.webURL(url.absoluteString) != nil
    }
    func save(tab: Tab, in store: TabStore) async {
        guard !store.isPrivate, !tab.isPrivate else { messages[tab.id] = ReadingQueueFailure.privateBrowsing.localizedDescription; return }
        guard Self.canSave(tab: tab, in: store) else { Toasts.show(ReadingQueueFailure.unsupported.localizedDescription, in: store); return }
        let key = "\(store.profileID)/\(tab.existingWeb?.url?.absoluteString ?? "")"
        guard sources.insert(key).inserted else { return }
        Motion.list { capturing.insert(tab.id); messages[tab.id] = "Saving…" }
        Toasts.show("Saving article…", in: store)
        defer { sources.remove(key); Motion.list { capturing.remove(tab.id) } }
        do {
            let repository = try ReadingQueueStore.shared(profileID: store.profileID, directory: Store.directory)
            let existing = repository.articles.first { $0.sourceURL == tab.existingWeb?.url?.absoluteString }
            let article = try await Self.capture(tab: tab, in: store, repository: repository, images: ReadingQueueImages())
            let text = existing != nil ? "Already saved." : (article.missingImages > 0 ? "Article saved. Some images were unavailable." : "Article saved for offline reading.")
            Motion.list { messages[tab.id] = text }
            Toasts.show(text, action: ("Reading Queue", { Library.open(.readingQueue, in: store) }), in: store)
        } catch {
            Motion.list { messages[tab.id] = error.localizedDescription }
            Toasts.show(error.localizedDescription, action: ("Retry", { Task { await self.save(tab: tab, in: store) } }), in: store)
        }
    }
    static func capture(tab: Tab, in store: TabStore, repository: ReadingQueueStore,
                        images: any ReadingQueueImageLoading) async throws -> ReadingArticle {
        guard !store.isPrivate, !tab.isPrivate, repository.profileID != Profile.incognito.id else { throw ReadingQueueFailure.privateBrowsing }
        guard tab.profileID == store.profileID, repository.profileID == store.profileID,
              let web = tab.existingWeb, !web.isLoading,
              let url = web.url, ReadingArticleCodec.webURL(url.absoluteString) != nil,
              tab.easelID == nil else { throw ReadingQueueFailure.unsupported }
        let generation = tab.readingDocumentGeneration
        func current() throws {
            guard tab.readingDocumentGeneration == generation, tab.existingWeb === web,
                  web.url == url, !web.isLoading, store.profileID == repository.profileID,
                  !repository.invalidated, !store.isParked, store.everyTab.contains(where: { $0 === tab }) else { throw ReadingQueueFailure.staleCapture }
        }
        await repository.waitUntilReady()
        try current()
        if let existing = repository.articles.first(where: { $0.sourceURL == url.absoluteString }) { return existing }
        let extracted: Reader.Extraction?
        if let retained = Reader.savedExtraction(for: tab) { extracted = retained }
        else { extracted = await Reader.extract(from: web) }
        try current()
        guard let extraction = extracted, Reader.isEnough(words: extraction.words) else { throw ReadingQueueFailure.unsupported }
        var imageURLs: [URL] = [], stack = extraction.nodes.map { ($0, 1) }, nodes = 0
        while let (node, depth) = stack.popLast() {
            nodes += 1
            guard depth <= 64, nodes <= 50_000 else { throw ReadingQueueFailure.tooLarge }
            if node.e == "img", let resolved = Reader.resolve(node.a?["src"] ?? "", base: url), let image = ReadingArticleCodec.webURL(resolved) { imageURLs.append(image) }
            stack += (node.c ?? []).map { ($0, depth + 1) }
        }
        if imageURLs.isEmpty, let lead = Reader.resolve(extraction.lead, base: url), let image = ReadingArticleCodec.webURL(lead) { imageURLs.append(image) }
        let urls = imageURLs
        let worker = Task.detached(priority: .userInitiated) { await images.collect(urls: urls) }
        let collected = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try current()
        func normalize(_ nodes: [Reader.Node]) -> [ReadingArticle.Node] {
            nodes.flatMap { node -> [ReadingArticle.Node] in
                if let text = node.x { return [.init(x: text)] }
                let children = normalize(node.c ?? [])
                guard let tag = node.e, ReadingArticleCodec.tags.contains(tag) else { return children }
                if tag == "img" {
                    guard let source = Reader.resolve(node.a?["src"] ?? "", base: url), let local = collected.mapping[source] else { return [] }
                    return [.init(e: "img", a: ["src": local, "alt": String((node.a?["alt"] ?? "").prefix(4_096))])]
                }
                if tag == "a" {
                    guard let href = Reader.resolve(node.a?["href"] ?? "", base: url) else { return children }
                    return [.init(e: tag, a: ["href": href], c: children)]
                }
                return [.init(e: tag, c: children)]
            }
        }
        var body = normalize(extraction.nodes)
        if !body.contains(where: { $0.e == "img" }), imageURLs.count == 1, extraction.nodes.allSatisfy({ $0.e != "img" }),
           let lead = Reader.resolve(extraction.lead, base: url), let mapped = collected.mapping[lead], !bodyImage(body) {
            body.insert(.init(e: "img", a: ["src": mapped, "alt": ""]), at: 0)
        }
        var article = ReadingArticle(profileID: repository.profileID,
            title: extraction.title.isEmpty ? (tab.title.isEmpty ? url.host! : tab.title) : extraction.title,
            sourceURL: url.absoluteString, nodes: body)
        article.byline = extraction.byline
        article.resources = collected.resources; article.missingImages = collected.missingCount
        return try await repository.publish(.init(article: article, images: collected.images), validity: current)
    }
    private static func bodyImage(_ nodes: [ReadingArticle.Node]) -> Bool {
        nodes.contains { $0.e == "img" || bodyImage($0.c ?? []) }
    }
}
