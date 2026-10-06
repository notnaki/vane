import SwiftUI

/// One continuous outline: the front flap leans forward as a folder opens.
struct FolderIcon: View {
    var open: Bool

    var body: some View {
        FolderOutline(openness: open ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .animation(Motion.reduced ? nil : Look.quick, value: open)
            .accessibilityHidden(true)
    }
}

private struct FolderOutline: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let lean = openness * 0.12
        let top = 0.32 + openness * 0.12
        var path = Path()
        // Back panel and tab retain their identity throughout the transform.
        path.move(to: point(0.14, 0.82))
        path.addLine(to: point(0.07, 0.23))
        path.addQuadCurve(to: point(0.13, 0.17), control: point(0.06, 0.17))
        path.addLine(to: point(0.37, 0.17))
        path.addLine(to: point(0.46, 0.28))
        path.addLine(to: point(0.79, 0.28))
        path.addQuadCurve(to: point(0.85, 0.34), control: point(0.85, 0.28))
        path.addLine(to: point(0.85, top))
        // The same front panel moves, rather than swapping closed/open glyphs.
        path.move(to: point(0.14, 0.82))
        path.addLine(to: point(0.12 + lean, top))
        path.addQuadCurve(to: point(0.18 + lean, top - 0.03),
                          control: point(0.13 + lean, top - 0.03))
        path.addLine(to: point(0.79 + lean, top - 0.03))
        path.addQuadCurve(to: point(0.85 + lean, top + 0.03),
                          control: point(0.87 + lean, top - 0.03))
        path.addLine(to: point(0.79, 0.82))
        path.addQuadCurve(to: point(0.74, 0.86), control: point(0.78, 0.86))
        path.addLine(to: point(0.19, 0.86))
        path.addQuadCurve(to: point(0.14, 0.82), control: point(0.14, 0.86))
        return path
    }
}
