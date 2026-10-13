import Foundation
import Combine

/// One local, validated snapshot per visible queue. No WebKit, network, HTML or
/// disk copies are created speculatively. The owner/revision must still match at use.
@MainActor final class Feel07ArticlePreparation: ObservableObject {
    private weak var owner: ReadingQueueStore?
    private var revision: Int?
    private var candidate: ReadingQueueCandidate?
    private var generation = UUID()

    func clear() {
        generation = UUID(); owner = nil; revision = nil; candidate = nil
    }
    func prepare(_ id: UUID, repository: ReadingQueueStore) async {
        clear()
        guard !repository.invalidated, repository.profileID != Profile.incognito.id else { return }
        let asked = generation, revision = repository.revision
        do {
            let loaded = try await repository.candidate(id)
            guard !Task.isCancelled, generation == asked, !repository.invalidated,
                  repository.revision == revision else { return }
            owner = repository; self.revision = revision; candidate = loaded
        } catch { /* Opening still reports errors through the ordinary validated path. */ }
    }
    func take(_ id: UUID, repository: ReadingQueueStore) -> ReadingQueueCandidate? {
        defer { clear() }
        guard owner === repository, revision == repository.revision, !repository.invalidated,
              candidate?.article.id == id, candidate?.article.profileID == repository.profileID else { return nil }
        return candidate
    }
}
