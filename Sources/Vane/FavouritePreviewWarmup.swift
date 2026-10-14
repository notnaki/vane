import AppKit
import Combine
import WebKit

/// One low-frequency clock for the app, not one timer or hidden page per tile/window.
@MainActor final class FavouritePreviewWarmup {
    static let shared = FavouritePreviewWarmup(previews: .shared)
    struct Candidate {
        let context: FavouritePreviewContext
        weak var source: WKWebView?
    }
    private let previews: FavouritePreviews
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var power: AnyCancellable?
    private var lastBatch: Date?
    private var generation = 0

    init(previews: FavouritePreviews) { self.previews = previews }

    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        timer?.tolerance = 30
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if NSApp.isActive { self?.schedule() } else { self?.suspend() }
                }
            })
        }
        power = BatterySaver.shared.$isActive.dropFirst().sink { [weak self] active in
            if active { self?.suspend() } else { self?.schedule() }
        }
        schedule()
    }

    private func suspend() {
        generation += 1
        task?.cancel(); task = nil
        previews.cancelWarmup()
    }
    private func schedule() {
        guard task == nil, lastBatch.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        let ticket = generation
        task = Task(priority: .background) { [weak self] in
            // Let window restoration and the selected page finish their launch work first.
            do { try await Task.sleep(for: .seconds(12), tolerance: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            defer { if self.generation == ticket { self.task = nil } }
            guard Self.allowed else { return }
            self.lastBatch = .now
            var seen = Set<FavouritePreviewContext>()
            let candidates = TabStore.all.filter {
                !$0.isPrivate && !$0.isLittle && !$0.isParked && $0.window?.isKeyWindow == true
                    && $0.window?.isMiniaturized == false && $0.window?.occlusionState.contains(.visible) == true
            }.flatMap(\.tabs).filter { $0.kind == .favourite }.compactMap { tab -> Candidate? in
                guard let url = tab.homeURL ?? tab.currentURL,
                      let context = FavouritePreviewContext(profileID: tab.profileID, url: url),
                      FavouritePreviews.enabled(context.service), seen.insert(context).inserted else { return nil }
                return Candidate(context: context, source: tab.existingWeb)
            }
            await self.refresh(candidates, allowed: { Self.allowed })
        }
    }
    private static var allowed: Bool {
        NSApp.isActive && !BatterySaver.shared.isActive
    }

    /// Budget is per batch across all profiles and services. Every step rechecks policy;
    /// foreground intent always wins through the coordinator's shared loader.
    func refresh(_ candidates: [Candidate], allowed: () -> Bool) async {
        for candidate in candidates.prefix(3) {
            guard !Task.isCancelled, allowed() else { return }
            await previews.warm(candidate.context, source: candidate.source)
        }
    }
}
