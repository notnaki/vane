import SwiftUI

/// Visibility of a retained navigation surface. Hidden surfaces keep native
/// identity; the experimental observation boundary may pause avoidable work.
private struct RenderSurfaceActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var renderSurfaceActive: Bool {
        get { self[RenderSurfaceActiveKey.self] }
        set { self[RenderSurfaceActiveKey.self] = newValue }
    }
}

/// Keep the retained controls active until the panel's bounded programmatic exit
/// finishes. Gesture exposure still arrives through `active`; reopening cancels
/// the old close task, and the current motion policy can end the tail immediately.
struct RetainedRenderSurfaceActivity: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver: BatterySaver
    @State private var retained: Bool
    private let sleep: @MainActor (Duration) async throws -> Void
    private struct Phase: Equatable { let active: Bool; let reduced: Bool }

    init(active: Bool, batterySaver: BatterySaver = .shared,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.active = active
        self.batterySaver = batterySaver
        self.sleep = sleep
        _retained = State(initialValue: active)
    }

    func body(content: Content) -> some View {
        let reduced = reduceMotion || batterySaver.isActive
        content
            .environment(\.renderSurfaceActive, active || (!reduced && retained))
            .onChange(of: active) {
                if active { retained = true }
                else if reduced { retained = false }
            }
            .onChange(of: reduced) {
                if reduced && !active { retained = false }
            }
            .task(id: Phase(active: active, reduced: reduced)) {
                guard !Task.isCancelled else { return }
                if active { retained = true; return }
                guard retained else { return }
                if reduced { retained = false; return }
                do { try await sleep(.milliseconds(240)) } catch { return }
                guard !Task.isCancelled else { return }
                retained = false
            }
    }
}

extension View {
    @ViewBuilder func renderSurfaceActivity(active: Bool) -> some View {
        if RenderPerformanceExperiment.hiddenSurfaces {
            modifier(RetainedRenderSurfaceActivity(active: active))
        } else {
            environment(\.renderSurfaceActive, active)
        }
    }
}
