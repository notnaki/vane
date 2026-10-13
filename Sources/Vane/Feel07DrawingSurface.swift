import SwiftUI

/// Only this surface updates for each raw pointer sample. The populated board and
/// its controls remain outside the stroke's state dependency. No delayed smoothing.
struct Feel07DrawingSurface: View {
    let kind: EaselItem.Kind
    let color: String
    let strokeWidth: Double
    let fillColor: String?
    let style: EaselObjectStyle
    let finish: ([EaselPoint]) -> Void
    @State private var points: [EaselPoint] = []
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("easel-canvas"))
                    .onChanged { append($0.location) }
                    .onEnded { value in
                        append(value.location)
                        let completed = points
                        points = []
                        finish(completed)
                    })
            EaselDrawingPreview(points: points, kind: kind, color: color, strokeWidth: strokeWidth,
                                fillColor: fillColor, style: style)
                .allowsHitTesting(false)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onChange(of: kind) { points = [] }
    }
    private func append(_ point: CGPoint) {
        guard points.count < 5000 else { return }
        points.append(.init(x: min(max(0, point.x), EaselStore.canvasWidth),
                            y: min(max(0, point.y), EaselStore.canvasHeight)))
    }
}
