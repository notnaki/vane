import SwiftUI

/// Native scrolling writes into its position binding when fingers take ownership.
/// Keep those writes below the content builder so a viewport move does not rebuild
/// stationary chrome or the command field and its result catalogue.
struct ScrollViewportPosition: ViewModifier {
    var initialOffset: CGFloat = 0
    var resetRequest: Int = 0
    var resetIdentity: UUID?
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear {
                if initialOffset != 0 { position.scrollTo(y: initialOffset) }
            }
            .onChange(of: resetRequest) { position.scrollTo(edge: .top) }
            .onChange(of: resetIdentity) { position.scrollTo(y: initialOffset) }
    }
}
