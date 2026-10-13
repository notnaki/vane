import Foundation
import Combine

/// One local, validated snapshot per visible queue. No WebKit, network, HTML or
/// disk copies are created speculatively. The owner/revision must still match at use.
@MainActor final class Feel07ArticlePreparation: ObservableObject {
    private weak var owner: ReadingQueueStore?
    private var revision: Int?
    private var articleID: UUID?
    private var candidate: ReadingQueueCandidate?
    private var worker: Task<ReadingQueueCandidate, Error>?
    private var generation = UUID()
    private let load: (UUID, ReadingQueueStore) async throws -> ReadingQueueCandidate

    init(load: @escaping (UUID, ReadingQueueStore) async throws -> ReadingQueueCandidate = { id, repository in
        try await repository.candidate(id)
    }) { self.load = load }

    func clear() {
        worker?.cancel()
        relinquish()
    }
    private func relinquish() {
        generation = UUID(); owner = nil; revision = nil; articleID = nil; candidate = nil; worker = nil
    }
    private func matches(_ id: UUID, repository: ReadingQueueStore) -> Bool {
        owner === repository && revision == repository.revision && articleID == id && !repository.invalidated
    }
    func prepare(_ id: UUID, repository: ReadingQueueStore) async {
        clear()
        guard !Task.isCancelled, !repository.invalidated, repository.profileID != Profile.incognito.id else { return }
        let asked = generation, revision = repository.revision, load = self.load
        owner = repository; self.revision = revision; articleID = id
        let worker = Task { try await load(id, repository) }
        self.worker = worker
        do {
            let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                Task { @MainActor [weak self] in
                    // An explicit open may already own this read. Queue cancellation
                    // must not cancel work transferred to its reader window.
                    if self?.generation == asked { self?.clear() }
                }
            }
            guard generation == asked else { return }
            guard !Task.isCancelled, !repository.invalidated, repository.revision == revision else { clear(); return }
            candidate = loaded; self.worker = nil
        } catch {
            if generation == asked { clear() }
            // Opening reports errors through the ordinary validated path.
        }
    }
    func take(_ id: UUID, repository: ReadingQueueStore) -> ReadingQueueCandidate? {
        defer { clear() }
        guard matches(id, repository: repository), candidate?.article.id == id,
              candidate?.article.profileID == repository.profileID else { return nil }
        return candidate
    }
    func takeOrWait(_ id: UUID, repository: ReadingQueueStore) async -> ReadingQueueCandidate? {
        guard matches(id, repository: repository) else { clear(); return nil }
        let revision = repository.revision, ready = candidate, worker = self.worker
        // Transfer ownership before awaiting: disappearance, hover changes and the
        // preparation caller's cancellation can now leave the explicit open alone.
        relinquish()
        let loaded: ReadingQueueCandidate?
        if let ready { loaded = ready }
        else if let worker {
            loaded = await withTaskCancellationHandler { try? await worker.value } onCancel: { worker.cancel() }
        } else { loaded = nil }
        guard !Task.isCancelled, !repository.invalidated, repository.revision == revision,
              loaded?.article.id == id, loaded?.article.profileID == repository.profileID else { return nil }
        return loaded
    }
}
