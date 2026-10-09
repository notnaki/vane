import SwiftUI

enum ReadingQueueFilter: String, CaseIterable, Sendable { case all = "All", unread = "Unread", read = "Read" }
enum ReadingQueueSearch {
    static func results(articles: [ReadingArticle], query: String, filter: ReadingQueueFilter) -> [ReadingArticle] {
        articles.filter { (filter == .all || $0.isRead == (filter == .read)) && ReadingArticleCodec.matches($0, query: query) }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt }
    }
    static func results(items: [ReadingQueueItem], query: String, filter: ReadingQueueFilter) -> [ReadingQueueItem] {
        var found: [ReadingQueueItem] = []
        for item in items {
            guard !Task.isCancelled else { return [] }
            if (filter == .all || item.article.isRead == (filter == .read)) && ReadingArticleCodec.matches(item.article, query: query) {
                found.append(item)
            }
        }
        return found.sorted {
            if $0.article.capturedAt != $1.article.capturedAt { return $0.article.capturedAt > $1.article.capturedAt }
            if $0.article.id != $1.article.id { return $0.article.id.uuidString < $1.article.id.uuidString }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
    }
}

struct ReadingQueueHost: View {
    @ObservedObject var origin: TabStore
    var body: some View {
        if origin.isPrivate { Text("Offline saving is unavailable in private browsing.").padding() }
        else { ReadingQueuePane(origin: origin) }
    }
}

struct ReadingQueuePane: View {
    @StateObject private var collection = ReadingQueueCollection()
    @ObservedObject var origin: TabStore
    @ObservedObject private var library = Library.shared
    @State private var filter = ReadingQueueFilter.all
    @State private var results: [ReadingQueueItem] = []
    @State private var message: String?
    @State private var searching = true
    @FocusState private var focusedArticle: ReadingQueueIdentity?
    private struct Request: Equatable, Sendable { var query: String; var filter: ReadingQueueFilter; var revisions: [ReadingQueueCollection.Revision] }
    private var request: Request { .init(query: library.query, filter: filter, revisions: collection.revisions) }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work(); message = nil } catch { message = error.localizedDescription } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            LibraryHead(section: .readingQueue, filtering: filter != .all, query: $library.query) {
                Picker("Show", selection: $filter) { ForEach(ReadingQueueFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            } actions: { Button("Retry / Refresh") { collection.reload(); message = nil } }
            Text("\(collection.usage.articleCount) saved · \(size(collection.usage.publishedBytes))").font(Look.caption).foregroundStyle(Look.inkSecondary)
            if collection.usage.pendingCleanupBytes > 0 {
                Text("\(size(collection.usage.pendingCleanupBytes)) pending cleanup").font(Look.caption).foregroundStyle(Look.inkSecondary)
            }
            if let message {
                Text(message).font(Look.caption).foregroundStyle(Look.inkSecondary)
            }
            ForEach(collection.failures) { failure in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(failure.profileName): \(failure.message)").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    Button("Retry") { collection.reload(profileID: failure.id); message = nil }
                }.accessibilityElement(children: .contain)
            }
            if collection.loading { Text("Loading saved articles…").font(Look.caption).foregroundStyle(Look.inkSecondary) }
            if searching { Text("Searching…").font(Look.caption).foregroundStyle(Look.inkSecondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.rowGap) {
                    if results.isEmpty && !searching && !collection.loading {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(collection.items.isEmpty ? "Read it later, offline" : "No matching articles").font(Look.heading)
                            Text(collection.items.isEmpty ? "Choose Save for Offline in Page Actions on an article. Saved copies from all profiles appear here." : "Try another search or choose All in Filter.").font(Look.small).foregroundStyle(Look.inkSecondary)
                        }.padding(.vertical, 18)
                    }
                    ForEach(results) { item in row(item) }
                    ForEach(collection.damaged) { damage in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Unreadable saved article").font(Look.small)
                            Text(damage.profileName).font(Look.caption).foregroundStyle(Look.inkTertiary)
                            Text(damage.entry.message).font(Look.caption).foregroundStyle(Look.inkSecondary)
                            HStack {
                                Button("Retry") { collection.reload(profileID: damage.profileID) }
                                Button("Remove", role: .destructive) {
                                    perform { try await ownedRepository(damage.profileID).remove(damage.entry.id) }
                                }
                            }
                        }.padding(8)
                    }
                }
            }
        }
        .padding(.horizontal, Look.inset).padding(.top, Look.inset)
        .task(id: request) {
            let asked = request, items = collection.items
            searching = true
            let worker = Task.detached(priority: .userInitiated) {
                ReadingQueueSearch.results(items: items, query: asked.query, filter: asked.filter)
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, request == asked else { return }
            Motion.list { results = found; searching = false }
        }
    }
    private func ownedRepository(_ profileID: UUID) throws -> ReadingQueueStore {
        guard !origin.isPrivate, let repository = collection.repository(for: profileID) else { throw ReadingQueueFailure.staleCapture }
        return repository
    }
    private func openSaved(_ item: ReadingQueueItem) {
        guard !origin.isPrivate, let repository = collection.repository(for: item.profileID) else { return }
        SavedReaderWindow.show(articleID: item.article.id, repository: repository, origin: origin)
    }
    private func row(_ item: ReadingQueueItem) -> some View {
        let article = item.article
        return HStack(alignment: .top, spacing: 7) {
            Button {
                openSaved(item)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: article.isRead ? "checkmark.circle" : "circle.fill").font(.system(size: 10)).foregroundStyle(article.isRead ? Look.inkTertiary : Look.inkPrimary).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(Look.small).foregroundStyle(Look.inkPrimary).lineLimit(3)
                        Text(URL(string: article.sourceURL)?.host ?? "").font(Look.caption).foregroundStyle(Look.inkSecondary).lineLimit(1)
                        Text("\(item.profileName) · \(article.capturedAt.formatted(date: .abbreviated, time: .omitted))").font(Look.caption).foregroundStyle(Look.inkTertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focusedArticle, equals: item.id)
                .accessibilityLabel("\(article.title), saved copy in \(item.profileName), \(article.isRead ? "read" : "unread")")
                .help("\(article.sourceURL)\nSaved \(article.capturedAt.formatted()) · \(size(collection.repository(for: item.profileID)?.bytes(for: article) ?? 0))")
            Menu { actions(item) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(article.title)")
        }.padding(8)
            .background(focusedArticle == item.id ? Look.controlFill : .clear, in: .rect(cornerRadius: Look.pillRadius))
            .contextMenu { actions(item) }
    }
    @ViewBuilder private func actions(_ item: ReadingQueueItem) -> some View {
        let article = item.article
        Button("Open Saved Copy") { openSaved(item) }
        Button(article.isRead ? "Mark Unread" : "Mark Read") { perform { try await ownedRepository(item.profileID).setRead(!article.isRead, id: article.id) } }
        Button("Open Live Page") {
            guard !origin.isPrivate, collection.repository(for: item.profileID) != nil, let url = ReadingArticleCodec.webURL(article.sourceURL) else { return }
            SavedReaderLivePage.open(url, profileID: item.profileID); Library.close(origin)
        }
        Text("\(size(collection.repository(for: item.profileID)?.bytes(for: article) ?? 0)) saved")
        Divider()
        Button("Remove", role: .destructive) { perform { try await ownedRepository(item.profileID).remove(article.id) } }
    }
}
