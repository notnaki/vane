import SwiftUI

enum ReadingQueueFilter: String, CaseIterable, Sendable { case all = "All", unread = "Unread", read = "Read" }
enum ReadingQueueSearch {
    static func results(articles: [ReadingArticle], query: String, filter: ReadingQueueFilter) -> [ReadingArticle] {
        articles.filter { (filter == .all || $0.isRead == (filter == .read)) && ReadingArticleCodec.matches($0, query: query) }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt }
    }
}

struct ReadingQueueHost: View {
    @ObservedObject var origin: TabStore
    @State private var retry = 0
    var body: some View {
        if origin.isPrivate { Text("Offline saving is unavailable in private browsing.").padding() }
        else {
            let result = Result { try ReadingQueueStore.shared(profileID: origin.profileID, directory: Store.directory) }
            switch result {
            case .success(let repository): ReadingQueuePane(repository: repository, origin: origin).id(origin.profileID)
            case .failure(let error):
                VStack(spacing: 12) {
                    Text("Could not open the reading queue").font(.headline)
                    Text(error.localizedDescription).font(.caption)
                    Button("Retry") { retry += 1 }
                }.padding().id(retry)
            }
        }
    }
}

struct ReadingQueuePane: View {
    @ObservedObject var repository: ReadingQueueStore
    @ObservedObject var origin: TabStore
    @ObservedObject private var library = Library.shared
    @State private var filter = ReadingQueueFilter.all
    @State private var results: [ReadingArticle] = []
    @State private var message: String?
    @State private var searching = true
    @FocusState private var focusedArticle: UUID?
    private struct Request: Equatable { var profile: UUID; var query: String; var filter: ReadingQueueFilter; var revision: Int }
    private var request: Request { .init(profile: repository.profileID, query: library.query, filter: filter, revision: repository.revision) }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work(); message = nil } catch { message = error.localizedDescription } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            LibraryHead(section: .readingQueue, filtering: filter != .all, query: $library.query) {
                Picker("Show", selection: $filter) { ForEach(ReadingQueueFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            } actions: { Button("Retry / Refresh") { repository.reload() } }
            Text("\(repository.usage.articleCount) saved · \(size(repository.usage.publishedBytes))").font(Look.caption).foregroundStyle(Look.inkSecondary)
            if repository.usage.pendingCleanupBytes > 0 {
                Text("\(size(repository.usage.pendingCleanupBytes)) pending cleanup").font(Look.caption).foregroundStyle(Look.inkSecondary)
            }
            if let error = message ?? repository.error {
                VStack(alignment: .leading, spacing: 5) {
                    Text(error).font(Look.caption).foregroundStyle(Look.inkSecondary)
                    Button("Retry") { repository.reload(); message = nil }
                }.accessibilityElement(children: .contain)
            }
            if repository.loading { Text("Loading saved articles…").font(Look.caption).foregroundStyle(Look.inkSecondary) }
            if searching { Text("Searching…").font(Look.caption).foregroundStyle(Look.inkSecondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.rowGap) {
                    if results.isEmpty && !searching && !repository.loading {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(repository.articles.isEmpty ? "Read it later, offline" : "No matching articles").font(Look.heading)
                            Text(repository.articles.isEmpty ? "Choose Save for Offline in Page Actions on an article. Saved copies stay in this profile." : "Try another search or choose All in Filter.").font(Look.small).foregroundStyle(Look.inkSecondary)
                        }.padding(.vertical, 18)
                    }
                    ForEach(results) { article in row(article) }
                    ForEach(repository.damaged) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Unreadable saved article").font(Look.small)
                            Text(entry.message).font(Look.caption).foregroundStyle(Look.inkSecondary)
                            HStack { Button("Retry") { repository.reload() }; Button("Remove", role: .destructive) { perform { try await repository.remove(entry.id) } } }
                        }.padding(8)
                    }
                }
            }
        }
        .padding(.horizontal, Look.inset).padding(.top, Look.inset)
        .task(id: request) {
            let asked = request, articles = repository.articles
            searching = true
            let found = await Task.detached(priority: .userInitiated) { ReadingQueueSearch.results(articles: articles, query: asked.query, filter: asked.filter) }.value
            guard !Task.isCancelled, request == asked else { return }
            Motion.list { results = found; searching = false }
        }
    }
    private func row(_ article: ReadingArticle) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button {
                SavedReaderWindow.show(articleID: article.id, repository: repository, origin: origin)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: article.isRead ? "checkmark.circle" : "circle.fill").font(.system(size: 10)).foregroundStyle(article.isRead ? Look.inkTertiary : Look.inkPrimary).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(Look.small).foregroundStyle(Look.inkPrimary).lineLimit(3)
                        Text(URL(string: article.sourceURL)?.host ?? "").font(Look.caption).foregroundStyle(Look.inkSecondary).lineLimit(1)
                        Text(article.capturedAt.formatted(date: .abbreviated, time: .omitted)).font(Look.caption).foregroundStyle(Look.inkTertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focusedArticle, equals: article.id)
                .accessibilityLabel("\(article.title), saved copy, \(article.isRead ? "read" : "unread")")
                .help("\(article.sourceURL)\nSaved \(article.capturedAt.formatted()) · \(size(repository.bytes(for: article)))")
            Menu { actions(article) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(article.title)")
        }.padding(8)
            .background(focusedArticle == article.id ? Look.controlFill : .clear, in: .rect(cornerRadius: Look.pillRadius))
            .contextMenu { actions(article) }
    }
    @ViewBuilder private func actions(_ article: ReadingArticle) -> some View {
        Button("Open Saved Copy") { SavedReaderWindow.show(articleID: article.id, repository: repository, origin: origin) }
        Button(article.isRead ? "Mark Unread" : "Mark Read") { perform { try await repository.setRead(!article.isRead, id: article.id) } }
        Button("Open Live Page") {
            guard !origin.isPrivate, origin.profileID == repository.profileID, let url = ReadingArticleCodec.webURL(article.sourceURL) else { return }
            SavedReaderLivePage.open(url, profileID: repository.profileID); Library.close(origin)
        }
        Text("\(size(repository.bytes(for: article))) saved")
        Divider()
        Button("Remove", role: .destructive) { perform { try await repository.remove(article.id) } }
    }
}
