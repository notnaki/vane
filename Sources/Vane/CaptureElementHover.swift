import AppKit

/// Start immediately, keep one WebKit lookup in flight, and follow the newest
/// pointer position rather than waiting for the pointer to stop moving.
@MainActor final class CaptureElementHover {
    private let query: @MainActor (CGPoint) async -> CGRect?
    private let update: @MainActor (CGRect?) -> Void
    private var pending: CGPoint?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(query: @escaping @MainActor (CGPoint) async -> CGRect?, update: @escaping @MainActor (CGRect?) -> Void) {
        self.query = query
        self.update = update
    }

    func move(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else {
            cancel()
            return
        }
        pending = point
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            while self.generation == token, !Task.isCancelled, let point = self.pending {
                self.pending = nil
                let rect = await self.query(point)
                guard self.generation == token, !Task.isCancelled else { return }
                // Do not flash an old element after the pointer has left it.
                if self.pending == nil || self.pending.map({ rect?.contains($0) == true }) == true {
                    self.update(rect)
                }
            }
            if self.generation == token { self.task = nil }
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        task?.cancel()
        task = nil
    }
}
