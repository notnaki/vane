import AppKit
import SwiftUI

/// One accepted download, routed to its originating window. This is transient UI state;
/// loading history or switching profiles must never replay the arrival animation.
@MainActor final class DownloadFeedback: ObservableObject {
    static let started = Notification.Name("VaneDownloadStarted")
    static let flightSeconds = 1.1

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
    /// Where the pointer was in the window (top-left origin) when the download began: the
    /// link that was clicked, so the flight leaves from it.
    private(set) var click: CGPoint?

    func receive(_ start: Start, in window: NSWindow?, isPrivate: Bool, reduced: Bool) {
        guard let origin = start.window, origin === window,
              (start.profileID == Profile.incognito.id) == isPrivate else { return }
        let pointer = origin.mouseLocationOutsideOfEventStream
        click = origin.contentView.map { CGPoint(x: pointer.x, y: $0.bounds.height - pointer.y) }
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

/// Measure only while a download needs its flight or landing control. An empty
/// animation still made window layout reduce anchor preferences through every row.
/// Keep the content outside the conditional so activating feedback preserves it.
struct DownloadFeedbackAnchor: ViewModifier {
    let target: DownloadFeedbackBounds.Target
    @EnvironmentObject private var feedback: DownloadFeedback

    func body(content: Content) -> some View {
        content.background {
            if feedback.start != nil {
                Color.clear
                    .anchorPreference(key: DownloadFeedbackBounds.self, value: .bounds) { [target: $0] }
                    .allowsHitTesting(false)
            }
        }
    }
}


struct DownloadFeedbackPresentation: ViewModifier {
    @ChromeObserved var store: TabStore
    let chrome: Bool
    @StateObject private var downloadFeedback = DownloadFeedback()
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
        .overlayPreferenceValue(DownloadFeedbackBounds.self) { bounds in
            GeometryReader { geometry in
                if let start = downloadFeedback.start, let page = bounds[.page],
                   let target = DownloadFeedbackBounds.destination(
                    page: geometry[page], bucket: bounds[.bucket].map { geometry[$0] }, chrome: chrome) {
                    let pageRect = geometry[page]
                    let origin = geometry.frame(in: .global).origin
                    let click = downloadFeedback.click.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
                    let source = DownloadFeedbackBounds.source(page: pageRect, click: click)
                    let still = reduceMotion || batterySaver.isActive
                    // Once landed, the arrow hops onto the bucket's corner and stays there.
                    let badge = Group {
                        if downloadFeedback.landed {
                            DownloadBadge(from: DownloadFlight.landing(on: target),
                                          to: DownloadFlight.badge(on: target), still: still)
                                .id(start.id)
                        }
                    }
                    let slide = Animation.spring(response: 0.37, dampingFraction: 0.78)
                    if !chrome {
                        // Box and badge are one piece: in from under the page's leading edge,
                        // clipped by it, and back out the same way together.
                        ZStack {
                            Button {
                                // Little Vane has no Library; its downloads open in a main
                                // window of the same profile and privacy, made if need be.
                                let host = !store.isLittle ? store
                                    : Windows.current(in: store.profileID, isPrivate: store.isPrivate)
                                        ?? Windows.open(isPrivate: store.isPrivate, profile: store.profile)
                                host.window?.makeKeyAndOrderFront(nil)
                                Motion.list { Library.open(.downloads, in: host) }
                            } label: {
                                LibraryDownloadGlyph(filled: true, hovered: false)
                                    .offset(y: -4)
                                    .frame(width: target.width, height: target.height)
                                    // Black with a soft white halo, about 17pt wide.
                                    .background(.black, in: .rect(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .white.opacity(0.1), radius: 12)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(TactileButtonStyle())
                            .foregroundStyle(Color(white: 0.85))
                            .accessibilityLabel("Download started: \(start.name)")
                            .accessibilityHint("Open Downloads in Library")
                            .position(x: target.midX, y: target.midY)
                            badge
                        }
                        .transition(.asymmetric(
                            insertion: .modifier(active: PageSlide(dx: pageRect.minX - target.maxX, page: pageRect),
                                                 identity: PageSlide(dx: 0, page: pageRect))
                                .animation(still ? nil : slide),
                            removal: .modifier(active: PageSlide(dx: pageRect.minX - target.maxX - 12, page: pageRect),
                                               identity: PageSlide(dx: 0, page: pageRect))
                                .animation(still ? nil : slide)))
                    } else {
                        badge
                    }
                    if !downloadFeedback.landed, !still {
                        DownloadFlight(source: source, destination: DownloadFlight.landing(on: target))
                            .id(start.id)
                    }
                }
            }
            .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick,
                       value: downloadFeedback.start?.id)
        }
        .environmentObject(downloadFeedback)
        .onReceive(NotificationCenter.default.publisher(for: DownloadFeedback.started)) { notification in
            guard let start = notification.object as? DownloadFeedback.Start else { return }
            downloadFeedback.receive(start, in: store.window, isPrivate: store.isPrivate,
                                     reduced: reduceMotion || batterySaver.isActive || store.libraryOpen)
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
        .onChange(of: reduceMotion || batterySaver.isActive || store.libraryOpen) {
            if reduceMotion || batterySaver.isActive || store.libraryOpen,
               let start = downloadFeedback.start { downloadFeedback.land(start.id) }
        }
        .onDisappear { downloadFeedback.cancel() }
    }
}

/// Moves its content sideways under a mask that stays on the page, so whatever slides past
/// the page's edge is hidden by it. The offset is inside the mask, not outside it.
private struct PageSlide: ViewModifier {
    let dx: CGFloat
    let page: CGRect

    func body(content: Content) -> some View {
        content.offset(x: dx).mask {
            Rectangle().frame(width: page.width, height: page.height).position(x: page.midX, y: page.midY)
        }
    }
}

struct LibraryDownloadGlyph: View {
    let filled: Bool
    let hovered: Bool

    var body: some View {
        // The bucket itself never changes: the landed arrow sits on its corner instead.
        LibraryBucket(filled: filled, hovered: hovered)
    }
}

/// Measure the live page and the actual Library control in the same window overlay,
/// including when the sidebar is floating or has been resized.
struct DownloadFeedbackBounds: PreferenceKey {
    enum Target: Hashable { case page, bucket }
    static let defaultValue: [Target: Anchor<CGRect>] = [:]

    /// With chrome hidden, give the flight a visible landing point inside the page.
    static func destination(page: CGRect, bucket: CGRect?, chrome: Bool) -> CGRect? {
        if chrome { return bucket }
        return CGRect(x: page.minX + 20, y: page.maxY - 66, width: 46, height: 46)
    }

    /// Leave from the clicked link; a download the page started on its own (pointer
    /// elsewhere) leaves from the page's centre.
    static func source(page: CGRect, click: CGPoint?) -> CGPoint {
        if let click, page.contains(click) { return click }
        return CGPoint(x: page.midX, y: page.midY)
    }
    static func reduce(value: inout [Target: Anchor<CGRect>],
                       nextValue: () -> [Target: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The arrow in its circle, shared by the flight and the badge it becomes.
private struct DownloadArrow: View {
    var body: some View {
        Image(systemName: "arrow.down.circle")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(.white)
            .background(Circle().fill(.black).padding(1))
            .shadow(color: .white.opacity(0.1), radius: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The landed arrow: a small hop from where it fell to the target's top-trailing corner.
struct DownloadBadge: View {
    let from: CGPoint
    let to: CGPoint
    var still = false
    @State private var hopped: Bool

    init(from: CGPoint, to: CGPoint, still: Bool = false) {
        self.from = from; self.to = to; self.still = still
        _hopped = State(initialValue: still)   // under Reduce Motion it starts settled
    }

    var body: some View {
        DownloadArrow()
            .scaleEffect(hopped ? 0.68 : 0.8)
            .position(hopped ? to : from)
            .task {
                guard !hopped else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.73)) { hopped = true }
            }
    }
}

struct DownloadFlight: View {
    let source: CGPoint
    let destination: CGPoint
    @State private var progress: CGFloat = 0

    var body: some View {
        DownloadArrow()
            .modifier(FlightPosition(progress: progress, source: source, destination: destination))
            .task {
                // Linear time: the throw's own curve (steady across, gravity down) is the easing.
                withAnimation(.linear(duration: DownloadFeedback.flightSeconds)) { progress = 1 }
            }
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
        content
            .scaleEffect(1 - 0.2 * progress)
            .position(DownloadFlight.point(progress, from: source, to: destination))
    }
}

extension DownloadFlight {
    /// How high the throw rises above the higher of its two ends.
    static let rise: CGFloat = 230

    /// Where the arrow falls: through the bucket to just under it, toward its trailing side.
    static func landing(on target: CGRect) -> CGPoint {
        CGPoint(x: target.maxX - 0.26 * target.width, y: target.maxY + 0.3 * target.height)
    }

    /// Where it settles: over the bucket's top-trailing corner.
    static func badge(on target: CGRect) -> CGPoint {
        CGPoint(x: target.maxX - 0.09 * target.width, y: target.minY + 0.09 * target.height)
    }

    /// A thrown arc: steady speed across, a parabola down (up, an apex, then falling into
    /// the target). The apex stays at least 24pt inside the window's top.
    nonisolated static func point(_ t: CGFloat, from source: CGPoint, to destination: CGPoint) -> CGPoint {
        let high = min(source.y, destination.y)
        let apex = min(high, max(24, high - rise))
        let up = (max(0, source.y - apex)).squareRoot(), down = (max(0, destination.y - apex)).squareRoot()
        let peak = up + down == 0 ? 0 : up / (up + down)
        let y = apex + (up + down) * (up + down) * (t - peak) * (t - peak)
        return CGPoint(x: source.x + (destination.x - source.x) * t, y: y)
    }
}
