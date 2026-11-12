import SwiftUI

/// A low, open-front folder drawn around the row's favicon slot.
struct FolderIcon: View {
    var open: Bool
    var previewing = false

    var body: some View {
        FolderOutline(openness: open ? 1 : previewing ? 0.22 : 0)
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .animation(Motion.reduced ? nil : Look.quick, value: open)
            .animation(Motion.reduced ? nil : Look.feedback, value: previewing)
            .transaction { if Motion.reduced { $0.disablesAnimations = true } }
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
        // The outline is wider than the 16pt favicon slot without moving the title.
        // Both states keep the reference's sloping back and trapezoidal front flap.
        let shoulder = -0.10 - openness * 0.02
        let top = 0.31 + openness * 0.04
        let frontLeft = 0.34 + openness * 0.03
        let frontRight = 1.18 + openness * 0.02
        var path = Path()
        path.move(to: point(0.17, 0.91))
        path.addLine(to: point(shoulder, 0.17))
        path.addQuadCurve(to: point(shoulder + 0.06, 0.09),
                          control: point(shoulder - 0.02, 0.09))
        path.addLine(to: point(0.24, 0.09))
        path.addQuadCurve(to: point(0.32, 0.12), control: point(0.29, 0.09))
        path.addLine(to: point(0.45, 0.23))
        path.addLine(to: point(0.80, 0.23))
        path.addQuadCurve(to: point(0.88, 0.31), control: point(0.88, 0.23))
        path.addLine(to: point(0.88, top))
        // Keep identical path topology so hover and disclosure interpolate smoothly.
        path.move(to: point(0.17, 0.91))
        path.addLine(to: point(frontLeft, top + 0.07))
        path.addQuadCurve(to: point(frontLeft + 0.07, top),
                          control: point(frontLeft, top))
        path.addLine(to: point(frontRight - 0.07, top))
        path.addQuadCurve(to: point(frontRight, top + 0.07),
                          control: point(frontRight + 0.02, top))
        path.addLine(to: point(0.96, 0.85))
        path.addQuadCurve(to: point(0.87, 0.92), control: point(0.94, 0.92))
        path.addLine(to: point(0.23, 0.92))
        path.addQuadCurve(to: point(0.17, 0.91), control: point(0.19, 0.92))
        path.closeSubpath()
        return path
    }
}
