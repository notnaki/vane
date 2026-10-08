import AppKit
import SwiftUI

/// One accepted download, routed to its originating window. This is transient UI state;
/// loading history or switching profiles must never replay the arrival animation.
@MainActor final class DownloadFeedback: ObservableObject {
    static let started = Notification.Name("VaneDownloadStarted")
    static let flightSeconds = 0.65

    struct Origin { weak var window: NSWindow? }

    final class Start: Identifiable {
        let id = UUID()
        let name: String
        let profileID: UUID
        weak var window: NSWindow?

        init(name: String, profileID: UUID, window: NSWindow?) {
            self.name = name
            self.profileID = profileID
            self.window = window
        }
    }

    @Published private(set) var start: Start?
    @Published private(set) var landed = false

    func receive(_ start: Start, in window: NSWindow?, isPrivate: Bool, reduced: Bool) {
        guard let origin = start.window, origin === window,
              (start.profileID == Profile.incognito.id) == isPrivate else { return }
        self.start = start
        landed = reduced
    }

    func land(_ id: UUID) {
        guard start?.id == id else { return }
        landed = true
    }

    func dismiss(_ id: UUID) {
        guard start?.id == id else { return }
        cancel()
    }

    func cancel() { start = nil; landed = false }
}


struct DownloadFeedbackPresentation: ViewModifier {
    @ObservedObject var store: TabStore
    let chrome: Bool
    @StateObject private var downloadFeedback = DownloadFeedback()
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
        .overlayPreferenceValue(DownloadFeedbackBounds.self) { bounds in
            GeometryReader { geometry in
                if let start = downloadFeedback.start, !downloadFeedback.landed,
                   !reduceMotion, !batterySaver.isActive,
                   let page = bounds[.page], let bucket = bounds[.bucket] {
                    let source = geometry[page]
                    let target = geometry[bucket]
                    DownloadFlight(source: CGPoint(x: source.midX, y: source.midY),
                                   destination: CGPoint(x: target.midX, y: target.midY - 4))
                        .id(start.id)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .environmentObject(downloadFeedback)
        .onReceive(NotificationCenter.default.publisher(for: DownloadFeedback.started)) { notification in
            guard let start = notification.object as? DownloadFeedback.Start else { return }
            downloadFeedback.receive(start, in: store.window, isPrivate: store.isPrivate,
                                     reduced: reduceMotion || batterySaver.isActive || !chrome || store.libraryOpen)
        }
        .task(id: downloadFeedback.start?.id) {
            guard let start = downloadFeedback.start else { return }
            do {
                if !downloadFeedback.landed {
                    try await Task.sleep(for: .seconds(DownloadFeedback.flightSeconds))
                    downloadFeedback.land(start.id)
                }
                try await Task.sleep(for: .milliseconds(1200))
                downloadFeedback.dismiss(start.id)
            } catch { }
        }
        .onChange(of: reduceMotion || batterySaver.isActive || !chrome || store.libraryOpen) {
            if reduceMotion || batterySaver.isActive || !chrome || store.libraryOpen,
               let start = downloadFeedback.start { downloadFeedback.land(start.id) }
        }
        .onDisappear { downloadFeedback.cancel() }
    }
}

struct LibraryDownloadGlyph: View {
    let filled: Bool
    let hovered: Bool
    @EnvironmentObject private var feedback: DownloadFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        ZStack {
            LibraryBucket(filled: filled, hovered: hovered)
                .opacity(feedback.landed ? 0 : 1)
            if feedback.landed, let start = feedback.start {
                Image(nsImage: FileIcons.icon(path: nil, name: start.name))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: feedback.landed)
    }
}

/// Measure the live page and the actual Library control in the same window overlay,
/// including when the sidebar is floating or has been resized.
struct DownloadFeedbackBounds: PreferenceKey {
    enum Target: Hashable { case page, bucket }
    static let defaultValue: [Target: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Target: Anchor<CGRect>],
                       nextValue: () -> [Target: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct DownloadFlight: View {
    let source: CGPoint
    let destination: CGPoint
    @State private var progress: CGFloat = 0

    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.85), in: .circle)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .modifier(FlightPosition(progress: progress, source: source, destination: destination))
            .task {
                withAnimation(.timingCurve(0.25, 0.05, 0.35, 1,
                                           duration: DownloadFeedback.flightSeconds)) { progress = 1 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct FlightPosition: AnimatableModifier {
    nonisolated var progress: CGFloat
    let source: CGPoint
    let destination: CGPoint
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Bend toward the sidebar first, then fall into the opening in one motion.
        let control = CGPoint(x: destination.x, y: source.y - 60)
        let remaining = 1 - progress
        let x = remaining * remaining * source.x + 2 * remaining * progress * control.x
            + progress * progress * destination.x
        let y = remaining * remaining * source.y + 2 * remaining * progress * control.y
            + progress * progress * destination.y
        content
            .scaleEffect(1 - 0.55 * progress)
            .opacity(Double(min(1, remaining / 0.12)))
            .position(x: x, y: y)
    }
}
