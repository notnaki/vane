import SwiftUI

/// Native scrolling writes into its position binding when fingers take ownership.
/// Keep those writes below the content builder so a viewport move does not rebuild
/// stationary chrome or the command field and its result catalogue.
struct ScrollViewportPosition: ViewModifier {
    var initialOffset: CGFloat = 0
    var resetRequest: Int = 0
    var resetIdentity: UUID?
    var offersScrollToTop = false
    var animatesScrollToTop = true
    @State private var position = ScrollPosition()
    @State private var showsScrollToTop = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear {
                if initialOffset != 0 { position.scrollTo(y: initialOffset) }
            }
            .onChange(of: resetRequest) { position.scrollTo(edge: .top) }
            .onChange(of: resetIdentity) { position.scrollTo(y: initialOffset) }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                offersScrollToTop && geometry.visibleRect.minY > 3 * (Look.rowHeight + Look.rowGap)
                    && geometry.contentSize.height > geometry.containerSize.height
            } action: { _, visible in
                showsScrollToTop = visible
            }
            .overlay(alignment: .top) {
                if showsScrollToTop {
                    Button {
                        Motion.animate(.easeOut(duration: Look.listSeconds)) { position.scrollTo(edge: .top) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(.circle)
                    }
                    .buttonStyle(SidebarScrollToTopStyle())
                    .accessibilityLabel("Scroll to Top")
                    .vaneTooltip("Scroll to Top")
                    .padding(4)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)).combined(with: .offset(y: 5)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
            }
            .animation(animatesScrollToTop ? Look.floatingSidebarAnimation : nil, value: showsScrollToTop)
            .vaneMotionPolicy()
    }
}

private struct SidebarScrollToTopStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var hovered = false
    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(white: 0.08))
            .background(Color(white: configuration.isPressed ? 0.85 : hovered ? 1 : 0.95), in: .circle)
            .shadow(color: .black.opacity(hovered ? 0.23 : 0.18), radius: hovered ? 5 : 4, y: hovered ? 3 : 2)
            .scaleEffect(reduced ? 1 : configuration.isPressed ? 0.93 : hovered ? 1.04 : 1)
            .offset(y: reduced || configuration.isPressed || !hovered ? 0 : -1)
            .animation(reduced ? nil : Look.floatingSidebarAnimation, value: configuration.isPressed)
            .animation(reduced ? nil : Look.feedback, value: hovered)
            .onHover { hovered = $0 }
            .vaneMotionPolicy()
    }
}
